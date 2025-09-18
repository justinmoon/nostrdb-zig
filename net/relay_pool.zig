const std = @import("std");
const RelayClient = @import("relay_client.zig").RelayClient;

const Allocator = std.mem.Allocator;

pub const Config = struct {
    allocator: Allocator,
    max_retry_backoff_ms: u64 = 5_000,
};

pub const PoolError = error{
    OutOfMemory,
};

pub const RelayPool = struct {
    allocator: Allocator,
    config: Config,
    clients: std.array_list.Managed(*RelayClient),
    subscriptions: std.StringHashMap(*RelayClient),

    pub fn init(config: Config) RelayPool {
        return .{
            .allocator = config.allocator,
            .config = config,
            .clients = std.array_list.Managed(*RelayClient).init(config.allocator),
            .subscriptions = std.StringHashMap(*RelayClient).init(config.allocator),
        };
    }

    pub fn deinit(self: *RelayPool) void {
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscriptions.deinit();
        self.clients.deinit();
    }

    pub fn registerRelay(self: *RelayPool, client: *RelayClient) PoolError!void {
        try self.clients.append(client);
    }

    pub fn relayCount(self: *const RelayPool) usize {
        return self.clients.items.len;
    }

    pub fn broadcast(self: *RelayPool, payload: []const u8) void {
        for (self.clients.items) |client| {
            client.sendText(payload) catch {
                std.log.warn("failed to send payload to relay", .{});
            };
        }
    }

    pub fn trackSubscription(self: *RelayPool, sub_id: []const u8, client: *RelayClient) PoolError!void {
        if (self.subscriptions.fetchRemove(sub_id)) |existing| {
            self.allocator.free(existing.key);
        }

        const id_copy = try self.allocator.dupe(u8, sub_id);
        errdefer self.allocator.free(id_copy);
        try self.subscriptions.put(id_copy, client);
    }

    pub fn relayForSubscription(self: *RelayPool, sub_id: []const u8) ?*RelayClient {
        return self.subscriptions.get(sub_id);
    }
};
