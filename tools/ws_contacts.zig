const std = @import("std");
const core = @import("ws_contacts_core.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var url: ?[]const u8 = null;
    var origin: []const u8 = "https://nostrdb-ssr.local";
    var npub: ?[]const u8 = null;
    var author_hex: ?[]const u8 = null;
    var post_limit: usize = 5;
    var timeout_ms: u32 = 20_000;

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
        } else if (std.mem.eql(u8, arg, "--npub")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            npub = args[i];
        } else if (std.mem.eql(u8, arg, "--author-hex")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            author_hex = args[i];
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            post_limit = std.fmt.parseUnsigned(usize, args[i], 10) catch post_limit;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i >= args.len) {
                usage();
                return;
            }
            timeout_ms = std.fmt.parseUnsigned(u32, args[i], 10) catch timeout_ms;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return;
        }
    }

    const url_value = url orelse {
        usage();
        return;
    };

    std.debug.print("handshake {s} origin={s}\n", .{ url_value, origin });

    var timeline = try core.fetchTimeline(allocator, .{
        .url = url_value,
        .origin = origin,
        .npub = npub,
        .author_hex = author_hex,
        .limit = post_limit,
        .timeout_ms = timeout_ms,
    });
    defer timeline.deinit(allocator);

    std.debug.print("follows captured: {d}\n", .{timeline.follows.len});
    for (timeline.posts) |post| {
        std.debug.print("{s}: {s}\n", .{ post.display_name, post.content });
        std.debug.print("https://primal.net/e/{s}\n\n", .{post.event_id});
    }

    std.debug.print("downloaded posts: {d}\n", .{timeline.posts.len});
}

fn usage() void {
    std.debug.print(
        "Usage: ws-contacts --url wss://relay --npub <npub> [--origin URL] [--limit N] [--timeout ms]\n   (deprecated) --author-hex <64hex> also accepted\n",
        .{},
    );
}
