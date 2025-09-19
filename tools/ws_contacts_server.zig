const std = @import("std");
const core = @import("ws_contacts_core.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var url: ?[]const u8 = null;
    var origin: []const u8 = "https://nostrdb-ssr.local";
    var limit: usize = 10;
    var timeout_ms: u32 = 20_000;
    var port: u16 = 8085;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--url")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            url = args[i];
        } else if (std.mem.eql(u8, arg, "--origin")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            origin = args[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            limit = std.fmt.parseUnsigned(usize, args[i], 10) catch limit;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            timeout_ms = std.fmt.parseUnsigned(u32, args[i], 10) catch timeout_ms;
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            port = std.fmt.parseUnsigned(u16, args[i], 10) catch port;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        }
    }

    const req_url = url orelse {
        usage();
        return;
    };

    var app = App{
        .allocator = allocator,
        .url = req_url,
        .origin = origin,
        .limit = limit,
        .timeout_ms = timeout_ms,
    };

    std.log.info("ws-contacts server listening on http://0.0.0.0:{d}", .{port});
    try app.serve(port);
}

fn usage() void {
    std.debug.print(
        "Usage: zig run tools/ws_contacts_server.zig -- --url wss://relay [--origin URL] [--limit N] [--timeout ms] [--port P]\n",
        .{},
    );
}

const App = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    origin: []const u8,
    limit: usize,
    timeout_ms: u32,

    fn serve(self: *App, port: u16) !void {
        const address = try std.net.Address.parseIp("0.0.0.0", port);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        while (true) {
            var conn = server.accept() catch |err| {
                std.log.warn("accept failed: {s}", .{@errorName(err)});
                continue;
            };
            self.handleConnection(&conn) catch |err| {
                std.log.warn("connection error: {s}", .{@errorName(err)});
            };
        }
    }

    fn handleConnection(self: *App, conn: *std.net.Server.Connection) !void {
        defer conn.stream.close();

        var read_buf: [16 * 1024]u8 = undefined;
        var write_buf: [16 * 1024]u8 = undefined;
        var reader = std.net.Stream.reader(conn.stream, &read_buf);
        var writer = std.net.Stream.writer(conn.stream, &write_buf);

        var server = std.http.Server.init(reader.interface(), &writer.interface);
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            error.HttpHeadersInvalid => return,
            else => return err,
        };

        if (req.head.method != .GET) {
            return req.respond("Method Not Allowed", .{
                .status = .method_not_allowed,
                .keep_alive = false,
            });
        }

        const path = req.head.target;
        if (!std.mem.startsWith(u8, path, "/")) {
            return req.respond("Bad Request", .{
                .status = .bad_request,
                .keep_alive = false,
            });
        }

        const query = if (std.mem.indexOfScalar(u8, path, '?')) |idx|
            path[idx + 1 ..]
        else
            path[path.len..path.len];

        const npub = findQueryValue(query, "npub");

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var timeline_opt: ?core.Timeline = null;
        var message: ?[]const u8 = null;

        if (npub) |npub_value| {
            if (npub_value.len == 0) {
                message = "npub cannot be empty";
            } else {
                timeline_opt = blk: {
                    const timeline_res = core.fetchTimeline(alloc, .{
                        .url = self.url,
                        .origin = self.origin,
                        .npub = npub_value,
                        .limit = self.limit,
                        .timeout_ms = self.timeout_ms,
                    }) catch |err| {
                        message = switch (err) {
                            error.MissingAuthor => "missing npub",
                            error.NoFollows => "no follows found",
                            error.UnsupportedScheme => "unsupported relay url",
                            error.Invalid => "invalid npub",
                            else => "failed to fetch timeline",
                        };
                        break :blk null;
                    };
                    break :blk @as(?core.Timeline, timeline_res);
                };
            }
        }

        var body = std.array_list.Managed(u8).init(self.allocator);
        defer body.deinit();
        var bw = body.writer();

        try bw.writeAll("<!DOCTYPE html><html><head><meta charset='utf-8'><title>nostr contacts viewer</title><style>body{font-family:system-ui;margin:0;padding:20px;background:#0f172a;color:#e2e8f0;}main{max-width:720px;margin:0 auto;}form{display:flex;gap:12px;margin-bottom:20px;}input{flex:1;padding:8px;border-radius:6px;border:1px solid #334155;background:#1e293b;color:#e2e8f0;}button{padding:8px 16px;border-radius:6px;border:none;background:#38bdf8;color:#0f172a;font-weight:600;}section.post{margin-bottom:18px;padding:12px;border-radius:8px;background:#1e293b;}a{color:#38bdf8;text-decoration:none;}a:hover{text-decoration:underline;}p.meta{color:#94a3b8;font-size:14px;margin-top:4px;}</style></head><body><main><h1>nostr contacts timeline</h1>");

        try bw.writeAll("<form method='GET'><input name='npub' placeholder='npub1...' value='");
        if (npub) |value| try htmlEscape(&bw, value);
        try bw.writeAll("'/><button type='submit'>Fetch</button></form>");

        if (message) |msg| {
            try bw.writeAll("<div class='flash'>");
            try htmlEscape(&bw, msg);
            try bw.writeAll("</div>");
        } else if (timeline_opt) |*timeline| {
            try bw.print("<p class='meta'>follows captured: {d} — posts fetched: {d}</p>", .{ timeline.follows.len, timeline.posts.len });
            for (timeline.posts) |post| {
                try bw.writeAll("<section class='post'><h2>");
                try htmlEscape(&bw, post.display_name);
                try bw.writeAll(": </h2><p>");
                try htmlEscapeMultiline(&bw, post.content);
                try bw.writeAll("</p><p class='meta'><a target='_blank' rel='noopener' href='https://primal.net/e/");
                try htmlEscape(&bw, post.event_id);
                try bw.writeAll("'>view on primal</a></p></section>");
            }
            timeline.deinit(alloc);
        }

        try bw.writeAll("</main></body></html>");

        const response_body = try body.toOwnedSlice();
        defer self.allocator.free(response_body);

        try req.respond(response_body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }
};

fn findQueryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const k = pair[0..eq];
        if (!std.mem.eql(u8, k, key)) continue;
        return pair[eq + 1 ..];
    }
    return null;
}

fn htmlEscape(writer: anytype, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '\"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(ch),
    };
}

fn htmlEscapeMultiline(writer: anytype, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\n' => try writer.writeAll("<br/>"),
        '\r' => {},
        '\t' => try writer.writeAll("&nbsp;&nbsp;&nbsp;&nbsp;"),
        else => {
            const single = [1]u8{ch};
            try htmlEscape(writer, single[0..]);
        },
    };
}
