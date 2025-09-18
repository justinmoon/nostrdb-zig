const std = @import("std");
const cli = @import("cli");
const net = @import("net");
const contacts = @import("contacts");
const timeline = @import("timeline");
const ingest = @import("ingest");
const ndb = @import("ndb");

const Response = net.MockRelayResponse;
const ResponseBatch = net.MockRelayResponseBatch;
const RequestLog = net.MockRelayRequestLog;

var port_seed: u16 = 42000;
fn reservePort() u16 {
    port_seed +%= 1;
    if (port_seed == 0) port_seed = 42000;
    return port_seed;
}

const CONTACT_EVENT =
    "[\"EVENT\",\"{SUB_ID}\",{\"id\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"pubkey\":\"e9142f724955c5854de36324dab0434f97b15ec6b33464d56ebe491e3f559d1b\",\"created_at\":1700000000,\"kind\":3,\"tags\":[[\"p\",\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\"]],\"content\":\"{}\"}]";

const POST_EVENT_1 = "[\"EVENT\",\"{SUB_ID}\",{\"kind\":1,\"id\":\"dc90c95f09947507c1044e8f48bcf6350aa6bff1507dd4acfc755b9239b5c962\",\"pubkey\":\"3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d\",\"created_at\":1644271588,\"tags\":[],\"content\":\"now that https://blueskyweb.org/blog/2-7-2022-overview was announced we can stop working on nostr?\",\"sig\":\"230e9d8f0ddaf7eb70b5f7741ccfa37e87a455c9a469282e3464e2052d3192cd63a167e196e381ef9d7e69e9ea43af2443b839974dc85d8aaab9efe1d9296524\"}]";

const POST_EVENT_2 = "[\"EVENT\",\"{SUB_ID}\",{\"kind\":1,\"id\":\"c7c8cdc2a22179045483af34259e0f30016b1ab6ee6aa7c680c1ebe458279e25\",\"pubkey\":\"7216e1df98ff551e77a4c0ce2d886a48ef79319d281b507ca3bfdd8118ce74ad\",\"created_at\":1741372926,\"tags\":[],\"content\":\"Hope it's sats, not yuan.\",\"sig\":\"a7aba006cf5b7c9fea3c1b7e378cc304847e7eddefa6fd9362270d0f2b338727f9142c78fbea90c67dd48b9471f1e3fa7646c3e7e52d9e00f44a23225cffd34e\"}]";

const EOSE_TEMPLATE = "[\"EOSE\",\"{SUB_ID}\"]";

const NPUB = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6";

fn makeOptions(allocator: std.mem.Allocator, relays: []const []const u8) !cli.Options {
    var opts = cli.Options.init(allocator);
    opts.npub = NPUB;
    for (relays) |relay| {
        try opts.relays.append(allocator, relay);
    }
    opts.limit = 5;
    return opts;
}

fn setupServer(batches: []const ResponseBatch, allocator: std.mem.Allocator, log: ?*RequestLog) !struct { server: net.MockRelayServer, url: []const u8 } {
    const port = reservePort();
    var server = try net.MockRelayServer.init(.{
        .allocator = allocator,
        .port = port,
        .batches = batches,
        .request_log = log,
    });
    try server.start();
    const url = try server.address(allocator);
    return .{ .server = server, .url = url };
}

test "CLI prints timeline from pipelines" {
    const allocator = std.testing.allocator;

    var contacts_batches = [_]ResponseBatch{.{ .messages = &.{
        Response{ .text = CONTACT_EVENT },
        Response{ .text = EOSE_TEMPLATE },
    } }};

    var posts_batches = [_]ResponseBatch{
        .{ .messages = &.{
            Response{ .text = CONTACT_EVENT },
            Response{ .text = POST_EVENT_1 },
            Response{ .text = EOSE_TEMPLATE },
        } },
        .{ .messages = &.{
            Response{ .text = POST_EVENT_2 },
            Response{ .text = EOSE_TEMPLATE },
        } },
    };

    var contact_log = RequestLog.init(allocator);
    defer contact_log.deinit();
    var posts_log = RequestLog.init(allocator);
    defer posts_log.deinit();

    var contact_server_bundle = try setupServer(&contacts_batches, allocator, &contact_log);
    defer contact_server_bundle.server.deinit();
    defer allocator.free(contact_server_bundle.url);

    var posts_server_bundle = try setupServer(&posts_batches, allocator, &posts_log);
    defer posts_server_bundle.server.deinit();
    defer allocator.free(posts_server_bundle.url);

    const relays = [_][]const u8{ contact_server_bundle.url, posts_server_bundle.url };
    var options = try makeOptions(allocator, &relays);
    defer options.deinit();

    var output_buffer = std.array_list.Managed(u8).init(allocator);
    defer output_buffer.deinit();

    const writer = output_buffer.writer();
    try cli.runWithOptions(options, writer);

    const output = output_buffer.items;
    try std.testing.expect(std.mem.indexOfScalar(u8, output, '\n') != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "dc90c95f"[0..]) != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "c7c8cdc2"[0..]) != null);

    // The first request to posts relay omits since, the second includes it
    try std.testing.expect(posts_log.entries.items.len >= 2);
    try std.testing.expect(std.mem.indexOf(u8, posts_log.entries.items[0], "\"since\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, posts_log.entries.items[1], "\"since\"") != null);
}
