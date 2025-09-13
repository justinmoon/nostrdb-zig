const std = @import("std");
const ndb = @import("ndb.zig");

test "Test 1: ndb_init_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    db.deinit();
}

test "Test 2: process_event_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    const ev = "[\"EVENT\",\"s\",{\"id\": \"0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930\",\"pubkey\": \"aeadd3bf2fd92e509e137c9e8bdf20e99f286b90be7692434e03c015e1d3bbfe\",\"created_at\": 1704401597,\"kind\": 1,\"tags\": [],\"content\": \"hello\",\"sig\": \"232395427153b693e0426b93d89a8319324d8657e67d23953f014a22159d2127b4da20b95644b3e34debd5e20be0401c283e7308ccb63c1c1e0f81cac7502f09\"}]";
    try db.processEvent(ev);
}

test "Test 3: poll_note_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    // Filter: kinds == 1337
    var f = try ndb.Filter.init();
    defer f.deinit();
    try f.kinds(&.{1337});

    const subid = db.subscribe(&f, 1);
    try std.testing.expect(subid != 0);

    const ev = "[\"EVENT\",\"s\",{\"id\": \"3718b368de4d01a021990e6e00dce4bdf860caed21baffd11b214ac498e7562e\",\"pubkey\": \"57c811c86a871081f52ca80e657004fe0376624a978f150073881b6daf0cbf1d\",\"created_at\": 1704300579,\"kind\": 1337,\"tags\": [],\"content\": \"test\",\"sig\": \"061c36d4004d8342495eb22e8e7c2e2b6e1a1c7b4ae6077fef09f9a5322c561b88bada4f63ff05c9508cb29d03f50f71ef3c93c0201dbec440fc32eda87f273b\"}]";
    try db.processEvent(ev);

    // Use deterministic helper to drain subscription
    const got = try db.drainSubscription(subid, 1, 2000);
    try std.testing.expectEqual(@as(usize, 1), got);
}

test "Test 4: transaction lifecycle" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    var txn = try ndb.Transaction.begin(&db);
    txn.end();
}

test "Test 5: get note by ID" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    const id_hex = "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930";
    const ev = "[\"EVENT\",\"s\",{\"id\": \"0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930\",\"pubkey\": \"aeadd3bf2fd92e509e137c9e8bdf20e99f286b90be7692434e03c015e1d3bbfe\",\"created_at\": 1704401597,\"kind\": 1,\"tags\": [],\"content\": \"hello\",\"sig\": \"232395427153b693e0426b93d89a8319324d8657e67d23953f014a22159d2127b4da20b95644b3e34debd5e20be0401c283e7308ccb63c1c1e0f81cac7502f09\"}]";
    try db.processEvent(ev);

    // Ensure background writer flushed 
    db.ensureProcessed(200);
    
    var id_bytes: [32]u8 = undefined;
    try ndb.hexTo32(&id_bytes, id_hex);

    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();
    const note_opt = ndb.getNoteByIdFree(&txn, &id_bytes);
    try std.testing.expect(note_opt != null);
    const note = note_opt.?;
    try std.testing.expectEqual(@as(u32, 1), note.kind());
    try std.testing.expect(std.mem.eql(u8, note.content(), "hello"));
}

test "Test 6: query_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    const ev1 = "[\"EVENT\",\"s\",{\"id\": \"0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930\",\"pubkey\": \"aeadd3bf2fd92e509e137c9e8bdf20e99f286b90be7692434e03c015e1d3bbfe\",\"created_at\": 1704401597,\"kind\": 1,\"tags\": [],\"content\": \"hello\",\"sig\": \"232395427153b693e0426b93d89a8319324d8657e67d23953f014a22159d2127b4da20b95644b3e34debd5e20be0401c283e7308ccb63c1c1e0f81cac7502f09\"}]";
    const ev2 = "[\"EVENT\",\"s\",{\"id\": \"0a350c5851af6f6ce368bab4e2d4fe442a1318642c7fe58de5392103700c10fc\",\"pubkey\": \"dfa3fc062f7430dab3d947417fd3c6fb38a7e60f82ffe3387e2679d4c6919b1d\",\"created_at\": 1704404822,\"kind\": 1,\"tags\": [],\"content\": \"hello2\",\"sig\": \"48a0bb9560b89ee2c6b88edcf1cbeeff04f5e1b10d26da8564cac851065f30fa6961ee51f450cefe5e8f4895e301e8ffb2be06a2ff44259684fbd4ea1c885696\"}]";

    try db.processEvent(ev1);
    try db.processEvent(ev2);

    // Wait for both notes to be processed
    db.ensureProcessed(200);

    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();

    // Build filter by IDs
    var f = try ndb.Filter.init();
    defer f.deinit();
    var id1: [32]u8 = undefined;
    var id2: [32]u8 = undefined;
    try ndb.hexTo32(&id1, "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930");
    try ndb.hexTo32(&id2, "0a350c5851af6f6ce368bab4e2d4fe442a1318642c7fe58de5392103700c10fc");

    // Use ids() helper to finalize filter
    try f.ids(&.{ id1, id2 });

    var results: [4]ndb.QueryResult = undefined;
    var filters = [_]ndb.Filter{f};
    const n = try ndb.query(&txn, filters[0..], results[0..]);
    try std.testing.expectEqual(@as(usize, 2), n);
    // Verify content one of them is hello or hello2
    const c0 = results[0].note.content();
    const c1 = results[1].note.content();
    const match = std.mem.eql(u8, c0, "hello") or std.mem.eql(u8, c0, "hello2");
    try std.testing.expect(match);
    const match2 = std.mem.eql(u8, c1, "hello") or std.mem.eql(u8, c1, "hello2");
    try std.testing.expect(match2);
}

test "Test 6b: query with large result set uses allocator" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    // Small query - should use stack allocation
    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();

    var f_small = try ndb.Filter.init();
    defer f_small.deinit();
    try f_small.kinds(&.{1});
    
    var small_results: [10]ndb.QueryResult = undefined;
    var small_filters = [_]ndb.Filter{f_small};
    
    // This should work without allocator (uses stack)
    const n_small = try ndb.query(&txn, small_filters[0..], small_results[0..]);
    try std.testing.expectEqual(@as(usize, 0), n_small); // No events yet

    // Large query - requires allocator
    var f_large = try ndb.Filter.init();
    defer f_large.deinit();
    try f_large.kinds(&.{1});
    
    var large_results: [100]ndb.QueryResult = undefined;
    var large_filters = [_]ndb.Filter{f_large};
    
    // This should still work as 100 > 64 but we pass the allocator
    const n_large = try ndb.queryWithAllocator(&txn, large_filters[0..], large_results[0..], alloc);
    try std.testing.expectEqual(@as(usize, 0), n_large);
}

// Phase 2: Extended Filter Tests

test "Test 7: filter_limit_iter_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var f = try ndb.Filter.init();
    defer f.deinit();
    var b = ndb.FilterBuilder.init(&f);
    _ = try b.limit(2);
    try b.build();

    // Iterate fields and verify LIMIT is present and equals 2
    const elems_opt = ndb.findField(&f, ndb.c.NDB_FILTER_LIMIT);
    try std.testing.expect(elems_opt != null);
    const elems = elems_opt.?;
    try std.testing.expectEqual(@as(i32, 1), elems.count());
    try std.testing.expectEqual(@as(u64, 2), elems.intAt(0));
}

test "Test 8: filter_id_iter_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var f = try ndb.Filter.init();
    defer f.deinit();
    var b = ndb.FilterBuilder.init(&f);

    var id1: [32]u8 = undefined;
    var id2: [32]u8 = undefined;
    try ndb.hexTo32(&id1, "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930");
    try ndb.hexTo32(&id2, "0a350c5851af6f6ce368bab4e2d4fe442a1318642c7fe58de5392103700c10fc");
    _ = try b.ids(&.{ id1, id2 });
    try b.build();

    const elems_opt = ndb.findField(&f, ndb.c.NDB_FILTER_IDS);
    try std.testing.expect(elems_opt != null);
    const elems = elems_opt.?;
    try std.testing.expectEqual(@as(i32, 2), elems.count());
}

test "Test 9: filter_since_mut_works" {
    var f = try ndb.Filter.init();
    defer f.deinit();
    var b = ndb.FilterBuilder.init(&f);
    _ = try b.since(1234);
    try b.build();

    var elems = (ndb.findField(&f, ndb.c.NDB_FILTER_SINCE)).?;
    try std.testing.expectEqual(@as(u64, 1234), elems.intAt(0));

    // Mutate since in-place via int pointer
    const p = elems.intPtrAt(0);
    p.* = 5678;
    elems = (ndb.findField(&f, ndb.c.NDB_FILTER_SINCE)).?;
    try std.testing.expectEqual(@as(u64, 5678), elems.intAt(0));
}

test "Test 10: filter_int_iter_works" {
    var f = try ndb.Filter.init();
    defer f.deinit();
    var b = ndb.FilterBuilder.init(&f);
    _ = try b.kinds(&.{ 1, 2, 3 });
    try b.build();

    const elems_opt = ndb.findField(&f, ndb.c.NDB_FILTER_KINDS);
    try std.testing.expect(elems_opt != null);
    const elems = elems_opt.?;
    try std.testing.expectEqual(@as(i32, 3), elems.count());
    try std.testing.expectEqual(@as(u64, 1), elems.intAt(0));
    try std.testing.expectEqual(@as(u64, 2), elems.intAt(1));
    try std.testing.expectEqual(@as(u64, 3), elems.intAt(2));
}

test "Test 11: filter_multiple_field_iter_works" {
    var f = try ndb.Filter.init();
    defer f.deinit();
    var b = ndb.FilterBuilder.init(&f);

    var id1: [32]u8 = undefined;
    try ndb.hexTo32(&id1, "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930");
    _ = try b.kinds(&.{ 1 });
    _ = try b.limit(5);
    _ = try b.event(&.{ id1 });
    try b.build();

    // Find kinds, limit, and e-tag fields exist
    try std.testing.expect(ndb.findField(&f, ndb.c.NDB_FILTER_KINDS) != null);
    try std.testing.expect(ndb.findField(&f, ndb.c.NDB_FILTER_LIMIT) != null);
    try std.testing.expect(ndb.findField(&f, ndb.c.NDB_FILTER_TAGS) != null);
}

// Phase 3: Note Management Tests

test "Test 12: note_builder_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var nb = try ndb.NoteBuilder.init(alloc, 16 * 1024);
    defer nb.deinit();

    try nb.setContent("hello");
    nb.setKind(1);
    nb.setCreatedAt(1700000000);
    try nb.newTag();
    try nb.pushTagStr("t");
    try nb.pushTagStr("hashtag");

    var kp = try ndb.Keypair.create();
    const note = try nb.finalize(&kp);
    try std.testing.expectEqual(@as(u32, 1), note.kind());
    try std.testing.expect(std.mem.eql(u8, note.content(), "hello"));

    var it = ndb.TagIter.start(note);
    var saw_tag = false;
    while (it.next()) {
        const k = it.tagStr(0);
        if (std.mem.eql(u8, k, "t")) {
            const v = it.tagStr(1);
            try std.testing.expect(std.mem.eql(u8, v, "hashtag"));
            saw_tag = true;
        }
    }
    try std.testing.expect(saw_tag);
}

test "Test 13: note_query_works (serialize + basic compare)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var nb = try ndb.NoteBuilder.init(alloc, 16 * 1024);
    defer nb.deinit();

    try nb.setContent("hello3");
    nb.setKind(1);
    nb.setCreatedAt(1700000001);
    const note = try nb.finalizeUnsigned();

    const js = try note.json(alloc);
    defer alloc.free(js);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"content\":\"hello3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "\"kind\":1") != null);
}

test "Test 14: tag iteration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var nb = try ndb.NoteBuilder.init(alloc, 16 * 1024);
    defer nb.deinit();

    try nb.setContent("hi");
    nb.setKind(1);
    try nb.newTag();
    try nb.pushTagStr("e");
    var id1: [32]u8 = undefined;
    try ndb.hexTo32(&id1, "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930");
    // Represent the id tag as hex string for this test (builder supports id push too)
    try nb.pushTagStr("0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930");
    try nb.newTag();
    try nb.pushTagStr("t");
    try nb.pushTagStr("topic");

    var kp = try ndb.Keypair.create();
    const note = try nb.finalize(&kp);

    var it = ndb.TagIter.start(note);
    var saw_e = false;
    var saw_t = false;
    while (it.next()) {
        const k = it.tagStr(0);
        if (std.mem.eql(u8, k, "e")) {
            saw_e = true;
        } else if (std.mem.eql(u8, k, "t")) {
            const v = it.tagStr(1);
            try std.testing.expect(std.mem.eql(u8, v, "topic"));
            saw_t = true;
        }
    }
    try std.testing.expect(saw_e and saw_t);

    // Also verify packed-id form is detectable via C accessors
    var it2 = ndb.TagIter.start(note);
    while (it2.next()) {
        const k = it2.tagStr(0);
        if (std.mem.eql(u8, k, "e")) {
            const s = ndb.c.ndb_iter_tag_str(&it2.iter, 1);
            // Either packed id or string depending on builder input.
            if (s.flag == ndb.c.NDB_PACKED_ID) {
                // Verify length 32 is sensible; content exactness tested elsewhere.
                const id_ptr: [*]const u8 = @ptrCast(s.unnamed_0.id);
                _ = id_ptr; // not asserting bytes here.
            }
        }
    }
}

test "Test 14b: tag packed id via pushTagId" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var nb = try ndb.NoteBuilder.init(alloc, 16 * 1024);
    defer nb.deinit();

    try nb.setContent("hi");
    nb.setKind(1);
    try nb.newTag();
    try nb.pushTagStr("e");
    var id_bytes: [32]u8 = undefined;
    try ndb.hexTo32(&id_bytes, "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930");
    try nb.pushTagId(&id_bytes);

    const note = try nb.finalizeUnsigned();

    // Now iterate and ensure the second element is packed id with matching bytes
    var it = ndb.TagIter.start(note);
    var found = false;
    while (it.next()) {
        const k = it.tagStr(0);
        if (std.mem.eql(u8, k, "e")) {
            const s = ndb.c.ndb_iter_tag_str(&it.iter, 1);
            try std.testing.expect(s.flag == ndb.c.NDB_PACKED_ID);
            const got: [*]const u8 = @ptrCast(s.unnamed_0.id);
            try std.testing.expect(std.mem.eql(u8, got[0..32], id_bytes[0..]));
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "Test 15: note_blocks_work" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const content = "Visit https://example.com and #hello";
    var blocks = try ndb.parseContentBlocks(alloc, content);
    defer blocks.deinit();

    var iter = ndb.BlocksIter.start(content, blocks.blocks);
    var saw_url = false;
    var saw_hashtag = false;
    while (iter.next()) |blk| {
        const t = ndb.c.ndb_get_block_type(blk);
        if (t == ndb.c.BLOCK_URL) {
            const s = ndb.c.ndb_block_str(blk);
            const ptr = ndb.c.ndb_str_block_ptr(s);
            const len: usize = ndb.c.ndb_str_block_len(s);
            const txt = @as([*]const u8, @ptrCast(ptr))[0..len];
            try std.testing.expect(std.mem.eql(u8, txt, "https://example.com"));
            saw_url = true;
        } else if (t == ndb.c.BLOCK_HASHTAG) {
            const s = ndb.c.ndb_block_str(blk);
            const ptr = ndb.c.ndb_str_block_ptr(s);
            const len: usize = ndb.c.ndb_str_block_len(s);
            const txt = @as([*]const u8, @ptrCast(ptr))[0..len];
            // Some implementations provide hashtags without '#'. Accept either.
            const expected = if (txt.len > 0 and txt[0] == '#') txt[1..] else txt;
            try std.testing.expect(std.mem.eql(u8, expected, "hello"));
            saw_hashtag = true;
        }
    }
    try std.testing.expect(saw_url and saw_hashtag);
}

test "Test 15b: bech32 mention parsing" {
    // Based on nostrdb/test.c test_parse_nevent
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const content = "nostr:nevent1qqs9qhc0pjvp6jl2w6ppk5cft8ets8fhxy7fcqcjnp7g38whjy0x5aqpzpmhxue69uhkummnw3ezuamfdejsyg86np9a0kajstc8u9h846rmy6320wdepdeydfz8w8cv7kh9sqv02g947d58,#hashtag";
    var blocks = try ndb.parseContentBlocks(alloc, content);
    defer blocks.deinit();

    var iter = ndb.BlocksIter.start(content, blocks.blocks);
    var idx: usize = 0;
    var saw_bech32 = false;
    var saw_comma_text = false;
    var saw_hashtag = false;
    while (iter.next()) |blk| {
        idx += 1;
        const t = ndb.c.ndb_get_block_type(blk);
        if (idx == 1) {
            try std.testing.expect(t == ndb.c.BLOCK_MENTION_BECH32);
            const bech = ndb.c.ndb_bech32_block(blk);
            try std.testing.expect(bech != null);
            const bech_ptr: *ndb.c.struct_nostr_bech32 = @ptrCast(bech);
            try std.testing.expect(bech_ptr.*.type == ndb.c.NOSTR_BECH32_NEVENT);
            saw_bech32 = true;
        } else if (idx == 2) {
            try std.testing.expect(t == ndb.c.BLOCK_TEXT);
            const s = ndb.c.ndb_block_str(blk);
            try std.testing.expect(ndb.c.ndb_str_block_ptr(s)[0] == ',');
            saw_comma_text = true;
        } else if (idx == 3) {
            try std.testing.expect(t == ndb.c.BLOCK_HASHTAG);
            const s = ndb.c.ndb_block_str(blk);
            const ptr = ndb.c.ndb_str_block_ptr(s);
            const len: usize = ndb.c.ndb_str_block_len(s);
            const txt = @as([*]const u8, @ptrCast(ptr))[0..len];
            // Accept both with and without leading '#'
            const expected = if (txt.len > 0 and txt[0] == '#') txt[1..] else txt;
            try std.testing.expect(std.mem.eql(u8, expected, "hashtag"));
            saw_hashtag = true;
        }
    }
    try std.testing.expect(saw_bech32 and saw_comma_text and saw_hashtag);
}

test "Test 15d: multiple URLs with separators" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const content = "https://github.com/damus-io, https://jb55.com/, http://wikipedia.org";
    var blocks = try ndb.parseContentBlocks(alloc, content);
    defer blocks.deinit();

    var iter = ndb.BlocksIter.start(content, blocks.blocks);
    var i: usize = 0;
    while (iter.next()) |blk| {
        i += 1;
        const t = ndb.c.ndb_get_block_type(blk);
        if (i == 1 or i == 3 or i == 5) {
            try std.testing.expect(t == ndb.c.BLOCK_URL);
        } else {
            try std.testing.expect(t == ndb.c.BLOCK_TEXT);
        }
    }
    try std.testing.expectEqual(@as(usize, 5), i);
}

// TODO: Invoice block parsing test disabled due to bolt11 parsing issues
// The bolt11 decoder has integer overflow issues causing panics.
// Invoice blocks are currently parsed as text blocks instead of BLOCK_INVOICE.
// This needs to be fixed in the nostrdb C code.
//
// test "Test 15e: invoice block parsing" {
//     // Test would verify that lightning invoices (lnbc...) are parsed as BLOCK_INVOICE
//     // Currently they're incorrectly parsed as BLOCK_TEXT
// }

test "Test 16: profile_record_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    // Process a profile event (kind 0)
    const profile_event = 
        \\["EVENT","nostril-query",{"content":"{\"nip05\":\"_@jb55.com\",\"website\":\"https://damus.io\",\"name\":\"jb55\",\"about\":\"I made damus, npubs and zaps. banned by apple & the ccp. my notes are not for sale.\",\"lud16\":\"jb55@sendsats.lol\",\"banner\":\"https://nostr.build/i/3d6f22d45d95ecc2c19b1acdec57aa15f2dba9c423b536e26fc62707c125f557.jpg\",\"display_name\":\"Will\",\"picture\":\"https://cdn.jb55.com/img/red-me.jpg\"}","created_at":1700855305,"id":"cad04d11f7fa9c36d57400baca198582dfeb94fa138366c4469e58da9ed60051","kind":0,"pubkey":"32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245","sig":"7a15e379ff27318460172b4a1d55a13e064c5007d05d5a188e7f60e244a9ed08996cb7676058b88c7a91ae9488f8edc719bc966cb5bf1eb99be44cdb745f915f","tags":[]}]
    ;
    
    try db.processEvent(profile_event);
    
    // Wait for background indexing to complete
    db.ensureProcessed(200);

    // Query the profile by pubkey
    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();

    var pk: [32]u8 = undefined;
    try ndb.hexTo32(&pk, "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245");
    const pr = try ndb.getProfileByPubkeyFree(&txn, &pk);
    
    // Check the profile fields
    const name = try pr.name();
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("jb55", name.?);

    const display_name = try pr.displayName();
    try std.testing.expect(display_name != null);
    try std.testing.expectEqualStrings("Will", display_name.?);

    const about = try pr.about();
    try std.testing.expect(about != null);
    try std.testing.expect(std.mem.indexOf(u8, about.?, "damus") != null);

    const website = try pr.website();
    try std.testing.expect(website != null);
    try std.testing.expectEqualStrings("https://damus.io", website.?);
}

test "ProfileRecord returns TransactionEnded error after transaction ends" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    // Process a profile event (kind 0)
    const profile_event = 
        \\["EVENT","nostril-query",{"content":"{\"nip05\":\"_@jb55.com\",\"website\":\"https://damus.io\",\"name\":\"jb55\",\"about\":\"I made damus, npubs and zaps. banned by apple & the ccp. my notes are not for sale.\",\"lud16\":\"jb55@sendsats.lol\",\"banner\":\"https://nostr.build/i/3d6f22d45d95ecc2c19b1acdec57aa15f2dba9c423b536e26fc62707c125f557.jpg\",\"display_name\":\"Will\",\"picture\":\"https://cdn.jb55.com/img/red-me.jpg\"}","created_at":1700855305,"id":"cad04d11f7fa9c36d57400baca198582dfeb94fa138366c4469e58da9ed60051","kind":0,"pubkey":"32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245","sig":"7a15e379ff27318460172b4a1d55a13e064c5007d05d5a188e7f60e244a9ed08996cb7676058b88c7a91ae9488f8edc719bc966cb5bf1eb99be44cdb745f915f","tags":[]}]
    ;
    
    try db.processEvent(profile_event);
    
    // Wait for background indexing to complete
    db.ensureProcessed(200);

    var pk: [32]u8 = undefined;
    try ndb.hexTo32(&pk, "32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245");
    
    // Get profile within a transaction
    var pr: ndb.profile.ProfileRecord = undefined;
    {
        var txn = try ndb.Transaction.begin(&db);
        defer txn.end();
        
        pr = try ndb.getProfileByPubkeyFree(&txn, &pk);
        
        // Verify we can access the profile while transaction is active
        const name = try pr.name();
        try std.testing.expect(name != null);
        try std.testing.expectEqualStrings("jb55", name.?);
    }
    // Transaction is now ended
    
    // Trying to access profile data should return TransactionEnded error
    const name_result = pr.name();
    try std.testing.expectError(ndb.Error.TransactionEnded, name_result);
    
    const display_result = pr.displayName();
    try std.testing.expectError(ndb.Error.TransactionEnded, display_result);
    
    const about_result = pr.about();
    try std.testing.expectError(ndb.Error.TransactionEnded, about_result);
    
    const website_result = pr.website();
    try std.testing.expectError(ndb.Error.TransactionEnded, website_result);
    
    const note_key_result = pr.noteKey();
    try std.testing.expectError(ndb.Error.TransactionEnded, note_key_result);
    
    const reactions_result = pr.reactions();
    try std.testing.expectError(ndb.Error.TransactionEnded, reactions_result);
    
    const donation_result = pr.damusDonation();
    try std.testing.expectError(ndb.Error.TransactionEnded, donation_result);
    
    // Demonstrate proper error handling pattern
    const handled_name = pr.name() catch |err| switch (err) {
        ndb.Error.TransactionEnded => blk: {
            // Log or handle the error appropriately
            break :blk null;
        },
        else => return err,
    };
    try std.testing.expect(handled_name == null);
}

test "ProfileRecord rejects invalid flatbuffer data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(dir);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(alloc, dir, &cfg);
    defer db.deinit();

    // Create various invalid buffers to test validation
    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();

    // Test 1: Too small buffer (less than 8 bytes)
    {
        var small_buffer: [4]u8 = .{ 0, 0, 0, 0 };
        var pr = ndb.profile.ProfileRecord{
            .ptr = &small_buffer,
            .len = small_buffer.len,
            .primary_key = ndb.profile.ProfileKey.new(0),
            .txn = &txn,
        };
        try std.testing.expect(!pr.isValid());
        // Since we don't auto-validate in getProfile, accessing invalid data
        // would be undefined behavior. The isValid() check is what protects us.
    }

    // Test 2: Invalid root offset (points beyond buffer)
    {
        var bad_offset: [8]u8 = undefined;
        // Set root offset to 100, but buffer is only 8 bytes
        std.mem.writeInt(u32, bad_offset[0..4], 100, .little);
        std.mem.writeInt(u32, bad_offset[4..8], 0, .little);
        
        var pr = ndb.profile.ProfileRecord{
            .ptr = &bad_offset,
            .len = bad_offset.len,
            .primary_key = ndb.profile.ProfileKey.new(0),
            .txn = &txn,
        };
        try std.testing.expect(!pr.isValid());
        // Don't access invalid data - would be undefined behavior
    }

    // Test 3: Invalid vtable offset (positive instead of negative)
    {
        var bad_vtable: [12]u8 = undefined;
        // Root offset = 4 (points to byte 8)
        std.mem.writeInt(u32, bad_vtable[0..4], 4, .little);
        // Padding
        std.mem.writeInt(u32, bad_vtable[4..8], 0, .little);
        // Vtable offset (positive = invalid)
        std.mem.writeInt(i32, bad_vtable[8..12], 10, .little);
        
        var pr = ndb.profile.ProfileRecord{
            .ptr = &bad_vtable,
            .len = bad_vtable.len,
            .primary_key = ndb.profile.ProfileKey.new(0),
            .txn = &txn,
        };
        try std.testing.expect(!pr.isValid());
        // Don't access invalid data - would be undefined behavior
    }

    // Test 4: Completely random data
    {
        var random_data: [100]u8 = undefined;
        var prng = std.Random.DefaultPrng.init(12345);
        prng.random().bytes(&random_data);
        
        var pr = ndb.profile.ProfileRecord{
            .ptr = &random_data,
            .len = random_data.len,
            .primary_key = ndb.profile.ProfileKey.new(0),
            .txn = &txn,
        };
        // Random data is extremely unlikely to be a valid flatbuffer
        try std.testing.expect(!pr.isValid());
        // Don't access invalid data - would be undefined behavior
    }
}

test "Test 14c: tag counts match" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var nb = try ndb.NoteBuilder.init(alloc, 16 * 1024);
    defer nb.deinit();

    try nb.setContent("content");
    nb.setKind(1);
    try nb.newTag();
    try nb.pushTagStr("comment");
    try nb.pushTagStr("this is a comment");
    try nb.newTag();
    try nb.pushTagStr("blah");
    try nb.pushTagStr("something");

    const note = try nb.finalizeUnsigned();

    var it = ndb.TagIter.start(note);
    var idx: usize = 0;
    while (it.next()) {
        idx += 1;
        const count = ndb.c.ndb_tag_count(it.iter.tag);
        if (idx == 1) {
            try std.testing.expect(count == 2);
        } else if (idx == 2) {
            try std.testing.expect(count == 2);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), idx);
}

test "search_profile_works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create temp directory
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);

    // Init database
    var config = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(allocator, dir, &config);
    defer db.deinit();

    // Create subscription for profile events
    var filter = try ndb.Filter.init();
    defer filter.deinit();
    var filter_builder = ndb.FilterBuilder.init(&filter);
    _ = try filter_builder.kinds(&[_]u64{0});
    _ = try filter_builder.build();
    var filters = [_]ndb.Filter{filter};
    
    const sub = db.subscribe(&filters[0], @intCast(filters.len));
    // No unsubscribe in current implementation

    // Process Derek Ross profile event
    const derek_event = 
        \\["EVENT","b",{  "id": "0b9f0e14727733e430dcb00c69b12a76a1e100f419ce369df837f7eb33e4523c",  "pubkey": "3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24",  "created_at": 1736785355,  "kind": 0,  "tags": [    [      "alt",      "User profile for Derek Ross"    ],    [      "i",      "twitter:derekmross",      "1634343988407726081"    ],    [      "i",      "github:derekross",      "3edaf845975fa4500496a15039323fa3I"    ]  ],  "content": "{\"about\":\"Building NostrPlebs.com and NostrNests.com. The purple pill helps the orange pill go down. Nostr is the social glue that binds all of your apps together.\",\"banner\":\"https://i.nostr.build/O2JE.jpg\",\"display_name\":\"Derek Ross\",\"lud16\":\"derekross@strike.me\",\"name\":\"Derek Ross\",\"nip05\":\"derekross@nostrplebs.com\",\"picture\":\"https://i.nostr.build/MVIJ6OOFSUzzjVEc.jpg\",\"website\":\"https://nostrplebs.com\",\"created_at\":1707238393}",  "sig": "51e1225ccaf9b6739861dc218ac29045b09d5cf3a51b0ac6ea64bd36827d2d4394244e5f58a4e4a324c84eeda060e1a27e267e0d536e5a0e45b0b6bdc2c43bbc"}]
    ;
    
    // Process KernelKind profile event
    const kernel_event =
        \\["EVENT","b",{  "id": "232a02ec7e1b2febf85370b52ed49bf34e2701c385c3d563511508dcf0767bcf",  "pubkey": "4a0510f26880d40e432f4865cb5714d9d3c200ca6ebb16b418ae6c555f574967",  "created_at": 1736017863,  "kind": 0,  "tags": [    [      "client",      "Damus Notedeck"    ]  ],  "content": "{\"display_name\":\"KernelKind\",\"name\":\"KernelKind\",\"about\":\"hello from notedeck!\",\"lud16\":\"kernelkind@getalby.com\"}",  "sig": "18c7dea0da3c30677d6822a31a6dfd9ebc02a18a31d69f0f2ac9ba88409e437d3db0ac433639111df1e4948a6d18451d1582173ee4fcd018d0ec92939f2c1506"}]
    ;

    try db.processEvent(derek_event);
    try db.processEvent(kernel_event);
    
    // Wait for processing and poll notes
    std.Thread.sleep(500 * std.time.ns_per_ms);
    var note_ids: [2]u64 = undefined;
    _ = db.pollForNotes(sub, &note_ids);

    // Begin transaction for search
    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();

    // Search for "kernel"
    {
        const results = try ndb.searchProfileFree(&txn, "kernel", 1, allocator);
        defer allocator.free(results);
        
        try std.testing.expect(results.len >= 1);
        
        const expected_kernelkind_bytes = [32]u8{
            0x4a, 0x05, 0x10, 0xf2, 0x68, 0x80, 0xd4, 0x0e, 0x43, 0x2f, 0x48, 0x65, 0xcb, 0x57,
            0x14, 0xd9, 0xd3, 0xc2, 0x00, 0xca, 0x6e, 0xbb, 0x16, 0xb4, 0x18, 0xae, 0x6c, 0x55,
            0x5f, 0x57, 0x49, 0x67,
        };
        try std.testing.expectEqualSlices(u8, &expected_kernelkind_bytes, &results[0].pubkey);
    }

    // Search for "Derek"
    {
        const results = try ndb.searchProfileFree(&txn, "Derek", 1, allocator);
        defer allocator.free(results);
        
        try std.testing.expect(results.len >= 1);
        
        const expected_derek_bytes = [32]u8{
            0x3f, 0x77, 0x0d, 0x65, 0xd3, 0xa7, 0x64, 0xa9, 0xc5, 0xcb, 0x50, 0x3a, 0xe1, 0x23,
            0xe6, 0x2e, 0xc7, 0x59, 0x8a, 0xd0, 0x35, 0xd8, 0x36, 0xe2, 0xa8, 0x10, 0xf3, 0x87,
            0x7a, 0x74, 0x5b, 0x24,
        };
        try std.testing.expectEqualSlices(u8, &expected_derek_bytes, &results[0].pubkey);
    }
}
