const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("nostrdb.h");
});

pub fn main() !void {
    std.debug.print("Test 2: Using Zig c_allocator...\n", .{});

    const bufsize: usize = 1024 * 16;

    // Try with Zig's c_allocator
    const buffer = try std.heap.c_allocator.alloc(u8, bufsize);
    defer std.heap.c_allocator.free(buffer);

    std.debug.print("Allocated buffer at {*}\n", .{buffer.ptr});

    // Initialize builder
    var builder: c.struct_ndb_builder = undefined;
    const init_ok = c.ndb_builder_init(&builder, buffer.ptr, buffer.len);
    if (init_ok == 0) {
        std.debug.print("Failed to init builder\n", .{});
        return;
    }
    std.debug.print("Builder initialized\n", .{});

    // Set content
    const content = "hello world";
    const content_ok = c.ndb_builder_set_content(&builder, content.ptr, content.len);
    if (content_ok == 0) {
        std.debug.print("Failed to set content\n", .{});
        return;
    }
    std.debug.print("Content set\n", .{});

    // Set kind
    c.ndb_builder_set_kind(&builder, 1);
    std.debug.print("Kind set\n", .{});

    // Create keypair
    var keypair: c.struct_ndb_keypair = undefined;
    const kp_ok = c.ndb_create_keypair(&keypair);
    if (kp_ok == 0) {
        std.debug.print("Failed to create keypair\n", .{});
        return;
    }
    std.debug.print("Keypair created\n", .{});

    // Finalize with signing
    var note_ptr: ?*c.struct_ndb_note = null;
    const finalize_ok = c.ndb_builder_finalize(&builder, &note_ptr, &keypair);

    if (finalize_ok == 0 or note_ptr == null) {
        std.debug.print("Failed to finalize note\n", .{});
        return;
    }

    std.debug.print("SUCCESS! Note created with kind: {}\n", .{c.ndb_note_kind(note_ptr)});
    std.debug.print("Content: {s}\n", .{c.ndb_note_content(note_ptr)});
}
