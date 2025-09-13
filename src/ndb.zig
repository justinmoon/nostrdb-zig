const std = @import("std");
const c = @import("c.zig").c;

pub const Error = error{
    InitFailed,
    ProcessFailed,
    QueryFailed,
};

pub const Config = struct {
    inner: c.struct_ndb_config = undefined,

    pub fn initDefault() Config {
        var cfg: Config = .{ .inner = undefined };
        // Zero-initialize then call C default to fill sane defaults
        @memset(std.mem.asBytes(&cfg.inner), 0);
        c.ndb_default_config(&cfg.inner);
        return cfg;
    }

    pub fn setFlags(self: *Config, flags: u32) void {
        c.ndb_config_set_flags(&self.inner, @intCast(flags));
    }

    pub fn setIngestThreads(self: *Config, threads: i32) void {
        c.ndb_config_set_ingest_threads(&self.inner, threads);
    }

    pub fn setMapSize(self: *Config, mapsize: usize) void {
        c.ndb_config_set_mapsize(&self.inner, mapsize);
    }
};

pub const Ndb = struct {
    ptr: *c.struct_ndb,

    pub fn init(allocator: std.mem.Allocator, dbdir: []const u8, cfg: *const Config) !Ndb {
        // Ensure NUL-terminated path for C
        const dbdir_z = try allocator.alloc(u8, dbdir.len + 1);
        defer allocator.free(dbdir_z);
        @memcpy(dbdir_z[0..dbdir.len], dbdir);
        dbdir_z[dbdir.len] = 0;

        var out: ?*c.struct_ndb = null;
        const ok = c.ndb_init(&out, @ptrCast(dbdir_z.ptr), &cfg.inner);
        if (ok == 0 or out == null) return Error.InitFailed;
        return .{ .ptr = out.? };
    }

    pub fn deinit(self: *Ndb) void {
        c.ndb_destroy(self.ptr);
    }

    pub fn processEvent(self: *Ndb, json: []const u8) !void {
        const ok = c.ndb_process_event(self.ptr, @ptrCast(json.ptr), @intCast(json.len));
        if (ok == 0) return Error.ProcessFailed;
    }

    pub fn subscribe(self: *Ndb, filter: *Filter, num_filters: i32) u64 {
        return c.ndb_subscribe(self.ptr, &filter.inner, num_filters);
    }

    pub fn pollForNotes(self: *Ndb, subid: u64, out_ids: []u64) i32 {
        return c.ndb_poll_for_notes(self.ptr, subid, out_ids.ptr, @intCast(out_ids.len));
    }

    pub fn waitForNotes(self: *Ndb, subid: u64, out_ids: []u64) i32 {
        return c.ndb_wait_for_notes(self.ptr, subid, out_ids.ptr, @intCast(out_ids.len));
    }
};

pub const Transaction = struct {
    inner: c.struct_ndb_txn = undefined,

    pub fn begin(ndb: *Ndb) !Transaction {
        var txn: Transaction = .{ .inner = undefined };
        const ok = c.ndb_begin_query(ndb.ptr, &txn.inner);
        if (ok == 0) return Error.QueryFailed;
        return txn;
    }

    pub fn end(self: *Transaction) void {
        _ = c.ndb_end_query(&self.inner);
    }
};

pub const Note = struct {
    ptr: *c.struct_ndb_note,

    pub fn kind(self: Note) u32 {
        return c.ndb_note_kind(self.ptr);
    }

    pub fn content(self: Note) []const u8 {
        const s = c.ndb_note_content(self.ptr);
        return std.mem.span(s);
    }
};

pub const NoteKey = u64;

pub const Filter = struct {
    inner: c.struct_ndb_filter = undefined,

    pub fn init() !Filter {
        var f: Filter = .{ .inner = undefined };
        const ok = c.ndb_filter_init(&f.inner);
        if (ok == 0) return Error.QueryFailed;
        return f;
    }

    pub fn deinit(self: *Filter) void {
        c.ndb_filter_destroy(&self.inner);
    }

    pub fn kinds(self: *Filter, kinds_slice: []const u64) !void {
        if (c.ndb_filter_start_field(&self.inner, c.NDB_FILTER_KINDS) == 0) return Error.QueryFailed;
        for (kinds_slice) |k| {
            if (c.ndb_filter_add_int_element(&self.inner, k) == 0) return Error.QueryFailed;
        }
        c.ndb_filter_end_field(&self.inner);
        if (c.ndb_filter_end(&self.inner) == 0) return Error.QueryFailed;
    }

    pub fn ids(self: *Filter, id_list: []const [32]u8) !void {
        if (c.ndb_filter_start_field(&self.inner, c.NDB_FILTER_IDS) == 0) return Error.QueryFailed;
        for (id_list) |id| {
            if (c.ndb_filter_add_id_element(&self.inner, &id[0]) == 0) return Error.QueryFailed;
        }
        c.ndb_filter_end_field(&self.inner);
        if (c.ndb_filter_end(&self.inner) == 0) return Error.QueryFailed;
    }
};

pub fn hexTo32(out: *[32]u8, hex_str: []const u8) !void {
    if (hex_str.len != 64) return error.InvalidHex;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const hi = try fromHexNibble(hex_str[i * 2]);
        const lo = try fromHexNibble(hex_str[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
}

fn fromHexNibble(cu: u8) !u8 {
    return switch (cu) {
        '0'...'9' => cu - '0',
        'a'...'f' => 10 + (cu - 'a'),
        'A'...'F' => 10 + (cu - 'A'),
        else => error.InvalidHex,
    };
}

pub fn getNoteById(txn: *Transaction, id: *const [32]u8) ?Note {
    var note_len: usize = 0;
    var primkey: u64 = 0;
    const note_ptr = c.ndb_get_note_by_id(&txn.inner, &id[0], &note_len, &primkey);
    if (note_ptr == null) return null;
    return Note{ .ptr = note_ptr.? };
}

pub const QueryResult = struct {
    note: Note,
    note_id: u64,
};

pub fn query(txn: *Transaction, filters: []Filter, results_out: []QueryResult) !usize {
    var count: c_int = 0;
    // FIXME: avoid using global page_allocator here; thread/arena-owned
    // allocator should be plumbed through the API for predictable lifetimes.
    var c_results: []c.struct_ndb_query_result = try std.heap.page_allocator.alloc(c.struct_ndb_query_result, results_out.len);
    defer std.heap.page_allocator.free(c_results);

    // FIXME: same as above; these copies are transient and could be avoided
    // by passing C-side filters directly or allocating on the caller's arena.
    var tmp_filters: []c.struct_ndb_filter = try std.heap.page_allocator.alloc(c.struct_ndb_filter, filters.len);
    defer std.heap.page_allocator.free(tmp_filters);
    for (filters, 0..) |f, i| tmp_filters[i] = f.inner;

    const ok = c.ndb_query(&txn.inner, &tmp_filters[0], @intCast(tmp_filters.len), &c_results[0], @intCast(c_results.len), &count);
    if (ok == 0) return Error.QueryFailed;

    const n: usize = @intCast(count);
    var i: usize = 0;
    while (i < n and i < results_out.len) : (i += 1) {
        const note_ptr = c_results[i].note.?;
        results_out[i] = .{ .note = .{ .ptr = note_ptr }, .note_id = c_results[i].note_id };
    }
    return n;
}
