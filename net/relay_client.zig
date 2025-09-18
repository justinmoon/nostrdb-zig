const std = @import("std");
const xev = @import("xev");
const websocket = @import("websocket");
const message = @import("message.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.relay_client);
const atomic = std.atomic;

pub const RelayClientState = enum {
    idle,
    connecting,
    connected,
    closed,
    failed,
};

pub const Options = struct {
    allocator: Allocator,
    url: []const u8,
    connect_timeout_ms: u32 = 5_000,
    read_timeout_ms: u32 = 0,
};

pub const ConnectError = error{
    UnsupportedScheme,
    InvalidUrl,
    MissingHost,
    InvalidPort,
    AlreadyConnected,
    ConnectionInProgress,
    OutOfMemory,
    HandshakeFailed,
    SocketError,
};

pub const SendError = error{
    NotConnected,
    OutOfMemory,
    WriteFailed,
};

pub const RelayClient = struct {
    allocator: Allocator,
    url_text: []u8,
    host: []u8,
    path: []u8,
    port: u16,
    use_tls: bool,
    options: Options,

    parser: message.Parser,

    state_internal: RelayClientState = .idle,

    ws_client: ?websocket.Client = null,
    reader_thread: ?std.Thread = null,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    queue_head: ?*MessageNode = null,
    queue_tail: ?*MessageNode = null,

    stop_requested: atomic.Value(bool) = atomic.Value(bool).init(false),

    // configuration
    read_timeout_ns: ?u64,

    const MessageNode = struct {
        next: ?*MessageNode = null,
        message: message.RelayMessage,
    };

    pub fn init(options: Options) !RelayClient {
        const allocator = options.allocator;
        const url_copy = try allocator.dupe(u8, options.url);
        errdefer allocator.free(url_copy);

        var parts = try parseUrl(allocator, url_copy);
        errdefer parts.deinit(allocator);

        return .{
            .allocator = allocator,
            .url_text = url_copy,
            .host = parts.host,
            .path = parts.path,
            .port = parts.port,
            .use_tls = parts.use_tls,
            .options = options,
            .parser = message.Parser.init(allocator),
            .read_timeout_ns = if (options.read_timeout_ms == 0)
                null
            else
                @as(u64, options.read_timeout_ms) * std.time.ns_per_ms,
        };
    }

    pub fn deinit(self: *RelayClient) void {
        self.close();
        self.joinReaderThread();
        self.drainQueue();
        if (self.ws_client) |*client| {
            client.deinit();
            self.ws_client = null;
        }
        self.parser.deinit();
        self.allocator.free(self.url_text);
        self.allocator.free(self.host);
        self.allocator.free(self.path);
    }

    pub fn state(self: *const RelayClient) RelayClientState {
        return self.state_internal;
    }

    pub fn connect(self: *RelayClient, loop: ?*xev.Loop) ConnectError!void {
        _ = loop; // reserved for future xev integration

        switch (self.state_internal) {
            .connected => return ConnectError.AlreadyConnected,
            .connecting => return ConnectError.ConnectionInProgress,
            else => {},
        }

        self.state_internal = .connecting;

        var client = websocket.Client.init(self.allocator, .{
            .port = self.port,
            .host = self.host,
            .tls = self.use_tls,
        }) catch |err| {
            self.state_internal = .failed;
            log.err("failed to init websocket client: {}", .{err});
            return ConnectError.SocketError;
        };
        errdefer {
            client.deinit();
            self.state_internal = .failed;
        }

        client.handshake(self.path, .{ .timeout_ms = self.options.connect_timeout_ms }) catch |err| {
            log.err("handshake failed: {}", .{err});
            return ConnectError.HandshakeFailed;
        };

        self.ws_client = client;
        self.state_internal = .connected;
        self.stop_requested.store(false, .monotonic);

        const reader = std.Thread.spawn(.{}, readLoopThread, .{self}) catch |err| {
            log.err("failed to spawn reader thread: {}", .{err});
            self.ws_client.?.deinit();
            self.ws_client = null;
            self.state_internal = .failed;
            return ConnectError.OutOfMemory;
        };
        self.reader_thread = reader;
    }

    pub fn sendText(self: *RelayClient, payload: []const u8) SendError!void {
        if (self.state_internal != .connected) return SendError.NotConnected;

        var buffer = try self.allocator.dupe(u8, payload);
        defer self.allocator.free(buffer);

        if (self.ws_client) |*client| {
            client.write(buffer) catch |err| {
                log.err("failed to send frame: {}", .{err});
                return SendError.WriteFailed;
            };
        } else {
            return SendError.NotConnected;
        }
    }

    pub fn close(self: *RelayClient) void {
        if (self.state_internal == .closed) return;

        self.stop_requested.store(true, .monotonic);

        if (self.ws_client) |*client| {
            client.close(.{}) catch |err| {
                log.warn("error closing websocket: {}", .{err});
            };
        }

        self.state_internal = .closed;
        self.cond.broadcast();
    }

    pub fn nextMessage(self: *RelayClient, timeout_ms: ?u64) !?message.RelayMessage {
        self.mutex.lock();
        defer self.mutex.unlock();

        var remaining_ns: ?u64 = if (timeout_ms) |ms|
            ms * std.time.ns_per_ms
        else
            self.read_timeout_ns;

        while (self.queue_head == null and self.state_internal == .connected) {
            if (remaining_ns) |*ns| {
                const before = std.time.nanoTimestamp();
                const wait_result = self.cond.timedWait(&self.mutex, ns.*);
                switch (wait_result) {
                    error.Timeout => return null,
                    else => {},
                }
                const after = std.time.nanoTimestamp();
                const elapsed = if (after > before)
                    @as(u64, @intCast(@min(@as(i128, after - before), @as(i128, std.math.maxInt(u64)))))
                else
                    0;
                if (elapsed >= ns.*) {
                    return null;
                }
                ns.* -= elapsed;
            } else {
                self.cond.wait(&self.mutex);
            }
        }

        if (self.queue_head) |node| {
            self.queue_head = node.next;
            if (self.queue_head == null) self.queue_tail = null;
            const msg = node.message;
            self.allocator.destroy(node);
            return msg;
        }

        return null;
    }

    fn enqueueMessage(self: *RelayClient, msg: message.RelayMessage) !void {
        var node = try self.allocator.create(MessageNode);
        node.* = .{ .message = msg, .next = null };

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue_tail) |tail| {
            tail.next = node;
        } else {
            self.queue_head = node;
        }
        self.queue_tail = node;
        self.cond.signal();
    }

    fn drainQueue(self: *RelayClient) void {
        var head_opt = self.queue_head;
        while (head_opt) |node| {
            head_opt = node.next;
            node.message.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.queue_head = null;
        self.queue_tail = null;
    }

    fn joinReaderThread(self: *RelayClient) void {
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
    }

    fn readLoopThread(self: *RelayClient) void {
        var handler = ConnectionHandler{ .parent = self };
        if (self.ws_client) |*client| {
            const read_result = client.readLoop(&handler);
            if (read_result) |err| {
                log.err("websocket read loop terminated: {}", .{err});
                self.state_internal = .failed;
            } else {
                self.state_internal = .closed;
            }
            client.deinit();
            self.ws_client = null;
        } else {
            self.state_internal = .failed;
        }
        self.stop_requested.store(true, .monotonic);
        self.cond.broadcast();
    }

    fn handleText(self: *RelayClient, data: []const u8) void {
        const parsed = self.parser.parseText(data) catch |err| {
            switch (err) {
                message.ParseError.InvalidJson, message.ParseError.InvalidStructure => log.warn("dropping malformed relay frame", .{}),
                message.ParseError.EmptyMessage => {},
                else => log.err("relay parser error: {}", .{err}),
            }
            return;
        };

        if (parsed == .notice) {
            log.warn("notice from relay: {s}", .{parsed.notice.text()});
        }

        if (self.enqueueMessage(parsed)) |_| {} else |enqueue_err| {
            log.err("failed to enqueue relay message: {}", .{enqueue_err});
            var msg = parsed;
            msg.deinit(self.allocator);
        }
    }

    fn handleBinary(self: *RelayClient, data: []const u8) void {
        log.debug("ignoring binary frame of {d} bytes", .{data.len});
    }

    fn handlePing(self: *RelayClient, payload: []const u8) void {
        if (self.ws_client) |*client| {
            var buffer = self.allocator.dupe(u8, payload) catch {
                log.warn("failed to reply to ping: out of memory", .{});
                return;
            };
            defer self.allocator.free(buffer);
            client.writePong(buffer) catch |err| {
                log.warn("failed to send pong: {}", .{err});
            };
        }
    }

    fn handleClose(self: *RelayClient) void {
        self.state_internal = .closed;
        self.stop_requested.store(true, .monotonic);
        self.cond.broadcast();
    }

    const ConnectionHandler = struct {
        parent: *RelayClient,

        pub fn serverMessage(self: *ConnectionHandler, data: []u8, tpe: websocket.MessageTextType) !void {
            switch (tpe) {
                .text => self.parent.handleText(data),
                .binary => self.parent.handleBinary(data),
            }
        }

        pub fn serverPing(self: *ConnectionHandler, data: []u8) !void {
            self.parent.handlePing(data);
        }

        pub fn serverClose(self: *ConnectionHandler) !void {
            self.parent.handleClose();
        }

        pub fn close(self: *ConnectionHandler) void {
            self.parent.handleClose();
        }
    };
};

const UrlParts = struct {
    host: []u8,
    path: []u8,
    port: u16,
    use_tls: bool,

    fn deinit(self: *UrlParts, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.path);
    }
};

fn parseUrl(allocator: Allocator, url: []const u8) (ConnectError || error{OutOfMemory})!UrlParts {
    const ws_prefix = "ws://";
    const wss_prefix = "wss://";

    var scheme: enum { ws, wss } = .ws;
    var remainder: []const u8 = undefined;
    if (std.mem.startsWith(u8, url, ws_prefix)) {
        remainder = url[ws_prefix.len..];
        scheme = .ws;
    } else if (std.mem.startsWith(u8, url, wss_prefix)) {
        remainder = url[wss_prefix.len..];
        scheme = .wss;
    } else {
        return ConnectError.UnsupportedScheme;
    }

    if (remainder.len == 0) return ConnectError.MissingHost;

    const slash_index = std.mem.indexOfScalar(u8, remainder, '/');
    const authority = if (slash_index) |idx|
        remainder[0..idx]
    else
        remainder;
    const path_slice = if (slash_index) |idx|
        remainder[idx..]
    else
        "/";

    if (authority.len == 0) return ConnectError.MissingHost;

    var host_slice = authority;
    var port: u16 = if (scheme == .wss) 443 else 80;

    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |idx| {
        if (idx == 0 or idx == authority.len - 1) return ConnectError.InvalidUrl;
        const port_str = authority[idx + 1 ..];
        port = std.fmt.parseInt(u16, port_str, 10) catch return ConnectError.InvalidPort;
        host_slice = authority[0..idx];
    }

    if (std.mem.indexOfScalar(u8, host_slice, '@') != null) {
        return ConnectError.InvalidUrl;
    }

    if (host_slice.len == 0) return ConnectError.MissingHost;

    const host_copy = try allocator.dupe(u8, host_slice);
    errdefer allocator.free(host_copy);
    const path_copy = try allocator.dupe(u8, path_slice);
    errdefer allocator.free(path_copy);

    return UrlParts{
        .host = host_copy,
        .path = path_copy,
        .port = port,
        .use_tls = scheme == .wss,
    };
}
