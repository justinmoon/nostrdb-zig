const std = @import("std");
const ascii = std.ascii;

pub const ParseError = error{
    EmptyMessage,
    InvalidJson,
    InvalidStructure,
};

pub const RelayMessage = union(enum) {
    event: Event,
    eose: Eose,
    notice: Notice,
    ok: Ok,
    unknown: Unknown,

    pub fn deinit(self: *RelayMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .event => |event| {
                allocator.free(event.raw_message);
                allocator.free(event.subscription_id);
                allocator.free(event.event_json);
            },
            .eose => |eose| {
                allocator.free(eose.raw_message);
                allocator.free(eose.subscription_id);
            },
            .notice => |notice| {
                allocator.free(notice.raw_message);
                allocator.free(notice.message);
            },
            .ok => |ok| {
                allocator.free(ok.raw_message);
                allocator.free(ok.event_id);
                allocator.free(ok.message);
            },
            .unknown => |unknown| {
                allocator.free(unknown.raw_message);
                allocator.free(unknown.command);
            },
        }
        self.* = undefined;
    }
};

pub const Event = struct {
    raw_message: []u8,
    subscription_id: []u8,
    event_json: []u8,

    pub fn subId(self: Event) []const u8 {
        return self.subscription_id;
    }

    pub fn raw(self: Event) []const u8 {
        return self.raw_message;
    }

    pub fn eventJson(self: Event) []const u8 {
        return self.event_json;
    }
};

pub const Eose = struct {
    raw_message: []u8,
    subscription_id: []u8,

    pub fn subId(self: Eose) []const u8 {
        return self.subscription_id;
    }
};

pub const Notice = struct {
    raw_message: []u8,
    message: []u8,

    pub fn text(self: Notice) []const u8 {
        return self.message;
    }
};

pub const Ok = struct {
    raw_message: []u8,
    event_id: []u8,
    accepted: bool,
    message: []u8,

    pub fn eventId(self: Ok) []const u8 {
        return self.event_id;
    }

    pub fn isAccepted(self: Ok) bool {
        return self.accepted;
    }

    pub fn text(self: Ok) []const u8 {
        return self.message;
    }
};

pub const Unknown = struct {
    raw_message: []u8,
    command: []u8,

    pub fn raw(self: Unknown) []const u8 {
        return self.raw_message;
    }

    pub fn name(self: Unknown) []const u8 {
        return self.command;
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }

    pub fn parseText(self: *Parser, text: []const u8) (ParseError || error{OutOfMemory})!RelayMessage {
        if (text.len == 0) return ParseError.EmptyMessage;

        const raw_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(raw_copy);

        const trimmed = std.mem.trim(u8, raw_copy, " \r\n\t");
        if (trimmed.len < 2) return ParseError.InvalidJson;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return ParseError.InvalidJson,
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return ParseError.InvalidStructure;
        const items = root.array.items;
        if (items.len == 0) return ParseError.InvalidStructure;

        if (items[0] != .string) return ParseError.InvalidStructure;
        const command_value = items[0].string;

        if (ascii.eqlIgnoreCase(command_value, "EVENT")) {
            if (items.len < 3) return ParseError.InvalidStructure;
            const subid_value = items[1];
            const event_value = items[2];
            if (subid_value != .string) return ParseError.InvalidStructure;
            if (event_value != .object) return ParseError.InvalidStructure;

            const subid = try self.allocator.dupe(u8, subid_value.string);
            errdefer self.allocator.free(subid);

            const event_json = try std.json.Stringify.valueAlloc(self.allocator, event_value, .{});
            errdefer self.allocator.free(event_json);

            return .{ .event = .{
                .raw_message = raw_copy,
                .subscription_id = subid,
                .event_json = event_json,
            } };
        } else if (ascii.eqlIgnoreCase(command_value, "EOSE")) {
            if (items.len < 2) return ParseError.InvalidStructure;
            const subid_value = items[1];
            if (subid_value != .string) return ParseError.InvalidStructure;

            const subid = try self.allocator.dupe(u8, subid_value.string);
            errdefer self.allocator.free(subid);

            return .{ .eose = .{
                .raw_message = raw_copy,
                .subscription_id = subid,
            } };
        } else if (ascii.eqlIgnoreCase(command_value, "NOTICE")) {
            if (items.len < 2) return ParseError.InvalidStructure;
            const message_value = items[1];
            if (message_value != .string) return ParseError.InvalidStructure;

            const msg = try self.allocator.dupe(u8, message_value.string);
            errdefer self.allocator.free(msg);

            return .{ .notice = .{
                .raw_message = raw_copy,
                .message = msg,
            } };
        } else if (ascii.eqlIgnoreCase(command_value, "OK")) {
            if (items.len < 4) return ParseError.InvalidStructure;
            const event_id_value = items[1];
            const accepted_value = items[2];
            const message_value = items[3];

            if (event_id_value != .string) return ParseError.InvalidStructure;
            if (message_value != .string) return ParseError.InvalidStructure;
            if (accepted_value != .bool) return ParseError.InvalidStructure;

            const event_id = try self.allocator.dupe(u8, event_id_value.string);
            errdefer self.allocator.free(event_id);
            const msg = try self.allocator.dupe(u8, message_value.string);
            errdefer self.allocator.free(msg);

            return .{ .ok = .{
                .raw_message = raw_copy,
                .event_id = event_id,
                .accepted = accepted_value.bool,
                .message = msg,
            } };
        } else {
            const command_dup = try self.allocator.dupe(u8, command_value);
            errdefer self.allocator.free(command_dup);
            return .{ .unknown = .{
                .raw_message = raw_copy,
                .command = command_dup,
            } };
        }
    }
};
