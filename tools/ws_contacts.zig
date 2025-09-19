const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var url: ?[]const u8 = null;
    var origin: []const u8 = "https://nostrdb-ssr.local";
    var npub: ?[]const u8 = null;
    var author_hex: ?[]const u8 = null; // deprecated input; prefer --npub
    var post_limit: usize = 5;
    var timeout_ms: u32 = 20_000;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--url")) {
            i += 1; if (i >= args.len) return usage();
            url = args[i];
        } else if (std.mem.eql(u8, arg, "--origin")) {
            i += 1; if (i >= args.len) return usage();
            origin = args[i];
        } else if (std.mem.eql(u8, arg, "--npub")) {
            i += 1; if (i >= args.len) return usage();
            npub = args[i];
        } else if (std.mem.eql(u8, arg, "--author-hex")) {
            i += 1; if (i >= args.len) return usage();
            author_hex = args[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1; if (i >= args.len) return usage();
            post_limit = std.fmt.parseUnsigned(usize, args[i], 10) catch 5;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1; if (i >= args.len) return usage();
            timeout_ms = std.fmt.parseUnsigned(u32, args[i], 10) catch 20_000;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return usage();
        }
    }

    if (url == null) return usage();

    var parts = try parseUrl(allocator, url.?);
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
    var hpos: usize = 0;
    hpos += copy(&header_buf, hpos, "Host: ");
    hpos += copy(&header_buf, hpos, host_header);
    hpos += copy(&header_buf, hpos, "\r\n");
    hpos += copy(&header_buf, hpos, "Origin: ");
    hpos += copy(&header_buf, hpos, origin);
    hpos += copy(&header_buf, hpos, "\r\n");

    std.debug.print("handshake {s}://{s}:{d}{s} origin={s}\n", .{ if (parts.use_tls) "wss" else "ws", parts.host, parts.port, parts.path, origin });
    try client.handshake(parts.path, .{ .timeout_ms = timeout_ms, .headers = header_buf[0..hpos] });

    // Resolve author hex
    var author_buf: [64]u8 = undefined;
    const author = blk: {
        if (author_hex) |h| break :blk h;
        if (npub) |n| {
            const pk = try decodeNpub(n);
            const hex = hexLower(&author_buf, pk[0..]);
            break :blk hex;
        }
        return usage();
    };

    // 1) Fetch contacts (kind=3) for author
    const sub_contacts = "contacts-1";
    const req_contacts = try std.fmt.allocPrint(allocator, "[\"REQ\",\"{s}\",{{\"kinds\":[3],\"authors\":[\"{s}\"],\"limit\":1}}]", .{ sub_contacts, author });
    defer allocator.free(req_contacts);
    try client.write(req_contacts);

    try client.readTimeout(timeout_ms);
    var follows = std.array_list.Managed([]const u8).init(allocator);
    defer {
        for (follows.items) |x| allocator.free(x);
        follows.deinit();
    }

    // Read until EOSE for contacts
    while (true) {
        const msg = (try client.read()) orelse continue;
        defer client.done(msg);
        switch (msg.type) {
            .text => {
                const d = msg.data;
                if (std.mem.startsWith(u8, d, "[\"EVENT\",")) {
                    if (std.mem.indexOf(u8, d, sub_contacts)) |_|
                        try extractFollows(allocator, d, &follows);
                } else if (std.mem.startsWith(u8, d, "[\"EOSE\",")) {
                    break;
                } else if (std.mem.startsWith(u8, d, "[\"NOTICE\",")) {
                    std.log.warn("NOTICE: {s}", .{d});
                }
            },
            .ping => try client.writePong(""),
            .close => break,
            else => {},
        }
    }

    std.debug.print("follows captured: {d}\n", .{follows.items.len});
    if (follows.items.len == 0) {
        std.log.warn("no follows; exiting", .{});
        return;
    }

    // 2) Fetch profiles (kind=0) for follows to map pubkey -> display name
    const sub_profiles = "profiles-1";
    const prof_req = try buildProfilesReq(allocator, sub_profiles, follows.items);
    defer allocator.free(prof_req);
    try client.write(prof_req);

    // 3) Fetch posts (kind=1) for follows
    const sub_posts = "posts-1";
    const posts_req = try buildPostsReq(allocator, sub_posts, follows.items, post_limit);
    defer allocator.free(posts_req);
    try client.write(posts_req);

    var names = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = names.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        names.deinit();
    }

    var printed: usize = 0;
    const start_ms: u64 = @intCast(std.time.milliTimestamp());
    while (printed < post_limit) {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        if ((now_ms - start_ms) > timeout_ms) break;
        const msg = (try client.read()) orelse continue;
        defer client.done(msg);
        switch (msg.type) {
            .text => {
                const d = msg.data;
                const kind = frameKind(d);
                if (kind == .event) {
                    const sub = subIdFromFrame(d) orelse continue;
                    if (std.mem.eql(u8, sub, sub_profiles)) {
                        updateNameMap(allocator, d, &names) catch {};
                    } else if (std.mem.eql(u8, sub, sub_posts)) {
                        if (printPostLine(allocator, d, &names, follows.items)) |did| {
                            if (did) printed += 1;
                        } else |_| {}
                    }
                } else if (kind == .eose) {
                    // ignore
                } else if (kind == .notice) {
                    std.log.warn("NOTICE: {s}", .{d});
                }
            },
            .ping => try client.writePong(""),
            .close => break,
            else => {},
        }
    }

    std.debug.print("downloaded posts: {d}\n", .{printed});
}

fn usage() !void {
    const s = "Usage: ws-contacts --url wss://relay --npub <npub> [--origin URL] [--limit N] [--timeout ms]\n" ++
        "   (deprecated) --author-hex <64hex> also accepted\n";
    try std.fs.File.stdout().writeAll(s);
}

fn buildPostsReq(allocator: Allocator, sub: []const u8, authors: []const []const u8, limit: usize) ![]u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    var w = list.writer();
    try w.writeAll("[\"REQ\",\"");
    try w.print("{s}", .{sub});
    try w.writeAll("\",{");
    try w.writeAll("\"kinds\":[1],\"authors\":[");
    var i: usize = 0;
    while (i < authors.len) : (i += 1) {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(authors[i]);
        try w.writeByte('"');
    }
    try w.writeAll("],\"limit\":");
    try w.print("{d}", .{limit});
    try w.writeAll("}]");
    return try list.toOwnedSlice();
}

fn buildProfilesReq(allocator: Allocator, sub: []const u8, authors: []const []const u8) ![]u8 {
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    var w = list.writer();
    try w.writeAll("[\"REQ\",\"");
    try w.print("{s}", .{sub});
    try w.writeAll("\",{");
    try w.writeAll("\"kinds\":[0],\"authors\":[");
    var i: usize = 0;
    while (i < authors.len) : (i += 1) {
        if (i != 0) try w.writeByte(',');
        try w.writeByte('"');
        try w.writeAll(authors[i]);
        try w.writeByte('"');
    }
    try w.writeAll("]}]");
    return try list.toOwnedSlice();
}

const FrameKind = enum { event, eose, notice, other };

fn frameKind(d: []const u8) FrameKind {
    if (std.mem.startsWith(u8, d, "[\"EVENT\",")) return .event;
    if (std.mem.startsWith(u8, d, "[\"EOSE\",")) return .eose;
    if (std.mem.startsWith(u8, d, "[\"NOTICE\",")) return .notice;
    return .other;
}

fn subIdFromFrame(d: []const u8) ?[]const u8 {
    // ["EVENT","sub",{...}]
    const first = std.mem.indexOfScalar(u8, d, ',') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, d, first + 1, ',') orelse return null;
    // substring between first+2 and second-1: "sub"
    if (first + 2 >= second - 1) return null;
    return d[first + 2 .. second - 1];
}

fn updateNameMap(allocator: Allocator, frame: []const u8, names: *std.StringHashMap([]const u8)) !void {
    // Extract event JSON
    const start = std.mem.indexOfScalar(u8, frame, '{') orelse return;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame[start..frame.len - 1], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const kind_v = obj.get("kind") orelse return;
    if (kind_v != .integer or kind_v.integer != 0) return;
    const pubkey_v = obj.get("pubkey") orelse return;
    const content_v = obj.get("content") orelse return;
    if (pubkey_v != .string or content_v != .string) return;
    // content is JSON string
    var prof = std.json.parseFromSlice(std.json.Value, allocator, content_v.string, .{}) catch return;
    defer prof.deinit();
    const pobj = prof.value.object;
    var name_opt: ?[]const u8 = null;
    if (pobj.get("display_name")) |dv| {
        if (dv == .string and dv.string.len > 0) name_opt = dv.string;
    }
    if (name_opt == null) {
        if (pobj.get("name")) |nv| {
            if (nv == .string and nv.string.len > 0) name_opt = nv.string;
        }
    }
    if (name_opt == null) {
        if (pobj.get("username")) |uv| {
            if (uv == .string and uv.string.len > 0) name_opt = uv.string;
        }
    }
    const name = name_opt orelse return;
    const key = try allocator.dupe(u8, pubkey_v.string);
    errdefer allocator.free(key);
    const val = try allocator.dupe(u8, name);
    errdefer allocator.free(val);
    // Replace if exists
    if (names.get(key)) |old| {
        // free our dupes and don’t overwrite existing
        allocator.free(key);
        allocator.free(val);
        _ = old;
        return;
    }
    try names.put(key, val);
}

fn printPostLine(allocator: Allocator, frame: []const u8, names: *std.StringHashMap([]const u8), follows: []const []const u8) !bool {
    const start = std.mem.indexOfScalar(u8, frame, '{') orelse return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame[start..frame.len - 1], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const id_v = obj.get("id") orelse return false;
    const pk_v = obj.get("pubkey") orelse return false;
    const content_v = obj.get("content") orelse return false;
    if (id_v != .string or pk_v != .string or content_v != .string) return false;
    const ev_id = id_v.string;
    const pk = pk_v.string;
    // Sanity: ensure the post's author is in our follows set
    var is_followed = false;
    for (follows) |fpk| {
        if (std.mem.eql(u8, fpk, pk)) { is_followed = true; break; }
    }
    if (!is_followed) return false;
    const content = content_v.string;
    const display = blk: {
        if (names.get(pk)) |n| break :blk n;
        // fallback: first 8 of pubkey
        break :blk pk[0..@min(pk.len, 8)];
    };
    std.debug.print("{s}: {s}\n", .{ display, content });
    // Print Primal link with hex event id for quick sanity checking
    std.debug.print("https://primal.net/e/{s}\n\n", .{ev_id});
    return true;
}

fn extractFollows(allocator: Allocator, frame: []const u8, out: *std.array_list.Managed([]const u8)) !void {
    // frame is ["EVENT","sub",{...}]
    const start = std.mem.indexOfScalar(u8, frame, '{') orelse return;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame[start..frame.len - 1], .{});
    defer parsed.deinit();
    const v = parsed.value;
    if (v != .object) return;
    const obj = v.object;
    const tags_v = obj.get("tags") orelse return;
    if (tags_v != .array) return;
    for (tags_v.array.items) |t| {
        if (t != .array) continue;
        const arr = t.array.items;
        if (arr.len < 2) continue;
        if (arr[0] != .string) continue;
        if (!std.ascii.eqlIgnoreCase(arr[0].string, "p")) continue;
        if (arr[1] != .string) continue;
        // copy hex pubkey string
        const pk = try allocator.dupe(u8, arr[1].string);
        try out.append(pk);
    }
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
    var tls = false;
    var rest: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, ws_prefix)) { rest = url[ws_prefix.len..]; tls = false; }
    else if (std.mem.startsWith(u8, url, wss_prefix)) { rest = url[wss_prefix.len..]; tls = true; }
    else return error.UnsupportedScheme;
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    var host_slice = authority;
    var port: u16 = if (tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |idx| {
        host_slice = authority[0..idx];
        port = std.fmt.parseInt(u16, authority[idx + 1 ..], 10) catch port;
    }
    return .{ .host = try allocator.dupe(u8, host_slice), .path = try allocator.dupe(u8, path), .port = port, .use_tls = tls };
}

fn hexLower(buf: []u8, bytes: []const u8) []const u8 {
    const charset = "0123456789abcdef";
    std.debug.assert(buf.len >= bytes.len * 2);
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        buf[i * 2] = charset[b >> 4];
        buf[i * 2 + 1] = charset[b & 0x0F];
    }
    return buf[0 .. bytes.len * 2];
}

fn decodeNpub(npub: []const u8) ![32]u8 {
    // Minimal bech32 decode for NIP-19 npub
    const pos = std.mem.lastIndexOfScalar(u8, npub, '1') orelse return error.Invalid;
    const hrp = npub[0..pos];
    if (!std.ascii.eqlIgnoreCase(hrp, "npub")) return error.Invalid;
    const data = npub[pos + 1 ..];
    var v: [1024]U5 = undefined;
    const n = try bech32Decode(data, v[0..]);
    if (n < 6) return error.Invalid;
    const payload = v[0 .. n - 6];
    var out: [64]u8 = undefined;
    const out_bytes = try convertBits(out[0..], payload, 5, 8, false);
    if (out_bytes.len != 32) return error.Invalid;
    var pk: [32]u8 = undefined;
    @memcpy(pk[0..], out_bytes);
    return pk;
}

const U5 = u8; // values 0..31

fn bech32Decode(s: []const u8, out: []U5) !usize {
    // decode charset
    const charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        const idx = std.mem.indexOfScalar(u8, charset, std.ascii.toLower(ch)) orelse return error.Invalid;
        if (i >= out.len) return error.Invalid;
        out[i] = @as(U5, @intCast(idx));
    }
    return s.len;
}

fn convertBits(out: []u8, in5: []const U5, from_bits: u8, to_bits: u8, pad: bool) ![]u8 {
    var acc: u32 = 0;
    var bits: u8 = 0;
    var maxv: u32 = 1;
    maxv = maxv << @as(u5, @intCast(to_bits));
    maxv -= 1;
    var j: usize = 0;
    for (in5) |value| {
        acc = (acc << @as(u5, @intCast(from_bits))) | value;
        bits += from_bits;
        while (bits >= to_bits) {
            bits -= to_bits;
            if (j >= out.len) return error.Invalid;
            out[j] = @as(u8, @intCast((acc >> @as(u5, @intCast(bits))) & maxv));
            j += 1;
        }
    }
    if (pad) {
        if (bits > 0) {
            if (j >= out.len) return error.Invalid;
            out[j] = @as(u8, @intCast((acc << @as(u5, @intCast(to_bits - bits))) & maxv));
            j += 1;
        }
    } else {
        if (bits >= from_bits) return error.Invalid;
        if (((acc << @as(u5, @intCast(to_bits - bits))) & maxv) != 0) return error.Invalid;
    }
    return out[0..j];
}
