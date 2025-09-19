const std = @import("std");
const net = @import("net");
const proto = @import("proto");

fn findFreePort() !u16 {
    var port: u16 = 48000;
    var tries: usize = 0;
    while (tries < 500) : (tries += 1) {
        const addr = try std.net.Address.parseIp("127.0.0.1", port);
        var listener = addr.listen(.{ .reuse_address = true }) catch {
            port +%= 1;
            continue;
        };
        listener.deinit();
        return port;
    }
    return error.PortSearchFailed;
}

fn encodeHexLower(buf: []u8, bytes: []const u8) []const u8 {
    const charset = "0123456789abcdef";
    std.debug.assert(buf.len >= bytes.len * 2);
    for (bytes, 0..) |b, i| {
        buf[i * 2] = charset[b >> 4];
        buf[i * 2 + 1] = charset[b & 0x0F];
    }
    return buf[0 .. bytes.len * 2];
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Prepare test data
    const npub_str = "npub1zxu639qym0esxnn7rzrt48wycmfhdu3e5yvzwx7ja3t84zyc2r8qz8cx2y";
    const npub_key = try proto.decodeNpub(npub_str);
    var npub_hex_buf: [64]u8 = undefined;
    const npub_hex = encodeHexLower(&npub_hex_buf, npub_key[0..]);

    // Follow author (use a fixed hex pubkey we also post from)
    const follow_hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d";

    // Build contacts event JSON (kind 3)
    const contacts_json = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"pubkey\":\"{s}\",\"created_at\":{d},\"kind\":3,\"tags\":[[\"p\",\"{s}\"]],\"content\":\"\",\"sig\":\"sig\"}}",
        .{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", npub_hex, 111, follow_hex },
    );
    defer allocator.free(contacts_json);

    // Build a post by the follow author (kind 1)
    const content_text = "hello e2e from follow";
    const post_json = try std.fmt.allocPrint(allocator,
        "{{\"id\":\"{s}\",\"pubkey\":\"{s}\",\"created_at\":{d},\"kind\":1,\"tags\":[],\"content\":\"{s}\",\"sig\":\"sig\"}}",
        .{ "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", follow_hex, 222, content_text },
    );
    defer allocator.free(post_json);

    // Prepare relay batches: contacts then posts
    const req_tmpl = "[\"REQ\",\"{SUB_ID}\",{}]"; // payload ignored by mock
    _ = req_tmpl; // unused, but doc
    const eose_tmpl = "[\"EOSE\",\"{SUB_ID}\"]";
    const contacts_event = try std.mem.concat(allocator, u8, &.{ "[\"EVENT\",\"{SUB_ID}\",", contacts_json, "]" });
    const post_event = try std.mem.concat(allocator, u8, &.{ "[\"EVENT\",\"{SUB_ID}\",", post_json, "]" });
    defer allocator.free(contacts_event);
    defer allocator.free(post_event);

    const relay_port = try findFreePort();
    var relay_thread = try std.Thread.spawn(.{}, simpleRelay, .{ allocator, relay_port, contacts_event, post_event, eose_tmpl });
    defer relay_thread.join();
    var relay_url_buf: [64]u8 = undefined;
    const relay_url = try std.fmt.bufPrint(&relay_url_buf, "ws://127.0.0.1:{d}", .{relay_port});

    // Start SSR binary
    const ssr_port = try findFreePort();
    // Create temp db path in CWD
    var db_path_buf: [128]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&db_path_buf, "e2e-db-{d}", .{std.time.milliTimestamp()});
    try std.fs.cwd().makePath(db_path);
    defer std.fs.cwd().deleteTree(db_path) catch {};

    const ssr_path = "zig-out/bin/ssr-demo";

    var child = std.process.Child.init(&.{ ssr_path, "--db-path", db_path, "--port", try std.fmt.allocPrint(allocator, "{d}", .{ssr_port}), "--relays", relay_url }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    defer { _ = child.kill() catch {}; }

    // Wait for SSR to listen by probing "/"
    var ready_tries: usize = 0;
    while (ready_tries < 30) : (ready_tries += 1) {
        if (try httpGetOk(ssr_port, "/")) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    // Trigger timeline for the npub
    var url_path_buf: [256]u8 = undefined;
    const url_path = try std.fmt.bufPrint(&url_path_buf, "/timeline?npub={s}", .{npub_str});

    var found = false;
    var attempts: usize = 0;
    while (attempts < 40 and !found) : (attempts += 1) {
        const body = try httpGetBody(allocator, ssr_port, url_path);
        defer allocator.free(body);
        if (std.mem.indexOf(u8, body, content_text) != null) {
            found = true;
            break;
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    if (!found) return error.E2EContentNotFound;
}

fn simpleRelay(
    allocator: std.mem.Allocator,
    port: u16,
    contacts_event_tmpl: []const u8,
    post_event_tmpl: []const u8,
    eose_tmpl: []const u8,
) void {
    _ = allocator;
    var listener = std.net.Address.parseIp("127.0.0.1", port) catch return;
    var server = listener.listen(.{ .reuse_address = true }) catch return;
    defer server.deinit();

    // Accept a single client
    var conn = server.accept() catch return;
    defer conn.stream.close();

    // Read HTTP request
    var hbuf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < hbuf.len) {
        const n = conn.stream.read(hbuf[total..]) catch 0;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, hbuf[0..total], "\r\n\r\n") != null) break;
    }
    const req_hdr = hbuf[0..total];
    const key = findHeader(req_hdr, "Sec-WebSocket-Key");
    if (key == null) return;
    var accept_buf: [28]u8 = undefined; // base64 sha1 is 28 bytes
    const accept = computeAccept(key.? , &accept_buf) catch return;

    // Send 101 response
    var wbuf2: [1024]u8 = undefined;
    var w2 = std.net.Stream.writer(conn.stream, &wbuf2);
    _ = w2.writeAll("HTTP/1.1 101 Switching Protocols\r\n") catch return;
    _ = w2.writeAll("Upgrade: websocket\r\nConnection: Upgrade\r\n") catch return;
    var lbuf: [256]u8 = undefined;
    const l = std.fmt.bufPrint(&lbuf, "Sec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return;
    _ = w2.writeAll(l) catch return;

    // Read first REQ frame; extract sub id
    var sub_buf: [64]u8 = undefined;
    const sub = readReqSubId(&conn.stream, &sub_buf) orelse return;

    // Prepare messages with sub id
    const ce = std.heap.page_allocator.alloc(u8, contacts_event_tmpl.len - 9 + sub.len) catch return; // replace {SUB_ID}
    defer std.heap.page_allocator.free(ce);
    _ = replaceSubId(contacts_event_tmpl, sub, ce);
    const pe = std.heap.page_allocator.alloc(u8, post_event_tmpl.len - 9 + sub.len) catch return;
    defer std.heap.page_allocator.free(pe);
    _ = replaceSubId(post_event_tmpl, sub, pe);
    const ee = std.heap.page_allocator.alloc(u8, eose_tmpl.len - 9 + sub.len) catch return;
    defer std.heap.page_allocator.free(ee);
    _ = replaceSubId(eose_tmpl, sub, ee);

    // Send contacts batch
    _ = writeTextFrame(&conn.stream, ce) catch return;
    _ = writeTextFrame(&conn.stream, ee) catch return;

    // Read second REQ (live) or timeout
    _ = readReqSubId(&conn.stream, &sub_buf);

    // Send post batch
    _ = writeTextFrame(&conn.stream, pe) catch return;
    _ = writeTextFrame(&conn.stream, ee) catch return;
}

fn findHeader(hdr: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, hdr, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\n");
        if (line.len <= name.len + 1) continue;
        if (std.ascii.startsWithIgnoreCase(line, name) and line[name.len] == ':') {
            const val = std.mem.trim(u8, line[name.len + 1 ..], " ");
            return val;
        }
    }
    return null;
}

fn computeAccept(key: []const u8, out: []u8) ![]const u8 {
    const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    const b64 = std.base64.standard.Encoder;
    const len = b64.calcSize(digest.len);
    if (out.len < len) return error.OutOfMemory;
    _ = b64.encode(out[0..len], &digest);
    return out[0..len];
}

fn readReqSubId(stream: *std.net.Stream, out: []u8) ?[]const u8 {
    // Minimal frame parser for masked text frames <=125 bytes
    var hdr: [2]u8 = undefined;
    if (stream.read(&hdr)) |n| { if (n != 2) return null; } else return null;
    if ((hdr[0] & 0x0F) != 1) return null; // not text
    const masked = (hdr[1] & 0x80) != 0;
    const len: usize = (hdr[1] & 0x7F);
    if (len == 126) return null; // keep simple
    var mask: [4]u8 = undefined;
    if (!masked) return null;
    if (stream.read(&mask)) |n| { if (n != 4) return null; } else return null;
    var payload = std.heap.page_allocator.alloc(u8, len) catch return null;
    defer std.heap.page_allocator.free(payload);
    if (stream.read(payload)) |n| { if (n != len) return null; } else return null;
    var i: usize = 0;
    while (i < len) : (i += 1) payload[i] ^= mask[i % 4];
    // find sub id in ["REQ","<sub>", ...]
    const start = std.mem.indexOf(u8, payload, "\"REQ\",\"") orelse return null;
    const s = start + 6;
    const end = std.mem.indexOfScalar(u8, payload[s..], '\"') orelse return null;
    const sub = payload[s .. s + end];
    if (sub.len > out.len) return null;
    std.mem.copy(u8, out[0..sub.len], sub);
    return out[0..sub.len];
}

fn writeTextFrame(stream: *std.net.Stream, payload: []const u8) !void {
    var header: [2]u8 = .{ 0x81, 0 };
    if (payload.len <= 125) {
        header[1] = @intCast(payload.len);
        try stream.writeAll(&header);
    } else {
        header[1] = 126;
        try stream.writeAll(&header);
        var ext: [2]u8 = undefined;
        std.mem.writeIntBig(u16, &ext, @intCast(payload.len));
        try stream.writeAll(&ext);
    }
    try stream.writeAll(payload);
}

fn replaceSubId(tmpl: []const u8, sub: []const u8, out: []u8) []const u8 {
    const needle = "{SUB_ID}";
    const pos = std.mem.indexOf(u8, tmpl, needle) orelse return tmpl;
    std.mem.copy(u8, out[0..pos], tmpl[0..pos]);
    std.mem.copy(u8, out[pos .. pos + sub.len], sub);
    std.mem.copy(u8, out[pos + sub.len ..], tmpl[pos + needle.len ..]);
    return out;
}
fn httpGetOk(port: u16, path: []const u8) !bool {
    var stream = try std.net.tcpConnectToAddress(try std.net.Address.parseIp("127.0.0.1", port));
    defer stream.close();
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path});
    _ = try stream.write(req);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.heap.page_allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&tmp) catch |e| switch (e) {
            error.ConnectionResetByPeer => 0,
            else => return e,
        };
        if (n == 0) break;
        try buf.appendSlice(std.heap.page_allocator, tmp[0..n]);
    }
    return std.mem.startsWith(u8, buf.items, "HTTP/1.1 200");
}

fn httpGetBody(allocator: std.mem.Allocator, port: u16, path: []const u8) ![]u8 {
    var stream = try std.net.tcpConnectToAddress(try std.net.Address.parseIp("127.0.0.1", port));
    defer stream.close();
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path});
    _ = try stream.write(req);
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&tmp) catch |e| switch (e) {
            error.ConnectionResetByPeer => 0,
            else => return e,
        };
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    // Split header and body
    if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |idx| {
        const body = buf.items[idx + 4 ..];
        const out = try allocator.dupe(u8, body);
        buf.deinit(allocator);
        return out;
    }
    const out_full = try allocator.dupe(u8, buf.items);
    buf.deinit(allocator);
    return out_full;
}
