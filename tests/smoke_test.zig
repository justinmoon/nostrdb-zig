const std = @import("std");
const net = @import("net");
const contacts = @import("contacts");
const timeline = @import("timeline");
const ingest = @import("ingest");
const ndb = @import("ndb");

const Response = net.MockRelayResponse;
const ResponseBatch = net.MockRelayResponseBatch;

fn reservePort() u16 {
    // Simple deterministic port chooser for CI
    const base: u16 = 41000;
    const offset: u16 = @intCast(std.time.milliTimestamp() % 1000);
    return base +% offset;
}

fn hexKey(hex: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    const written = std.fmt.hexToBytes(out[0..], hex) catch unreachable;
    std.debug.assert(written == 32);
    return out;
}

const EOSE_TEMPLATE = "[\"EOSE\",\"{SUB_ID}\"]";

test "smoke: pipeline completes with EOSE only (fast)" {
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

    var timeline_store = try timeline.Store.init(allocator, .{ .path = timeline_path, .max_entries = 8 });
    defer timeline_store.deinit();

    // Author and a single follow
    const npub = hexKey("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const follow = hexKey("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d");
    var follows = try allocator.alloc(contacts.ContactKey, 1);
    follows[0] = follow;
    var contact_event = contacts.ContactEvent{
        .allocator = allocator,
        .author = npub,
        .created_at = 1,
        .event_id = hexKey("0101010101010101010101010101010101010101010101010101010101010101"),
        .follows = follows,
    };
    try contacts_store.applyEvent(&contact_event);

    var pipeline = ingest.Pipeline.init(allocator, npub, 8, &contacts_store, &timeline_store, &db);

    // Two-phase EOSE: initial (triggers resubscribe), then live (finishes)
    const batches = [_]ResponseBatch{
        .{ .messages = &.{Response{ .text = EOSE_TEMPLATE }} },
        .{ .messages = &.{Response{ .text = EOSE_TEMPLATE }} },
    };

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

    try pipeline.run(&.{relay_url});

    // Verify nothing was ingested (no events), and it completed promptly
    var snapshot = try timeline.loadTimeline(&timeline_store, npub);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.entries.len);
}
