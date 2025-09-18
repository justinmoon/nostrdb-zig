const std = @import("std");
const c = @cImport({
    @cInclude("openmls_ffi.h");
});

fn bufferSlice(buffer: c.OpenmlsFfiBuffer) []const u8 {
    if (buffer.data == null or buffer.len == 0) return &[_]u8{};
    return buffer.data[0..buffer.len];
}

test "openmls ffi basic flow" {
    const version = c.openmls_ffi_version();
    try std.testing.expect(version != null);

    const provider_alice = c.openmls_ffi_provider_new_default();
    try std.testing.expect(provider_alice != null);
    defer c.openmls_ffi_provider_free(provider_alice);

    const provider_bob = c.openmls_ffi_provider_new_default();
    try std.testing.expect(provider_bob != null);
    defer c.openmls_ffi_provider_free(provider_bob);

    const provider_charlie = c.openmls_ffi_provider_new_default();
    try std.testing.expect(provider_charlie != null);
    defer c.openmls_ffi_provider_free(provider_charlie);

    var key_package = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const key_status = c.openmls_ffi_key_package_create(
        provider_bob,
        "884704bd421671e01c13f854d2ce23ce2a5bfe9562f4f297ad2bc921ba30c3a6",
        0x0001,
        null,
        0,
        true,
        &key_package,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, key_status);
    defer c.openmls_ffi_buffer_free(key_package);

    var group_id = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var commit_msg = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var welcome_msg = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var group_info = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };

    const group_status = c.openmls_ffi_group_create(
        provider_alice,
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        0x0001,
        null,
        0,
        null,
        0,
        &key_package,
        1,
        true,
        &group_id,
        &commit_msg,
        &welcome_msg,
        &group_info,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, group_status);
    defer c.openmls_ffi_buffer_free(group_id);
    defer c.openmls_ffi_buffer_free(commit_msg);
    defer c.openmls_ffi_buffer_free(welcome_msg);
    defer c.openmls_ffi_buffer_free(group_info);

    var staged: ?*anyopaque = null;
    var group_context = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const parse_status = c.openmls_ffi_welcome_parse(
        provider_bob,
        &welcome_msg,
        null,
        true,
        &staged,
        &group_context,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, parse_status);
    defer c.openmls_ffi_buffer_free(group_context);

    var bob_group_id = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const join_status = c.openmls_ffi_welcome_join(provider_bob, staged.?, &bob_group_id);
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, join_status);
    defer c.openmls_ffi_buffer_free(bob_group_id);
    c.openmls_ffi_welcome_free(staged.?);

    const allocator = std.testing.allocator;
    const message_bytes = "Hi Bob!";
    const message_copy = try allocator.dupe(u8, message_bytes);
    defer allocator.free(message_copy);

    var plaintext = c.OpenmlsFfiBuffer{
        .data = message_copy.ptr,
        .len = message_copy.len,
    };
    var ciphertext = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const encrypt_status = c.openmls_ffi_message_encrypt(
        provider_alice,
        &group_id,
        &plaintext,
        &ciphertext,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, encrypt_status);
    defer c.openmls_ffi_buffer_free(ciphertext);

    var decrypted = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var msg_type: c.OpenmlsProcessedMessageType = c.Other;
    const decrypt_status = c.openmls_ffi_message_decrypt(
        provider_bob,
        &bob_group_id,
        &ciphertext,
        &decrypted,
        &msg_type,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, decrypt_status);
    defer c.openmls_ffi_buffer_free(decrypted);

    try std.testing.expectEqual(@as(c.OpenmlsProcessedMessageType, c.Application), msg_type);
    try std.testing.expectEqualStrings(message_bytes, bufferSlice(decrypted));

    // === Membership mutations ===

    var charlie_key_package = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const charlie_key_status = c.openmls_ffi_key_package_create(
        provider_charlie,
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        0x0001,
        null,
        0,
        true,
        &charlie_key_package,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, charlie_key_status);
    defer c.openmls_ffi_buffer_free(charlie_key_package);

    var add_commit = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var add_welcome = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var add_group_info = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const add_buffers = [_]c.OpenmlsFfiBuffer{charlie_key_package};
    const add_status = c.openmls_ffi_group_add_members(
        provider_alice,
        &group_id,
        &add_buffers[0],
        add_buffers.len,
        &add_commit,
        &add_welcome,
        &add_group_info,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, add_status);
    defer c.openmls_ffi_buffer_free(add_commit);
    defer c.openmls_ffi_buffer_free(add_welcome);
    defer c.openmls_ffi_buffer_free(add_group_info);
    try std.testing.expect(add_welcome.len > 0);

    var add_plaintext = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var add_type: c.OpenmlsProcessedMessageType = c.Other;
    const add_decrypt_status = c.openmls_ffi_message_decrypt(
        provider_bob,
        &bob_group_id,
        &add_commit,
        &add_plaintext,
        &add_type,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, add_decrypt_status);
    try std.testing.expectEqual(@as(c.OpenmlsProcessedMessageType, c.Commit), add_type);
    c.openmls_ffi_buffer_free(add_plaintext);

    const merge_add_status = c.openmls_ffi_group_merge_pending_commit(provider_alice, &group_id);
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, merge_add_status);

    var charlie_staged: ?*anyopaque = null;
    var charlie_context = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const charlie_parse = c.openmls_ffi_welcome_parse(
        provider_charlie,
        &add_welcome,
        null,
        true,
        &charlie_staged,
        &charlie_context,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, charlie_parse);
    defer c.openmls_ffi_buffer_free(charlie_context);

    var charlie_group_id = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const charlie_join =
        c.openmls_ffi_welcome_join(provider_charlie, charlie_staged.?, &charlie_group_id);
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, charlie_join);
    defer c.openmls_ffi_buffer_free(charlie_group_id);
    c.openmls_ffi_welcome_free(charlie_staged.?);

    const alice_group_slice = bufferSlice(group_id);
    const charlie_group_slice = bufferSlice(charlie_group_id);
    try std.testing.expectEqual(alice_group_slice.len, charlie_group_slice.len);
    try std.testing.expect(std.mem.eql(u8, alice_group_slice, charlie_group_slice));

    var remove_commit = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var remove_welcome = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var remove_group_info = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const remove_indices = [_]u32{2};
    const remove_status = c.openmls_ffi_group_remove_members(
        provider_alice,
        &group_id,
        &remove_indices[0],
        remove_indices.len,
        &remove_commit,
        &remove_welcome,
        &remove_group_info,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, remove_status);
    defer c.openmls_ffi_buffer_free(remove_commit);
    defer c.openmls_ffi_buffer_free(remove_welcome);
    defer c.openmls_ffi_buffer_free(remove_group_info);
    try std.testing.expectEqual(@as(usize, 0), remove_welcome.len);

    var remove_plaintext = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var remove_type: c.OpenmlsProcessedMessageType = c.Other;
    const remove_decrypt = c.openmls_ffi_message_decrypt(
        provider_bob,
        &bob_group_id,
        &remove_commit,
        &remove_plaintext,
        &remove_type,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, remove_decrypt);
    try std.testing.expectEqual(@as(c.OpenmlsProcessedMessageType, c.Commit), remove_type);
    c.openmls_ffi_buffer_free(remove_plaintext);

    const merge_remove_status = c.openmls_ffi_group_merge_pending_commit(provider_alice, &group_id);
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, merge_remove_status);

    var self_commit = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var self_welcome = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var self_group_info = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const self_status = c.openmls_ffi_group_self_update(
        provider_alice,
        &group_id,
        &self_commit,
        &self_welcome,
        &self_group_info,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, self_status);
    defer c.openmls_ffi_buffer_free(self_commit);
    defer c.openmls_ffi_buffer_free(self_welcome);
    defer c.openmls_ffi_buffer_free(self_group_info);
    try std.testing.expectEqual(@as(usize, 0), self_welcome.len);

    var self_plaintext = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var self_type: c.OpenmlsProcessedMessageType = c.Other;
    const self_decrypt = c.openmls_ffi_message_decrypt(
        provider_bob,
        &bob_group_id,
        &self_commit,
        &self_plaintext,
        &self_type,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, self_decrypt);
    try std.testing.expectEqual(@as(c.OpenmlsProcessedMessageType, c.Commit), self_type);
    c.openmls_ffi_buffer_free(self_plaintext);

    const merge_self_status = c.openmls_ffi_group_merge_pending_commit(provider_alice, &group_id);
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, merge_self_status);

    var leave_message = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    const leave_status = c.openmls_ffi_group_leave(provider_bob, &bob_group_id, &leave_message);
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, leave_status);
    defer c.openmls_ffi_buffer_free(leave_message);

    var leave_plaintext = c.OpenmlsFfiBuffer{ .data = null, .len = 0 };
    var leave_type: c.OpenmlsProcessedMessageType = c.Other;
    const leave_decrypt = c.openmls_ffi_message_decrypt(
        provider_alice,
        &group_id,
        &leave_message,
        &leave_plaintext,
        &leave_type,
    );
    try std.testing.expectEqual(c.OPENMLS_STATUS_OK, leave_decrypt);
    try std.testing.expectEqual(@as(c.OpenmlsProcessedMessageType, c.Proposal), leave_type);
    c.openmls_ffi_buffer_free(leave_plaintext);
}
