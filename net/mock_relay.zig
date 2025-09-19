const std = @import("std");
const websocket = @import("websocket");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.mock_relay);

pub const Response = union(enum) {
    text: []const u8,
    binary: []const u8,
};

pub const ResponseBatch = struct {
    messages: []const Response,
};

pub const RequestLog = struct {
    allocator: Allocator,
    entries: std.array_list.Managed([]u8),

    pub fn init(allocator: Allocator) RequestLog {
        return .{ .allocator = allocator, .entries = std.array_list.Managed([]u8).init(allocator) };
    }

    pub fn deinit(self: *RequestLog) void {
        for (self.entries.items) |item| self.allocator.free(item);
        self.entries.deinit();
    }

    pub fn append(self: *RequestLog, data: []const u8) Allocator.Error!void {
        const copy = try self.allocator.dupe(u8, data);
        try self.entries.append(copy);
    }
};

pub const Options = struct {
    allocator: Allocator,
    port: u16,
    host: []const u8 = "127.0.0.1",
    batches: []const ResponseBatch,
    request_log: ?*RequestLog = null,
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
    batches: []BatchStorage,
    request_log: ?*RequestLog,

    server: websocket.Server(Handler),
    thread: ?std.Thread = null,
    started: bool = false,

    pub fn init(options: Options) !MockRelayServer {
        const host_copy = try options.allocator.dupe(u8, options.host);
        errdefer options.allocator.free(host_copy);

        var batches_copy = try options.allocator.alloc(BatchStorage, options.batches.len);
        errdefer options.allocator.free(batches_copy);

        for (options.batches, 0..) |batch, idx| {
            const storage = try BatchStorage.init(options.allocator, batch.messages);
            errdefer storage.deinit(options.allocator);
            batches_copy[idx] = storage;
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
            .batches = batches_copy,
            .request_log = options.request_log,
            .server = server,
        };
    }

    pub fn deinit(self: *MockRelayServer) void {
        self.stop() catch |err| {
            if (err != MockError.NotStarted) {
                log.warn("error stopping mock relay: {}", .{err});
            }
        };

        for (self.batches) |batch| batch.deinit(self.allocator);
        self.allocator.free(self.batches);
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
        batch_index: usize = 0,

        pub fn init(h: *const websocket.Handshake, conn: *websocket.Conn, parent: *MockRelayServer) !Handler {
            _ = h;
            return .{ .conn = conn, .parent = parent };
        }

        pub fn clientMessage(self: *Handler, allocator: Allocator, data: []const u8) !void {
            if (self.subscription_id == null) {
                const sub_copy = try extractSubId(self.parent.allocator, allocator, data);
                self.subscription_id = sub_copy;
            }

            if (self.parent.request_log) |request_capture| {
                try request_capture.append(data);
            }

            if (self.responded) return;
            if (!std.mem.startsWith(u8, data, "[\"REQ")) return;

            self.responded = true;
            const batches = self.parent.batches;
            if (self.batch_index >= batches.len) {
                self.responded = false;
                return;
            }
            const current = batches[self.batch_index];
            for (current.messages) |resp| try self.sendResponse(resp);
            self.batch_index += 1;
            self.responded = false;
        }

        pub fn close(self: *Handler) void {
            if (self.subscription_id) |sid| {
                self.parent.allocator.free(sid);
            }
        }

        fn sendResponse(self: *Handler, resp: ResponseStorage) !void {
            switch (resp.tag) {
                .text => {
                    const rendered = try self.renderText(resp.data);
                    defer if (rendered.owned) self.parent.allocator.free(rendered.data);
                    try self.conn.writeText(rendered.data);
                },
                .binary => try self.conn.writeBin(resp.data),
            }
        }

        fn renderText(self: *Handler, template: []const u8) Allocator.Error!RenderedText {
            const sub = self.subscription_id orelse return RenderedText{ .data = template, .owned = false };
            const placeholder = "{SUB_ID}";
            if (std.mem.indexOf(u8, template, placeholder) == null) {
                return RenderedText{ .data = template, .owned = false };
            }

            var builder = std.array_list.Managed(u8).init(self.parent.allocator);
            errdefer builder.deinit();

            var text_start: usize = 0;
            while (std.mem.indexOf(u8, template[text_start..], placeholder)) |pos| {
                try builder.appendSlice(template[text_start .. text_start + pos]);
                try builder.appendSlice(sub);
                text_start += pos + placeholder.len;
            }
            try builder.appendSlice(template[text_start..]);

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

const BatchStorage = struct {
    messages: []ResponseStorage,

    fn init(allocator: Allocator, src: []const Response) !BatchStorage {
        var entries = try allocator.alloc(ResponseStorage, src.len);
        errdefer allocator.free(entries);
        for (src, 0..) |resp, idx| {
            entries[idx] = switch (resp) {
                .text => |payload| .{ .tag = .text, .data = try allocator.dupe(u8, payload) },
                .binary => |payload| .{ .tag = .binary, .data = try allocator.dupe(u8, payload) },
            };
        }
        return .{ .messages = entries };
    }

    fn deinit(self: *const BatchStorage, allocator: Allocator) void {
        for (self.messages) |resp| allocator.free(resp.data);
        allocator.free(self.messages);
    }
};

const RenderedText = struct {
    data: []const u8,
    owned: bool,
};

const ExtractError = error{InvalidRequest};

fn extractSubId(dest_allocator: Allocator, temp_allocator: Allocator, request: []const u8) (Allocator.Error || ExtractError)![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, request, .{}) catch {
        return ExtractError.InvalidRequest;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return ExtractError.InvalidRequest;
    const arr = root.array.items;
    if (arr.len < 2) return ExtractError.InvalidRequest;
    if (arr[1] != .string) return ExtractError.InvalidRequest;
    return try dest_allocator.dupe(u8, arr[1].string);
}
