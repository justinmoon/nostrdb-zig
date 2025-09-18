const std = @import("std");
const ascii = std.ascii;

pub const Allocator = std.mem.Allocator;

pub const ContactKey = [32]u8;

const zero_key = [_]u8{0} ** 32;

pub const ContactList = struct {
    event_id: ContactKey = zero_key,
    created_at: u64 = 0,
    follows: std.AutoHashMap(ContactKey, void),

    pub fn init(allocator: Allocator) ContactList {
        return .{ .follows = std.AutoHashMap(ContactKey, void).init(allocator) };
    }

    pub fn deinit(self: *ContactList) void {
        self.follows.deinit();
    }
};

pub const Store = struct {
    allocator: Allocator,
    lists: std.AutoHashMap(ContactKey, ContactList),

    pub fn init(allocator: Allocator) Store {
        return .{
            .allocator = allocator,
            .lists = std.AutoHashMap(ContactKey, ContactList).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.lists.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr.*;
            list.deinit();
        }
        self.lists.deinit();
    }

    pub fn get(self: *Store, npub: ContactKey) ?*ContactList {
        return self.lists.getPtr(npub);
    }

    pub fn ensure(self: *Store, npub: ContactKey) !*ContactList {
        if (self.lists.getPtr(npub)) |existing| return existing;
        var list = ContactList.init(self.allocator);
        const gop = try self.lists.put(npub, list);
        return gop.value_ptr;
    }

    pub fn applyEvent(self: *Store, event: *ContactEvent) StoreError!void {
        defer event.deinit();

        var list = try self.ensure(event.author);

        if (list.created_at > event.created_at) return;
        if (list.created_at == event.created_at) {
            if (std.mem.lessThan(u8, event.event_id[0..], list.event_id[0..])) {
                return;
            }
        }

        list.follows.clearRetainingCapacity();
        for (event.follows) |follow| {
            try list.follows.put(follow, {});
        }
        list.created_at = event.created_at;
        list.event_id = event.event_id;
    }
};

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

    const StdParseError = std.json.ParseError(std.json.Value);
    const ExtraParseError = error{
        UnexpectedRoot,
        MissingField,
        InvalidType,
        InvalidHex,
        InvalidTag,
    };
    pub const ParseError = StdParseError || ExtraParseError || Allocator.Error;

    pub fn init(allocator: Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }

    pub fn parse(self: *Parser, json: []const u8) ParseError!ContactEvent {
        var follows_list = std.ArrayList(ContactKey).init(self.allocator);
        var cleanup_list = true;
        errdefer if (cleanup_list) follows_list.deinit();

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json, .{});
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
            .integer => |x| std.math.cast(u64, x) catch ExtraParseError.InvalidType,
            .float => |x| std.math.cast(u64, @intFromFloat(@floor(x))) catch ExtraParseError.InvalidType,
            .string => |s| std.fmt.parseInt(u64, s, 10) catch ExtraParseError.InvalidType,
            .number_string => |s| std.fmt.parseInt(u64, s, 10) catch ExtraParseError.InvalidType,
            else => ExtraParseError.InvalidType,
        };
    }

    fn getStringField(obj: std.json.Object, name: []const u8) ParseError![]const u8 {
        const value = obj.get(name) orelse return ExtraParseError.MissingField;
        if (value != .string) return ExtraParseError.InvalidType;
        return value.string;
    }

    fn hexToKey(hex: []const u8) ParseError!ContactKey {
        if (hex.len != 64) return ExtraParseError.InvalidHex;
        var out: ContactKey = undefined;
        const written = std.fmt.hexToBytes(out[0..], hex) catch return ExtraParseError.InvalidHex;
        if (written != 32) return ExtraParseError.InvalidHex;
        return out;
    }
};

pub const StoreError = Allocator.Error;

pub const Fetcher = struct {
    allocator: Allocator,
    store: *Store,
    parser: Parser,

    pub const FetchError = Allocator.Error || net.RelayClient.ConnectError || net.RelayClient.SendError || ndb.Error || proto.ReqBuilderError || Parser.ParseError || error{CompletionTimeout};

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
        if (relays.len == 0) return;

        var filter = try proto.buildContactsFilter(self.allocator, .{ .author = npub });
        defer self.allocator.free(filter);

        var clients = try self.allocator.alloc(ClientState, relays.len);
        var initialized: usize = 0;
        errdefer {
            var idx: usize = 0;
            while (idx < initialized) : (idx += 1) {
                clients[idx].deinit(self.allocator);
            }
            self.allocator.free(clients);
        }

        for (relays, 0..) |relay_url, idx| {
            clients[idx] = try ClientState.init(self.allocator, relay_url, filter);
            initialized += 1;
        }

        var active = initialized;
        var idle_loops: usize = 0;

        while (active > 0) {
            var progressed = false;

            for (clients[0..initialized]) |*entry| {
                if (entry.done) continue;
                const msg_opt = try entry.client.nextMessage(2_000);
                if (msg_opt) |msg| {
                    progressed = true;
                    try self.handleMessage(msg, npub, db, entry);
                }
                if (entry.done) {
                    active -= 1;
                    const close_msg = try proto.buildClose(self.allocator, entry.sub_id);
                    defer self.allocator.free(close_msg);
                    entry.client.sendText(close_msg) catch |err| {
                        log.warn("failed to send CLOSE frame: {}", .{err});
                    };
                }
            }

            if (!progressed) {
                idle_loops += 1;
                if (idle_loops >= 3) break;
            } else {
                idle_loops = 0;
            }
        }

        var idx: usize = 0;
        while (idx < initialized) : (idx += 1) {
            clients[idx].deinit(self.allocator);
        }
        self.allocator.free(clients);

        if (active != 0) {
            return error.CompletionTimeout;
        }
    }

    fn handleMessage(self: *Fetcher, msg: net.RelayMessage, npub: ContactKey, db: *ndb.Ndb, entry: *ClientState) FetchError!void {
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

        fn init(allocator: Allocator, relay_url: []const u8, filter: []const u8) !ClientState {
            var client = try net.RelayClient.init(.{
                .allocator = allocator,
                .url = relay_url,
            });
            errdefer client.deinit();

            try client.connect(null);

            var sub_id = try proto.nextSubId(allocator);
            errdefer allocator.free(sub_id);

            const filters = [_][]const u8{filter};
            var req = try proto.buildReq(allocator, sub_id, &filters);
            defer allocator.free(req);

            try client.sendText(req);

            return .{
                .client = client,
                .sub_id = sub_id,
                .done = false,
            };
        }

        fn deinit(self: *ClientState, allocator: Allocator) void {
            self.client.close();
            self.client.deinit();
            allocator.free(self.sub_id);
        }
    };
};
