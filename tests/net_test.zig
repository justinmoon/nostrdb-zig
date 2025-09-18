const std = @import("std");
const net = @import("net");
const Response = net.MockRelayResponse;

var port_seed: u16 = 38000;

fn reservePort() u16 {
    port_seed +%= 1;
    if (port_seed == 0) port_seed = 38000;
    return port_seed;
}

test "relay message parser mirrors enostr cases" {
    var parser = net.RelayMessageParser.init(std.testing.allocator);
    defer parser.deinit();

    const valid_cases = [_]struct {
        message: []const u8,
        kind: enum { event, eose, notice, ok, unknown },
        extra: []const u8,
    }{
        .{
            .message = "[\"EOSE\",\"x\"]",
            .kind = .eose,
            .extra = "x",
        },
        .{
            .message = "[\"NOTICE\",\"hello world\"]",
            .kind = .notice,
            .extra = "hello world",
        },
        .{
            .message = "[\"EVENT\", \"random_string\", {\"id\":\"example\",\"content\":\"test\"}]",
            .kind = .event,
            .extra = "{\"id\":\"example\",\"content\":\"test\"}",
        },
        .{
            .message = "[\"OK\",\"b1a649ebe8b435ec71d3784793f3bbf4b93e64e17568a741aecd4c7ddeafce30\",true,\"pow: difficulty 25>=24\"]",
            .kind = .ok,
            .extra = "pow: difficulty 25>=24",
        },
        .{
            .message = "[\"AUTH\",\"token\"]",
            .kind = .unknown,
            .extra = "AUTH",
        },
    };

    inline for (valid_cases) |case| {
        var msg = try parser.parseText(case.message);
        defer msg.deinit(std.testing.allocator);

        switch (msg) {
            .event => |event| {
                try std.testing.expectEqualStrings("random_string", event.subId());
                const canonical_expected = try canonicalJson(case.extra);
                defer std.testing.allocator.free(canonical_expected);
                try std.testing.expectEqualStrings(canonical_expected, event.eventJson());
                try std.testing.expectEqualStrings(case.message, event.raw());
            },
            .eose => |eose| {
                try std.testing.expectEqualStrings(case.extra, eose.subId());
            },
            .notice => |notice| {
                try std.testing.expectEqualStrings(case.extra, notice.text());
            },
            .ok => |ok| {
                try std.testing.expectEqual(ok.isAccepted(), true);
                try std.testing.expectEqualStrings(
                    "b1a649ebe8b435ec71d3784793f3bbf4b93e64e17568a741aecd4c7ddeafce30",
                    ok.eventId(),
                );
                try std.testing.expectEqualStrings(case.extra, ok.text());
            },
            .unknown => |unknown| {
                try std.testing.expectEqualStrings(case.extra, unknown.name());
                try std.testing.expectEqualStrings(case.message, unknown.raw());
            },
        }
    }

    const invalid_cases = [_]struct {
        message: []const u8,
        err: net.RelayMessageParseError,
    }{
        .{ .message = "", .err = net.RelayMessageParseError.EmptyMessage },
        .{ .message = "[]", .err = net.RelayMessageParseError.InvalidStructure },
        .{ .message = "[\"EVENT\"]", .err = net.RelayMessageParseError.InvalidStructure },
        .{ .message = "[\"EOSE\"]", .err = net.RelayMessageParseError.InvalidStructure },
        .{ .message = "[\"NOTICE\",404]", .err = net.RelayMessageParseError.InvalidStructure },
        .{ .message = "[\"OK\",\"id\",\"not-bool\",\"msg\"]", .err = net.RelayMessageParseError.InvalidStructure },
    };

    inline for (invalid_cases) |case| {
        try std.testing.expectError(case.err, parser.parseText(case.message));
    }
}

fn canonicalJson(input: []const u8) ![]u8 {
    const allocator = std.testing.allocator;
    var value = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer value.deinit();
    return std.json.Stringify.valueAlloc(allocator, value.value, .{});
}

test "relay pool tracks subscriptions" {
    var pool = net.RelayPool.init(.{ .allocator = std.testing.allocator });
    defer pool.deinit();

    var dummy_client = try net.RelayClient.init(.{
        .allocator = std.testing.allocator,
        .url = "ws://example.com",
        .connect_timeout_ms = 1,
    });
    defer dummy_client.deinit();

    try pool.registerRelay(&dummy_client);
    try std.testing.expectEqual(@as(usize, 1), pool.relayCount());

    try pool.trackSubscription("sub-1", &dummy_client);
    try std.testing.expect(pool.relayForSubscription("sub-1") != null);

    pool.broadcast("[\"REQ\"]");
}

test "relay client receives scripted events and eose" {
    const allocator = std.testing.allocator;
    const port = reservePort();
    const responses = [_]Response{
        .{ .text = "[\"EVENT\",\"sub-123\",{\"id\":\"1\",\"pubkey\":\"p\",\"created_at\":1,\"kind\":1,\"tags\":[],\"content\":\"hello\",\"sig\":\"sig1\"}]" },
        .{ .text = "[\"EVENT\",\"sub-123\",{\"id\":\"2\",\"pubkey\":\"p\",\"created_at\":2,\"kind\":1,\"tags\":[],\"content\":\"world\",\"sig\":\"sig2\"}]" },
        .{ .text = "[\"EOSE\",\"sub-123\"]" },
    };

    var server = try net.MockRelayServer.init(.{ .allocator = allocator, .port = port, .responses = &responses });
    defer server.deinit();
    try server.start();

    const url = try server.address(allocator);
    defer allocator.free(url);

    var client = try net.RelayClient.init(.{
        .allocator = allocator,
        .url = url,
        .connect_timeout_ms = 2_000,
    });
    defer client.deinit();

    try client.connect(null);
    try client.sendText("[\"REQ\",\"sub-123\",{}]");

    const msg1_opt = try client.nextMessage(2_000);
    try std.testing.expect(msg1_opt != null);
    var msg1 = msg1_opt.?;
    defer msg1.deinit(allocator);
    switch (msg1) {
        .event => |event| {
            try std.testing.expectEqualStrings("sub-123", event.subId());
            const expected = try canonicalJson("{\"id\":\"1\",\"pubkey\":\"p\",\"created_at\":1,\"kind\":1,\"tags\":[],\"content\":\"hello\",\"sig\":\"sig1\"}");
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, event.eventJson());
        },
        else => try std.testing.expect(false),
    }

    const msg2_opt = try client.nextMessage(2_000);
    try std.testing.expect(msg2_opt != null);
    var msg2 = msg2_opt.?;
    defer msg2.deinit(allocator);
    switch (msg2) {
        .event => |event| {
            const expected = try canonicalJson("{\"id\":\"2\",\"pubkey\":\"p\",\"created_at\":2,\"kind\":1,\"tags\":[],\"content\":\"world\",\"sig\":\"sig2\"}");
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, event.eventJson());
        },
        else => try std.testing.expect(false),
    }

    const msg3_opt = try client.nextMessage(2_000);
    try std.testing.expect(msg3_opt != null);
    var msg3 = msg3_opt.?;
    defer msg3.deinit(allocator);
    switch (msg3) {
        .eose => |eose| try std.testing.expectEqualStrings("sub-123", eose.subId()),
        else => try std.testing.expect(false),
    }
}

test "relay client ignores binary frames and handles notice" {
    const allocator = std.testing.allocator;
    const port = reservePort();
    const responses = [_]Response{
        .{ .binary = "ignored" },
        .{ .text = "[\"NOTICE\",\"maintenance\"]" },
    };

    var server = try net.MockRelayServer.init(.{ .allocator = allocator, .port = port, .responses = &responses });
    defer server.deinit();
    try server.start();

    const url = try server.address(allocator);
    defer allocator.free(url);

    var client = try net.RelayClient.init(.{ .allocator = allocator, .url = url });
    defer client.deinit();

    try client.connect(null);
    try client.sendText("[\"REQ\",\"sub-bin\",{}]");

    const notice_opt = try client.nextMessage(2_000);
    try std.testing.expect(notice_opt != null);
    var notice_msg = notice_opt.?;
    defer notice_msg.deinit(allocator);
    switch (notice_msg) {
        .notice => |notice| try std.testing.expectEqualStrings("maintenance", notice.text()),
        else => try std.testing.expect(false),
    }

    try std.testing.expect((try client.nextMessage(100)) == null);
}

test "relay client drops malformed messages" {
    const allocator = std.testing.allocator;
    const port = reservePort();
    const responses = [_]Response{
        .{ .text = "[\"EVENT\",\"sub-err\"]" },
        .{ .text = "[\"EOSE\",\"sub-err\"]" },
    };

    var server = try net.MockRelayServer.init(.{ .allocator = allocator, .port = port, .responses = &responses });
    defer server.deinit();
    try server.start();

    const url = try server.address(allocator);
    defer allocator.free(url);

    var client = try net.RelayClient.init(.{ .allocator = allocator, .url = url });
    defer client.deinit();

    try client.connect(null);
    try client.sendText("[\"REQ\",\"sub-err\",{}]");

    try std.testing.expect((try client.nextMessage(200)) == null);

    const eose_opt = try client.nextMessage(2_000);
    try std.testing.expect(eose_opt != null);
    var eose_msg = eose_opt.?;
    defer eose_msg.deinit(allocator);
    try std.testing.expect(eose_msg == .eose);
}
