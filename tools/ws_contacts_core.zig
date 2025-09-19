const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;

pub const FetchOptions = struct {
    url: []const u8,
    origin: []const u8 = "https://nostrdb-ssr.local",
    npub: ?[]const u8 = null,
    author_hex: ?[]const u8 = null,
    limit: usize = 5,
    timeout_ms: u32 = 20_000,
};

pub const Post = struct {
    display_name: []const u8,
    content: []const u8,
    event_id: []const u8,
    pubkey: []const u8,
};

pub const Timeline = struct {
    follows: [][]const u8,
    posts: []Post,

    pub fn deinit(self: *Timeline, allocator: Allocator) void {
        for (self.follows) |f| allocator.free(f);
        allocator.free(self.follows);
        for (self.posts) |post| {
            allocator.free(post.display_name);
            allocator.free(post.content);
            allocator.free(post.event_id);
            allocator.free(post.pubkey);
        }
        allocator.free(self.posts);
    }
};

pub fn fetchTimeline(allocator: Allocator, opts: FetchOptions) !Timeline {
    if (opts.author_hex == null and opts.npub == null) return error.MissingAuthor;

    var parts = try parseUrl(allocator, opts.url);
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
    hpos += copy(&header_buf, hpos, opts.origin);
    hpos += copy(&header_buf, hpos, "\r\n");

    try client.handshake(parts.path, .{ .timeout_ms = opts.timeout_ms, .headers = header_buf[0..hpos] });

    var author_buf: [64]u8 = undefined;
    const author_hex = blk: {
        if (opts.author_hex) |h| break :blk h;
        const npub = opts.npub.?;
        const pk = try decodeNpub(npub);
        const hex = hexLower(&author_buf, pk[0..]);
        break :blk hex;
    };

    const sub_contacts = "contacts-1";
    const req_contacts = try std.fmt.allocPrint(allocator, "[\"REQ\",\"{s}\",{{\"kinds\":[3],\"authors\":[\"{s}\"],\"limit\":1}}]", .{ sub_contacts, author_hex });
    defer allocator.free(req_contacts);
    try client.write(req_contacts);

    try client.readTimeout(opts.timeout_ms);

    var follows_list = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (follows_list.items) |item| allocator.free(item);
        follows_list.deinit();
    }

    while (true) {
        const msg = (try client.read()) orelse continue;
        defer client.done(msg);
        switch (msg.type) {
            .text => {
                const data = msg.data;
                if (std.mem.startsWith(u8, data, "[\"EVENT\",")) {
                    if (std.mem.indexOf(u8, data, sub_contacts)) |_|
                        try extractFollows(allocator, data, &follows_list);
                } else if (std.mem.startsWith(u8, data, "[\"EOSE\",")) {
                    break;
                } else if (std.mem.startsWith(u8, data, "[\"NOTICE\",")) {
                    std.log.warn("NOTICE contacts: {s}", .{data});
                }
            },
            .ping => try client.writePong(""),
            .close => break,
            else => {},
        }
    }

    const follows_owned = try follows_list.toOwnedSlice();
    if (follows_owned.len == 0) {
        for (follows_owned) |f| allocator.free(f);
        allocator.free(follows_owned);
        return error.NoFollows;
    }

    const sub_profiles = "profiles-1";
    const profiles_req = try buildProfilesReq(allocator, sub_profiles, follows_owned);
    defer allocator.free(profiles_req);
    try client.write(profiles_req);

    const sub_posts = "posts-1";
    const posts_req = try buildPostsReq(allocator, sub_posts, follows_owned, opts.limit);
    defer allocator.free(posts_req);
    try client.write(posts_req);

    var names = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = names.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        names.deinit();
    }

    var posts_list = std.array_list.Managed(Post).init(allocator);
    errdefer {
        for (posts_list.items) |p| {
            allocator.free(p.display_name);
            allocator.free(p.content);
            allocator.free(p.event_id);
            allocator.free(p.pubkey);
        }
        posts_list.deinit();
        for (follows_owned) |f| allocator.free(f);
        allocator.free(follows_owned);
    }

    var follow_set = FollowSet.init(follows_owned);

    const start_ms: u64 = @intCast(std.time.milliTimestamp());
    while (posts_list.items.len < opts.limit) {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        if ((now_ms - start_ms) > opts.timeout_ms) break;

        const msg = (try client.read()) orelse continue;
        defer client.done(msg);

        switch (msg.type) {
            .text => {
                const data = msg.data;
                switch (frameKind(data)) {
                    .event => {
                        const sub = subIdFromFrame(data) orelse continue;
                        if (std.mem.eql(u8, sub, sub_profiles)) {
                            updateNameMap(allocator, data, &names) catch |err| switch (err) {
                                error.InvalidProfile => {},
                                else => return err,
                            };
                        } else if (std.mem.eql(u8, sub, sub_posts)) {
                            if (try collectPost(allocator, data, &names, &follow_set)) |post| {
                                try posts_list.append(post);
                            }
                        }
                    },
                    .notice => std.log.warn("NOTICE events: {s}", .{data}),
                    else => {},
                }
            },
            .ping => try client.writePong(""),
            .close => break,
            else => {},
        }
    }

    const posts_owned = try posts_list.toOwnedSlice();
    posts_list.deinit();

    return Timeline{
        .follows = follows_owned,
        .posts = posts_owned,
    };
}

const FollowSet = struct {
    keys: [][]const u8,

    fn init(keys: [][]const u8) FollowSet {
        return .{ .keys = keys };
    }

    fn contains(self: *const FollowSet, key: []const u8) bool {
        for (self.keys) |item| {
            if (std.mem.eql(u8, item, key)) return true;
        }
        return false;
    }
};

fn collectPost(allocator: Allocator, frame: []const u8, names: *std.StringHashMap([]const u8), follows: *const FollowSet) !?Post {
    const start = std.mem.indexOfScalar(u8, frame, '{') orelse return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, frame[start .. frame.len - 1], .{}) catch return null;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const id_v = obj.get("id") orelse return null;
    const pk_v = obj.get("pubkey") orelse return null;
    const content_v = obj.get("content") orelse return null;
    if (id_v != .string or pk_v != .string or content_v != .string) return null;
    const event_id = id_v.string;
    const pk = pk_v.string;
    if (!follows.contains(pk)) return null;

    const content = content_v.string;
    const display = blk: {
        if (names.get(pk)) |n| break :blk n;
        break :blk pk[0..@min(pk.len, 8)];
    };

    const display_copy = try allocator.dupe(u8, display);
    errdefer allocator.free(display_copy);
    const content_copy = try allocator.dupe(u8, content);
    errdefer allocator.free(content_copy);
    const event_copy = try allocator.dupe(u8, event_id);
    errdefer allocator.free(event_copy);
    const pk_copy = try allocator.dupe(u8, pk);
    errdefer allocator.free(pk_copy);

    return Post{
        .display_name = display_copy,
        .content = content_copy,
        .event_id = event_copy,
        .pubkey = pk_copy,
    };
}

fn buildPostsReq(allocator: Allocator, sub: []const u8, authors: [][]const u8, limit: usize) ![]u8 {
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

fn buildProfilesReq(allocator: Allocator, sub: []const u8, authors: [][]const u8) ![]u8 {
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
    const first = std.mem.indexOfScalar(u8, d, ',') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, d, first + 1, ',') orelse return null;
    if (first + 2 >= second - 1) return null;
    return d[first + 2 .. second - 1];
}

fn updateNameMap(allocator: Allocator, frame: []const u8, names: *std.StringHashMap([]const u8)) !void {
    const start = std.mem.indexOfScalar(u8, frame, '{') orelse return error.InvalidProfile;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame[start .. frame.len - 1], .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const kind_v = obj.get("kind") orelse return error.InvalidProfile;
    if (kind_v != .integer or kind_v.integer != 0) return;
    const pubkey_v = obj.get("pubkey") orelse return error.InvalidProfile;
    const content_v = obj.get("content") orelse return error.InvalidProfile;
    if (pubkey_v != .string or content_v != .string) return error.InvalidProfile;

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

    if (names.get(key)) |old| {
        allocator.free(key);
        allocator.free(val);
        _ = old;
        return;
    }
    try names.put(key, val);
}

fn extractFollows(allocator: Allocator, frame: []const u8, out: *std.array_list.Managed([]const u8)) !void {
    const start = std.mem.indexOfScalar(u8, frame, '{') orelse return;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame[start .. frame.len - 1], .{});
    defer parsed.deinit();
    const tags_v = parsed.value.object.get("tags") orelse return;
    if (tags_v != .array) return;
    for (tags_v.array.items) |entry| {
        if (entry != .array) continue;
        const arr = entry.array.items;
        if (arr.len < 2) continue;
        if (arr[0] != .string) continue;
        if (!std.ascii.eqlIgnoreCase(arr[0].string, "p")) continue;
        if (arr[1] != .string) continue;
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
    return try std.fmt.bufPrint(buf, "{s}:{d}", .{ host, port });
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
    if (std.mem.startsWith(u8, url, ws_prefix)) {
        rest = url[ws_prefix.len..];
    } else if (std.mem.startsWith(u8, url, wss_prefix)) {
        rest = url[wss_prefix.len..];
        tls = true;
    } else return error.UnsupportedScheme;

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = if (slash < rest.len) rest[slash..] else "/";
    var host_slice = authority;
    var port: u16 = if (tls) 443 else 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |idx| {
        host_slice = authority[0..idx];
        port = std.fmt.parseInt(u16, authority[idx + 1 ..], 10) catch port;
    }

    return .{
        .host = try allocator.dupe(u8, host_slice),
        .path = try allocator.dupe(u8, path),
        .port = port,
        .use_tls = tls,
    };
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

pub fn decodeNpub(npub: []const u8) ![32]u8 {
    const pos = std.mem.lastIndexOfScalar(u8, npub, '1') orelse return error.Invalid;
    const hrp = npub[0..pos];
    if (!std.ascii.eqlIgnoreCase(hrp, "npub")) return error.Invalid;
    const data = npub[pos + 1 ..];
    var v: [1024]U5 = undefined;
    const n = try bech32Decode(data, v[0..]);
    if (n < 6) return error.Invalid;
    const payload = v[0 .. n - 6];
    var out_buf: [64]u8 = undefined;
    const out_bytes = try convertBits(out_buf[0..], payload, 5, 8, false);
    if (out_bytes.len != 32) return error.Invalid;
    var pk: [32]u8 = undefined;
    @memcpy(pk[0..], out_bytes);
    return pk;
}

const U5 = u8;

fn bech32Decode(s: []const u8, out: []U5) !usize {
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
    const from_bits_u5: u5 = @intCast(from_bits);
    const to_bits_u5: u5 = @intCast(to_bits);
    var acc: u32 = 0;
    var bits: u8 = 0;
    const maxv: u32 = (@as(u32, 1) << to_bits_u5) - 1;
    var j: usize = 0;
    for (in5) |value| {
        if ((@as(u32, value) >> from_bits_u5) != 0) return error.Invalid;
        acc = (acc << from_bits_u5) | @as(u32, value);
        bits += from_bits;
        while (bits >= to_bits) {
            bits -= to_bits;
            if (j >= out.len) return error.Invalid;
            const shift: u5 = @intCast(bits);
            out[j] = @as(u8, @intCast((acc >> shift) & maxv));
            j += 1;
        }
    }
    if (pad) {
        if (bits > 0) {
            if (j >= out.len) return error.Invalid;
            const shift: u5 = @intCast(to_bits - bits);
            out[j] = @as(u8, @intCast((acc << shift) & maxv));
            j += 1;
        }
    } else {
        if (bits >= from_bits) return error.Invalid;
        const shift: u5 = @intCast(to_bits - bits);
        if (((acc << shift) & maxv) != 0) return error.Invalid;
    }
    return out[0..j];
}
