const std = @import("std");
const xev = @import("xev");
const ndb = @import("ndb.zig");
const c = @import("c.zig").c;
const builtin = @import("builtin");

// Platform detection for optimization
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;

/// Subscription context for timer callbacks
pub const SubscriptionContext = struct {
    ndb: *ndb.Ndb,
    sub_id: u64,
    buffer: std.ArrayList(u64),
    allocator: std.mem.Allocator,
    on_notes: ?*const fn ([]const u64) void,
    active: bool,
    poll_interval_ms: u64,
    backoff_ms: u64,
    max_backoff_ms: u64,

    pub fn init(allocator: std.mem.Allocator, db: *ndb.Ndb, sub_id: u64) !*SubscriptionContext {
        const ctx = try allocator.create(SubscriptionContext);
        ctx.* = .{
            .ndb = db,
            .sub_id = sub_id,
            .buffer = try std.ArrayList(u64).initCapacity(allocator, 256),
            .allocator = allocator,
            .on_notes = null,
            .active = true,
            .poll_interval_ms = 10, // Start with 10ms polling
            .backoff_ms = 10,
            .max_backoff_ms = 100,
        };
        return ctx;
    }

    pub fn deinit(self: *SubscriptionContext, allocator: std.mem.Allocator) void {
        self.buffer.deinit(self.allocator);
        allocator.destroy(self);
    }

    pub fn adjustPollingInterval(self: *SubscriptionContext, found_notes: bool) void {
        if (found_notes) {
            // Reset to fast polling when we find notes
            self.poll_interval_ms = 10;
            self.backoff_ms = 10;
        } else {
            // Exponential backoff when no notes
            self.backoff_ms = @min(self.backoff_ms * 2, self.max_backoff_ms);
            self.poll_interval_ms = self.backoff_ms;
        }
    }
};

/// Event-driven subscription stream with platform optimizations
pub const SubscriptionStream = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    ctx: *SubscriptionContext,
    timer: xev.Timer,

    // Platform-specific: macOS needs alternating completions
    // Linux can potentially reuse a single completion
    completions: if (is_macos) [2]xev.Completion else [1]xev.Completion,
    current_completion: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        db: *ndb.Ndb,
        sub_id: u64,
    ) !SubscriptionStream {
        const ctx = try SubscriptionContext.init(allocator, db, sub_id);
        const timer = try xev.Timer.init();

        var stream = SubscriptionStream{
            .allocator = allocator,
            .loop = loop,
            .ctx = ctx,
            .timer = timer,
            .completions = undefined,
            .current_completion = 0,
        };

        // Initialize completions
        for (&stream.completions) |*comp| {
            comp.* = .{};
        }

        return stream;
    }

    pub fn deinit(self: *SubscriptionStream) void {
        self.ctx.active = false;
        // Unsubscribe from ndb if available
        if (self.ctx.ndb.unsubscribe(self.ctx.sub_id)) |_| {} else |_| {}
        self.ctx.deinit(self.allocator);
        self.timer.deinit();
    }

    /// Start the subscription polling
    pub fn start(self: *SubscriptionStream) void {
        self.scheduleNextPoll();
    }

    /// Schedule the next poll with platform-appropriate completion handling
    fn scheduleNextPoll(self: *SubscriptionStream) void {
        const comp = &self.completions[self.current_completion];

        self.timer.run(
            self.loop,
            comp,
            self.ctx.poll_interval_ms,
            SubscriptionStream,
            self,
            pollCallback,
        );
    }

    /// Timer callback for polling
    fn pollCallback(
        userdata: ?*SubscriptionStream,
        loop: *xev.Loop,
        comp: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = loop;
        _ = comp;
        _ = result catch |err| {
            std.log.err("Timer error: {}", .{err});
            return .disarm;
        };

        const stream = userdata orelse return .disarm;
        if (!stream.ctx.active) return .disarm;

        // Poll for notes
        var notes_buf: [256]u64 = undefined;
        const count = stream.ctx.ndb.pollForNotes(stream.ctx.sub_id, &notes_buf);

        if (count > 0) {
            const notes = notes_buf[0..@intCast(count)];

            // Buffer the notes
            stream.ctx.buffer.appendSlice(stream.ctx.allocator, notes) catch |err| {
                std.log.err("Failed to buffer notes: {}", .{err});
                return .disarm;
            };

            // Call callback if provided
            if (stream.ctx.on_notes) |callback| {
                callback(notes);
            }

            // Found notes, adjust polling
            stream.ctx.adjustPollingInterval(true);
        } else {
            // No notes, back off
            stream.ctx.adjustPollingInterval(false);
        }

        // Check if we should continue
        if (!stream.ctx.active) {
            return .disarm;
        }

        // Platform-specific completion handling
        if (is_macos) {
            // macOS: Must alternate between completions
            stream.current_completion = 1 - stream.current_completion;
            stream.scheduleNextPoll();
            return .disarm; // Critical: disarm on macOS, not rearm
        } else {
            // Linux: Try to rearm directly (io_uring should handle this)
            // If this fails on Linux, fall back to macOS pattern
            const new_timer = xev.Timer.init() catch return .disarm;
            new_timer.run(
                stream.loop,
                &stream.completions[0],
                stream.ctx.poll_interval_ms,
                SubscriptionStream,
                stream,
                pollCallback,
            );
            return .rearm;
        }
    }

    /// Get buffered notes (non-blocking)
    pub fn poll(self: *SubscriptionStream) ?[]u64 {
        if (self.ctx.buffer.items.len > 0) {
            return self.ctx.buffer.toOwnedSlice(self.ctx.allocator) catch null;
        }
        return null;
    }

    /// Wait for notes with timeout
    pub fn next(self: *SubscriptionStream, timeout_ms: u64) !?[]u64 {
        const start_time = std.time.milliTimestamp();

        while (self.ctx.active) {
            // Run event loop once
            try self.loop.run(.no_wait);

            // Check for notes
            if (self.poll()) |notes| {
                return notes;
            }

            // Check timeout
            const elapsed = std.time.milliTimestamp() - start_time;
            if (elapsed >= timeout_ms) {
                return error.Timeout;
            }

            // Small sleep to prevent busy waiting
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        return null; // Stream closed
    }

    /// Cancel the subscription
    pub fn cancel(self: *SubscriptionStream) void {
        self.ctx.active = false;

        // Note: Timer cancellation can be tricky on different platforms
        // For now, just mark as inactive and let it disarm naturally
    }
};

/// Helper to wait for notes using libxev
pub fn waitForNotesXev(
    allocator: std.mem.Allocator,
    db: *ndb.Ndb,
    sub_id: u64,
    max_notes: usize,
    timeout_ms: u64,
) ![]u64 {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var stream = try SubscriptionStream.init(allocator, &loop, db, sub_id);
    defer stream.deinit();

    stream.start();

    var all_notes = try std.ArrayList(u64).initCapacity(allocator, 256);
    defer all_notes.deinit(allocator);

    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));

    while (all_notes.items.len < max_notes) {
        const remaining = @as(u64, @intCast(@max(0, deadline - std.time.milliTimestamp())));
        if (remaining == 0) break;

        if (try stream.next(remaining)) |notes| {
            try all_notes.appendSlice(allocator, notes);
            allocator.free(notes); // Free the owned slice
        }
    }

    return all_notes.toOwnedSlice(allocator);
}

/// Helper to drain a subscription until we get the expected number of notes
pub fn drainSubscriptionXev(
    allocator: std.mem.Allocator,
    db: *ndb.Ndb,
    sub_id: u64,
    target_count: usize,
    timeout_ms: u64,
) !usize {
    const notes = try waitForNotesXev(allocator, db, sub_id, target_count, timeout_ms);
    defer allocator.free(notes);
    return notes.len;
}

/// Simple synchronous helper for tests that don't need async
pub fn waitForNotesSync(
    db: *ndb.Ndb,
    sub_id: u64,
    timeout_ms: u64,
) !u64 {
    const start = std.time.milliTimestamp();
    var notes_buf: [256]u64 = undefined;

    while (std.time.milliTimestamp() - start < timeout_ms) {
        const count = db.pollForNotes(sub_id, &notes_buf);
        if (count > 0) {
            return notes_buf[0];
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    return error.Timeout;
}
