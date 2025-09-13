const std = @import("std");
const xev = @import("xev");

// Working solution for subscription-like polling with libxev
pub fn main() !void {
    std.debug.print("\n=== Working Subscription Pattern with libxev ===\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    // Create a subscription manager
    var sub = try SubscriptionManager.init(allocator, &loop);
    defer sub.deinit();
    
    // Start polling
    try sub.start();
    
    // Run the event loop
    try loop.run(.until_done);
    
    std.debug.print("\nSubscription complete!\n", .{});
    std.debug.print("Total polls: {}\n", .{sub.ctx.poll_count});
    std.debug.print("Items found: {}\n", .{sub.ctx.buffer.items.len});
}

const SubscriptionManager = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    ctx: SubscriptionContext,
    timer: xev.Timer,
    // Use a pool of completions that we rotate through
    completions: [2]xev.Completion,
    current_completion: usize,
    
    pub fn init(allocator: std.mem.Allocator, loop: *xev.Loop) !SubscriptionManager {
        return .{
            .allocator = allocator,
            .loop = loop,
            .ctx = try SubscriptionContext.init(allocator),
            .timer = try xev.Timer.init(),
            .completions = .{ .{}, .{} },
            .current_completion = 0,
        };
    }
    
    pub fn deinit(self: *SubscriptionManager) void {
        self.ctx.deinit();
        self.timer.deinit();
    }
    
    pub fn start(self: *SubscriptionManager) !void {
        self.scheduleNextPoll();
    }
    
    fn scheduleNextPoll(self: *SubscriptionManager) void {
        // Use the current completion
        const comp = &self.completions[self.current_completion];
        
        // Schedule the timer
        self.timer.run(
            self.loop,
            comp,
            self.ctx.poll_interval_ms,
            SubscriptionManager,
            self,
            pollCallback,
        );
    }
    
    fn pollCallback(
        userdata: ?*SubscriptionManager,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch return .disarm;
        
        const manager = userdata orelse return .disarm;
        
        // Do the poll
        const items = manager.ctx.poll() catch |err| {
            std.debug.print("Poll error: {}\n", .{err});
            return .disarm;
        };
        
        std.debug.print("Poll #{}: found {} items\n", .{manager.ctx.poll_count, items});
        
        // Adjust polling interval
        manager.ctx.adjustInterval(items > 0);
        
        // Check if we're done
        if (manager.ctx.poll_count >= manager.ctx.max_polls) {
            std.debug.print("Reached max polls, stopping\n", .{});
            return .disarm;
        }
        
        // Switch to the other completion for next poll
        manager.current_completion = 1 - manager.current_completion;
        
        // Schedule next poll with the alternate completion
        manager.scheduleNextPoll();
        
        // Important: return .disarm, not .rearm
        // We've already scheduled the next timer
        return .disarm;
    }
};

const SubscriptionContext = struct {
    buffer: std.ArrayList(u64),
    allocator: std.mem.Allocator,
    poll_count: u32,
    max_polls: u32,
    poll_interval_ms: u64,
    
    pub fn init(allocator: std.mem.Allocator) !SubscriptionContext {
        return .{
            .buffer = try std.ArrayList(u64).initCapacity(allocator, 100),
            .allocator = allocator,
            .poll_count = 0,
            .max_polls = 10,
            .poll_interval_ms = 10,
        };
    }
    
    pub fn deinit(self: *SubscriptionContext) void {
        self.buffer.deinit(self.allocator);
    }
    
    pub fn poll(self: *SubscriptionContext) !usize {
        self.poll_count += 1;
        
        // Simulate finding data every 3rd poll
        if (self.poll_count % 3 == 0) {
            const base = self.poll_count * 100;
            try self.buffer.append(self.allocator, base);
            try self.buffer.append(self.allocator, base + 1);
            return 2;
        }
        
        return 0;
    }
    
    pub fn adjustInterval(self: *SubscriptionContext, found_items: bool) void {
        if (found_items) {
            self.poll_interval_ms = 10; // Fast polling
        } else {
            self.poll_interval_ms = @min(self.poll_interval_ms * 2, 100);
        }
    }
};

// Alternative approach: Using manual event loop control
pub fn alternativeApproach() !void {
    std.debug.print("\n=== Alternative: Manual Loop Control ===\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    var ctx = try SubscriptionContext.init(allocator);
    defer ctx.deinit();
    
    // Instead of rearming, we'll manually schedule each poll
    while (ctx.poll_count < ctx.max_polls) {
        var timer = try xev.Timer.init();
        defer timer.deinit();
        
        var completion: xev.Completion = .{};
        
        timer.run(&loop, &completion, ctx.poll_interval_ms, SubscriptionContext, &ctx, struct {
            fn callback(
                userdata: ?*SubscriptionContext,
                _: *xev.Loop,
                _: *xev.Completion,
                result: xev.Timer.RunError!void,
            ) xev.CallbackAction {
                _ = result catch return .disarm;
                
                const context = userdata orelse return .disarm;
                const items = context.poll() catch return .disarm;
                
                std.debug.print("Poll #{}: found {} items\n", .{context.poll_count, items});
                context.adjustInterval(items > 0);
                
                return .disarm;
            }
        }.callback);
        
        // Run this single timer
        try loop.run(.until_done);
    }
    
    std.debug.print("Complete! Total items: {}\n", .{ctx.buffer.items.len});
}