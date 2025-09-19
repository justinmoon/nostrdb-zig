const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var url: ?[]const u8 = null;
    var origin: []const u8 = "https://nostrdb-ssr.local";
    var timeout_ms: u32 = 10_000;
    var author_hex: ?[]const u8 = null;
    var contacts: bool = false;
    var close_on_eose: bool = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--url")) {
            i += 1; if (i >= args.len) return error.InvalidArgument;
            url = args[i];
        } else if (std.mem.eql(u8, arg, "--origin")) {
            i += 1; if (i >= args.len) return error.InvalidArgument;
            origin = args[i];
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1; if (i >= args.len) return error.InvalidArgument;
            timeout_ms = std.fmt.parseUnsigned(u32, args[i], 10) catch 10_000;
        } else if (std.mem.eql(u8, arg, "--author-hex")) {
            i += 1; if (i >= args.len) return error.InvalidArgument;
            author_hex = args[i];
        } else if (std.mem.eql(u8, arg, "--contacts")) {
            contacts = true;
        } else if (std.mem.eql(u8, arg, "--close-on-eose")) {
            close_on_eose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage();
            return;
        } else {}
    }

    if (url == null) {
        std.log.info("No --url provided; trying RELAYS env (comma separated)", .{});
        const relays = std.process.getEnvVarOwned(allocator, "RELAYS") catch null;
        defer if (relays) |r| allocator.free(r);
        if (relays) |list| {
            var it = std.mem.splitScalar(u8, list, ',');
            var ok = false;
            while (it.next()) |entry| {
                const trimmed = std.mem.trim(u8, entry, " ");
                if (trimmed.len == 0) continue;
                ok = try tryOnce(allocator, trimmed, origin, timeout_ms, author_hex, contacts, close_on_eose);
                if (ok) return;
            }
            return error.NoRelaySucceeded;
        } else {
            try printUsage();
            return error.InvalidArgument;
        }
    } else {
        if (try tryOnce(allocator, url.?, origin, timeout_ms, author_hex, contacts, close_on_eose)) return;
        return error.NoRelaySucceeded;
    }
}

fn tryOnce(allocator: Allocator, url: []const u8, origin: []const u8, timeout_ms: u32, author_hex: ?[]const u8, contacts: bool, close_on_eose: bool) !bool {
    var parts = try parseUrl(allocator, url);
    defer parts.deinit(allocator);

    var client = try websocket.Client.init(allocator, .{
        .port = parts.port,
        .host = parts.host,
        .tls = parts.use_tls,
        .buffer_size = 4096,
        .max_size = 65536,
    });
    defer client.deinit();

    var host_header_buf: [256]u8 = undefined;
    const host_header = hostHeader(&host_header_buf, parts.host, parts.port, parts.use_tls) catch parts.host;

    var header_buf: [512]u8 = undefined;
    var pos: usize = 0;
    pos += copy(&header_buf, pos, "Host: ");
    pos += copy(&header_buf, pos, host_header);
    pos += copy(&header_buf, pos, "\r\n");
    pos += copy(&header_buf, pos, "Origin: ");
    pos += copy(&header_buf, pos, origin);
    pos += copy(&header_buf, pos, "\r\n");

    std.log.info("handshake {s}://{s}:{d}{s} origin={s}", .{ if (parts.use_tls) "wss" else "ws", parts.host, parts.port, parts.path, origin });
    try client.handshake(parts.path, .{ .timeout_ms = timeout_ms, .headers = header_buf[0..pos] });

    // subscribe to something: default kinds=1; or contacts for author
    const req = if (contacts and author_hex != null)
        try std.fmt.allocPrint(allocator, "[\\\"REQ\\\",\\\"smoke\\\",{{\\\"kinds\\\":[3],\\\"authors\\\":[\\\"{s}\\\"],\\\"limit\\\":1}}]", .{author_hex.?})
    else
        try allocator.dupe(u8, "[\"REQ\",\"smoke\",{\"kinds\":[1],\"limit\":1}]");
    defer allocator.free(req);
    try client.write(req);

    // read up to first message or EOSE. Give it up to timeout_ms total.
    try client.readTimeout(timeout_ms);
    const start = std.time.milliTimestamp();
    while (true) {
        const msg = (try client.read()) orelse {
            if (@as(u32, @intCast(std.time.milliTimestamp() - start)) >= timeout_ms) break;
            continue;
        };
        defer client.done(msg);

        switch (msg.type) {
            .text => {
                const d = msg.data;
                if (std.mem.startsWith(u8, d, "[\"EOSE\",")) {
                    std.log.info("got EOSE", .{});
                    if (close_on_eose) {
                        client.close(.{}) catch {};
                    }
                    return true;
                } else {
                    std.log.info("got text frame: {s}", .{d});
                    return true;
                }
            },
            .binary => {
                std.log.info("got binary frame {d} bytes", .{msg.data.len});
                return true;
            },
            .ping => try client.writePong(""),
            .pong => {},
            .close => break,
        }
    }
    return false;
}

fn copy(dst: []u8, pos: usize, src: []const u8) usize {
    @memcpy(dst[pos .. pos + src.len], src);
    return src.len;
}

fn hostHeader(buf: []u8, host: []const u8, port: u16, use_tls: bool) ![]const u8 {
    const default_port: u16 = if (use_tls) 443 else 80;
    if (port == default_port) return host;
    const n = try std.fmt.bufPrint(buf, "{s}:{d}", .{ host, port });
    return n;
}

const UrlParts = struct {
    host: []u8,
    path: []u8,
    port: u16,
    use_tls: bool,

    fn deinit(self: *UrlParts, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

fn parseUrl(allocator: Allocator, url: []const u8) !UrlParts {
    const ws_prefix = "ws://";
    const wss_prefix = "wss://";
    var scheme_tls = false;
    var remainder: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, ws_prefix)) {
        remainder = url[ws_prefix.len..];
        scheme_tls = false;
    } else if (std.mem.startsWith(u8, url, wss_prefix)) {
        remainder = url[wss_prefix.len..];
        scheme_tls = true;
    } else return error.UnsupportedScheme;

    const slash = std.mem.indexOfScalar(u8, remainder, '/') orelse remainder.len;
    const authority = remainder[0..slash];
    const path = if (slash < remainder.len) remainder[slash..] else "/";

    var host_slice = authority;
    var port: u16 = if (scheme_tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |idx| {
        host_slice = authority[0..idx];
        port = std.fmt.parseInt(u16, authority[idx + 1 ..], 10) catch port;
    }
    const host_copy = try allocator.dupe(u8, host_slice);
    const path_copy = try allocator.dupe(u8, path);
    return .{ .host = host_copy, .path = path_copy, .port = port, .use_tls = scheme_tls };
}

fn printUsage() !void {
    const s = "Usage: ws-smoke --url wss://relay.example.com [/path] [--origin https://site] [--timeout ms] [--contacts --author-hex HEX] [--close-on-eose]\n" ++
        "  Or set RELAYS=comma,separated,urls and omit --url\n";
    try std.fs.File.stdout().writeAll(s);
}
