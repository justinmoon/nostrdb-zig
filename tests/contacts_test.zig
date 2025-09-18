const std = @import("std");
const contacts = @import("contacts");
const net = @import("net");
const ndb = @import("root").ndb;
const Response = net.MockRelayResponse;

var port_seed: u16 = 38000;

fn reservePort() u16 {
    port_seed +%= 1;
    if (port_seed == 0) port_seed = 38000;
    return port_seed;
}

fn hexKey(hex: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    const written = std.fmt.hexToBytes(out[0..], hex) catch unreachable;
    std.debug.assert(written == 32);
    return out;
}

test "parser extracts follows from p tags" {
    const allocator = std.testing.allocator;
    var parser = contacts.Parser.init(allocator);
    defer parser.deinit();

    const event_json =
        "{\"id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"pubkey\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"created_at\":1700000000," ++
        "\"kind\":3," ++
        "\"tags\":[" ++
        "[\"p\",\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"wss://relay.example\"]," ++
        "[\"p\",\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"]," ++
        "[\"e\",\"ignored\"]" ++
        "]," ++
        "\"content\":\"contacts\"}";

    var event = try parser.parse(event_json);
    defer event.deinit();

    const expected_author = hexKey("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const expected_event_id = hexKey("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const expected_follow1 = hexKey("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");
    const expected_follow2 = hexKey("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");

    try std.testing.expectEqualSlices(u8, &expected_author, &event.author);
    try std.testing.expectEqual(1700000000, event.created_at);
    try std.testing.expectEqualSlices(u8, &expected_event_id, &event.event_id);
    try std.testing.expectEqual(@as(usize, 2), event.follows.len);
    try std.testing.expectEqualSlices(u8, &expected_follow1, &event.follows[0]);
    try std.testing.expectEqualSlices(u8, &expected_follow2, &event.follows[1]);
}

test "store keeps latest created_at" {
    const allocator = std.testing.allocator;
    var store = contacts.Store.init(allocator);
    defer store.deinit();

    var parser = contacts.Parser.init(allocator);
    defer parser.deinit();

    const old_event_json =
        "{\"id\":\"1111111111111111111111111111111111111111111111111111111111111111\"," ++
        "\"pubkey\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"created_at\":10," ++
        "\"kind\":3," ++
        "\"tags\":[[\"p\",\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"]]," ++
        "\"content\":\"a\"}";

    var old_event = try parser.parse(old_event_json);
    try store.applyEvent(&old_event);

    const new_event_json =
        "{\"id\":\"2222222222222222222222222222222222222222222222222222222222222222\"," ++
        "\"pubkey\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"created_at\":20," ++
        "\"kind\":3," ++
        "\"tags\":[[\"p\",\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"]]," ++
        "\"content\":\"b\"}";

    var new_event = try parser.parse(new_event_json);
    try store.applyEvent(&new_event);

    const key = hexKey("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const list = store.get(key) orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(u64, 20), list.created_at);
    const expected_event = hexKey("2222222222222222222222222222222222222222222222222222222222222222");
    try std.testing.expectEqualSlices(u8, &expected_event, &list.event_id);
    try std.testing.expectEqual(@as(usize, 1), list.follows.count());
    try std.testing.expect(list.follows.contains(hexKey("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd")));
}

test "store keeps lexicographically greater event id on tie" {
    const allocator = std.testing.allocator;
    var store = contacts.Store.init(allocator);
    defer store.deinit();

    var parser = contacts.Parser.init(allocator);
    defer parser.deinit();

    const first_json =
        "{\"id\":\"1111111111111111111111111111111111111111111111111111111111111111\"," ++
        "\"pubkey\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"created_at\":30," ++
        "\"kind\":3," ++
        "\"tags\":[],\"content\":\"c\"}";

    var first_event = try parser.parse(first_json);
    try store.applyEvent(&first_event);

    const second_json =
        "{\"id\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"," ++
        "\"pubkey\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"," ++
        "\"created_at\":30," ++
        "\"kind\":3," ++
        "\"tags\":[],\"content\":\"d\"}";

    var second_event = try parser.parse(second_json);
    try store.applyEvent(&second_event);

    const key = hexKey("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const list = store.get(key) orelse return error.TestExpectedResult;
    const expected_final = hexKey("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff");
    try std.testing.expectEqualSlices(u8, &expected_final, &list.event_id);
}

test "fetcher picks latest contact list" {
    const allocator = std.testing.allocator;

    var tmp_dir = try std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(allocator, db_path, &cfg);
    defer db.deinit();

    var store = contacts.Store.init(allocator);
    defer store.deinit();

    var fetcher = contacts.Fetcher.init(allocator, &store);
    defer fetcher.deinit();

    const npub = hexKey("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const follow_old = hexKey("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");
    const follow_new = hexKey("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd");

    const event_old =
        "[\"EVENT\",\"{SUB_ID}\",{" ++
        "\"id\":\"0101010101010101010101010101010101010101010101010101010101010101\"," ++
        "\"pubkey\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"created_at\":100," ++
        "\"kind\":3," ++
        "\"tags\":[[\"p\",\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\"]]," ++
        "\"content\":\"old\"}]";

    const event_new =
        "[\"EVENT\",\"{SUB_ID}\",{" ++
        "\"id\":\"0202020202020202020202020202020202020202020202020202020202020202\"," ++
        "\"pubkey\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"," ++
        "\"created_at\":200," ++
        "\"kind\":3," ++
        "\"tags\":[[\"p\",\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\"]]," ++
        "\"content\":\"new\"}]";

    const eose = "[\"EOSE\",\"{SUB_ID}\"]";

    const port = reservePort();
    var server = try net.MockRelayServer.init(.{
        .allocator = allocator,
        .port = port,
        .responses = &.{
            Response{ .text = event_old },
            Response{ .text = event_new },
            Response{ .text = eose },
        },
    });
    defer server.deinit();
    try server.start();

    const relay_url = try server.address(allocator);
    defer allocator.free(relay_url);

    try fetcher.fetchContacts(npub, &.{relay_url}, &db);

    const list = store.get(npub) orelse return error.TestExpectedResult;
    try std.testing.expectEqual(@as(u64, 200), list.created_at);
    const expected_event = hexKey("0202020202020202020202020202020202020202020202020202020202020202");
    try std.testing.expectEqualSlices(u8, &expected_event, &list.event_id);
    try std.testing.expect(list.follows.contains(follow_new));
    try std.testing.expect(!list.follows.contains(follow_old));
}
