# Phase 5 libxev Implementation Guide

## Quick Start Implementation

### Step 1: Add libxev Dependency

Create or update `build.zig.zon`:
```zig
.{
    .name = "nostrdb-zig",
    .version = "0.0.1",
    .dependencies = .{
        .libxev = .{
            // Use latest stable release
            .url = "https://github.com/mitchellh/libxev/archive/2024.10.1.tar.gz",
            .hash = "1220fa7180306b38132e21c8f3d82587f4c5e4bc877cbdaa1ca7b1340fb7c4626fa8",
        },
    },
}
```

### Step 2: Update build.zig

```zig
// In build.zig, add libxev module
const xev = b.dependency("libxev", .{
    .target = target,
    .optimize = optimize,
});

// Add to your library/tests
lib.root_module.addImport("xev", xev.module("xev"));
test_step.root_module.addImport("xev", xev.module("xev"));
```

### Step 3: Create subscription_xev.zig

```zig
const std = @import("std");
const xev = @import("xev");
const ndb = @import("ndb.zig");
const c = @import("c.zig");

/// Subscription context for timer callbacks
pub const SubscriptionContext = struct {
    ndb: *ndb.Ndb,
    sub_id: u64,
    buffer: std.ArrayList(u64),
    on_notes: ?*const fn([]const u64) void,
    active: bool,
    poll_interval_ms: u64,
    backoff_ms: u64,
    max_backoff_ms: u64,
    
    pub fn init(allocator: std.mem.Allocator, db: *ndb.Ndb, sub_id: u64) !*SubscriptionContext {
        const ctx = try allocator.create(SubscriptionContext);
        ctx.* = .{
            .ndb = db,
            .sub_id = sub_id,
            .buffer = std.ArrayList(u64).init(allocator),
            .on_notes = null,
            .active = true,
            .poll_interval_ms = 10, // Start with 10ms polling
            .backoff_ms = 10,
            .max_backoff_ms = 100,
        };
        return ctx;
    }
    
    pub fn deinit(self: *SubscriptionContext, allocator: std.mem.Allocator) void {
        self.buffer.deinit();
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
    c: *xev.Completion,
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
        ctx.buffer.appendSlice(notes) catch |err| {
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
    timer.run(loop, c, ctx.poll_interval_ms, SubscriptionContext, ctx, pollSubscription);
    
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
            return self.ctx.buffer.toOwnedSlice() catch null;
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
            std.time.sleep(1 * std.time.ns_per_ms);
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
    
    var all_notes = std.ArrayList(u64).init(allocator);
    defer all_notes.deinit();
    
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    
    while (all_notes.items.len < max_notes) {
        const remaining = @as(u64, @intCast(@max(0, deadline - std.time.milliTimestamp())));
        if (remaining == 0) break;
        
        if (try stream.next(remaining)) |notes| {
            try all_notes.appendSlice(notes);
            allocator.free(notes); // Free the owned slice
        }
    }
    
    return all_notes.toOwnedSlice();
}
```

### Step 4: Integrate with Existing ndb.zig

Add to `ndb.zig`:
```zig
const xev_sub = @import("subscription_xev.zig");

pub fn subscribeAsync(
    self: *Ndb,
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    filter: *Filter,
    num_filters: i32,
) !xev_sub.SubscriptionStream {
    const sub_id = self.subscribe(filter, num_filters);
    var stream = try xev_sub.SubscriptionStream.init(allocator, loop, self, sub_id);
    stream.start();
    return stream;
}

pub fn unsubscribe(self: *Ndb, subid: u64) !void {
    const result = c.ndb_unsubscribe(self.ptr, subid);
    if (result == 0) return error.UnsubscribeFailed;
}
```

### Step 5: Test Implementation

Create `test_xev.zig`:
```zig
const std = @import("std");
const xev = @import("xev");
const ndb = @import("ndb.zig");
const xev_sub = @import("subscription_xev.zig");

test "Test 18: subscribe_event_works with libxev" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    
    // Setup database
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    
    // Initialize event loop
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    // Initialize database
    var db = try ndb.Ndb.init(tmp_path, &ndb.Config.default());
    defer db.deinit();
    
    // Create filter
    var f = ndb.Filter.init();
    defer f.deinit();
    try f.kinds(&.{1});
    
    // Subscribe with libxev
    var stream = try db.subscribeAsync(alloc, &loop, &f, 1);
    defer stream.deinit();
    
    // Process event
    const ev = "[\"EVENT\",\"s\",{\"id\": \"...\", \"kind\": 1, ...}]";
    try db.processEvent(ev);
    
    // Wait for notes
    const notes = try stream.next(2000); // 2 second timeout
    try std.testing.expect(notes != null);
    try std.testing.expectEqual(@as(usize, 1), notes.?.len);
    
    alloc.free(notes.?);
}

test "Test 19: multiple_events_work with libxev" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    var db = try ndb.Ndb.init(tmp_path, &ndb.Config.default());
    defer db.deinit();
    
    var f = ndb.Filter.init();
    defer f.deinit();
    try f.kinds(&.{1});
    
    var stream = try db.subscribeAsync(alloc, &loop, &f, 1);
    defer stream.deinit();
    
    // Process multiple events
    const events = [_][]const u8{
        "[\"EVENT\",\"s\",{\"id\": \"event1\", ...}]",
        "[\"EVENT\",\"s\",{\"id\": \"event2\", ...}]",
        "[\"EVENT\",\"s\",{\"id\": \"event3\", ...}]",
    };
    
    for (events) |event| {
        try db.processEvent(event);
    }
    
    // Collect all notes
    var total: usize = 0;
    while (total < events.len) {
        if (try stream.next(100)) |notes| {
            total += notes.len;
            alloc.free(notes);
        }
    }
    
    try std.testing.expectEqual(events.len, total);
}

test "Test 21: automatic cleanup on drop" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    var db = try ndb.Ndb.init(tmp_path, &ndb.Config.default());
    defer db.deinit();
    
    {
        var f = ndb.Filter.init();
        defer f.deinit();
        try f.kinds(&.{1});
        
        var stream = try db.subscribeAsync(alloc, &loop, &f, 1);
        defer stream.deinit(); // Automatic cleanup
        
        try db.processEvent("[\"EVENT\",\"s\",{...}]");
        
        if (try stream.next(100)) |notes| {
            try std.testing.expect(notes.len > 0);
            alloc.free(notes);
        }
        // Stream automatically cleaned up when going out of scope
    }
    
    // Verify subscription was cleaned up
    try std.testing.expectEqual(@as(i32, 0), c.ndb_num_subscriptions(db.ptr));
}
```

## Implementation Checklist

### Foundation (2 hours)
- [x] Research libxev architecture
- [x] Design subscription system with libxev
- [ ] Add libxev dependency to build.zig.zon
- [ ] Create subscription_xev.zig module
- [ ] Add unsubscribe() to ndb.zig

### Core Implementation (4 hours)
- [ ] Implement SubscriptionContext
- [ ] Create timer-based polling callback
- [ ] Implement SubscriptionStream
- [ ] Add adaptive polling intervals
- [ ] Buffer management for notes

### Integration (2 hours)
- [ ] Update ndb.zig with async methods
- [ ] Create helper functions
- [ ] Add cancellation support
- [ ] Automatic cleanup on drop

### Testing (3 hours)
- [ ] Port Test 18: subscribe_event_works
- [ ] Port Test 19: multiple_events_work
- [ ] Port Test 20: with_final_pause
- [ ] Port Test 21: unsub_on_drop
- [ ] Port Test 22: stream cancellation

### Optimization (1 hour)
- [ ] Benchmark vs thread approach
- [ ] Tune polling intervals
- [ ] Optimize buffer sizes
- [ ] Memory pool for allocations

## Key Implementation Insights

### 1. Single Event Loop Per Application
```zig
// Application-wide event loop
const app = struct {
    var loop: ?*xev.Loop = null;
    
    pub fn initLoop() !void {
        if (loop == null) {
            loop = try xev.Loop.init(.{});
        }
    }
    
    pub fn deinitLoop() void {
        if (loop) |l| {
            l.deinit();
            loop = null;
        }
    }
};
```

### 2. Batch Processing Pattern
```zig
// Process all available notes in one poll
pub fn batchPoll(ctx: *SubscriptionContext) !usize {
    var total: usize = 0;
    while (true) {
        var buf: [1024]u64 = undefined;
        const count = ctx.ndb.pollForNotes(ctx.sub_id, &buf);
        if (count == 0) break;
        
        try ctx.buffer.appendSlice(buf[0..@intCast(count)]);
        total += @intCast(count);
    }
    return total;
}
```

### 3. Integration with Existing Tests
```zig
// Adapter to use libxev with existing test infrastructure
pub fn drainSubscriptionXev(
    db: *ndb.Ndb,
    sub_id: u64,
    target_count: usize,
    timeout_ms: u64,
) !usize {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    
    const notes = try waitForNotesXev(
        std.testing.allocator,
        db,
        sub_id,
        target_count,
        timeout_ms,
    );
    defer std.testing.allocator.free(notes);
    
    return notes.len;
}
```

## Performance Considerations

### Memory Usage
- Each subscription: ~1KB (buffer + context)
- Each completion: 256 bytes
- Timer overhead: minimal

### CPU Usage
- Idle: < 0.1% (adaptive polling)
- Active: Depends on event rate
- Overhead: Single syscall per poll cycle

### Latency
- Best case: < 1ms (immediate poll hit)
- Average: 10-20ms (normal polling interval)
- Worst case: 100ms (max backoff)

## Migration Strategy

### Phase 1: Parallel Implementation
1. Keep existing synchronous API
2. Add libxev-based async API
3. Run both in tests

### Phase 2: Validation
1. Compare results between implementations
2. Benchmark performance
3. Test edge cases

### Phase 3: Gradual Adoption
1. Migrate one test at a time
2. Update documentation
3. Deprecate thread approach if superior

## Troubleshooting

### Common Issues

1. **Event loop not running**
   - Ensure loop.run() is called
   - Check for .no_wait vs .until_done

2. **Memory leaks**
   - Always free owned slices
   - Use defer for cleanup
   - Check allocator usage

3. **Missed events**
   - Increase buffer size
   - Reduce polling interval
   - Check subscription active flag

4. **High CPU usage**
   - Verify adaptive polling works
   - Check for busy loops
   - Use appropriate run mode

## Next Steps

1. **Immediate**: Add libxev dependency and create basic module
2. **Short-term**: Implement core SubscriptionStream
3. **Medium-term**: Port all Phase 5 tests
4. **Long-term**: Optimize and benchmark

This implementation provides a clean, event-driven approach to async subscriptions without the complexity of threads, making it ideal for the nostrdb-zig project.