const std = @import("std");
const xev = @import("xev");

test "basic timer functionality" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    var completion: xev.Completion = .{};
    var fired = false;

    timer.run(&loop, &completion, 10, bool, &fired, struct {
        fn callback(
            userdata: ?*bool,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            if (userdata) |flag| {
                flag.* = true;
            }
            return .disarm;
        }
    }.callback);

    try loop.run(.until_done);
    try std.testing.expect(fired);
}

test "timer cancellation" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    var completion: xev.Completion = .{};
    var cancel_completion: xev.Completion = .{};
    var fired = false;

    // Start a timer for 100ms
    timer.run(&loop, &completion, 100, bool, &fired, struct {
        fn callback(
            userdata: ?*bool,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            if (userdata) |flag| {
                flag.* = true;
            }
            return .disarm;
        }
    }.callback);

    // Cancel it immediately
    timer.cancel(&loop, &completion, &cancel_completion, void, null, struct {
        fn cancel_cb(
            _: ?*void,
            _: *xev.Loop,
            _: *xev.Completion,
            _: xev.Timer.CancelError!void,
        ) xev.CallbackAction {
            return .disarm;
        }
    }.cancel_cb);

    // Run for a short time
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < 50) {
        try loop.run(.no_wait);
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    // Timer should not have fired
    try std.testing.expect(!fired);
}

test "multiple concurrent timers" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer1 = try xev.Timer.init();
    defer timer1.deinit();
    var timer2 = try xev.Timer.init();
    defer timer2.deinit();

    var c1: xev.Completion = .{};
    var c2: xev.Completion = .{};

    var count: u32 = 0;

    timer1.run(&loop, &c1, 10, u32, &count, struct {
        fn cb(userdata: ?*u32, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
            if (userdata) |c| {
                c.* += 1;
            }
            return .disarm;
        }
    }.cb);

    timer2.run(&loop, &c2, 20, u32, &count, struct {
        fn cb(userdata: ?*u32, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
            if (userdata) |c| {
                c.* += 10;
            }
            return .disarm;
        }
    }.cb);

    try loop.run(.until_done);
    try std.testing.expectEqual(@as(u32, 11), count); // 1 + 10
}

test "rearm pattern for repeating timer" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    const Context = struct {
        count: u32,
        target: u32,
    };

    var ctx = Context{ .count = 0, .target = 3 };
    var completion: xev.Completion = .{};

    timer.run(&loop, &completion, 10, Context, &ctx, struct {
        fn callback(
            userdata: ?*Context,
            loop_ptr: *xev.Loop,
            c: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;

            const context = userdata orelse return .disarm;
            context.count += 1;

            if (context.count >= context.target) {
                return .disarm;
            }

            // Rearm for next iteration
            const timer = xev.Timer.init() catch return .disarm;
            timer.run(loop_ptr, c, 10, Context, context, callback);
            return .rearm;
        }
    }.callback);

    try loop.run(.until_done);
    try std.testing.expectEqual(@as(u32, 3), ctx.count);
}

test "no_wait run mode" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    var completion: xev.Completion = .{};
    var fired = false;

    timer.run(&loop, &completion, 50, bool, &fired, struct {
        fn callback(
            userdata: ?*bool,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            if (userdata) |flag| {
                flag.* = true;
            }
            return .disarm;
        }
    }.callback);

    // Poll with no_wait
    const start = std.time.milliTimestamp();
    while (!fired and std.time.milliTimestamp() - start < 100) {
        try loop.run(.no_wait);
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }

    try std.testing.expect(fired);
}

test "subscription simulation" {
    const MockSubscription = struct {
        buffer: std.ArrayList(u64),
        poll_count: u32,
        allocator: std.mem.Allocator,

        fn poll(self: *@This()) ![]const u64 {
            self.poll_count += 1;

            // Simulate data availability every 2nd poll
            if (self.poll_count % 2 == 0) {
                const start = self.buffer.items.len;
                try self.buffer.append(self.allocator, self.poll_count * 100);
                try self.buffer.append(self.allocator, self.poll_count * 100 + 1);
                return self.buffer.items[start..];
            }

            return &.{};
        }
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    var sub = MockSubscription{
        .buffer = try std.ArrayList(u64).initCapacity(allocator, 10),
        .poll_count = 0,
        .allocator = allocator,
    };
    defer sub.buffer.deinit(allocator);

    var completion: xev.Completion = .{};
    const max_polls = 6;

    timer.run(&loop, &completion, 10, MockSubscription, &sub, struct {
        fn callback(
            userdata: ?*MockSubscription,
            loop_ptr: *xev.Loop,
            c: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;

            const subscription = userdata orelse return .disarm;
            const items = subscription.poll() catch return .disarm;
            _ = items;

            if (subscription.poll_count >= max_polls) {
                return .disarm;
            }

            const timer = xev.Timer.init() catch return .disarm;
            timer.run(loop_ptr, c, 10, MockSubscription, subscription, callback);
            return .rearm;
        }
    }.callback);

    try loop.run(.until_done);

    try std.testing.expectEqual(@as(u32, max_polls), sub.poll_count);
    try std.testing.expectEqual(@as(usize, 6), sub.buffer.items.len); // 3 successful polls * 2 items
}

test "memory safety with context" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    // Allocate context on heap
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const Context = struct {
        value: u32,
        allocator: std.mem.Allocator,
    };

    var ctx = try allocator.create(Context);
    ctx.* = .{ .value = 42, .allocator = allocator };
    defer allocator.destroy(ctx);

    var completion: xev.Completion = .{};

    timer.run(&loop, &completion, 10, Context, ctx, struct {
        fn callback(
            userdata: ?*Context,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;

            const context = userdata orelse return .disarm;
            context.value += 1;
            return .disarm;
        }
    }.callback);

    try loop.run(.until_done);
    try std.testing.expectEqual(@as(u32, 43), ctx.value);
}

test "error handling in callbacks" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    const Context = struct {
        should_error: bool,
        error_handled: bool,
    };

    var ctx = Context{ .should_error = true, .error_handled = false };
    var completion: xev.Completion = .{};

    timer.run(&loop, &completion, 10, Context, &ctx, struct {
        fn callback(
            userdata: ?*Context,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch |err| {
                _ = err;
                if (userdata) |context| {
                    context.error_handled = true;
                }
                return .disarm;
            };

            const context = userdata orelse return .disarm;

            if (context.should_error) {
                // In real code, this would be an actual error condition
                context.error_handled = true;
                return .disarm;
            }

            return .disarm;
        }
    }.callback);

    try loop.run(.until_done);
    try std.testing.expect(ctx.error_handled);
}
