const std = @import("std");
const ascii = std.ascii;
const proto = @import("proto");
const net = @import("net");
const ndb = @import("ndb");
const diag = @import("ingdiag");
const clmdb = @cImport({
    @cInclude("lmdb.h");
});

const log = std.log.scoped(.contacts);

pub const Allocator = std.mem.Allocator;

pub const ContactKey = [32]u8;

const zero_key = [_]u8{0} ** 32;

const LmdbError = error{
    MapFull,
    NotFound,
    KeyExist,
    TxnFull,
    Corrupt,
    Unexpected,
};

pub const ContactList = struct {
    allocator: Allocator,
    event_id: ContactKey = zero_key,
    created_at: u64 = 0,
    follows: []ContactKey = &[_]ContactKey{},

    pub fn deinit(self: *ContactList) void {
        self.allocator.free(self.follows);
        self.* = undefined;
    }

    pub fn contains(self: ContactList, key: ContactKey) bool {
        for (self.follows) |follow| {
            if (std.mem.eql(u8, follow[0..], key[0..])) return true;
        }
        return false;
    }
};

pub const Options = struct {
    path: []const u8,
    map_size: usize = 32 * 1024 * 1024,
};

pub const Store = struct {
    allocator: Allocator,
    env: *clmdb.MDB_env,
    lists_dbi: clmdb.MDB_dbi,

    pub fn init(allocator: Allocator, options: Options) !Store {
        try ensureDirectory(options.path);

        var env_ptr: ?*clmdb.MDB_env = null;
        try check(clmdb.mdb_env_create(&env_ptr));
        errdefer clmdb.mdb_env_close(env_ptr.?);

        try check(clmdb.mdb_env_set_maxdbs(env_ptr.?, 4));
        try check(clmdb.mdb_env_set_mapsize(env_ptr.?, options.map_size));

        const path_z = try allocator.dupeZ(u8, options.path);
        defer allocator.free(path_z);

        try check(clmdb.mdb_env_open(env_ptr.?, @ptrCast(path_z.ptr), 0, 0o664));

        var txn_ptr: ?*clmdb.MDB_txn = null;
        try check(clmdb.mdb_txn_begin(env_ptr.?, null, 0, &txn_ptr));
        errdefer clmdb.mdb_txn_abort(txn_ptr.?);

        const lists_name = try allocator.dupeZ(u8, "contact_lists");
        defer allocator.free(lists_name);
        var lists_dbi: clmdb.MDB_dbi = undefined;
        try check(clmdb.mdb_dbi_open(txn_ptr.?, @ptrCast(lists_name.ptr), clmdb.MDB_CREATE, &lists_dbi));

        try check(clmdb.mdb_txn_commit(txn_ptr.?));

        return Store{
            .allocator = allocator,
            .env = env_ptr.?,
            .lists_dbi = lists_dbi,
        };
    }

    pub fn deinit(self: *Store) void {
        clmdb.mdb_env_close(self.env);
        self.* = undefined;
    }

    pub fn get(self: *Store, npub: ContactKey) StoreError!?ContactList {
        var txn_ptr: ?*clmdb.MDB_txn = null;
        try check(clmdb.mdb_txn_begin(self.env, null, clmdb.MDB_RDONLY, &txn_ptr));
        defer clmdb.mdb_txn_abort(txn_ptr.?);

        var key = mdbVal(npub[0..]);
        var value: clmdb.MDB_val = undefined;
        const rc = clmdb.mdb_get(txn_ptr.?, self.lists_dbi, &key, &value);
        if (rc == clmdb.MDB_NOTFOUND) {
            return null;
        }
        try check(rc);

        const parsed = try parseStoredList(self, value);
        return @as(?ContactList, parsed);
    }

    pub fn applyEvent(self: *Store, event: *ContactEvent) StoreError!void {
        defer event.deinit();

        var txn_ptr: ?*clmdb.MDB_txn = null;
        try check(clmdb.mdb_txn_begin(self.env, null, 0, &txn_ptr));
        errdefer clmdb.mdb_txn_abort(txn_ptr.?);

        var committed = false;
        defer if (!committed) clmdb.mdb_txn_abort(txn_ptr.?);

        var key = mdbVal(event.author[0..]);
        var existing_val: clmdb.MDB_val = undefined;
        const rc = clmdb.mdb_get(txn_ptr.?, self.lists_dbi, &key, &existing_val);
        if (rc != clmdb.MDB_NOTFOUND) {
            try check(rc);
            const existing = try parseStoredMeta(existing_val);
            if (existing.created_at > event.created_at) {
                return;
            }
            if (existing.created_at == event.created_at and std.mem.lessThan(u8, event.event_id[0..], existing.event_id[0..])) {
                return;
            }
        }

        const follow_count = event.follows.len;
        if (follow_count > std.math.maxInt(u32)) return error.TooManyFollows;
        const stored_count: u32 = @intCast(follow_count);
        const total_len = 8 + 32 + 4 + follow_count * 32;
        var buf = try self.allocator.alloc(u8, total_len);
        defer self.allocator.free(buf);

        std.mem.writeInt(u64, buf[0..8], event.created_at, .little);
        @memcpy(buf[8..40], event.event_id[0..]);
        std.mem.writeInt(u32, buf[40..44], stored_count, .little);

        var offset: usize = 44;
        for (event.follows) |follow| {
            @memcpy(buf[offset .. offset + 32], follow[0..]);
            offset += 32;
        }

        var value = mdbVal(buf);
        try check(clmdb.mdb_put(txn_ptr.?, self.lists_dbi, &key, &value, 0));

        try check(clmdb.mdb_txn_commit(txn_ptr.?));
        committed = true;
    }
};

const StoredMeta = struct {
    created_at: u64,
    event_id: ContactKey,
};

fn parseStoredMeta(val: clmdb.MDB_val) StoreError!StoredMeta {
    const bytes = mdbSliceConst(val);
    if (bytes.len < 40) return error.Corrupt;
    var event_id: ContactKey = undefined;
    @memcpy(event_id[0..], bytes[8..40]);
    return StoredMeta{
        .created_at = std.mem.readInt(u64, bytes[0..8], .little),
        .event_id = event_id,
    };
}

fn parseStoredList(self: *Store, val: clmdb.MDB_val) StoreError!ContactList {
    const bytes = mdbSliceConst(val);
    if (bytes.len < 44) return error.Corrupt;
    const created_at = std.mem.readInt(u64, bytes[0..8], .little);
    var event_id: ContactKey = undefined;
    @memcpy(event_id[0..], bytes[8..40]);
    const count = std.mem.readInt(u32, bytes[40..44], .little);
    const required = 44 + @as(usize, count) * 32;
    if (bytes.len != required) return error.Corrupt;

    const follows_bytes = bytes[44..];
    const count_usize: usize = @intCast(count);
    const follows = try self.allocator.alloc(ContactKey, count_usize);
    errdefer self.allocator.free(follows);

    var offset: usize = 0;
    var idx: usize = 0;
    while (idx < count_usize) : (idx += 1) {
        @memcpy(follows[idx][0..], follows_bytes[offset .. offset + 32]);
        offset += 32;
    }

    return ContactList{
        .allocator = self.allocator,
        .event_id = event_id,
        .created_at = created_at,
        .follows = follows,
    };
}

fn ensureDirectory(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn mdbSliceConst(val: clmdb.MDB_val) []const u8 {
    const ptr: [*]const u8 = @ptrCast(val.mv_data);
    return ptr[0..val.mv_size];
}

fn mdbVal(bytes: []const u8) clmdb.MDB_val {
    return .{
        .mv_size = bytes.len,
        .mv_data = @ptrCast(@constCast(bytes.ptr)),
    };
}

fn check(rc: c_int) LmdbError!void {
    if (rc != 0) {
        return mapError(rc);
    }
}

fn mapError(rc: c_int) LmdbError {
    return switch (rc) {
        clmdb.MDB_NOTFOUND => error.NotFound,
        clmdb.MDB_MAP_FULL => error.MapFull,
        clmdb.MDB_KEYEXIST => error.KeyExist,
        clmdb.MDB_TXN_FULL => error.TxnFull,
        clmdb.MDB_CORRUPTED, clmdb.MDB_PAGE_NOTFOUND => error.Corrupt,
        else => error.Unexpected,
    };
}

pub const ContactEvent = struct {
    allocator: Allocator,
    author: ContactKey,
    created_at: u64,
    event_id: [32]u8,
    follows: []const ContactKey,

    pub fn deinit(self: *ContactEvent) void {
        self.allocator.free(self.follows);
        self.* = undefined;
    }
};

pub const Parser = struct {
    allocator: Allocator,

    const ExtraParseError = error{
        UnexpectedRoot,
        MissingField,
        InvalidType,
        InvalidHex,
        InvalidTag,
        InvalidJson,
    };
    pub const ParseError = ExtraParseError || Allocator.Error;

    pub fn init(allocator: Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }

    pub fn parse(self: *Parser, json: []const u8) ParseError!ContactEvent {
        var follows_list = std.array_list.Managed(ContactKey).init(self.allocator);
        var cleanup_list = true;
        errdefer if (cleanup_list) follows_list.deinit();

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ExtraParseError.InvalidJson,
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return ExtraParseError.UnexpectedRoot;

        const object = root.object;

        const author_hex = try getStringField(object, "pubkey");
        const event_id_hex = try getStringField(object, "id");
        const created_at_value = object.get("created_at") orelse return ExtraParseError.MissingField;
        const tags_value = object.get("tags") orelse return ExtraParseError.MissingField;

        const author = try hexToKey(author_hex);
        const event_id = try hexToKey(event_id_hex);
        const created_at = try parseTimestamp(created_at_value);

        if (tags_value != .array) return ExtraParseError.InvalidType;

        const tags = tags_value.array.items;
        for (tags) |tag| {
            if (tag != .array) continue;
            const parts = tag.array.items;
            if (parts.len < 2) continue;
            const tag_name = parts[0];
            if (tag_name != .string) continue;
            if (!ascii.eqlIgnoreCase(tag_name.string, "p")) continue;

            const pub_str = parts[1];
            if (pub_str != .string) return ExtraParseError.InvalidTag;
            const follow = try hexToKey(pub_str.string);
            try follows_list.append(follow);
        }

        const follows = try follows_list.toOwnedSlice();
        cleanup_list = false;

        return ContactEvent{
            .allocator = self.allocator,
            .author = author,
            .created_at = created_at,
            .event_id = event_id,
            .follows = follows,
        };
    }

    fn parseTimestamp(value: std.json.Value) ParseError!u64 {
        return switch (value) {
            .integer => |x| std.math.cast(u64, x) orelse return ExtraParseError.InvalidType,
            .float => ExtraParseError.InvalidType,
            .string => |s| std.fmt.parseInt(u64, s, 10) catch ExtraParseError.InvalidType,
            .number_string => |s| std.fmt.parseInt(u64, s, 10) catch ExtraParseError.InvalidType,
            else => ExtraParseError.InvalidType,
        };
    }

    fn getStringField(obj: std.json.ObjectMap, name: []const u8) ParseError![]const u8 {
        const value = obj.get(name) orelse return ExtraParseError.MissingField;
        if (value != .string) return ExtraParseError.InvalidType;
        return value.string;
    }

    fn hexToKey(hex: []const u8) ParseError!ContactKey {
        if (hex.len != 64) return ExtraParseError.InvalidHex;
        var out: ContactKey = undefined;
        const decoded = std.fmt.hexToBytes(out[0..], hex) catch return ExtraParseError.InvalidHex;
        if (decoded.len != 32) return ExtraParseError.InvalidHex;
        return out;
    }
};

pub const StoreError = Allocator.Error || LmdbError || error{TooManyFollows};

pub const Fetcher = struct {
    allocator: Allocator,
    store: *Store,
    parser: Parser,

    pub const FetchError = Allocator.Error || net.RelayClientConnectError || net.RelayClientSendError || ndb.Error || proto.ReqBuilderError || Parser.ParseError || StoreError || error{CompletionTimeout, NoAvailableRelays};

    pub fn init(allocator: Allocator, store: *Store) Fetcher {
        return .{
            .allocator = allocator,
            .store = store,
            .parser = Parser.init(allocator),
        };
    }

    pub fn deinit(self: *Fetcher) void {
        self.parser.deinit();
    }

    pub fn fetchContacts(self: *Fetcher, npub: ContactKey, relays: []const []const u8, db: *ndb.Ndb) FetchError!void {
        // Backwards-compatible wrapper without diagnostics and origin
        return self.fetchContactsEx(npub, relays, db, null, 0, null);
    }

    pub fn fetchContactsEx(
        self: *Fetcher,
        npub: ContactKey,
        relays: []const []const u8,
        db: *ndb.Ndb,
        diag_states: ?[]diag.RelayDiag,
        job_start_ms: u64,
        origin: ?[]const u8,
    ) FetchError!void {
        if (relays.len == 0) return;

        const filter = try proto.buildContactsFilter(self.allocator, .{ .author = npub });
        defer self.allocator.free(filter);

        var clients = std.array_list.Managed(ClientState).init(self.allocator);
        defer clients.deinit();

        var connected: usize = 0;
        for (relays, 0..) |relay_url, idx| {
            const now_ms: u64 = @intCast(std.time.milliTimestamp());
            if (diag_states) |ds| {
                ds[idx].attempts += 1;
                ds[idx].last_change_ms = if (job_start_ms == 0) 0 else now_ms - job_start_ms;
            }
            log.info("contacts: connecting to {s}", .{relay_url});
            var client = net.RelayClient.init(.{
                .allocator = self.allocator,
                .url = relay_url,
                .origin = origin,
            }) catch |err| {
                if (diag_states) |ds| ds[idx].last_error = self.allocator.dupe(u8, @errorName(err)) catch null;
                log.warn("contacts: init failed url={s} err={s}", .{ relay_url, @errorName(err) });
                continue;
            };
            errdefer client.deinit();

            client.connect(null) catch |err| {
                if (diag_states) |ds| ds[idx].last_error = self.allocator.dupe(u8, @errorName(err)) catch null;
                log.warn("contacts: connect failed url={s} err={s}", .{ relay_url, @errorName(err) });
                client.deinit();
                continue;
            };

            const sub_id = try proto.nextSubId(self.allocator);
            errdefer self.allocator.free(sub_id);

            const filters = [_][]const u8{filter};
            const req = try proto.buildReq(self.allocator, sub_id, &filters);
            defer self.allocator.free(req);

            client.sendText(req) catch |err| {
                if (diag_states) |ds| ds[idx].last_error = self.allocator.dupe(u8, @errorName(err)) catch null;
                log.warn("contacts: send REQ failed url={s} err={s}", .{ relay_url, @errorName(err) });
                client.close();
                client.deinit();
                continue;
            };
            log.info("contacts: REQ sent to {s}", .{relay_url});

            const st = ClientState{ .client = client, .sub_id = sub_id, .done = false, .relay_index = idx };
            try clients.append(st);
            connected += 1;
        }

        if (connected == 0) return error.NoAvailableRelays;

        var active = connected;
        var idle_loops: usize = 0;

        while (active > 0) {
            var progressed = false;
            var i: usize = 0;
            while (i < clients.items.len) : (i += 1) {
                var entry = &clients.items[i];
                if (entry.done) continue;
                const msg_opt = entry.client.nextMessage(2_000) catch |err| switch (err) {
                    error.Timeout => null,
                };
                if (msg_opt) |msg| {
                    progressed = true;
                    try self.handleMessage(msg, npub, db, entry, diag_states, job_start_ms);
                }
                if (entry.done) {
                    active -= 1;
                    // Avoid sending CLOSE frames here; we'll teardown on cleanup
                }
            }

            if (!progressed) {
                idle_loops += 1;
                if (idle_loops >= 3) break;
            } else {
                idle_loops = 0;
            }
        }

        // Cleanup
        var j: usize = 0;
        while (j < clients.items.len) : (j += 1) {
            clients.items[j].deinit(self.allocator);
        }

        if (active != 0) {
            return error.CompletionTimeout;
        }
    }

    fn handleMessage(
        self: *Fetcher,
        msg: net.RelayMessage,
        npub: ContactKey,
        db: *ndb.Ndb,
        entry: *ClientState,
        diag_states: ?[]diag.RelayDiag,
        job_start_ms: u64,
    ) FetchError!void {
        var owned = msg;
        defer owned.deinit(self.allocator);

        switch (owned) {
            .event => |event| {
                if (!std.mem.eql(u8, event.subId(), entry.sub_id)) return;
                try db.processEvent(event.raw());
                var contact_event = try self.parser.parse(event.eventJson());
                if (std.mem.eql(u8, contact_event.author[0..], npub[0..])) {
                    try self.store.applyEvent(&contact_event);
                } else {
                    contact_event.deinit();
                }
            },
            .eose => |eose| {
                if (!std.mem.eql(u8, eose.subId(), entry.sub_id)) return;
                entry.done = true;
                const now_ms: u64 = @intCast(std.time.milliTimestamp());
                if (diag_states) |ds| {
                    if (entry.relay_index < ds.len) {
                        ds[entry.relay_index].eose = true;
                        ds[entry.relay_index].last_change_ms = if (job_start_ms == 0) 0 else now_ms - job_start_ms;
                    }
                }
                log.info("contacts: EOSE from relay_index={d}", .{entry.relay_index});
            },
            .notice => |notice| {
                log.info("relay notice: {s}", .{notice.text()});
            },
            else => {},
        }
    }

    const ClientState = struct {
        client: net.RelayClient,
        sub_id: []u8,
        done: bool = false,
        relay_index: usize = 0,

        fn init(allocator: Allocator, relay_url: []const u8, filter: []const u8) !ClientState {
            var client = try net.RelayClient.init(.{
                .allocator = allocator,
                .url = relay_url,
            });
            errdefer client.deinit();

            try client.connect(null);

            const sub_id = try proto.nextSubId(allocator);
            errdefer allocator.free(sub_id);

            const filters = [_][]const u8{filter};
            const req = try proto.buildReq(allocator, sub_id, &filters);
            log.info("contacts REQ to {s}: {s}", .{ relay_url, req });
            defer allocator.free(req);

            try client.sendText(req);

            return .{
                .client = client,
                .sub_id = sub_id,
                .done = false,
                .relay_index = 0,
            };
        }

        fn deinit(self: *ClientState, allocator: Allocator) void {
            self.client.deinit();
            allocator.free(self.sub_id);
        }
    };
};
