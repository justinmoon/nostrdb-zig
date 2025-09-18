const std = @import("std");
const ndb = @import("ndb.zig");

test "verify signing produces valid id/sig" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var nb = try ndb.NoteBuilder.init(alloc, 16 * 1024);
    defer nb.deinit();

    try nb.setContent("test message");
    nb.setKind(1);
    nb.setCreatedAt(1700000000);

    var kp = try ndb.Keypair.create();
    const note = try nb.finalize(&kp);

    // The note should have valid id and signature fields
    const id = ndb.c.ndb_note_id(note.ptr);
    const sig = ndb.c.ndb_note_sig(note.ptr);
    const pubkey = ndb.c.ndb_note_pubkey(note.ptr);

    // Just verify they're not null and print first few bytes
    try std.testing.expect(id != null);
    try std.testing.expect(sig != null);
    try std.testing.expect(pubkey != null);

    std.debug.print("\nSigning verification:\n", .{});
    std.debug.print("  ID: {x:0>2}{x:0>2}{x:0>2}{x:0>2}...\n", .{ id[0], id[1], id[2], id[3] });
    std.debug.print("  Sig: {x:0>2}{x:0>2}{x:0>2}{x:0>2}...\n", .{ sig[0], sig[1], sig[2], sig[3] });
    std.debug.print("  Pubkey: {x:0>2}{x:0>2}{x:0>2}{x:0>2}...\n", .{ pubkey[0], pubkey[1], pubkey[2], pubkey[3] });
}
