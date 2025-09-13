const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("nostrdb.h");
});

pub fn main() !void {
    std.debug.print("Test 4: Reproducing Test 14 with tags...\n", .{});
    std.debug.print("HAVE_UNALIGNED_ACCESS = {}\n", .{c.HAVE_UNALIGNED_ACCESS});
    
    const bufsize: usize = 1024 * 16;
    const buffer = try std.heap.c_allocator.alloc(u8, bufsize);
    defer std.heap.c_allocator.free(buffer);
    
    std.debug.print("Buffer at: 0x{x} (aligned to 4: {})\n", .{@intFromPtr(buffer.ptr), @intFromPtr(buffer.ptr) % 4 == 0});
    
    // Initialize builder
    var builder: c.struct_ndb_builder = undefined;
    const init_ok = c.ndb_builder_init(&builder, buffer.ptr, buffer.len);
    if (init_ok == 0) {
        std.debug.print("Failed to init builder\n", .{});
        return;
    }
    
    // Set content - same as Test 14
    const content = "hi";
    const content_ok = c.ndb_builder_set_content(&builder, content.ptr, content.len);
    if (content_ok == 0) {
        std.debug.print("Failed to set content\n", .{});
        return;
    }
    
    // Set kind
    c.ndb_builder_set_kind(&builder, 1);
    
    // Add first tag - same as Test 14
    std.debug.print("Adding first tag...\n", .{});
    if (c.ndb_builder_new_tag(&builder) == 0) {
        std.debug.print("Failed to create tag\n", .{});
        return;
    }
    if (c.ndb_builder_push_tag_str(&builder, "e", 1) == 0) {
        std.debug.print("Failed to push 'e'\n", .{});
        return;
    }
    
    // Push the hex string like Test 14
    const hex_str = "0336948bdfbf5f939802eba03aa78735c82825211eece987a6d2e20e3cfff930";
    if (c.ndb_builder_push_tag_str(&builder, hex_str.ptr, hex_str.len) == 0) {
        std.debug.print("Failed to push hex string\n", .{});
        return;
    }
    
    // Add second tag
    std.debug.print("Adding second tag...\n", .{});
    if (c.ndb_builder_new_tag(&builder) == 0) {
        std.debug.print("Failed to create second tag\n", .{});
        return;
    }
    if (c.ndb_builder_push_tag_str(&builder, "t", 1) == 0) {
        std.debug.print("Failed to push 't'\n", .{});
        return;
    }
    if (c.ndb_builder_push_tag_str(&builder, "topic", 5) == 0) {
        std.debug.print("Failed to push 'topic'\n", .{});
        return;
    }
    
    // Create keypair and finalize
    std.debug.print("Creating keypair and finalizing...\n", .{});
    var keypair: c.struct_ndb_keypair = undefined;
    const kp_ok = c.ndb_create_keypair(&keypair);
    if (kp_ok == 0) {
        std.debug.print("Failed to create keypair\n", .{});
        return;
    }
    
    var note_ptr: ?*c.struct_ndb_note = null;
    const finalize_ok = c.ndb_builder_finalize(&builder, &note_ptr, &keypair);
    
    if (finalize_ok == 0 or note_ptr == null) {
        std.debug.print("Failed to finalize note\n", .{});
        return;
    }
    
    std.debug.print("SUCCESS! Note created\n", .{});
    
    // Print some debug info about the note structure
    const note_addr = @intFromPtr(note_ptr);
    std.debug.print("Note at: 0x{x} (aligned to 4: {})\n", .{note_addr, note_addr % 4 == 0});
}