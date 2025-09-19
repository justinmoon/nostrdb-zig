const std = @import("std");
const proto = @import("proto");
const net = @import("net");
const contacts = @import("contacts");
const timeline = @import("timeline");
const ndb = @import("ndb");

const log = std.log.scoped(.ingest);
pub const diag = @import("ingdiag");

pub const Allocator = std.mem.Allocator;

pub const EventMeta = struct {
    id: timeline.EventId,
    author: timeline.PubKey,
    created_at: u64,
    kind: u64,
};

pub const PipelineError = Allocator.Error || net.RelayClientConnectError || net.RelayClientSendError || ndb.Error || proto.ReqBuilderError || proto.FilterError || contacts.StoreError || timeline.InsertError || timeline.StoreError || error{
    NoFollowSet,
    CompletionTimeout,
    EventParseFailed,
};

pub const Pipeline = struct {
    allocator: Allocator,
    npub: timeline.PubKey,
    limit: u32,
    contacts_store: *contacts.Store,
    timeline_store: *timeline.Store,
    db: *ndb.Ndb,

    pub fn init(
        allocator: Allocator,
        npub: timeline.PubKey,
        limit: u32,
        contacts_store: *contacts.Store,
        timeline_store: *timeline.Store,
        db: *ndb.Ndb,
    ) Pipeline {
        return .{
            .allocator = allocator,
            .npub = npub,
            .limit = limit,
            .contacts_store = contacts_store,
            .timeline_store = timeline_store,
            .db = db,
        };
    }

    pub fn run(self: *Pipeline, relays: []const []const u8) PipelineError!void {
        if (relays.len == 0) return;

        const follows = try self.captureFollows();
        defer self.allocator.free(follows);
        if (follows.len == 0) return error.NoFollowSet;

        var follow_lookup = try SelfFollowSet.init(self.allocator, follows);
        defer follow_lookup.deinit();

        const initial_since = self.initialSince();
        const filters = try self.buildFilters(follows, initial_since);
        defer self.freeFilters(filters);

        const clients = try self.allocator.alloc(ClientState, relays.len);
        var initialized: usize = 0;
        errdefer {
            var idx: usize = 0;
            while (idx < initialized) : (idx += 1) {
                clients[idx].deinit(self.allocator);
            }
            self.allocator.free(clients);
        }

        for (relays, 0..) |relay_url, idx| {
            clients[idx] = try ClientState.init(self.allocator, relay_url, filters);
            initialized += 1;
        }

        var active = initialized;
        var idle_loops: usize = 0;

        while (active > 0) {
            var progressed = false;
            for (clients[0..initialized]) |*entry| {
                if (entry.phase == .finished) continue;
                const msg_opt = entry.client.nextMessage(2_000) catch |err| switch (err) {
                    error.Timeout => null,
                };
                if (msg_opt) |msg| {
                    progressed = true;
                    try self.handleMessage(msg, &follow_lookup, entry);
                }
                if (entry.phase == .finished) {
                    active -= 1;
                }
            }

            if (!progressed) {
                idle_loops += 1;
                if (idle_loops >= 3) break;
            } else {
                idle_loops = 0;
            }
        }

        var idx: usize = 0;
        while (idx < initialized) : (idx += 1) {
            clients[idx].deinit(self.allocator);
        }
        self.allocator.free(clients);

        if (active != 0) return error.CompletionTimeout;
    }

    pub fn runEx(
        self: *Pipeline,
        relays: []const []const u8,
        diag_states: ?[]diag.RelayDiag,
        job_start_ms: u64,
        origin: ?[]const u8,
    ) PipelineError!bool {
        if (relays.len == 0) return false;

        const follows = try self.captureFollows();
        defer self.allocator.free(follows);
        if (follows.len == 0) return error.NoFollowSet;

        var follow_lookup = try SelfFollowSet.init(self.allocator, follows);
        defer follow_lookup.deinit();

        const initial_since = self.initialSince();
        const filters = try self.buildFilters(follows, initial_since);
        defer self.freeFilters(filters);

        var clients = std.array_list.Managed(ClientState).init(self.allocator);
        defer clients.deinit();

        var connected: usize = 0;
        for (relays, 0..) |relay_url, idx| {
            const now_ms: u64 = @intCast(std.time.milliTimestamp());
            if (diag_states) |ds| {
                ds[idx].attempts += 1;
                ds[idx].last_change_ms = if (job_start_ms == 0) 0 else now_ms - job_start_ms;
            }
            log.info("ingest: connecting to {s}", .{relay_url});
            var client = net.RelayClient.init(.{ .allocator = self.allocator, .url = relay_url, .origin = origin }) catch |err| {
                if (diag_states) |ds| ds[idx].last_error = self.allocator.dupe(u8, @errorName(err)) catch null;
                log.warn("ingest: init failed url={s} err={s}", .{ relay_url, @errorName(err) });
                continue;
            };
            errdefer client.deinit();

            client.connect(null) catch |err| {
                if (diag_states) |ds| ds[idx].last_error = self.allocator.dupe(u8, @errorName(err)) catch null;
                log.warn("ingest: connect failed url={s} err={s}", .{ relay_url, @errorName(err) });
                client.deinit();
                continue;
            };

            const sub_id = try proto.nextSubId(self.allocator);
            errdefer self.allocator.free(sub_id);
            const req = try buildRequest(self.allocator, sub_id, filters);
            defer self.allocator.free(req);
            client.sendText(req) catch |err| {
                if (diag_states) |ds| ds[idx].last_error = self.allocator.dupe(u8, @errorName(err)) catch null;
                log.warn("ingest: send REQ failed url={s} err={s}", .{ relay_url, @errorName(err) });
                client.close();
                client.deinit();
                continue;
            };
            log.info("ingest: REQ sent to {s}", .{relay_url});

            try clients.append(.{ .client = client, .sub_id = sub_id, .phase = .initial, .relay_index = idx });
            connected += 1;
        }

        if (connected == 0) return error.CompletionTimeout;

        var active = connected;
        var idle_loops: usize = 0;
        var finished_any = false;

        while (active > 0) {
            var progressed = false;
            var i: usize = 0;
            while (i < clients.items.len) : (i += 1) {
                var entry = &clients.items[i];
                if (entry.phase == .finished) continue;
                const msg_opt = entry.client.nextMessage(2_000) catch |err| switch (err) {
                    error.Timeout => null,
                };
                if (msg_opt) |msg| {
                    progressed = true;
                    try self.handleMessageEx(msg, &follow_lookup, entry, diag_states, job_start_ms, &finished_any);
                }
                if (entry.phase == .finished) {
                    active -= 1;
                }
            }

            if (finished_any) break;

            if (!progressed) {
                idle_loops += 1;
                if (idle_loops >= 3) break;
            } else {
                idle_loops = 0;
            }
        }

        // cleanup
        var j: usize = 0;
        while (j < clients.items.len) : (j += 1) {
            clients.items[j].deinit(self.allocator);
        }

        if (!finished_any) return error.CompletionTimeout;
        return true;
    }

    fn handleMessage(
        self: *Pipeline,
        msg: net.RelayMessage,
        follow_lookup: *SelfFollowSet,
        client: *ClientState,
    ) PipelineError!void {
        var owned = msg;
        defer owned.deinit(self.allocator);

        switch (owned) {
            .event => |event| {
                if (!std.mem.eql(u8, event.subId(), client.sub_id)) return;
                self.db.processEvent(event.raw()) catch |err| {
                    log.warn("Ndb.processEvent failed: {}", .{err});
                    return;
                };
                const meta = parseEventMeta(self.allocator, event.eventJson()) catch |err| {
                    log.warn("failed to parse event metadata: {}", .{err});
                    return;
                };
                if (meta.kind != 1) return;
                if (!follow_lookup.contains(meta.author)) return;
                const entry = timeline.TimelineEntry{
                    .event_id = meta.id,
                    .created_at = meta.created_at,
                    .author = meta.author,
                };
                timeline.insertEvent(self.timeline_store, self.npub, entry, event.eventJson()) catch |err| {
                    log.warn("timeline insert failed: {}", .{err});
                };
            },
            .eose => |eose| {
                if (!std.mem.eql(u8, eose.subId(), client.sub_id)) return;
                try self.onEose(client, follow_lookup);
            },
            .notice => |notice| {
                log.info("relay notice: {s}", .{notice.text()});
            },
            else => {},
        }
    }

    fn handleMessageEx(
        self: *Pipeline,
        msg: net.RelayMessage,
        follow_lookup: *SelfFollowSet,
        client: *ClientState,
        diag_states: ?[]diag.RelayDiag,
        job_start_ms: u64,
        finished_any: *bool,
    ) PipelineError!void {
        var owned = msg;
        defer owned.deinit(self.allocator);

        switch (owned) {
            .event => |event| {
                if (!std.mem.eql(u8, event.subId(), client.sub_id)) return;
                self.db.processEvent(event.raw()) catch |err| {
                    log.warn("ndb process event failed: {}", .{err});
                    return;
                };
                const meta = try parseEventMeta(self.allocator, event.eventJson());
                const entry = timeline.TimelineEntry{
                    .event_id = meta.id,
                    .author = meta.author,
                    .created_at = meta.created_at,
                };
                timeline.insertEvent(self.timeline_store, self.npub, entry, event.eventJson()) catch |err| {
                    log.warn("timeline insert failed: {}", .{err});
                };
            },
            .eose => |eose| {
                if (!std.mem.eql(u8, eose.subId(), client.sub_id)) return;
                const now_ms: u64 = @intCast(std.time.milliTimestamp());
                if (diag_states) |ds| {
                    if (client.relay_index < ds.len) {
                        ds[client.relay_index].eose = true;
                        ds[client.relay_index].last_change_ms = if (job_start_ms == 0) 0 else now_ms - job_start_ms;
                    }
                }
                try self.onEose(client, follow_lookup);
                if (client.phase == .finished) {
                    finished_any.* = true;
                }
            },
            .notice => |notice| {
                log.info("relay notice: {s}", .{notice.text()});
            },
            else => {},
        }
    }

    fn onEose(self: *Pipeline, client: *ClientState, follow_lookup: *SelfFollowSet) PipelineError!void {
        switch (client.phase) {
            .initial => {
                const since = try timeline.latestCreatedAt(self.timeline_store, self.npub);
                const filters = try self.buildFilters(follow_lookup.authors, since);
                defer self.freeFilters(filters);

                const close_frame = try proto.buildClose(self.allocator, client.sub_id);
                defer self.allocator.free(close_frame);
                client.client.sendText(close_frame) catch |err| {
                    log.warn("failed to send CLOSE frame: {}", .{err});
                };

                try client.resubscribe(self.allocator, filters);
                client.phase = .live;
            },
            .live => {
                client.phase = .finished;
            },
            .finished => {},
        }
    }

    fn captureFollows(self: *Pipeline) (Allocator.Error || contacts.StoreError)![]timeline.PubKey {
        var array = std.array_list.Managed(timeline.PubKey).init(self.allocator);
        errdefer array.deinit();

        if (try self.contacts_store.get(self.npub)) |list| {
            var owned = list;
            defer owned.deinit();
            for (owned.follows) |follow| {
                try array.append(follow);
            }
        }

        return try array.toOwnedSlice();
    }

    fn buildFilters(
        self: *Pipeline,
        authors: []const timeline.PubKey,
        since: ?u64,
    ) (Allocator.Error || proto.FilterError)![][:0]const u8 {
        return try proto.buildPostsFilters(self.allocator, .{
            .authors = authors,
            .limit = self.limit,
            .since = since,
        });
    }

    fn freeFilters(self: *Pipeline, filters: [][:0]const u8) void {
        for (filters) |item| {
            self.allocator.free(item);
        }
        self.allocator.free(filters);
    }

    fn initialSince(self: *Pipeline) ?u64 {
        const meta = timeline.getMeta(self.timeline_store, self.npub) catch |err| {
            log.warn("failed to load timeline meta: {}", .{err});
            return null;
        };
        if (meta.count >= @as(usize, self.limit)) {
            return meta.latest_created_at;
        }
        return null;
    }
};

const ClientPhase = enum { initial, live, finished };

const ClientState = struct {
    client: net.RelayClient,
    sub_id: []u8,
    phase: ClientPhase = .initial,
    relay_index: usize = 0,

    fn init(
        allocator: Allocator,
        relay_url: []const u8,
        filters: [][:0]const u8,
    ) !ClientState {
        var client = try net.RelayClient.init(.{ .allocator = allocator, .url = relay_url });
        errdefer client.deinit();

        try client.connect(null);

        const sub_id = try proto.nextSubId(allocator);
        errdefer allocator.free(sub_id);

        const req = try buildRequest(allocator, sub_id, filters);
        log.info("ingest REQ to {s}: {s}", .{ relay_url, req });
        defer allocator.free(req);

        try client.sendText(req);

        return .{ .client = client, .sub_id = sub_id, .phase = .initial, .relay_index = 0 };
    }

    fn resubscribe(
        self: *ClientState,
        allocator: Allocator,
        filters: [][:0]const u8,
    ) !void {
        const req = try buildRequest(allocator, self.sub_id, filters);
        log.info("ingest RESUB to {s}: {s}", .{ self.client.host, req });
        defer allocator.free(req);
        try self.client.sendText(req);
    }

    fn deinit(self: *ClientState, allocator: Allocator) void {
        self.client.deinit();
        allocator.free(self.sub_id);
    }
};

const SelfFollowSet = struct {
    allocator: Allocator,
    authors: []timeline.PubKey,
    map: std.AutoHashMap(timeline.PubKey, void),

    fn init(allocator: Allocator, authors: []const timeline.PubKey) !SelfFollowSet {
        var holder = try allocator.alloc(timeline.PubKey, authors.len);
        var map = std.AutoHashMap(timeline.PubKey, void).init(allocator);
        errdefer allocator.free(holder);
        errdefer map.deinit();

        for (authors, 0..) |author, idx| {
            holder[idx] = author;
            try map.put(author, {});
        }

        return .{
            .allocator = allocator,
            .authors = holder,
            .map = map,
        };
    }

    fn contains(self: *SelfFollowSet, key: timeline.PubKey) bool {
        return self.map.contains(key);
    }

    fn deinit(self: *SelfFollowSet) void {
        self.map.deinit();
        self.allocator.free(self.authors);
    }
};

fn parseEventMeta(allocator: Allocator, json: []const u8) (Allocator.Error || error{EventParseFailed})!EventMeta {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EventParseFailed,
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.EventParseFailed;
    const object = root.object;

    const id_field = object.get("id") orelse return error.EventParseFailed;
    const author_field = object.get("pubkey") orelse return error.EventParseFailed;
    const created_field = object.get("created_at") orelse return error.EventParseFailed;
    const kind_field = object.get("kind") orelse return error.EventParseFailed;

    if (id_field != .string or author_field != .string) return error.EventParseFailed;
    const id = try hexToKey(id_field.string);
    const author = try hexToKey(author_field.string);

    const created_at = switch (created_field) {
        .integer => |x| std.math.cast(u64, x) orelse return error.EventParseFailed,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch return error.EventParseFailed,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch return error.EventParseFailed,
        else => return error.EventParseFailed,
    };

    const kind = switch (kind_field) {
        .integer => |x| std.math.cast(u64, x) orelse return error.EventParseFailed,
        .string => |s| std.fmt.parseInt(u64, s, 10) catch return error.EventParseFailed,
        .number_string => |s| std.fmt.parseInt(u64, s, 10) catch return error.EventParseFailed,
        else => return error.EventParseFailed,
    };

    return EventMeta{ .id = id, .author = author, .created_at = created_at, .kind = kind };
}

fn hexToKey(hex: []const u8) error{EventParseFailed}!timeline.EventId {
    if (hex.len != 64) return error.EventParseFailed;
    var out: timeline.EventId = undefined;
    const decoded = std.fmt.hexToBytes(out[0..], hex) catch return error.EventParseFailed;
    if (decoded.len != 32) return error.EventParseFailed;
    return out;
}

fn buildRequest(
    allocator: Allocator,
    sub_id: []const u8,
    filters: [][:0]const u8,
) (Allocator.Error || proto.ReqBuilderError)![]u8 {
    var refs = try allocator.alloc([]const u8, filters.len);
    defer allocator.free(refs);
    for (filters, 0..) |filter, idx| {
        refs[idx] = std.mem.sliceTo(filter, 0);
    }
    return proto.buildReq(allocator, sub_id, refs);
}
