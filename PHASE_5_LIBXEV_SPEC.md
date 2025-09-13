# Phase 5 Alternative: libxev Event-Driven Subscriptions

## Executive Summary
Instead of using threads and channels for async subscriptions, we can leverage libxev - a mature, cross-platform event loop library that powers Ghostty and other sophisticated Zig projects. This approach eliminates threading complexity, provides better performance, and aligns with modern event-driven architectures.

## Why libxev Over Threads?

### Advantages
1. **No Threading Complexity**: Single-threaded event loop eliminates race conditions
2. **Battle-Tested**: Used in production by Ghostty, zml, and other major projects
3. **Zero Allocations**: Predictable runtime performance
4. **Cross-Platform**: Works on Linux (io_uring/epoll), macOS (kqueue), Windows (IOCP), WASI
5. **Proactor Pattern**: Notified of work completion, not readiness
6. **Natural Fit**: Event-driven model matches subscription semantics perfectly

### Comparison with Thread+Channel Approach

| Aspect | Thread+Channel | libxev |
|--------|---------------|---------|
| Complexity | High (synchronization) | Low (single-threaded) |
| Memory | Thread stacks + buffers | Minimal completions |
| Performance | Context switches | Event-driven efficiency |
| Debugging | Complex (races) | Simple (sequential) |
| Dependencies | OS threads | libxev only |
| Maturity | Custom implementation | Production-proven |

## Architecture Design with libxev

### Core Components

#### 1. SubscriptionWatcher
```zig
pub const SubscriptionWatcher = struct {
    ndb: *Ndb,
    sub_id: u64,
    timer: xev.Timer,
    loop: *xev.Loop,
    
    // Polling configuration
    poll_interval_ms: u64 = 10,
    max_notes_per_poll: u32 = 100,
    
    // State
    active: bool = true,
    buffer: std.ArrayList(u64),
    
    // Callbacks
    on_notes: ?*const fn(notes: []u64) void,
    on_error: ?*const fn(err: anyerror) void,
};
```

#### 2. Event Loop Integration
```zig
pub const NdbEventLoop = struct {
    loop: xev.Loop,
    subscriptions: std.AutoHashMap(u64, *SubscriptionWatcher),
    
    pub fn init() !NdbEventLoop {
        return .{
            .loop = try xev.Loop.init(.{}),
            .subscriptions = std.AutoHashMap(u64, *SubscriptionWatcher).init(allocator),
        };
    }
    
    pub fn run(self: *NdbEventLoop) !void {
        try self.loop.run(.until_done);
    }
    
    pub fn runOnce(self: *NdbEventLoop) !void {
        try self.loop.run(.no_wait);
    }
};
```

#### 3. Subscription Stream (libxev-based)
```zig
pub const SubscriptionStream = struct {
    watcher: *SubscriptionWatcher,
    completion: xev.Completion,
    event_loop: *NdbEventLoop,
    
    pub fn next(self: *SubscriptionStream) !?[]u64 {
        // Run event loop until we have notes
        while (self.watcher.buffer.items.len == 0) {
            try self.event_loop.runOnce();
            if (!self.watcher.active) return null;
        }
        return self.watcher.buffer.toOwnedSlice();
    }
    
    pub fn nextWithTimeout(self: *SubscriptionStream, timeout_ms: u64) !?[]u64 {
        var timeout_timer = try xev.Timer.init();
        var timeout_c: xev.Completion = .{};
        
        timeout_timer.run(&self.event_loop.loop, &timeout_c, timeout_ms, void, null, timeoutCallback);
        
        // Run until notes or timeout
        while (self.watcher.buffer.items.len == 0 and !timeout_fired) {
            try self.event_loop.runOnce();
        }
        
        return if (self.watcher.buffer.items.len > 0)
            self.watcher.buffer.toOwnedSlice()
        else
            error.Timeout;
    }
};
```

### Polling Implementation with libxev Timer

```zig
fn pollCallback(
    userdata: ?*SubscriptionWatcher,
    loop: *xev.Loop,
    c: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const watcher = userdata.?;
    
    // Poll for notes from nostrdb
    var notes_buf: [256]u64 = undefined;
    const count = watcher.ndb.pollForNotes(watcher.sub_id, &notes_buf);
    
    if (count > 0) {
        // Add to buffer
        watcher.buffer.appendSlice(notes_buf[0..count]) catch |err| {
            if (watcher.on_error) |on_err| on_err(err);
            return .disarm;
        };
        
        // Notify consumer
        if (watcher.on_notes) |on_notes| {
            on_notes(notes_buf[0..count]);
        }
    }
    
    // Rearm timer for next poll if still active
    if (watcher.active) {
        watcher.timer.run(loop, c, watcher.poll_interval_ms, SubscriptionWatcher, watcher, pollCallback);
        return .rearm;
    }
    
    return .disarm;
}
```

## Implementation Plan

### Phase 1: Foundation (4 hours)
1. Add libxev dependency to build.zig.zon
2. Create subscription_xev.zig module
3. Implement basic SubscriptionWatcher
4. Add unsubscribe() to ndb.zig

### Phase 2: Event Loop Integration (4 hours)
1. Create NdbEventLoop wrapper
2. Implement timer-based polling
3. Add buffer management
4. Handle subscription lifecycle

### Phase 3: Stream Interface (4 hours)
1. Implement SubscriptionStream with libxev
2. Add next() and nextWithTimeout()
3. Create iterator interface
4. Automatic cleanup on drop

### Phase 4: Test Adaptation (6 hours)
1. Adapt Test 18: subscribe_event_works
2. Adapt Test 19: multiple_events_work
3. Adapt Test 20: with_final_pause
4. Adapt Test 21: unsub_on_drop
5. Adapt Test 22: stream cancellation

### Phase 5: Optimization (2 hours)
1. Adaptive polling intervals
2. Batch processing
3. Memory pool for buffers

## Test Implementation Examples

### Test 18: subscribe_event_works (libxev version)
```zig
test "Test 18: subscribe_event_works with libxev" {
    var event_loop = try NdbEventLoop.init();
    defer event_loop.deinit();
    
    var ndb = try Ndb.init(db_path, &config);
    defer ndb.deinit();
    
    const filter = Filter.new().kinds(&.{1}).build();
    const sub_id = ndb.subscribe(&filter, 1);
    
    // Create subscription watcher
    var watcher = try SubscriptionWatcher.init(&ndb, sub_id, &event_loop);
    defer watcher.deinit();
    
    // Process event
    try ndb.processEvent(test_event);
    
    // Wait for notes using event loop
    var notes_received: ?[]u64 = null;
    watcher.on_notes = struct {
        fn callback(notes: []u64) void {
            notes_received = notes;
        }
    }.callback;
    
    // Run event loop with timeout
    var timeout = try xev.Timer.init();
    var timeout_c: xev.Completion = .{};
    timeout.run(&event_loop.loop, &timeout_c, 2000, void, null, struct {
        fn cb(_: ?*void, loop: *xev.Loop, _: *xev.Completion, _: xev.Timer.RunError!void) xev.CallbackAction {
            loop.stop();
            return .disarm;
        }
    }.cb);
    
    try event_loop.run();
    
    try std.testing.expect(notes_received != null);
    try std.testing.expectEqual(@as(usize, 1), notes_received.?.len);
}
```

### Test 19: multiple_events_work (libxev version)
```zig
test "Test 19: multiple_events_work with libxev" {
    var event_loop = try NdbEventLoop.init();
    defer event_loop.deinit();
    
    var ndb = try Ndb.init(db_path, &config);
    defer ndb.deinit();
    
    const filter = Filter.new().kinds(&.{1}).build();
    const sub_id = ndb.subscribe(&filter, 1);
    
    var stream = try event_loop.subscribeStream(&ndb, sub_id);
    defer stream.deinit();
    
    // Process multiple events
    for (test_events) |event| {
        try ndb.processEvent(event);
    }
    
    // Collect notes using stream interface
    var total_notes: usize = 0;
    while (total_notes < 6) {
        if (try stream.nextWithTimeout(100)) |notes| {
            total_notes += notes.len;
        }
    }
    
    try std.testing.expectEqual(@as(usize, 6), total_notes);
}
```

## Key Implementation Details

### 1. No Threads Required
All async behavior comes from the event loop running in the main thread.

### 2. Adaptive Polling
```zig
const AdaptivePollStrategy = struct {
    interval_ms: u64 = 1,
    max_interval_ms: u64 = 100,
    
    pub fn adjust(self: *AdaptivePollStrategy, found_notes: bool) void {
        if (found_notes) {
            self.interval_ms = 1; // Reset to fast polling
        } else {
            self.interval_ms = @min(self.interval_ms * 2, self.max_interval_ms);
        }
    }
};
```

### 3. Batch Processing
```zig
pub fn processBatch(watcher: *SubscriptionWatcher) !void {
    var total: usize = 0;
    const max_batch = 1000;
    
    while (total < max_batch) {
        var notes_buf: [256]u64 = undefined;
        const count = watcher.ndb.pollForNotes(watcher.sub_id, &notes_buf);
        if (count == 0) break;
        
        try watcher.buffer.appendSlice(notes_buf[0..count]);
        total += count;
    }
}
```

### 4. Integration with Existing Code
The libxev approach can coexist with the current synchronous API:
```zig
// Synchronous (existing)
const notes = ndb.pollForNotes(sub_id, &buf);

// Async with libxev (new)
var stream = try event_loop.subscribeStream(&ndb, sub_id);
const notes = try stream.next();
```

## Migration Path

### Step 1: Add libxev dependency
```zig
// build.zig.zon
.dependencies = .{
    .libxev = .{
        .url = "https://github.com/mitchellh/libxev/archive/v0.2.4.tar.gz",
        .hash = "...",
    },
},
```

### Step 2: Create parallel implementation
- Keep existing sync API
- Add new xev-based async API
- Run tests for both

### Step 3: Gradual adoption
- Start with Test 18 (simplest)
- Validate each test passes
- Compare performance

## Performance Expectations

### libxev Advantages
1. **Single-threaded**: No context switches
2. **Zero allocations**: Predictable latency
3. **io_uring on Linux**: Maximum efficiency
4. **Batching**: Process multiple notes per poll

### Benchmarks (Expected)
- Latency: < 1ms for note delivery
- Throughput: > 100K notes/second
- Memory: < 1KB per subscription
- CPU: < 1% idle usage

## Risk Mitigation

### Low Risk with libxev
1. **Mature library**: Used in production
2. **Simple integration**: Just timers and callbacks
3. **Fallback available**: Can keep thread approach
4. **Incremental adoption**: Test one at a time

## Conclusion

libxev provides a superior foundation for async subscriptions:
- Simpler than threads (no synchronization)
- Better performance (event-driven)
- Production-proven (Ghostty uses it)
- Natural fit (subscription = event stream)

The implementation is straightforward:
1. Timer polls nostrdb periodically
2. Results buffered for consumption
3. Event loop handles all async behavior
4. Stream interface provides clean API

This approach eliminates the complexity of the thread+channel design while providing better performance and maintainability.