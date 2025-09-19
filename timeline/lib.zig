const std = @import("std");
const clmdb = @cImport({
    @cInclude("lmdb.h");
});

pub const Allocator = std.mem.Allocator;

pub const EventId = [32]u8;
pub const PubKey = [32]u8;

pub const TimelineEntry = struct {
    event_id: EventId,
    created_at: u64,
    author: PubKey,
};

pub const EventRecord = struct {
    allocator: Allocator,
    payload: []u8,
    created_at: u64,
    author: PubKey,

    pub fn deinit(self: *EventRecord) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const TimelineMeta = struct {
    latest_created_at: u64 = 0,
    count: usize = 0,
};

pub const TimelineSnapshot = struct {
    allocator: Allocator,
    entries: []TimelineEntry,
    meta: TimelineMeta,

    pub fn deinit(self: *TimelineSnapshot) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

const LmdbError = error{
    MapFull,
    NotFound,
    KeyExist,
    TxnFull,
    Corrupt,
    Unexpected,
};

pub const Options = struct {
    path: []const u8,
    max_entries: usize,
    map_size: usize = 128 * 1024 * 1024,
};

pub const Store = struct {
    allocator: Allocator,
    env: *clmdb.MDB_env,
    timeline_dbi: clmdb.MDB_dbi,
    events_dbi: clmdb.MDB_dbi,
    meta_dbi: clmdb.MDB_dbi,
    max_entries: usize,

    pub fn init(allocator: Allocator, options: Options) !Store {
        try ensureDirectory(options.path);

        var env_ptr: ?*clmdb.MDB_env = null;
        try check(clmdb.mdb_env_create(&env_ptr));
        errdefer clmdb.mdb_env_close(env_ptr.?);

        try check(clmdb.mdb_env_set_maxdbs(env_ptr.?, 8));
        try check(clmdb.mdb_env_set_mapsize(env_ptr.?, options.map_size));

        const path_z = try allocator.dupeZ(u8, options.path);
        defer allocator.free(path_z);

        try check(clmdb.mdb_env_open(env_ptr.?, @ptrCast(path_z.ptr), 0, 0o664));

        var txn_ptr: ?*clmdb.MDB_txn = null;
        try check(clmdb.mdb_txn_begin(env_ptr.?, null, 0, &txn_ptr));
        errdefer clmdb.mdb_txn_abort(txn_ptr.?);

        const timeline_name = try allocator.dupeZ(u8, "timeline_entries");
        defer allocator.free(timeline_name);
        var timeline_dbi: clmdb.MDB_dbi = undefined;
        try check(clmdb.mdb_dbi_open(txn_ptr.?, @ptrCast(timeline_name.ptr), clmdb.MDB_CREATE, &timeline_dbi));

        const events_name = try allocator.dupeZ(u8, "timeline_events");
        defer allocator.free(events_name);
        var events_dbi: clmdb.MDB_dbi = undefined;
        try check(clmdb.mdb_dbi_open(txn_ptr.?, @ptrCast(events_name.ptr), clmdb.MDB_CREATE, &events_dbi));

        const meta_name = try allocator.dupeZ(u8, "timeline_meta");
        defer allocator.free(meta_name);
        var meta_dbi: clmdb.MDB_dbi = undefined;
        try check(clmdb.mdb_dbi_open(txn_ptr.?, @ptrCast(meta_name.ptr), clmdb.MDB_CREATE, &meta_dbi));

        try check(clmdb.mdb_txn_commit(txn_ptr.?));

        return Store{
            .allocator = allocator,
            .env = env_ptr.?,
            .timeline_dbi = timeline_dbi,
            .events_dbi = events_dbi,
            .meta_dbi = meta_dbi,
            .max_entries = options.max_entries,
        };
    }

    pub fn deinit(self: *Store) void {
        clmdb.mdb_env_close(self.env);
        self.* = undefined;
    }
};

pub const InsertError = Allocator.Error || LmdbError;
pub const StoreError = Allocator.Error || LmdbError;

pub fn insertEvent(
    store: *Store,
    npub: PubKey,
    entry: TimelineEntry,
    record_payload: []const u8,
) InsertError!void {
    var txn_ptr: ?*clmdb.MDB_txn = null;
    try check(clmdb.mdb_txn_begin(store.env, null, 0, &txn_ptr));
    errdefer clmdb.mdb_txn_abort(txn_ptr.?);

    var committed = false;
    defer if (!committed) clmdb.mdb_txn_abort(txn_ptr.?);

    // Write event payload (ignore duplicates)
    const event_key_buf = entry.event_id;
    var event_key = mdbVal(event_key_buf[0..]);

    const header_len = 8 + 32;
    const total_len = header_len + record_payload.len;
    var event_buf = try store.allocator.alloc(u8, total_len);
    defer store.allocator.free(event_buf);
    std.mem.writeInt(u64, event_buf[0..8], entry.created_at, .little);
    @memcpy(event_buf[8..40], entry.author[0..]);
    @memcpy(event_buf[40..], record_payload);

    var event_val = mdbVal(event_buf);
    const put_event_rc = clmdb.mdb_put(txn_ptr.?, store.events_dbi, &event_key, &event_val, clmdb.MDB_NOOVERWRITE);
    if (put_event_rc != 0 and put_event_rc != clmdb.MDB_KEYEXIST) {
        return mapError(put_event_rc);
    }

    var timeline_key_buf = makeTimelineKey(npub, entry.event_id);
    var timeline_key = mdbVal(timeline_key_buf[0..]);

    var timeline_val_buf: [40]u8 = undefined;
    std.mem.writeInt(u64, timeline_val_buf[0..8], entry.created_at, .little);
    @memcpy(timeline_val_buf[8..40], entry.author[0..]);
    var timeline_val = mdbVal(timeline_val_buf[0..]);

    const put_timeline_rc = clmdb.mdb_put(txn_ptr.?, store.timeline_dbi, &timeline_key, &timeline_val, clmdb.MDB_NOOVERWRITE);
    if (put_timeline_rc == clmdb.MDB_KEYEXIST) {
        committed = true;
        try check(clmdb.mdb_txn_commit(txn_ptr.?));
        return;
    } else if (put_timeline_rc != 0) {
        return mapError(put_timeline_rc);
    }

    const entries = try loadEntriesInternal(store, txn_ptr.?, npub);
    defer store.allocator.free(entries);
    sortEntries(entries);

    const remaining = @min(entries.len, store.max_entries);
    if (entries.len > store.max_entries) {
        var idx: usize = remaining;
        while (idx < entries.len) : (idx += 1) {
            const to_drop = entries[idx];
            var drop_key_buf = makeTimelineKey(npub, to_drop.event_id);
            var drop_key = mdbVal(drop_key_buf[0..]);
            const del_rc = clmdb.mdb_del(txn_ptr.?, store.timeline_dbi, &drop_key, null);
            if (del_rc != 0 and del_rc != clmdb.MDB_NOTFOUND) {
                return mapError(del_rc);
            }

            var drop_event_key = mdbVal(to_drop.event_id[0..]);
            const del_event_rc = clmdb.mdb_del(txn_ptr.?, store.events_dbi, &drop_event_key, null);
            if (del_event_rc != 0 and del_event_rc != clmdb.MDB_NOTFOUND) {
                return mapError(del_event_rc);
            }
        }
    }

    var meta = TimelineMeta{};
    meta.count = remaining;
    if (remaining > 0) {
        meta.latest_created_at = entries[0].created_at;
    }

    try writeMeta(store, txn_ptr.?, npub, meta);

    try check(clmdb.mdb_txn_commit(txn_ptr.?));
    committed = true;
}

pub fn latestCreatedAt(store: *Store, npub: PubKey) StoreError!u64 {
    var txn_ptr: ?*clmdb.MDB_txn = null;
    try check(clmdb.mdb_txn_begin(store.env, null, clmdb.MDB_RDONLY, &txn_ptr));
    defer clmdb.mdb_txn_abort(txn_ptr.?);

    const meta = readMeta(store, txn_ptr.?, npub) catch |err| switch (err) {
        error.NotFound => return 0,
        else => return err,
    };
    return meta.latest_created_at;
}

pub fn getMeta(store: *Store, npub: PubKey) StoreError!TimelineMeta {
    var txn_ptr: ?*clmdb.MDB_txn = null;
    try check(clmdb.mdb_txn_begin(store.env, null, clmdb.MDB_RDONLY, &txn_ptr));
    defer clmdb.mdb_txn_abort(txn_ptr.?);

    return readMeta(store, txn_ptr.?, npub) catch |err| switch (err) {
        error.NotFound => TimelineMeta{},
        else => return err,
    };
}

pub fn loadTimeline(store: *Store, npub: PubKey) StoreError!TimelineSnapshot {
    var txn_ptr: ?*clmdb.MDB_txn = null;
    try check(clmdb.mdb_txn_begin(store.env, null, clmdb.MDB_RDONLY, &txn_ptr));
    defer clmdb.mdb_txn_abort(txn_ptr.?);

    const entries = try loadEntriesInternal(store, txn_ptr.?, npub);
    errdefer store.allocator.free(entries);

    sortEntries(entries);

    var meta = readMeta(store, txn_ptr.?, npub) catch |err| switch (err) {
        error.NotFound => TimelineMeta{},
        else => return err,
    };

    meta.count = entries.len;
    meta.latest_created_at = if (entries.len > 0) entries[0].created_at else 0;

    return TimelineSnapshot{
        .allocator = store.allocator,
        .entries = entries,
        .meta = meta,
    };
}

pub fn getEvent(store: *Store, id: EventId) StoreError!?EventRecord {
    var txn_ptr: ?*clmdb.MDB_txn = null;
    try check(clmdb.mdb_txn_begin(store.env, null, clmdb.MDB_RDONLY, &txn_ptr));
    defer clmdb.mdb_txn_abort(txn_ptr.?);

    var key = mdbVal(id[0..]);
    var val: clmdb.MDB_val = undefined;
    const rc = clmdb.mdb_get(txn_ptr.?, store.events_dbi, &key, &val);
    if (rc == clmdb.MDB_NOTFOUND) {
        return null;
    }
    try check(rc);

    const bytes = mdbSliceConst(val);
    if (bytes.len < 40) return error.Corrupt;

    const created_at = std.mem.readInt(u64, bytes[0..8], .little);
    var author: PubKey = undefined;
    @memcpy(author[0..], bytes[8..40]);
    const payload_slice = bytes[40..];
    const payload_copy = try store.allocator.dupe(u8, payload_slice);

    return EventRecord{
        .allocator = store.allocator,
        .payload = payload_copy,
        .created_at = created_at,
        .author = author,
    };
}

fn ensureDirectory(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn makeTimelineKey(npub: PubKey, event_id: EventId) [64]u8 {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..32], npub[0..]);
    @memcpy(buf[32..64], event_id[0..]);
    return buf;
}

fn sortEntries(entries: []TimelineEntry) void {
    std.sort.block(TimelineEntry, entries, {}, lessThanTimeline);
}

fn lessThanTimeline(_: void, lhs: TimelineEntry, rhs: TimelineEntry) bool {
    if (lhs.created_at == rhs.created_at) {
        return std.mem.order(u8, lhs.event_id[0..], rhs.event_id[0..]) == .gt;
    }
    return lhs.created_at > rhs.created_at;
}

fn loadEntriesInternal(store: *Store, txn: *clmdb.MDB_txn, npub: PubKey) StoreError![]TimelineEntry {
    var cursor_ptr: ?*clmdb.MDB_cursor = null;
    try check(clmdb.mdb_cursor_open(txn, store.timeline_dbi, &cursor_ptr));
    defer clmdb.mdb_cursor_close(cursor_ptr.?);

    var entries = std.ArrayList(TimelineEntry).empty;
    errdefer entries.deinit(store.allocator);

    var key_buf: [64]u8 = undefined;
    @memcpy(key_buf[0..32], npub[0..]);
    @memset(key_buf[32..], 0);

    var key = mdbVal(key_buf[0..]);
    var value: clmdb.MDB_val = undefined;

    var rc = clmdb.mdb_cursor_get(cursor_ptr.?, &key, &value, clmdb.MDB_SET_RANGE);
    while (rc == 0) {
        const key_bytes = mdbSliceConst(key);
        if (key_bytes.len != 64) break;
        if (!std.mem.eql(u8, key_bytes[0..32], npub[0..])) break;

        const value_bytes = mdbSliceConst(value);
        if (value_bytes.len < 40) return error.Corrupt;

        var entry = TimelineEntry{
            .event_id = undefined,
            .created_at = std.mem.readInt(u64, value_bytes[0..8], .little),
            .author = undefined,
        };
        @memcpy(entry.event_id[0..], key_bytes[32..64]);
        @memcpy(entry.author[0..], value_bytes[8..40]);

        try entries.append(store.allocator, entry);

        rc = clmdb.mdb_cursor_get(cursor_ptr.?, &key, &value, clmdb.MDB_NEXT);
    }

    if (rc != 0 and rc != clmdb.MDB_NOTFOUND) {
        return mapError(rc);
    }

    return entries.toOwnedSlice(store.allocator);
}

fn readMeta(store: *Store, txn: *clmdb.MDB_txn, npub: PubKey) StoreError!TimelineMeta {
    var key = mdbVal(npub[0..]);
    var value: clmdb.MDB_val = undefined;
    const rc = clmdb.mdb_get(txn, store.meta_dbi, &key, &value);
    if (rc == clmdb.MDB_NOTFOUND) {
        return error.NotFound;
    }
    try check(rc);

    const bytes = mdbSliceConst(value);
    if (bytes.len < 16) return error.Corrupt;

    return TimelineMeta{
        .latest_created_at = std.mem.readInt(u64, bytes[0..8], .little),
        .count = @as(usize, @intCast(std.mem.readInt(u64, bytes[8..16], .little))),
    };
}

fn writeMeta(store: *Store, txn: *clmdb.MDB_txn, npub: PubKey, meta: TimelineMeta) !void {
    var key = mdbVal(npub[0..]);
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], meta.latest_created_at, .little);
    std.mem.writeInt(u64, buf[8..16], @as(u64, @intCast(meta.count)), .little);
    var value = mdbVal(buf[0..]);
    try check(clmdb.mdb_put(txn, store.meta_dbi, &key, &value, 0));
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
