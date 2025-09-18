const std = @import("std");
const ndb = @import("ndb");
const c = ndb.c;

pub const DecodeError = error{
    InvalidNpub,
};

pub const FilterError = error{
    InvalidChunkSize,
};

pub const ContactsFilterOptions = struct {
    author: [32]u8,
    limit: u32 = 1,
};

pub const PostsFilterOptions = struct {
    authors: []const [32]u8,
    limit: u32,
    since: ?u64 = null,
    chunk_size: usize = 256,
};

pub const ReqBuilderError = error{
    InvalidFilterEncoding,
};

var subid_counter = std.atomic.Value(u64).init(0);

pub fn decodeNpub(npub: []const u8) DecodeError![32]u8 {
    if (npub.len == 0) return DecodeError.InvalidNpub;

    var scratch: [512]u8 = undefined;
    var parsed: c.struct_nostr_bech32 = undefined;

    const ok = c.parse_nostr_bech32(&scratch, scratch.len, npub.ptr, npub.len, &parsed);
    if (ok == 0) return DecodeError.InvalidNpub;
    if (parsed.type != @as(@TypeOf(parsed.type), c.NOSTR_BECH32_NPUB)) return DecodeError.InvalidNpub;
    if (parsed.unnamed_0.npub.pubkey == null) return DecodeError.InvalidNpub;

    var out: [32]u8 = undefined;
    const src = parsed.unnamed_0.npub.pubkey[0..32];
    @memcpy(out[0..], src);
    return out;
}

pub fn buildContactsFilter(allocator: std.mem.Allocator, opts: ContactsFilterOptions) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    var writer = list.writer();
    try writer.writeAll("[{\"authors\":[\"");
    try writeHex(writer, &opts.author);
    try writer.writeAll("\"],\"kinds\":[3],\"limit\":");
    try writer.print("{d}", .{opts.limit});
    try writer.writeAll("}]");

    const owned = try list.toOwnedSlice();
    list.deinit();
    return owned;
}

pub fn buildPostsFilters(allocator: std.mem.Allocator, opts: PostsFilterOptions) (FilterError || error{OutOfMemory})![][:0]const u8 {
    if (opts.chunk_size == 0) return FilterError.InvalidChunkSize;

    var filters = std.ArrayList([:0]const u8).init(allocator);
    errdefer {
        for (filters.items) |entry| allocator.free(entry);
        filters.deinit();
    }

    var index: usize = 0;
    while (index < opts.authors.len) {
        const end = @min(index + opts.chunk_size, opts.authors.len);
        const chunk = opts.authors[index..end];
        const filter = try buildPostsFilterChunk(allocator, chunk, opts.limit, opts.since);
        try filters.append(filter);
        index = end;
    }

    const owned = try filters.toOwnedSlice();
    filters.deinit();
    return owned;
}

fn buildPostsFilterChunk(
    allocator: std.mem.Allocator,
    authors: []const [32]u8,
    limit: u32,
    since: ?u64,
) ![:0]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    var writer = list.writer();
    try writer.writeAll("[{\"authors\":[");
    for (authors, 0..) |author, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('"');
        try writeHex(writer, &author);
        try writer.writeByte('"');
    }
    try writer.writeAll("],\"kinds\":[1],\"limit\":");
    try writer.print("{d}", .{limit});
    if (since) |value| {
        try writer.writeAll(",\"since\":");
        try writer.print("{d}", .{value});
    }
    try writer.writeAll("}]");

    const owned = try list.toOwnedSlice();
    list.deinit();
    const z = try allocator.dupeZ(u8, owned);
    allocator.free(owned);
    return z;
}

pub fn buildReq(
    allocator: std.mem.Allocator,
    subid: []const u8,
    filters: []const []const u8,
) ReqBuilderError![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    errdefer list.deinit();

    var writer = list.writer();
    try writer.print("[\"REQ\",\"{s}\"", .{subid});

    for (filters) |filter| {
        const trimmed = try trimArrayEnvelope(filter);
        if (trimmed.len == 0) continue;
        try writer.writeByte(',');
        try writer.writeAll(trimmed);
    }

    try writer.writeByte(']');
    const owned = try list.toOwnedSlice();
    list.deinit();
    return owned;
}

pub fn buildClose(allocator: std.mem.Allocator, subid: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "[\"CLOSE\",\"{s}\"]", .{subid});
}

pub fn nextSubId(allocator: std.mem.Allocator) ![]u8 {
    const value = subid_counter.fetchAdd(1, .monotonic);
    return std.fmt.allocPrint(allocator, "sub-{x:0>16}", .{value});
}

fn trimArrayEnvelope(filter: []const u8) ReqBuilderError![]const u8 {
    if (filter.len < 2) return ReqBuilderError.InvalidFilterEncoding;
    if (filter[0] != '[' or filter[filter.len - 1] != ']') return ReqBuilderError.InvalidFilterEncoding;
    return filter[1 .. filter.len - 1];
}

fn writeHex(writer: anytype, bytes: []const u8) !void {
    var buf: [64]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&buf, "{s}", .{std.fmt.fmtSliceHexLower(bytes)});
    try writer.writeAll(rendered);
}
