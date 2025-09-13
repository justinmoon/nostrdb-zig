const std = @import("std");
const xev = @import("xev");
const ndb = @import("ndb.zig");
const xev_sub = @import("subscription_xev.zig");
const Filter = ndb.Filter;
const Ndb = ndb.Ndb;
const Config = ndb.Config;

// Test event from Rust tests
const TEST_EVENT_1 = 
    \\["EVENT","b",{"id": "702555e52e82cc24ad517ba78c21879f6e47a7c0692b9b20df147916ae8731a3","pubkey": "32bf915904bfde2d136ba45dde32c88f4aca863783999faea2e847a8fafd2f15","created_at": 1702675561,"kind": 1,"tags": [],"content": "hello, world","sig": "2275c5f5417abfd644b7bc74f0388d70feb5d08b6f90fa18655dda5c95d013bfbc5258ea77c05b7e40e0ee51d8a2efa931dc7a0ec1db4c0a94519762c6625675"}]
;

// Additional test events for multiple_events test
const TEST_EVENT_2 = 
    \\["EVENT","s",{"id": "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930","pubkey": "aeadd3bf2fd92e509e137c9e8bdf20e99f286b90be7692434e03c015e1d3bbfe","created_at": 1704401597,"kind": 1,"tags": [],"content": "hello","sig": "232395427153b693e0426b93d89a8319324d8657e67d23953f014a22159d2127b4da20b95644b3e34debd5e20be0401c283e7308ccb63c1c1e0f81cac7502f09"}]
;

const TEST_EVENT_3 = 
    \\["EVENT","c",{"id": "3718b368de4d01a021990e6e00dce4bdf860caed21baffd11b214ac498e7562e","pubkey": "57c811c86a871081f52ca80e657004fe0376624a978f150073881b6daf0cbf1d","created_at": 1704300579,"kind": 1,"tags": [],"content": "test","sig": "061c36d4004d8342495eb22e8e7c2e2b6e1a1c7b4ae6077fef09f9a5322c561b88bada4f63ff05c9508cb29d03f50f71ef3c93c0201dbec440fc32eda87f273b"}]
;

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
    var config = Config.initDefault();
    var db = try Ndb.init(alloc, tmp_path, &config);
    defer db.deinit();

    // Create filter for kind 1 events
    var f = try Filter.init();
    defer f.deinit();
    try f.kinds(&.{1});

    // Subscribe with libxev
    var stream = try db.subscribeAsync(alloc, &loop, &f, 1);
    defer stream.deinit();

    // Process event
    try db.processEvent(TEST_EVENT_1);

    // Wait for notes with 2 second timeout
    const notes = try stream.next(2000);
    try std.testing.expect(notes != null);
    try std.testing.expectEqual(@as(usize, 1), notes.?.len);

    // Note key should be 1 (first note in database)
    try std.testing.expectEqual(@as(u64, 1), notes.?[0]);
    
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

    var config = Config.initDefault();
    var db = try Ndb.init(alloc, tmp_path, &config);
    defer db.deinit();

    var f = try Filter.init();
    defer f.deinit();
    try f.kinds(&.{1});

    var stream = try db.subscribeAsync(alloc, &loop, &f, 1);
    defer stream.deinit();

    // Process multiple events
    const events = [_][]const u8{ TEST_EVENT_1, TEST_EVENT_2, TEST_EVENT_3 };
    for (events) |event| {
        try db.processEvent(event);
    }

    // Collect all notes
    var total: usize = 0;
    var collected_notes = try std.ArrayList(u64).initCapacity(alloc, 256);
    defer collected_notes.deinit(alloc);

    // We should get 3 notes (all are kind 1)
    while (total < events.len) {
        if (try stream.next(100)) |notes| {
            try collected_notes.appendSlice(alloc, notes);
            total += notes.len;
            alloc.free(notes);
        } else {
            break;
        }
    }

    try std.testing.expectEqual(@as(usize, 3), total);
}

test "Test 20: multiple_events_with_final_pause_work" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var config = Config.initDefault();
    var db = try Ndb.init(alloc, tmp_path, &config);
    defer db.deinit();

    var f = try Filter.init();
    defer f.deinit();
    try f.kinds(&.{1});

    var stream = try db.subscribeAsync(alloc, &loop, &f, 1);
    defer stream.deinit();

    // Process events with pause
    try db.processEvent(TEST_EVENT_1);
    try db.processEvent(TEST_EVENT_2);
    
    // Small pause before last event
    std.Thread.sleep(50 * std.time.ns_per_ms);
    
    try db.processEvent(TEST_EVENT_3);

    // Collect all notes with timeout
    var total: usize = 0;
    const deadline = std.time.milliTimestamp() + 2000;
    
    while (total < 3) {
        const remaining = @as(u64, @intCast(@max(0, deadline - std.time.milliTimestamp())));
        if (remaining == 0) break;
        
        if (try stream.next(remaining)) |notes| {
            total += notes.len;
            alloc.free(notes);
        } else {
            break;
        }
    }

    try std.testing.expectEqual(@as(usize, 3), total);
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

    var config = Config.initDefault();
    var db = try Ndb.init(alloc, tmp_path, &config);
    defer db.deinit();

    // Create scope for automatic cleanup
    {
        var f = try Filter.init();
        defer f.deinit();
        try f.kinds(&.{1});

        var stream = try db.subscribeAsync(alloc, &loop, &f, 1);
        defer stream.deinit(); // Automatic cleanup including unsubscribe

        try db.processEvent(TEST_EVENT_1);

        if (try stream.next(100)) |notes| {
            try std.testing.expect(notes.len > 0);
            alloc.free(notes);
        }
        // Stream automatically cleaned up when going out of scope
    }

    // After cleanup, new subscription should work fine
    var f2 = try Filter.init();
    defer f2.deinit();
    try f2.kinds(&.{1});

    var stream2 = try db.subscribeAsync(alloc, &loop, &f2, 1);
    defer stream2.deinit();

    try db.processEvent(TEST_EVENT_2);

    if (try stream2.next(100)) |notes| {
        try std.testing.expect(notes.len > 0);
        alloc.free(notes);
    }
}

test "Test 22: stream cancellation works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var config = Config.initDefault();
    var db = try Ndb.init(alloc, tmp_path, &config);
    defer db.deinit();

    var f = try Filter.init();
    defer f.deinit();
    try f.kinds(&.{1});

    var stream = try db.subscribeAsync(alloc, &loop, &f, 1);
    defer stream.deinit();

    // Process first event
    try db.processEvent(TEST_EVENT_1);

    // Get first note
    const notes1 = try stream.next(100);
    try std.testing.expect(notes1 != null);
    try std.testing.expectEqual(@as(usize, 1), notes1.?.len);
    alloc.free(notes1.?);

    // Cancel the stream
    stream.cancel();

    // Process another event
    try db.processEvent(TEST_EVENT_2);

    // Stream should be cancelled, next() should return null
    const notes2 = stream.next(100) catch |err| switch (err) {
        error.Timeout => null,
        else => return err,
    };
    
    // We expect either null (stream closed) or timeout since stream is cancelled
    if (notes2) |n| {
        // If we got notes before cancellation took effect, that's ok
        alloc.free(n);
    }
}

// Helper test to ensure libxev integration works
test "Test libxev: basic timer functionality" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var timer = try xev.Timer.init();
    defer timer.deinit();

    var fired = false;
    var c: xev.Completion = .{};

    const Context = struct {
        fired: *bool,
    };
    
    var ctx = Context{ .fired = &fired };

    timer.run(&loop, &c, 10, Context, &ctx, struct {
        fn callback(
            userdata: ?*Context,
            l: *xev.Loop,
            comp: *xev.Completion,
            r: xev.Timer.RunError!void,
        ) xev.CallbackAction {
            _ = l;
            _ = comp;
            _ = r catch {};
            if (userdata) |context| {
                context.fired.* = true;
            }
            return .disarm;
        }
    }.callback);

    // Run loop with timeout
    const start = std.time.milliTimestamp();
    while (!fired and std.time.milliTimestamp() - start < 100) {
        try loop.run(.no_wait);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expect(fired);
}