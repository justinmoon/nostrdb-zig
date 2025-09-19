const std = @import("std");
const net = @import("net");

fn findFreePort() !u16 {
    var server = try std.net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(.{ .address = std.net.Address.initIp4(.{ .a = 127, .b = 0, .c = 0, .d = 1 }, 0) });
    const addr = try server.addr();
    return addr.getPort();
}

test "handshake fails against non-websocket HTTP server" {
    const allocator = std.testing.allocator;

    // Spin a trivial HTTP server that returns 200 OK (not a 101 upgrade)
    const port = try findFreePort();
    var server = try std.net.StreamServer.init(.{ .reuse_address = true });
    defer server.deinit();
    try server.listen(.{ .address = std.net.Address.initIp4(.{ .a = 127, .b = 0, .c = 0, .d = 1 }, port) });

    var accept_thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *std.net.StreamServer) void {
            var conn = srv.accept() catch return;
            defer conn.stream.close();
            const resp = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n";
            _ = conn.stream.writer().writeAll(resp) catch {};
        }
    }.run, .{&server});
    defer accept_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}", .{port});

    var client = try net.RelayClient.init(.{ .allocator = allocator, .url = url, .connect_timeout_ms = 1500 });
    defer client.deinit();
    try std.testing.expectError(net.RelayClientConnectError.HandshakeFailed, client.connect(null));
}

test "external relay handshake (opt-in via RELAY_URL)" {
    const allocator = std.testing.allocator;
    const env = std.process.getEnvMap(allocator) catch {
        // Environment not available under some runners; skip
        return;
    };
    defer env.deinit();
    const relay_url = env.get("RELAY_URL") orelse return; // opt-in

    var client = try net.RelayClient.init(.{ .allocator = allocator, .url = relay_url, .connect_timeout_ms = 4000 });
    defer client.deinit();
    // Should at least handshake
    try client.connect(null);
    client.close();
}

