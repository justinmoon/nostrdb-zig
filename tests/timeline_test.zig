const std = @import("std");
const timeline = @import("timeline");

fn hexKey(hex: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    const written = std.fmt.hexToBytes(out[0..], hex) catch unreachable;
    std.debug.assert(written == 32);
    return out;
}

const StoreContext = struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.testing.TmpDir,
    path: []u8,
    store: timeline.Store,

    fn init(allocator: std.mem.Allocator, max_entries: usize) !StoreContext {
        var tmp_dir = try std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        try tmp_dir.dir.makePath("timeline");
        const path = try tmp_dir.dir.realpathAlloc(allocator, "timeline");
        errdefer allocator.free(path);

        var store = try timeline.Store.init(allocator, .{
            .path = path,
            .max_entries = max_entries,
        });
        errdefer store.deinit();

        return StoreContext{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .path = path,
            .store = store,
        };
    }

    fn deinit(self: *StoreContext) void {
        self.store.deinit();
        self.allocator.free(self.path);
        self.tmp_dir.cleanup();
    }
};

test "timeline orders entries and respects cap" {
    const allocator = std.testing.allocator;
    var ctx = try StoreContext.init(allocator, 3);
    defer ctx.deinit();

    const npub = hexKey("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const author = hexKey("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");

    const events = [_]struct {
        id: [32]u8,
        created_at: u64,
    }{
        .{ .id = hexKey("1111111111111111111111111111111111111111111111111111111111111111"), .created_at = 10 },
        .{ .id = hexKey("2222222222222222222222222222222222222222222222222222222222222222"), .created_at = 30 },
        .{ .id = hexKey("3333333333333333333333333333333333333333333333333333333333333333"), .created_at = 20 },
        .{ .id = hexKey("4444444444444444444444444444444444444444444444444444444444444444"), .created_at = 40 },
    };

    for (events) |ev| {
        const entry = timeline.TimelineEntry{ .event_id = ev.id, .created_at = ev.created_at, .author = author };
        const payload = "{\"id\":\"dummy\"}";
        try timeline.insertEvent(&ctx.store, npub, entry, payload);
    }

    var snapshot = try timeline.loadTimeline(&ctx.store, npub);
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 3), snapshot.entries.len);
    try std.testing.expectEqual(@as(u64, 40), snapshot.entries[0].created_at);
    try std.testing.expectEqual(@as(u64, 30), snapshot.entries[1].created_at);
    try std.testing.expectEqual(@as(u64, 20), snapshot.entries[2].created_at);
    try std.testing.expectEqual(@as(u64, 40), snapshot.meta.latest_created_at);
}

test "timeline skips duplicates" {
    const allocator = std.testing.allocator;
    var ctx = try StoreContext.init(allocator, 5);
    defer ctx.deinit();

    const npub = hexKey("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const author = hexKey("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const id = hexKey("9999999999999999999999999999999999999999999999999999999999999999");

    const entry = timeline.TimelineEntry{ .event_id = id, .created_at = 100, .author = author };
    const payload = "{\"id\":\"x\"}";
    try timeline.insertEvent(&ctx.store, npub, entry, payload);
    try timeline.insertEvent(&ctx.store, npub, entry, payload);

    var snapshot = try timeline.loadTimeline(&ctx.store, npub);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.entries.len);
}

test "timeline cap enforced under load" {
    const allocator = std.testing.allocator;
    var ctx = try StoreContext.init(allocator, 50);
    defer ctx.deinit();

    const npub = hexKey("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    const author = hexKey("1111111111111111111111111111111111111111111111111111111111111111");

    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "%064x", .{i}) catch unreachable;
        const id = hexKey(slice);
        const entry = timeline.TimelineEntry{ .event_id = id, .created_at = @intCast(i), .author = author };
        try timeline.insertEvent(&ctx.store, npub, entry, "{\"kind\":1}");
    }

    var snapshot = try timeline.loadTimeline(&ctx.store, npub);
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 50), snapshot.entries.len);
    try std.testing.expectEqual(@as(u64, 4999), snapshot.meta.latest_created_at);
    try std.testing.expectEqual(@as(u64, 4999), snapshot.entries[0].created_at);
    try std.testing.expectEqual(@as(u64, 4950), snapshot.entries[49].created_at);
}
