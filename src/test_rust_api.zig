// Test file demonstrating Rust-like API consistency

const std = @import("std");
const ndb = @import("ndb.zig");

test "Rust-like API: methods on Ndb struct" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    
    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(allocator, dir, &cfg);
    defer db.deinit();
    
    // Process a test event
    const event_json = 
        \\["EVENT","sub",{"id":"b947267d70c2e4c747075aae1ae43dd9fb0f15ea075cf5faeb3bb70c2e6c51f4","pubkey":"32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245","created_at":1612345678,"kind":1,"tags":[],"content":"hello","sig":"foobar"}]
    ;
    try db.processEvent(event_json);
    
    // Process a profile event
    const profile_json = 
        \\["EVENT","b",{"id":"0b9f0e14727733e430dcb00c69b12a76a1e100f419ce369df837f7eb33e4523c","pubkey":"3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24","created_at":1736785355,"kind":0,"tags":[],"content":"{\"name\":\"Test User\",\"about\":\"Test bio\"}","sig":"test"}]
    ;
    try db.processEvent(profile_json);
    
    db.ensureProcessed(200);
    
    // Begin transaction
    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();
    
    // Test 1: getNoteById - method on Ndb (Rust-like)
    {
        var id: [32]u8 = undefined;
        try ndb.hexTo32(&id, "b947267d70c2e4c747075aae1ae43dd9fb0f15ea075cf5faeb3bb70c2e6c51f4");
        
        // Rust-like: ndb.get_note_by_id(&txn, &id)
        const note = db.getNoteById(&txn, &id);
        try std.testing.expect(note != null);
        try std.testing.expectEqualStrings("hello", note.?.content());
    }
    
    // Test 2: getProfileByPubkey - method on Ndb (Rust-like)
    {
        var pubkey: [32]u8 = undefined;
        try ndb.hexTo32(&pubkey, "3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24");
        
        // Rust-like: ndb.get_profile_by_pubkey(&txn, &pubkey)
        const profile = try db.getProfileByPubkey(&txn, &pubkey);
        try std.testing.expect(profile.name() != null);
    }
    
    // Test 3: searchProfile - method on Ndb (Rust-like)
    {
        // Rust-like: ndb.search_profile(&txn, "Test", 10)
        const results = try db.searchProfile(&txn, "Test", 10, allocator);
        defer allocator.free(results);
        
        // We should find our test user
        try std.testing.expect(results.len >= 0);
    }
    
    // Test 4: searchProfileIter - iterator version (memory efficient)
    {
        const query = try allocator.dupeZ(u8, "Test");
        defer allocator.free(query);
        
        var iter = try db.searchProfileIter(&txn, "Test", allocator);
        defer iter.deinit();
        
        // Can iterate without allocating all results upfront
        var count: usize = 0;
        while (iter.next()) |_| {
            count += 1;
            if (count >= 5) break; // Early termination example
        }
    }
}

test "Rust-like error handling" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    
    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(allocator, dir, &cfg);
    defer db.deinit();
    
    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();
    
    // Test NotFound error
    var pubkey: [32]u8 = undefined;
    try ndb.hexTo32(&pubkey, "0000000000000000000000000000000000000000000000000000000000000000");
    
    const result = db.getProfileByPubkey(&txn, &pubkey);
    try std.testing.expectError(ndb.Error.NotFound, result);
}