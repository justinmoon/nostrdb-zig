# libxev Integration Findings

## The Problem
When integrating libxev for async subscriptions in nostrdb-zig, we encountered:
```
error(libxev_kqueue): invalid state in submission queue state=.active
```

This error occurred when trying to rearm timers for repeated polling.

## Root Cause
The issue is with **Completion reuse** in libxev's kqueue backend on macOS:
- A `Completion` tracks the state of an async operation
- Once a completion is in `.active` state, it cannot be reused until it completes
- Attempting to rearm with the same completion while it's still active causes the error
- The `.rearm` callback action doesn't properly reset the completion state

## Solutions Found

### 1. ❌ Don't Rearm (Broken Pattern)
```zig
fn callback(...) xev.CallbackAction {
    // Try to rearm with same timer/completion
    timer.run(loop, completion, delay, ...);
    return .rearm;  // This causes the error!
}
```

### 2. ✅ Alternating Completions (Working Pattern)
```zig
const Manager = struct {
    completions: [2]xev.Completion,
    current_completion: usize,
    
    fn scheduleNext(self: *Manager) void {
        const comp = &self.completions[self.current_completion];
        timer.run(loop, comp, delay, ...);
    }
    
    fn callback(...) xev.CallbackAction {
        // Switch to other completion
        manager.current_completion = 1 - manager.current_completion;
        manager.scheduleNext();
        return .disarm;  // Important: disarm, not rearm
    }
};
```

### 3. ✅ Manual Loop Control (Alternative)
```zig
// Instead of rearming, create new timer for each poll
while (need_more_polls) {
    var timer = try xev.Timer.init();
    defer timer.deinit();
    var completion: xev.Completion = .{};
    
    timer.run(&loop, &completion, delay, ...);
    try loop.run(.until_done);
}
```

### 4. ✅ Multiple Pre-allocated Completions
```zig
// Pre-allocate all completions needed
var completions: [MAX_POLLS]xev.Completion = undefined;
for (&completions, 0..) |*comp, i| {
    comp.* = .{};
    timers[i].run(loop, comp, delay * i, ...);
}
```

## Key Insights

1. **Completion Lifecycle**: Each completion has a state machine: 
   - `.idle` → `.active` → `.idle`
   - Cannot transition `.active` → `.active`

2. **Platform Differences**: This issue is specific to kqueue (macOS/BSD). 
   - Linux (io_uring/epoll) may handle this differently
   - Windows (IOCP) has its own semantics

3. **Memory Safety**: The alternating completion pattern ensures we never access a completion while it's in use by the kernel

4. **Performance**: The alternating pattern has minimal overhead - just 2 completions regardless of poll count

## Recommended Implementation for nostrdb-zig

```zig
pub const SubscriptionStream = struct {
    timer: xev.Timer,
    completions: [2]xev.Completion,
    current_completion: usize,
    ctx: *SubscriptionContext,
    
    pub fn start(self: *SubscriptionStream) void {
        self.scheduleNextPoll();
    }
    
    fn scheduleNextPoll(self: *SubscriptionStream) void {
        const comp = &self.completions[self.current_completion];
        self.timer.run(self.loop, comp, self.ctx.poll_interval_ms, 
                      SubscriptionStream, self, pollCallback);
    }
    
    fn pollCallback(...) xev.CallbackAction {
        // Do work...
        
        // Switch completions
        self.current_completion = 1 - self.current_completion;
        self.scheduleNextPoll();
        
        return .disarm;  // Critical: disarm, not rearm
    }
};
```

## Testing Checklist
- [x] Single timer execution works
- [x] Repeating timer with alternating completions works
- [x] Multiple concurrent timers work
- [x] Manual loop control works
- [x] No memory leaks
- [x] No race conditions (single-threaded)
- [x] Adaptive polling intervals work

## Conclusion
The libxev integration issue was caused by attempting to reuse active completions. The solution is straightforward: use alternating completions or create new ones for each operation. This pattern provides reliable, efficient async behavior without threading complexity.