const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("string.h");
    @cInclude("nostrdb.h");
});

pub fn main() !void {
    std.debug.print("Test 3: Check HAVE_UNALIGNED_ACCESS value...\n", .{});
    
    // Let's see what HAVE_UNALIGNED_ACCESS is actually set to
    std.debug.print("HAVE_UNALIGNED_ACCESS = {}\n", .{c.HAVE_UNALIGNED_ACCESS});
    
    // Test with different allocators
    try testWithAllocator("malloc", true);
    try testWithAllocator("c_allocator", false);
}

fn testWithAllocator(name: []const u8, use_malloc: bool) !void {
    std.debug.print("\n--- Testing with {s} ---\n", .{name});
    
    const bufsize: usize = 1024 * 16;
    
    var buffer: []u8 = undefined;
    if (use_malloc) {
        const ptr = c.malloc(bufsize);
        if (ptr == null) return error.OutOfMemory;
        buffer = @as([*]u8, @ptrCast(ptr.?))[0..bufsize];
    } else {
        buffer = try std.heap.c_allocator.alloc(u8, bufsize);
    }
    defer {
        if (use_malloc) {
            c.free(buffer.ptr);
        } else {
            std.heap.c_allocator.free(buffer);
        }
    }
    
    // Check alignment of buffer
    const addr = @intFromPtr(buffer.ptr);
    std.debug.print("Buffer address: 0x{x}\n", .{addr});
    std.debug.print("Aligned to 4 bytes: {}\n", .{addr % 4 == 0});
    std.debug.print("Aligned to 8 bytes: {}\n", .{addr % 8 == 0});
    std.debug.print("Aligned to 16 bytes: {}\n", .{addr % 16 == 0});
    
    // Try the full signing process
    var builder: c.struct_ndb_builder = undefined;
    const init_ok = c.ndb_builder_init(&builder, buffer.ptr, buffer.len);
    if (init_ok == 0) {
        std.debug.print("Failed to init builder\n", .{});
        return;
    }
    
    const content = "hello world";
    const content_ok = c.ndb_builder_set_content(&builder, content.ptr, content.len);
    if (content_ok == 0) {
        std.debug.print("Failed to set content\n", .{});
        return;
    }
    
    c.ndb_builder_set_kind(&builder, 1);
    
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
    
    std.debug.print("SUCCESS with {s}!\n", .{name});
}