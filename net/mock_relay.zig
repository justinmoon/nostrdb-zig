const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.mock_relay);

pub const Response = union(enum) {
    text: []const u8,
    binary: []const u8,
};

pub const Options = struct {
    allocator: Allocator,
    port: u16,
    host: []const u8 = "127.0.0.1",
    responses: []const Response,
};

pub const MockError = error{
    AlreadyStarted,
    NotStarted,
    OutOfMemory,
    ListenFailed,
};

pub const MockRelayServer = struct {
    allocator: Allocator,
    host: []u8,
    port: u16,
    responses: []ResponseStorage,

    server: websocket.Server(Handler),
    thread: ?std.Thread = null,
    started: bool = false,

    pub fn init(options: Options) !MockRelayServer {
        var host_copy = try options.allocator.dupe(u8, options.host);
        errdefer options.allocator.free(host_copy);

        var responses_copy = try options.allocator.alloc(ResponseStorage, options.responses.len);
        errdefer options.allocator.free(responses_copy);

        for (options.responses, 0..) |item, idx| {
            responses_copy[idx] = switch (item) {
                .text => |payload| .{ .tag = .text, .data = try options.allocator.dupe(u8, payload) },
                .binary => |payload| .{ .tag = .binary, .data = try options.allocator.dupe(u8, payload) },
            };
        }

        var server = try websocket.Server(Handler).init(options.allocator, .{
            .port = options.port,
            .address = options.host,
        });
        errdefer server.deinit();

        return .{
            .allocator = options.allocator,
            .host = host_copy,
            .port = options.port,
            .responses = responses_copy,
            .server = server,
        };
    }

    pub fn deinit(self: *MockRelayServer) void {
        self.stop() catch |err| {
            if (err != MockError.NotStarted) {
                log.warn("error stopping mock relay: {}", .{err});
            }
        };

        for (self.responses) |resp| {
            self.allocator.free(resp.data);
        }
        self.allocator.free(self.responses);
        self.allocator.free(self.host);
        self.server.deinit();
    }

    pub fn start(self: *MockRelayServer) MockError!void {
        if (self.started) return MockError.AlreadyStarted;

        const thread = self.server.listenInNewThread(self) catch |err| {
            log.err("failed to start mock relay listener: {}", .{err});
            return MockError.ListenFailed;
        };

        self.thread = thread;
        self.started = true;
    }

    pub fn stop(self: *MockRelayServer) MockError!void {
        if (!self.started) return MockError.NotStarted;

        self.server.stop();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.started = false;
    }

    pub fn address(self: *MockRelayServer, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "ws://{s}:{d}", .{ self.host, self.port });
    }

    const Handler = struct {
        conn: *websocket.Conn,
        parent: *MockRelayServer,
        responded: bool = false,
        subscription_id: ?[]u8 = null,

        pub fn init(h: *const websocket.Handshake, conn: *websocket.Conn, parent: *MockRelayServer) !Handler {
            _ = h;
            return .{ .conn = conn, .parent = parent };
        }

        pub fn clientMessage(self: *Handler, allocator: Allocator, data: []const u8) !void {
            if (self.subscription_id == null) {
                const sub_copy = try extractSubId(self.parent.allocator, allocator, data);
                self.subscription_id = sub_copy;
            }

            if (self.responded) return;
            if (!std.mem.startsWith(u8, data, "[\"REQ")) return;

            self.responded = true;
            for (self.parent.responses) |resp| {
                switch (resp.tag) {
                    .text => {
                        const rendered = try self.renderText(resp.data);
                        defer if (rendered.owned) self.parent.allocator.free(rendered.data);
                        try self.conn.writeText(rendered.data);
                    },
                    .binary => try self.conn.writeBin(resp.data),
                }
            }
        }

        pub fn close(self: *Handler) void {
            if (self.subscription_id) |sid| {
                self.parent.allocator.free(sid);
            }
        }

        fn renderText(self: *Handler, template: []const u8) Allocator.Error!RenderedText {
            const sub = self.subscription_id orelse return RenderedText{ .data = template, .owned = false };
            const placeholder = "{SUB_ID}";
            if (std.mem.indexOf(u8, template, placeholder) == null) {
                return RenderedText{ .data = template, .owned = false };
            }

            var builder = std.ArrayList(u8).init(self.parent.allocator);
            errdefer builder.deinit();

            var start: usize = 0;
            while (std.mem.indexOf(u8, template[start..], placeholder)) |pos| {
                try builder.appendSlice(template[start .. start + pos]);
                try builder.appendSlice(sub);
                start += pos + placeholder.len;
            }
            try builder.appendSlice(template[start..]);

            const owned = try builder.toOwnedSlice();
            builder.deinit();
            return RenderedText{ .data = owned, .owned = true };
        }
    };
};

const ResponseStorage = struct {
    tag: enum { text, binary },
    data: []u8,
};

const RenderedText = struct {
    data: []const u8,
    owned: bool,
};

const ExtractError = error{InvalidRequest};

fn extractSubId(dest_allocator: Allocator, temp_allocator: Allocator, request: []const u8) (Allocator.Error || ExtractError)![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, temp_allocator, request, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return ExtractError.InvalidRequest;
    const arr = root.array.items;
    if (arr.len < 2) return ExtractError.InvalidRequest;
    if (arr[1] != .string) return ExtractError.InvalidRequest;
    return try dest_allocator.dupe(u8, arr[1].string);
}
