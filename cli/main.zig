const std = @import("std");

pub const CliError = error{
    MissingCommand,
    UnknownCommand,
    MissingValue,
    UnknownArgument,
    InvalidLimit,
    MissingNpub,
    MissingRelays,
};

const Options = struct {
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

    try runIngest(args[2..], arena_allocator);
}

fn runIngest(args: []const [:0]u8, allocator: std.mem.Allocator) !void {
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

    try echoArgs(options);
}

fn echoArgs(options: Options) !void {
    var stdout = std.fs.File.stdout();
    var buffer: [256]u8 = undefined;

    var line = try std.fmt.bufPrint(&buffer, "npub: {s}\n", .{options.npub.?});
    try stdout.writeAll(line);

    line = try std.fmt.bufPrint(&buffer, "limit: {d}\n", .{options.limit});
    try stdout.writeAll(line);

    line = try std.fmt.bufPrint(&buffer, "relays ({d}):\n", .{options.relays.items.len});
    try stdout.writeAll(line);

    for (options.relays.items, 0..) |relay, idx| {
        line = try std.fmt.bufPrint(&buffer, "  [{d}] {s}\n", .{ idx, relay });
        try stdout.writeAll(line);
    }
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
