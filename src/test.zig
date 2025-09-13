const std = @import("std");
const ndb = @import("ndb.zig");
const build_options = @import("build_options");

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

    var ids: [1]u64 = .{0};
    var got: i32 = 0;
    // Poll loop: allow background writer to index
    var tries: usize = 0;
    // FIXME: sleeping + polling is brittle. Replace with a proper
    // subscription wrapper helper that waits deterministically.
    while (got == 0 and tries < 20) : (tries += 1) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        got = db.pollForNotes(subid, &ids);
    }
    try std.testing.expectEqual(@as(i32, 1), got);
    try std.testing.expect(ids[0] != 0);
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
    // FIXME: This uses waitForNotes with a dummy subid to nudge the
    // background writer. Replace with a real subscription or explicit
    // flush signal once exposed.
    var ids: [1]u64 = .{0};
    _ = db.waitForNotes(1, &ids);
    std.Thread.sleep(150 * std.time.ns_per_ms);

    var txn = try ndb.Transaction.begin(&db);
    defer txn.end();

    var id_bytes: [32]u8 = undefined;
    try ndb.hexTo32(&id_bytes, id_hex);
    const note_opt = ndb.getNoteById(&txn, &id_bytes);
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

    // Wait for both notes
    var ids_buf: [4]u64 = .{0} ** 4;
    var total: usize = 0;
    var spins: usize = 0;
    // FIXME: sleeping while waiting for notes is timing-sensitive.
    // Consider a helper that drains until count is reached with a timeout.
    while (total < 2 and spins < 40) : (spins += 1) {
        std.Thread.sleep(50 * std.time.ns_per_ms);
        const got = db.waitForNotes(1, ids_buf[total..]) ;
        if (got > 0) total += @intCast(got);
    }

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

    var maybe_kp: ?ndb.Keypair = null;
    if (build_options.enable_sign_tests) {
        maybe_kp = try ndb.Keypair.create();
    }
    const note = if (build_options.enable_sign_tests)
        try nb.finalize(&maybe_kp.?)
    else
        try nb.finalizeUnsigned();
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

    var maybe_kp: ?ndb.Keypair = null;
    if (build_options.enable_sign_tests) {
        maybe_kp = try ndb.Keypair.create();
    }
    const note = if (build_options.enable_sign_tests)
        try nb.finalize(&maybe_kp.?)
    else
        try nb.finalizeUnsigned();

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
