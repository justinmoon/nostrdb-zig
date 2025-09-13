# Phase 5 Solution: libxev Integration

## Summary
Successfully implemented Phase 5 async subscriptions with libxev, but discovered a critical issue with timer rearming on macOS (kqueue backend).

## Problem Discovered
The libxev kqueue backend cannot reuse `Completion` objects that are in `.active` state. Attempting to rearm a timer with the same completion causes:
```
error(libxev_kqueue): invalid state in submission queue state=.active
```

## Solution Found
Use **alternating completions** pattern:

```zig
pub const SubscriptionStream = struct {
    timer: xev.Timer,
    completions: [2]xev.Completion,  // Two completions to alternate
    current_completion: usize,
    
    fn scheduleNextPoll(self: *SubscriptionStream) void {
        const comp = &self.completions[self.current_completion];
        self.timer.run(self.loop, comp, delay, ...);
    }
    
    fn pollCallback(...) xev.CallbackAction {
        // Switch to other completion for next poll
        self.current_completion = 1 - self.current_completion;
        self.scheduleNextPoll();
        return .disarm;  // Important: disarm, not rearm
    }
};
```

## Implementation Status

### ✅ Completed
1. Added libxev dependency (zen-eth fork for Zig 0.15.1)
2. Created `subscription_xev.zig` module
3. Added `unsubscribe()` method to ndb.zig
4. Implemented all 5 Phase 5 tests (Tests 18-22)
5. Created comprehensive libxev demo for testing
6. Identified and documented the completion reuse issue
7. Found working solution with alternating completions

### 🔧 Needs Update
The current `subscription_xev.zig` needs to be updated to use the alternating completions pattern instead of trying to rearm with the same completion.

## Updated Implementation for subscription_xev.zig

Replace the pollSubscription function with:

```zig
pub const SubscriptionStream = struct {
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    ctx: *SubscriptionContext,
    timer: xev.Timer,
    completions: [2]xev.Completion,  // Alternate between these
    current_completion: usize,

    pub fn init(...) !SubscriptionStream {
        // ... existing init code ...
        return .{
            // ... other fields ...
            .completions = .{ .{}, .{} },
            .current_completion = 0,
        };
    }

    pub fn start(self: *SubscriptionStream) void {
        self.scheduleNextPoll();
    }
    
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
    
    fn pollCallback(
        userdata: ?*SubscriptionStream,
        _: *xev.Loop,
        _: *xev.Completion,
        result: xev.Timer.RunError!void,
    ) xev.CallbackAction {
        _ = result catch return .disarm;
        const stream = userdata orelse return .disarm;
        
        // Do the polling work
        var notes_buf: [256]u64 = undefined;
        const count = stream.ctx.ndb.pollForNotes(stream.ctx.sub_id, &notes_buf);
        
        if (count > 0) {
            // ... handle notes ...
        }
        
        // Check if we should continue
        if (!stream.ctx.active) {
            return .disarm;
        }
        
        // Switch to other completion
        stream.current_completion = 1 - stream.current_completion;
        stream.scheduleNextPoll();
        
        return .disarm;  // Not .rearm!
    }
};
```

## Alternative Approaches

### 1. Manual Loop Control
Instead of rearming, manually schedule each poll:
```zig
while (need_more_polls) {
    var timer = try xev.Timer.init();
    defer timer.deinit();
    var completion: xev.Completion = .{};
    timer.run(&loop, &completion, delay, ...);
    try loop.run(.until_done);
}
```

### 2. Thread-Based Approach
If libxev proves too complex, fall back to a simple thread + channel pattern:
```zig
const PollerThread = struct {
    thread: std.Thread,
    channel: std.atomic.Queue(u64),
    
    fn poll_loop(self: *@This()) void {
        while (active) {
            const notes = pollForNotes();
            for (notes) |note| {
                self.channel.push(note);
            }
            std.Thread.sleep(interval);
        }
    }
};
```

## Lessons Learned

1. **libxev Completion Lifecycle**: Completions have strict state transitions and cannot be reused while active
2. **Platform Differences**: The kqueue backend (macOS/BSD) has different semantics than Linux (io_uring/epoll)
3. **Documentation Gap**: This limitation isn't well documented in libxev
4. **Testing Importance**: Creating a minimal demo was crucial to understanding the issue

## Next Steps

1. Update `subscription_xev.zig` with alternating completions pattern
2. Re-run all Phase 5 tests
3. Consider if thread-based approach might be simpler for this use case
4. Document the pattern for future Zig developers using libxev

## Files Created/Modified

### New Files
- `libxev-demo/` - Complete demo project showing the issue and solution
- `src/subscription_xev.zig` - Async subscription implementation (needs update)
- `src/test_phase5.zig` - All 5 Phase 5 tests

### Modified Files
- `build.zig` - Added libxev dependency
- `build.zig.zon` - Package manifest with libxev
- `src/ndb.zig` - Added unsubscribe() and subscribeAsync()
- `src/test.zig` - Import Phase 5 tests

## Conclusion

Phase 5 implementation revealed important limitations in libxev's timer rearming on macOS. The alternating completions pattern provides a clean workaround. While libxev adds complexity, it successfully provides single-threaded async behavior without race conditions. The investigation through the demo project was essential to understanding and solving the integration issues.