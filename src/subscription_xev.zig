const std = @import("std");
const xev = @import("xev");
const ndb = @import("ndb.zig");
const c = @import("c.zig");

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
            .buffer = std.ArrayList(u64).initCapacity(allocator, 256) catch return error.OutOfMemory,
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

/// Timer-based subscription poller
pub fn pollSubscription(
    userdata: ?*SubscriptionContext,
    loop: *xev.Loop,
    comp: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = result catch |err| {
        std.log.err("Timer error: {}", .{err});
        return .disarm;
    };

    const ctx = userdata orelse return .disarm;
    if (!ctx.active) return .disarm;

    // Poll for notes
    var notes_buf: [256]u64 = undefined;
    const count = ctx.ndb.pollForNotes(ctx.sub_id, &notes_buf);

    if (count > 0) {
        const notes = notes_buf[0..@intCast(count)];

        // Buffer the notes
        ctx.buffer.appendSlice(ctx.allocator, notes) catch |err| {
            std.log.err("Failed to buffer notes: {}", .{err});
            return .disarm;
        };

        // Call callback if provided
        if (ctx.on_notes) |callback| {
            callback(notes);
        }

        // Found notes, adjust polling
        ctx.adjustPollingInterval(true);
    } else {
        // No notes, back off
        ctx.adjustPollingInterval(false);
    }

    // Rearm timer for next poll
    const timer = xev.Timer.init() catch return .disarm;
    timer.run(loop, comp, ctx.poll_interval_ms, SubscriptionContext, ctx, pollSubscription);

    return .rearm;
}

/// Event-driven subscription stream
pub const SubscriptionStream = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    ctx: *SubscriptionContext,
    timer: xev.Timer,
    completion: xev.Completion,

    pub fn init(
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        db: *ndb.Ndb,
        sub_id: u64,
    ) !SubscriptionStream {
        const ctx = try SubscriptionContext.init(allocator, db, sub_id);
        const timer = try xev.Timer.init();

        return .{
            .allocator = allocator,
            .loop = loop,
            .ctx = ctx,
            .timer = timer,
            .completion = .{},
        };
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
        self.timer.run(
            self.loop,
            &self.completion,
            self.ctx.poll_interval_ms,
            SubscriptionContext,
            self.ctx,
            pollSubscription,
        );
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

        // Cancel timer
        var cancel_c: xev.Completion = .{};
        self.timer.cancel(
            self.loop,
            &self.completion,
            &cancel_c,
            void,
            null,
            struct {
                fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.CancelError!void) xev.CallbackAction {
                    return .disarm;
                }
            }.cb,
        );
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