const std = @import("std");
const proto = @import("proto");
const contacts = @import("contacts");
const ingest = @import("ingest");
const timeline = @import("timeline");
const ndb = @import("ndb");

pub const CliError = error{
    MissingCommand,
    UnknownCommand,
    MissingValue,
    UnknownArgument,
    InvalidLimit,
    MissingNpub,
    MissingRelays,
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    npub: ?[]const u8 = null,
    relays: std.ArrayList([]const u8),
    limit: u32 = 500,

    pub fn init(allocator: std.mem.Allocator) Options {
        return .{ .allocator = allocator, .relays = std.ArrayList([]const u8).empty };
    }

    pub fn deinit(self: *Options) void {
        self.relays.deinit(self.allocator);
    }

    /// Returns true when parsing completed and execution should continue.
    pub fn parse(self: *Options, args: []const [:0]u8) !bool {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = std.mem.sliceTo(args[i], 0);

            if (std.mem.eql(u8, arg, "--npub")) {
                i += 1;
                if (i >= args.len) return CliError.MissingValue;
                self.npub = std.mem.sliceTo(args[i], 0);
                continue;
            }

            if (std.mem.eql(u8, arg, "--relays")) {
                i += 1;
                if (i >= args.len) return CliError.MissingValue;
                try self.setRelays(std.mem.sliceTo(args[i], 0));
                continue;
            }

            if (std.mem.eql(u8, arg, "--limit")) {
                i += 1;
                if (i >= args.len) return CliError.MissingValue;
                const parsed = std.fmt.parseInt(u32, std.mem.sliceTo(args[i], 0), 10) catch return CliError.InvalidLimit;
                self.limit = parsed;
                continue;
            }

            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                try printIngestUsage(std.fs.File.stdout());
                return false;
            }

            return CliError.UnknownArgument;
        }

        if (self.npub == null) return CliError.MissingNpub;
        if (self.relays.items.len == 0) return CliError.MissingRelays;
        return true;
    }

    fn setRelays(self: *Options, value: []const u8) !void {
        self.relays.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |relay| {
            const trimmed = std.mem.trim(u8, relay, " ");
            if (trimmed.len == 0) continue;
            try self.relays.append(self.allocator, trimmed);
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();
    const args = try std.process.argsAlloc(arena_allocator);
    defer std.process.argsFree(arena_allocator, args);

    if (args.len <= 1) {
        try printUsage(std.fs.File.stdout());
        return CliError.MissingCommand;
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(std.fs.File.stdout());
        return;
    }

    if (!std.mem.eql(u8, command, "ingest")) {
        std.log.err("unknown command: {s}", .{command});
        try printUsage(std.fs.File.stdout());
        return CliError.UnknownCommand;
    }

    const stdout_file = std.fs.File.stdout();
    try runIngest(args[2..], arena_allocator, stdout_file);
}

pub fn runIngest(args: []const [:0]u8, allocator: std.mem.Allocator, writer: anytype) !void {
    var options = Options.init(allocator);
    defer options.deinit();

    const should_continue = options.parse(args) catch |err| {
        switch (err) {
            CliError.MissingValue => std.log.err("missing value for flag", .{}),
            CliError.UnknownArgument => std.log.err("unknown argument", .{}),
            CliError.InvalidLimit => std.log.err("invalid limit", .{}),
            CliError.MissingNpub => std.log.err("--npub is required", .{}),
            CliError.MissingRelays => std.log.err("--relays is required", .{}),
            else => return err,
        }
        try printIngestUsage(std.fs.File.stdout());
        return err;
    };

    if (!should_continue) return;

    try runWithOptions(options, writer);
}

pub fn runWithOptions(options: Options, writer: anytype) !void {
    const npub_str = options.npub.?;
    const npub_key = proto.decodeNpub(npub_str) catch |err| {
        std.log.err("failed to decode npub: {s}", .{npub_str});
        return err;
    };

    const cwd = std.fs.cwd();
    const temp_dir_name = try std.fmt.allocPrint(options.allocator, "megalith-db-{x}", .{std.time.nanoTimestamp()});
    defer options.allocator.free(temp_dir_name);

    const db_path_buffer = try cwd.realpathAlloc(options.allocator, ".");
    defer options.allocator.free(db_path_buffer);

    const tmp_subdir = try std.fs.path.join(options.allocator, &.{ db_path_buffer, temp_dir_name });
    defer options.allocator.free(tmp_subdir);

    cwd.makePath(tmp_subdir) catch |err| {
        std.log.err("failed to create temp directory: {s}", .{tmp_subdir});
        return err;
    };
    defer cwd.deleteTree(tmp_subdir) catch {};

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(options.allocator, tmp_subdir, &cfg);
    defer db.deinit();

    const contacts_dir = try std.fs.path.join(options.allocator, &.{ tmp_subdir, "contacts" });
    defer options.allocator.free(contacts_dir);
    std.fs.makeDirAbsolute(contacts_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var contacts_store = try contacts.Store.init(options.allocator, .{ .path = contacts_dir });
    defer contacts_store.deinit();

    const timeline_dir = try std.fs.path.join(options.allocator, &.{ tmp_subdir, "timeline" });
    defer options.allocator.free(timeline_dir);
    std.fs.makeDirAbsolute(timeline_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var timeline_store = try timeline.Store.init(options.allocator, .{
        .path = timeline_dir,
        .max_entries = @intCast(options.limit),
    });
    defer timeline_store.deinit();

    var fetcher = contacts.Fetcher.init(options.allocator, &contacts_store);
    defer fetcher.deinit();

    fetcher.fetchContacts(npub_key, options.relays.items, &db) catch |err| {
        std.log.err("failed to fetch contacts: {}", .{err});
        return err;
    };

    var pipeline = ingest.Pipeline.init(options.allocator, npub_key, options.limit, &contacts_store, &timeline_store, &db);
    pipeline.run(options.relays.items) catch |err| switch (err) {
        ingest.PipelineError.NoFollowSet => {
            var msg_buf: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(&msg_buf, "No contacts found for {s}.\n", .{npub_str});
            try writer.writeAll(line);
            return;
        },
        else => {
            std.log.err("pipeline failed: {}", .{err});
            return err;
        },
    };

    try printTimeline(writer, options.allocator, npub_key, &timeline_store, options.limit);
}

fn printUsage(file: std.fs.File) !void {
    const text = "Megalith CLI\n\nCommands:\n  ingest    Fetch contacts and timeline for an npub\n\nUse `megalith <command> --help` for more details.\n";
    try file.writeAll(text);
    try file.writeAll("\n");
}

fn printIngestUsage(file: std.fs.File) !void {
    const text =
        "Usage: megalith ingest --npub <npub> --relays <wss://...,...> [--limit N]\n\n" ++ " Options:\n" ++ "   --npub <npub>         Target npub (required)\n" ++ "   --relays <list>       Comma-separated relay URLs (required)\n" ++ "   --limit <N>           Maximum posts to fetch (default 500)\n" ++ "   --help                Show this help message\n";
    try file.writeAll(text);
    try file.writeAll("\n");
}

fn printTimeline(
    writer: anytype,
    allocator: std.mem.Allocator,
    npub: timeline.PubKey,
    store: *timeline.Store,
    limit: u32,
) !void {
    var snapshot = try timeline.loadTimeline(store, npub);
    defer snapshot.deinit();

    if (snapshot.entries.len == 0) {
        try writer.writeAll("No events found.\n");
        return;
    }

    const total = snapshot.entries.len;
    const display_count = @min(@as(usize, limit), total);

    var header_buf: [128]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "Timeline ({d} events, showing {d})\n", .{ total, display_count });
    try writer.writeAll(header);

    var event_buf: [64]u8 = undefined;
    var author_buf: [64]u8 = undefined;
    var line_buf: [192]u8 = undefined;

    var idx: usize = 0;
    while (idx < display_count) : (idx += 1) {
        const entry = snapshot.entries[idx];
        const event_hex = encodeHexLower(&event_buf, entry.event_id[0..]);
        const author_hex = encodeHexLower(&author_buf, entry.author[0..]);

        const prefix = try std.fmt.bufPrint(&line_buf, "[{d:>3}] {d}  {s} {s}", .{ idx, entry.created_at, event_hex, author_hex });
        try writer.writeAll(prefix);

        if (try timeline.getEvent(store, entry.event_id)) |record| {
            defer record.deinit();
            try writer.writeAll("  ");
            try writeContentPreview(writer, allocator, record.payload);
        }

        try writer.writeAll("\n");
    }
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

fn writeContentPreview(writer: anytype, allocator: std.mem.Allocator, payload: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{}) catch {
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return;
    const object = root.object;
    const content = object.get("content") orelse return;
    if (content != .string) return;
    const text = content.string;
    if (text.len == 0) return;

    const preview_len = @min(text.len, 80);
    const snippet = text[0..preview_len];
    var line_buf: [160]u8 = undefined;
    const quoted = try std.fmt.bufPrint(&line_buf, "\"{s}\"", .{snippet});
    try writer.writeAll(quoted);
    if (text.len > preview_len) try writer.writeAll("…");
}
