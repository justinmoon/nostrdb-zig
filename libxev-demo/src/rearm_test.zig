const std = @import("std");
const xev = @import("xev");

// Simplified test to understand the rearm issue
pub fn main() !void {
    std.debug.print("\n=== Testing Timer Rearm Pattern ===\n", .{});
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    // Test 1: Basic rearm without creating new timer
    try test1_rearm_same_timer(&loop);
    
    // Test 2: Rearm with new timer instance
    try test2_rearm_new_timer(&loop);
    
    // Test 3: Multiple completions approach
    try test3_multiple_completions(&loop);
    
    std.debug.print("\nAll rearm tests completed!\n", .{});
}

fn test1_rearm_same_timer(loop: *xev.Loop) !void {
    std.debug.print("\nTest 1: Rearm same timer\n", .{});
    
    var timer = try xev.Timer.init();
    defer timer.deinit();
    
    const Context = struct {
        count: u32,
        max: u32,
        timer: *xev.Timer,
    };
    
    var ctx = Context{ .count = 0, .max = 3, .timer = &timer };
    var completion: xev.Completion = .{};
    
    timer.run(loop, &completion, 10, Context, &ctx, struct {
        fn callback(
            userdata: ?*Context,
            l: *xev.Loop,
            c: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            
            const context = userdata orelse return .disarm;
            context.count += 1;
            std.debug.print("  Tick #{}\n", .{context.count});
            
            if (context.count >= context.max) {
                return .disarm;
            }
            
            // Try to rearm the same timer
            context.timer.run(l, c, 10, Context, context, callback);
            return .rearm;
        }
    }.callback);
    
    try loop.run(.until_done);
    std.debug.print("  Final count: {}\n", .{ctx.count});
}

fn test2_rearm_new_timer(loop: *xev.Loop) !void {
    std.debug.print("\nTest 2: Rearm with new timer\n", .{});
    
    const Context = struct {
        count: u32,
        max: u32,
    };
    
    var ctx = Context{ .count = 0, .max = 3 };
    var completion: xev.Completion = .{};
    
    // Initial timer
    var timer = try xev.Timer.init();
    defer timer.deinit();
    
    timer.run(loop, &completion, 10, Context, &ctx, struct {
        fn callback(
            userdata: ?*Context,
            l: *xev.Loop,
            c: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            _ = l;
            _ = c;
            
            const context = userdata orelse return .disarm;
            context.count += 1;
            std.debug.print("  Tick #{}\n", .{context.count});
            
            if (context.count >= context.max) {
                return .disarm;
            }
            
            // Don't rearm here - just disarm
            // We'll schedule next timer separately
            return .disarm;
        }
    }.callback);
    
    // For this test, we just run once
    try loop.run(.until_done);
    std.debug.print("  Final count: {}\n", .{ctx.count});
}

fn test3_multiple_completions(loop: *xev.Loop) !void {
    std.debug.print("\nTest 3: Multiple completions\n", .{});
    
    const Context = struct {
        count: u32,
        max: u32,
    };
    
    var ctx = Context{ .count = 0, .max = 3 };
    
    // Create separate completions for each tick
    var completions: [3]xev.Completion = undefined;
    for (&completions) |*c| {
        c.* = .{};
    }
    var timers: [3]xev.Timer = undefined;
    
    // Initialize all timers
    for (&timers) |*t| {
        t.* = try xev.Timer.init();
    }
    defer for (&timers) |*t| {
        t.deinit();
    };
    
    // Schedule them with different delays
    for (timers[0..ctx.max], completions[0..ctx.max], 0..) |*timer, *comp, i| {
        const delay = 10 + @as(u64, @intCast(i)) * 20; // 10ms, 30ms, 50ms
        
        timer.run(loop, comp, delay, Context, &ctx, struct {
            fn callback(
                userdata: ?*Context,
                _: *xev.Loop,
                _: *xev.Completion,
                result: xev.Timer.RunError!void,
            ) xev.CallbackAction {
                _ = result catch return .disarm;
                
                const context = userdata orelse return .disarm;
                context.count += 1;
                std.debug.print("  Tick #{}\n", .{context.count});
                
                return .disarm;
            }
        }.callback);
    }
    
    try loop.run(.until_done);
    std.debug.print("  Final count: {}\n", .{ctx.count});
}

// Test the pattern that's failing in our subscription code
fn test4_subscription_pattern(loop: *xev.Loop) !void {
    std.debug.print("\nTest 4: Subscription-like pattern\n", .{});
    
    const SubContext = struct {
        poll_count: u32,
        max_polls: u32,
        items_found: u32,
        
        fn poll(self: *@This()) u32 {
            self.poll_count += 1;
            if (self.poll_count % 2 == 0) {
                self.items_found += 2;
                return 2;
            }
            return 0;
        }
    };
    
    var ctx = SubContext{ 
        .poll_count = 0,
        .max_polls = 5,
        .items_found = 0,
    };
    
    // Try using a single timer that we DON'T rearm
    var timer = try xev.Timer.init();
    defer timer.deinit();
    
    var completion: xev.Completion = .{};
    
    // Schedule first poll
    timer.run(loop, &completion, 10, SubContext, &ctx, struct {
        fn pollCallback(
            userdata: ?*SubContext,
            _: *xev.Loop,
            _: *xev.Completion,
            result: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = result catch return .disarm;
            
            const context = userdata orelse return .disarm;
            const found = context.poll();
            
            std.debug.print("  Poll #{}: found {} items\n", .{context.poll_count, found});
            
            // Always disarm - don't try to rearm
            return .disarm;
        }
    }.pollCallback);
    
    // Run one poll at a time
    while (ctx.poll_count < ctx.max_polls) {
        try loop.run(.until_done);
        
        if (ctx.poll_count < ctx.max_polls) {
            // Schedule next poll with a fresh completion
            completion = .{};
            timer.run(loop, &completion, 10, SubContext, &ctx, struct {
                fn pollCallback(
                    userdata: ?*SubContext,
                    _: *xev.Loop,
                    _: *xev.Completion,
                    result: xev.Timer.RunError!void,
                ) xev.CallbackAction {
                    _ = result catch return .disarm;
                    
                    const context = userdata orelse return .disarm;
                    const found = context.poll();
                    
                    std.debug.print("  Poll #{}: found {} items\n", .{context.poll_count, found});
                    
                    return .disarm;
                }
            }.pollCallback);
        }
    }
    
    std.debug.print("  Total items found: {}\n", .{ctx.items_found});
}