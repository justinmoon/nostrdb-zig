const std = @import("std");
const proto = @import("proto");

test "decode npub success" {
    const npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6";
    const expected_hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d";

    const decoded = try proto.decodeNpub(npub);

    var expected: [32]u8 = undefined;
    const written = try std.fmt.hexToBytes(expected[0..], expected_hex);
    try std.testing.expectEqual(@as(usize, 32), written);
    try std.testing.expectEqualSlices(u8, expected[0..], decoded[0..]);
}

test "decode npub failure" {
    const invalid = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w4";
    try std.testing.expectError(proto.DecodeError.InvalidNpub, proto.decodeNpub(invalid));
}

test "contacts filter JSON" {
    const allocator = std.testing.allocator;
    const pk = try hexToArray32("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d");

    const filter = try proto.buildContactsFilter(allocator, .{ .author = pk });
    defer allocator.free(filter);

    const expected = "[{\"authors\":[\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\"],\"kinds\":[3],\"limit\":1}]";
    try std.testing.expectEqualStrings(expected, filter);
}

test "posts filter without since" {
    const allocator = std.testing.allocator;
    const a1 = try hexToArray32("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d");
    const a2 = try hexToArray32("e8b487c079b0f67c695ae6c4c2552a47f38adfa2533cc5926bd2c102942fdcb7");

    var authors = [_][32]u8{ a1, a2 };
    const filters = try proto.buildPostsFilters(allocator, .{ .authors = &authors, .limit = 500 });
    defer freeFilterList(allocator, filters);

    try std.testing.expectEqual(@as(usize, 1), filters.len);

    const filter_str = std.mem.sliceTo(filters[0], 0);
    const expected = "[{\"authors\":[\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\",\"e8b487c079b0f67c695ae6c4c2552a47f38adfa2533cc5926bd2c102942fdcb7\"],\"kinds\":[1],\"limit\":500}]";
    try std.testing.expectEqualStrings(expected, filter_str);
}

test "posts filter with since" {
    const allocator = std.testing.allocator;
    const a1 = try hexToArray32("45326f5d6962ab1e3cd424e758c3002b8665f7b0d8dcee9fe9e288d7751ac194");

    var authors = [_][32]u8{a1};
    const filters = try proto.buildPostsFilters(allocator, .{ .authors = &authors, .limit = 42, .since = 123456 });
    defer freeFilterList(allocator, filters);

    try std.testing.expectEqual(@as(usize, 1), filters.len);
    const filter_str = std.mem.sliceTo(filters[0], 0);
    const expected = "[{\"authors\":[\"45326f5d6962ab1e3cd424e758c3002b8665f7b0d8dcee9fe9e288d7751ac194\"],\"kinds\":[1],\"limit\":42,\"since\":123456}]";
    try std.testing.expectEqualStrings(expected, filter_str);
}

test "posts filter chunking" {
    const allocator = std.testing.allocator;
    const a1 = try hexToArray32("1111111111111111111111111111111111111111111111111111111111111111");
    const a2 = try hexToArray32("2222222222222222222222222222222222222222222222222222222222222222");
    const a3 = try hexToArray32("3333333333333333333333333333333333333333333333333333333333333333");

    var authors = [_][32]u8{ a1, a2, a3 };
    const filters = try proto.buildPostsFilters(allocator, .{ .authors = &authors, .limit = 10, .chunk_size = 2 });
    defer freeFilterList(allocator, filters);

    try std.testing.expectEqual(@as(usize, 2), filters.len);

    const first = std.mem.sliceTo(filters[0], 0);
    const second = std.mem.sliceTo(filters[1], 0);

    const expected_first = "[{\"authors\":[\"1111111111111111111111111111111111111111111111111111111111111111\",\"2222222222222222222222222222222222222222222222222222222222222222\"],\"kinds\":[1],\"limit\":10}]";
    const expected_second = "[{\"authors\":[\"3333333333333333333333333333333333333333333333333333333333333333\"],\"kinds\":[1],\"limit\":10}]";

    try std.testing.expectEqualStrings(expected_first, first);
    try std.testing.expectEqualStrings(expected_second, second);
}

test "subid generator uniqueness" {
    const allocator = std.testing.allocator;
    var map = std.StringHashMap(void).init(allocator);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        map.deinit();
    }

    const iterations: usize = 10_000;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const id = try proto.nextSubId(allocator);
        errdefer allocator.free(id);
        try map.put(id, {});
    }

    try std.testing.expectEqual(iterations, map.count());
}

test "build req and close messages" {
    const allocator = std.testing.allocator;
    const author = try hexToArray32("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d");
    const contact_filter = try proto.buildContactsFilter(allocator, .{ .author = author });
    defer allocator.free(contact_filter);

    const posts_filters = try proto.buildPostsFilters(allocator, .{ .authors = &[_][32]u8{author}, .limit = 100 });
    defer freeFilterList(allocator, posts_filters);

    const filters_for_req = [_][]const u8{
        contact_filter,
        std.mem.sliceTo(posts_filters[0], 0),
    };

    const req = try proto.buildReq(allocator, "sub-abc", &filters_for_req);
    defer allocator.free(req);

    const expected_req = "[\"REQ\",\"sub-abc\",{\"authors\":[\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\"],\"kinds\":[3],\"limit\":1},{\"authors\":[\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\"],\"kinds\":[1],\"limit\":100}]";
    try std.testing.expectEqualStrings(expected_req, req);

    const close = try proto.buildClose(allocator, "sub-abc");
    defer allocator.free(close);
    try std.testing.expectEqualStrings("[\"CLOSE\",\"sub-abc\"]", close);
}

fn hexToArray32(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidHexLength;
    var out: [32]u8 = undefined;
    const written = try std.fmt.hexToBytes(out[0..], hex);
    if (written != 32) return error.InvalidHexLength;
    return out;
}

fn freeFilterList(allocator: std.mem.Allocator, filters: [][:0]const u8) void {
    for (filters) |item| {
        allocator.free(item);
    }
    allocator.free(filters);
}
