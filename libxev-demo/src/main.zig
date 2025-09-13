const std = @import("std");
const xev = @import("xev");

// Demo 1: Basic timer - single shot
fn demo1_basic_timer() !void {
    std.debug.print("\n=== Demo 1: Basic Timer ===\n", .{});
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    var timer = try xev.Timer.init();
    defer timer.deinit();
    
    var completion: xev.Completion = .{};
    var fired = false;
    
    // Run timer for 100ms
    timer.run(&loop, &completion, 100, bool, &fired, struct {
        fn callback(
            userdata: ?*bool,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch |err| {
                std.debug.print("Timer error: {}\n", .{err});
                return .disarm;
            };
            
            if (userdata) |flag| {
                flag.* = true;
                std.debug.print("Timer fired after 100ms!\n", .{});
            }
            return .disarm;
        }
    }.callback);
    
    // Run the event loop
    try loop.run(.until_done);
    
    std.debug.print("Timer fired: {}\n", .{fired});
}

// Demo 2: Repeating timer with rearm
fn demo2_repeating_timer() !void {
    std.debug.print("\n=== Demo 2: Repeating Timer ===\n", .{});
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    var timer = try xev.Timer.init();
    defer timer.deinit();
    
    const Context = struct {
        count: u32,
        max_count: u32,
    };
    
    var ctx = Context{ .count = 0, .max_count = 5 };
    var completion: xev.Completion = .{};
    
    timer.run(&loop, &completion, 50, Context, &ctx, struct {
        fn callback(
            userdata: ?*Context,
            loop_ptr: *xev.Loop,
            c: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch |err| {
                std.debug.print("Timer error: {}\n", .{err});
                return .disarm;
            };
            
            const context = userdata orelse return .disarm;
            context.count += 1;
            std.debug.print("Timer tick #{}\n", .{context.count});
            
            if (context.count >= context.max_count) {
                std.debug.print("Reached max count, stopping\n", .{});
                return .disarm;
            }
            
            // Rearm the timer for next tick
            const new_timer = xev.Timer.init() catch return .disarm;
            new_timer.run(loop_ptr, c, 50, Context, context, callback);
            return .rearm;
        }
    }.callback);
    
    try loop.run(.until_done);
    std.debug.print("Total ticks: {}\n", .{ctx.count});
}

// Demo 3: Multiple timers running concurrently
fn demo3_multiple_timers() !void {
    std.debug.print("\n=== Demo 3: Multiple Timers ===\n", .{});
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    var timer1 = try xev.Timer.init();
    defer timer1.deinit();
    var timer2 = try xev.Timer.init();
    defer timer2.deinit();
    var timer3 = try xev.Timer.init();
    defer timer3.deinit();
    
    var c1: xev.Completion = .{};
    var c2: xev.Completion = .{};
    var c3: xev.Completion = .{};
    
    const TimerContext = struct {
        name: []const u8,
    };
    
    var ctx1 = TimerContext{ .name = "Timer A (50ms)" };
    var ctx2 = TimerContext{ .name = "Timer B (100ms)" };
    var ctx3 = TimerContext{ .name = "Timer C (150ms)" };
    
    timer1.run(&loop, &c1, 50, TimerContext, &ctx1, struct {
        fn cb(userdata: ?*TimerContext, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
            if (userdata) |ctx| {
                std.debug.print("{s} fired!\n", .{ctx.name});
            }
            return .disarm;
        }
    }.cb);
    
    timer2.run(&loop, &c2, 100, TimerContext, &ctx2, struct {
        fn cb(userdata: ?*TimerContext, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
            if (userdata) |ctx| {
                std.debug.print("{s} fired!\n", .{ctx.name});
            }
            return .disarm;
        }
    }.cb);
    
    timer3.run(&loop, &c3, 150, TimerContext, &ctx3, struct {
        fn cb(userdata: ?*TimerContext, _: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
            if (userdata) |ctx| {
                std.debug.print("{s} fired!\n", .{ctx.name});
            }
            return .disarm;
        }
    }.cb);
    
    try loop.run(.until_done);
    std.debug.print("All timers completed\n", .{});
}

// Demo 4: Non-blocking run with manual ticking
fn demo4_manual_ticking() !void {
    std.debug.print("\n=== Demo 4: Manual Ticking ===\n", .{});
    
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
    
    // Manual ticking - run loop in small increments
    var ticks: u32 = 0;
    while (!fired and ticks < 100) {
        try loop.run(.no_wait);
        std.Thread.sleep(10 * std.time.ns_per_ms);
        ticks += 1;
        if (ticks % 10 == 0) {
            std.debug.print("Tick {}, timer fired: {}\n", .{ticks, fired});
        }
    }
    
    std.debug.print("Timer fired after {} ticks\n", .{ticks});
}

// Demo 5: Simulating our subscription polling pattern
fn demo5_subscription_pattern() !void {
    std.debug.print("\n=== Demo 5: Subscription Pattern ===\n", .{});
    
    const SubscriptionContext = struct {
        id: u32,
        buffer: std.ArrayList(u32),
        poll_count: u32,
        max_polls: u32,
        poll_interval_ms: u64,
        allocator: std.mem.Allocator,
        
        fn poll(self: *@This()) !u32 {
            // Simulate polling that sometimes finds data
            self.poll_count += 1;
            
            // Every 3rd poll finds some data
            if (self.poll_count % 3 == 0) {
                const count = self.poll_count;
                try self.buffer.append(self.allocator, count * 100);
                try self.buffer.append(self.allocator, count * 100 + 1);
                std.debug.print("  Poll #{}: Found 2 items\n", .{self.poll_count});
                return 2;
            }
            
            std.debug.print("  Poll #{}: No items\n", .{self.poll_count});
            return 0;
        }
        
        fn adjustInterval(self: *@This(), found_items: bool) void {
            if (found_items) {
                self.poll_interval_ms = 10; // Fast polling when finding items
            } else {
                self.poll_interval_ms = @min(self.poll_interval_ms * 2, 100);
            }
        }
    };
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    var timer = try xev.Timer.init();
    defer timer.deinit();
    
    var ctx = SubscriptionContext{
        .id = 1,
        .buffer = try std.ArrayList(u32).initCapacity(allocator, 100),
        .poll_count = 0,
        .max_polls = 10,
        .poll_interval_ms = 10,
        .allocator = allocator,
    };
    defer ctx.buffer.deinit(allocator);
    
    var completion: xev.Completion = .{};
    
    timer.run(&loop, &completion, ctx.poll_interval_ms, SubscriptionContext, &ctx, struct {
        fn callback(
            userdata: ?*SubscriptionContext,
            loop_ptr: *xev.Loop,
            c: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            
            const context = userdata orelse return .disarm;
            
            // Simulate polling
            const items_found = context.poll() catch |err| {
                std.debug.print("Poll error: {}\n", .{err});
                return .disarm;
            };
            
            // Adjust polling interval based on results
            context.adjustInterval(items_found > 0);
            
            // Check if we're done
            if (context.poll_count >= context.max_polls) {
                std.debug.print("Subscription complete. Buffer has {} items\n", .{context.buffer.items.len});
                return .disarm;
            }
            
            // Rearm with adjusted interval
            const new_timer = xev.Timer.init() catch return .disarm;
            new_timer.run(loop_ptr, c, context.poll_interval_ms, SubscriptionContext, context, callback);
            return .rearm;
        }
    }.callback);
    
    try loop.run(.until_done);
    
    std.debug.print("Final buffer contents: ", .{});
    for (ctx.buffer.items) |item| {
        std.debug.print("{} ", .{item});
    }
    std.debug.print("\n", .{});
}

pub fn main() !void {
    std.debug.print("LibXev Demo - Understanding the API\n", .{});
    std.debug.print("====================================\n", .{});
    
    try demo1_basic_timer();
    try demo2_repeating_timer();
    try demo3_multiple_timers();
    try demo4_manual_ticking();
    try demo5_subscription_pattern();
    
    std.debug.print("\nAll demos completed successfully!\n", .{});
}