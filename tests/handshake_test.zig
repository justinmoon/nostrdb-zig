const std = @import("std");
const net = @import("net");

test "optional: relay handshake with optional Origin" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const relay_url = std.process.getEnvVarOwned(allocator, "RELAY_URL") catch null;
    defer if (relay_url) |r| allocator.free(r);
    if (relay_url == null) return; // skip unless provided

    const origin = std.process.getEnvVarOwned(allocator, "WS_ORIGIN") catch null;
    defer if (origin) |o| allocator.free(o);

    var client = try net.RelayClient.init(.{
        .allocator = allocator,
        .url = relay_url.?,
        .origin = if (origin) |o| o else null,
    });
    defer client.deinit();

    try client.connect(null);
    client.close();
}

