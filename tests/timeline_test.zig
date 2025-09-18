const std = @import("std");
const timeline = @import("timeline");

fn hexKey(hex: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    const written = std.fmt.hexToBytes(out[0..], hex) catch unreachable;
    std.debug.assert(written == 32);
    return out;
}

test "timeline orders entries and respects cap" {
    const allocator = std.testing.allocator;
    var store = timeline.Store.init(allocator, 3);
    defer store.deinit();

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
        try timeline.insertEvent(&store, npub, entry, payload);
    }

    const list = store.getTimeline(npub) orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 3), list.entries.items.len);
    try std.testing.expectEqual(@as(u64, 40), list.entries.items[0].created_at);
    try std.testing.expectEqual(@as(u64, 30), list.entries.items[1].created_at);
    try std.testing.expectEqual(@as(u64, 20), list.entries.items[2].created_at);
    try std.testing.expectEqual(@as(u64, 40), list.meta.latest_created_at);
}

test "timeline skips duplicates" {
    const allocator = std.testing.allocator;
    var store = timeline.Store.init(allocator, 5);
    defer store.deinit();

    const npub = hexKey("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const author = hexKey("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const id = hexKey("9999999999999999999999999999999999999999999999999999999999999999");

    const entry = timeline.TimelineEntry{ .event_id = id, .created_at = 100, .author = author };
    const payload = "{\"id\":\"x\"}";
    try timeline.insertEvent(&store, npub, entry, payload);
    try timeline.insertEvent(&store, npub, entry, payload);

    const list = store.getTimeline(npub) orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(usize, 1), list.entries.items.len);
}
