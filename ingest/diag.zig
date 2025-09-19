const std = @import("std");

pub const Allocator = std.mem.Allocator;

// Diagnostic information tracked per relay during an ingestion job.
pub const RelayDiag = struct {
    url: []const u8,
    attempts: u32 = 0,
    eose: bool = false,
    last_error: ?[]const u8 = null,
    last_change_ms: u64 = 0,

    pub fn deinit(self: *RelayDiag, allocator: Allocator) void {
        if (self.last_error) |e| allocator.free(e);
        self.* = undefined;
    }
};

