// Error types consistent with nostrdb-rs error handling

const std = @import("std");

/// Main error enum matching Rust's Error enum structure
pub const Error = error{
    /// Database open failed
    DbOpenFailed,

    /// Resource not found
    NotFound,

    /// Data decode error
    DecodeError,

    /// Query failed
    QueryFailed,

    /// Transaction begin failed
    TransactionFailed,

    /// Invalid input
    InvalidInput,

    /// Out of memory
    OutOfMemory,

    /// Search failed
    SearchFailed,
};

/// Result type similar to Rust's Result<T, Error>
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Error,

        pub fn isOk(self: @This()) bool {
            return self == .ok;
        }

        pub fn isErr(self: @This()) bool {
            return self == .err;
        }

        pub fn unwrap(self: @This()) T {
            return switch (self) {
                .ok => |val| val,
                .err => |e| std.debug.panic("unwrap called on error: {}", .{e}),
            };
        }

        pub fn unwrapOr(self: @This(), default: T) T {
            return switch (self) {
                .ok => |val| val,
                .err => default,
            };
        }

        pub fn unwrapErr(self: @This()) Error {
            return switch (self) {
                .ok => std.debug.panic("unwrapErr called on ok value", .{}),
                .err => |e| e,
            };
        }
    };
}
