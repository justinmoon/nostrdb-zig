const std = @import("std");
const net = @import("net");
const contacts = @import("contacts");
const timeline = @import("timeline");
const ingest = @import("ingest");
const ndb = @import("ndb");

const Response = net.MockRelayResponse;
const ResponseBatch = net.MockRelayResponseBatch;
const RequestLog = net.MockRelayRequestLog;

var port_seed: u16 = 40000;

fn reservePort() u16 {
    port_seed +%= 1;
    if (port_seed == 0) port_seed = 40000;
    return port_seed;
}

fn hexKey(hex: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    const written = std.fmt.hexToBytes(out[0..], hex) catch unreachable;
    std.debug.assert(written == 32);
    return out;
}

const EVENT_FOLLOW = "{\"kind\":1,\"id\":\"dc90c95f09947507c1044e8f48bcf6350aa6bff1507dd4acfc755b9239b5c962\",\"pubkey\":\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\",\"created_at\":1644271588,\"tags\":[],\"content\":\"now that https://blueskyweb.org/blog/2-7-2022-overview was announced we can stop working on nostr?\",\"sig\":\"230e9d8f0ddaf7eb70b5f7741ccfa37e87a455c9a469282e3464e2052d3192cd63a167e196e381ef9d7e69e9ea43af2443b839974dc85d8aaab9efe1d9296524\"}";
const EVENT_NONFOLLOW = "{\"content\":\"Wow 🤩 I like the way that this dude thinks. Is this the moment that Bitcoin becomes harder currency than gold, I hope so.\",\"created_at\":1741372929,\"id\":\"bc990203855b44130b25686fe70aeae45f4c98fb916f224800b3acba667a8b85\",\"kind\":1,\"pubkey\":\"3bbcab7e3d2b07a55027206d5e193813f01406882daad05412389a50b67ba92e\",\"sig\":\"4224f1769d86c25e3dca51a1ac0dc1b1612038ae0b1dee0df711c1251d8571668648bacca322d914e2d0ae379f7f428e4cb519baef13d95fbcb5d4675e0556a7\",\"tags\":[[\"e\",\"c56312f922d8984b15b2f005019965df2135a5e299a5a7499f68e7249ca95734\",\"wss://@nos.lol\",\"root\"],[\"p\",\"7c765d407d3a9d5ea117cb8b8699628560787fc084a0c76afaa449bfbd121d84\"]]}";
const EVENT_LIVE = "{\"content\":\"Hope it's sats, not yuan.\",\"created_at\":1741372926,\"id\":\"c7c8cdc2a22179045483af34259e0f30016b1ab6ee6aa7c680c1ebe458279e25\",\"kind\":1,\"pubkey\":\"7216e1df98ff551e77a4c0ce2d886a48ef79319d281b507ca3bfdd8118ce74ad\",\"sig\":\"a7aba006cf5b7c9fea3c1b7e378cc304847e7eddefa6fd9362270d0f2b338727f9142c78fbea90c67dd48b9471f1e3fa7646c3e7e52d9e00f44a23225cffd34e\",\"tags\":[[\"e\",\"cacef23e836e3aeba2d5f72e04d185e213509a6ce15f58f7849efeee25677442\",\"\",\"reply\"],[\"p\",\"35c8cb369688f9f68ace8efbb639e68a1808959993d2507bc4c1fe81b2e2972f\"]]}";

fn makeEventMessage(event_json: []const u8) []const u8 {
    return std.fmt.comptimePrint("[\"EVENT\",\"{SUB_ID}\",{s}]", .{event_json});
}

const EOSE_TEMPLATE = "[\"EOSE\",\"{SUB_ID}\"]";

test "pipeline ingests followed events and ignores others" {
    const allocator = std.testing.allocator;

    var tmp_dir = try std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(allocator, db_path, &cfg);
    defer db.deinit();

    try tmp_dir.dir.makePath("contacts");
    const contacts_path = try tmp_dir.dir.realpathAlloc(allocator, "contacts");
    defer allocator.free(contacts_path);

    var contacts_store = try contacts.Store.init(allocator, .{ .path = contacts_path });
    defer contacts_store.deinit();

    try tmp_dir.dir.makePath("timeline");
    const timeline_path = try tmp_dir.dir.realpathAlloc(allocator, "timeline");
    defer allocator.free(timeline_path);

    var timeline_store = try timeline.Store.init(allocator, .{
        .path = timeline_path,
        .max_entries = 32,
    });
    defer timeline_store.deinit();

    const npub = hexKey("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const follow1 = hexKey("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d");
    const follow2 = hexKey("7216e1df98ff551e77a4c0ce2d886a48ef79319d281b507ca3bfdd8118ce74ad");

    var follows = try allocator.alloc(contacts.ContactKey, 2);
    follows[0] = follow1;
    follows[1] = follow2;
    var contact_event = contacts.ContactEvent{
        .allocator = allocator,
        .author = npub,
        .created_at = 1,
        .event_id = hexKey("0101010101010101010101010101010101010101010101010101010101010101"),
        .follows = follows,
    };
    try contacts_store.applyEvent(&contact_event);

    var pipeline = ingest.Pipeline.init(allocator, npub, 100, &contacts_store, &timeline_store, &db);

    const port = reservePort();
    var request_log = RequestLog.init(allocator);
    defer request_log.deinit();

    const batches = [_]ResponseBatch{
        .{ .messages = &.{
            Response{ .text = makeEventMessage(EVENT_FOLLOW) },
            Response{ .text = makeEventMessage(EVENT_NONFOLLOW) },
            Response{ .text = EOSE_TEMPLATE },
        } },
        .{ .messages = &.{
            Response{ .text = makeEventMessage(EVENT_LIVE) },
            Response{ .text = EOSE_TEMPLATE },
        } },
    };

    var server = try net.MockRelayServer.init(.{
        .allocator = allocator,
        .port = port,
        .batches = &batches,
        .request_log = &request_log,
    });
    defer server.deinit();
    try server.start();

    const relay_url = try server.address(allocator);
    defer allocator.free(relay_url);

    try pipeline.run(&.{relay_url});

    try std.testing.expect(request_log.entries.items.len >= 2);
    try std.testing.expect(std.mem.indexOf(u8, request_log.entries.items[0], "\"since\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, request_log.entries.items[1], "\"since\"") != null);

    var snapshot = try timeline.loadTimeline(&timeline_store, npub);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.entries.len);
    try std.testing.expectEqual(@as(u64, 1741372926), snapshot.meta.latest_created_at);

    const latest_event_id = hexKey("c7c8cdc2a22179045483af34259e0f30016b1ab6ee6aa7c680c1ebe458279e25");
    try std.testing.expectEqualSlices(u8, &latest_event_id, &snapshot.entries[0].event_id);

    const non_follow_event = hexKey("bc990203855b44130b25686fe70aeae45f4c98fb916f224800b3acba667a8b85");
    const record_opt = try timeline.getEvent(&timeline_store, non_follow_event);
    if (record_opt) |record| {
        defer record.deinit();
        return error.TestUnexpectedResult;
    }
}

test "pipeline initial request includes since when timeline full" {
    const allocator = std.testing.allocator;

    var tmp_dir = try std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(allocator, db_path, &cfg);
    defer db.deinit();

    try tmp_dir.dir.makePath("contacts");
    const contacts_path = try tmp_dir.dir.realpathAlloc(allocator, "contacts");
    defer allocator.free(contacts_path);

    var contacts_store = try contacts.Store.init(allocator, .{ .path = contacts_path });
    defer contacts_store.deinit();

    try tmp_dir.dir.makePath("timeline");
    const timeline_path = try tmp_dir.dir.realpathAlloc(allocator, "timeline");
    defer allocator.free(timeline_path);

    var timeline_store = try timeline.Store.init(allocator, .{
        .path = timeline_path,
        .max_entries = 2,
    });
    defer timeline_store.deinit();

    const npub = hexKey("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc");
    const follow = hexKey("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d");
    var follows = try allocator.alloc(contacts.ContactKey, 1);
    follows[0] = follow;
    var contact_event = contacts.ContactEvent{
        .allocator = allocator,
        .author = npub,
        .created_at = 1,
        .event_id = hexKey("0202020202020202020202020202020202020202020202020202020202020202"),
        .follows = follows,
    };
    try contacts_store.applyEvent(&contact_event);

    const author = follow;
    const payload = "{\"kind\":1}";
    try timeline.insertEvent(&timeline_store, npub, .{ .event_id = hexKey("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), .created_at = 50, .author = author }, payload);
    try timeline.insertEvent(&timeline_store, npub, .{ .event_id = hexKey("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"), .created_at = 60, .author = author }, payload);

    var pipeline = ingest.Pipeline.init(allocator, npub, 2, &contacts_store, &timeline_store, &db);

    var request_log = RequestLog.init(allocator);
    defer request_log.deinit();

    const batches = [_]ResponseBatch{.{ .messages = &.{Response{ .text = EOSE_TEMPLATE }} }};

    const port = reservePort();
    var server = try net.MockRelayServer.init(.{
        .allocator = allocator,
        .port = port,
        .batches = &batches,
        .request_log = &request_log,
    });
    defer server.deinit();
    try server.start();

    const relay_url = try server.address(allocator);
    defer allocator.free(relay_url);

    try pipeline.run(&.{relay_url});

    try std.testing.expect(request_log.entries.items.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, request_log.entries.items[0], "\"since\"") != null);
}

test "invalid signature is skipped" {
    const allocator = std.testing.allocator;

    var tmp_dir = try std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(db_path);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(allocator, db_path, &cfg);
    defer db.deinit();

    try tmp_dir.dir.makePath("contacts");
    const contacts_path = try tmp_dir.dir.realpathAlloc(allocator, "contacts");
    defer allocator.free(contacts_path);

    var contacts_store = try contacts.Store.init(allocator, .{ .path = contacts_path });
    defer contacts_store.deinit();

    try tmp_dir.dir.makePath("timeline");
    const timeline_path = try tmp_dir.dir.realpathAlloc(allocator, "timeline");
    defer allocator.free(timeline_path);

    var timeline_store = try timeline.Store.init(allocator, .{
        .path = timeline_path,
        .max_entries = 32,
    });
    defer timeline_store.deinit();

    const npub = hexKey("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    const follow = hexKey("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d");

    var follows = try allocator.alloc(contacts.ContactKey, 1);
    follows[0] = follow;
    var contact_event = contacts.ContactEvent{
        .allocator = allocator,
        .author = npub,
        .created_at = 1,
        .event_id = hexKey("0303030303030303030303030303030303030303030303030303030303030303"),
        .follows = follows,
    };
    try contacts_store.applyEvent(&contact_event);

    var pipeline = ingest.Pipeline.init(allocator, npub, 100, &contacts_store, &timeline_store, &db);

    const invalid_event_json = "{\"kind\":1,\"id\":\"dc90c95f09947507c1044e8f48bcf6350aa6bff1507dd4acfc755b9239b5c962\",\"pubkey\":\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\",\"created_at\":1644271588,\"tags\":[],\"content\":\"now that https://blueskyweb.org/blog/2-7-2022-overview was announced we can stop working on nostr?\",\"sig\":\"fffffffff98d8f0ddaf7eb70b5f7741ccfa37e87a455c9a469282e3464e2052d3192cd63a167e196e381ef9d7e69e9ea43af2443b839974dc85d8aaab9efe1d9296524\"}";

    const batches = [_]ResponseBatch{.{ .messages = &.{
        Response{ .text = makeEventMessage(invalid_event_json) },
        Response{ .text = EOSE_TEMPLATE },
    } }};

    const port = reservePort();
    var server = try net.MockRelayServer.init(.{
        .allocator = allocator,
        .port = port,
        .batches = &batches,
    });
    defer server.deinit();
    try server.start();

    const relay_url = try server.address(allocator);
    defer allocator.free(relay_url);

    const result = pipeline.run(&.{relay_url});
    // Pipeline may succeed even if no events ingested; ensure no entries
    _ = result catch |err| switch (err) {
        error.CompletionTimeout => {},
        else => return err,
    };

    var snapshot = try timeline.loadTimeline(&timeline_store, npub);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.entries.len);
}
