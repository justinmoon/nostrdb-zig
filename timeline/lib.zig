const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const EventId = [32]u8;
pub const PubKey = [32]u8;

pub const TimelineEntry = struct {
    event_id: EventId,
    created_at: u64,
    author: PubKey,
};

pub const EventRecord = struct {
    allocator: Allocator,
    payload: []u8,
    created_at: u64,
    author: PubKey,

    pub fn deinit(self: *EventRecord) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const TimelineMeta = struct {
    latest_created_at: u64 = 0,
};

pub const Timeline = struct {
    entries: std.ArrayListUnmanaged(TimelineEntry) = .{},
    meta: TimelineMeta = .{},

    pub fn init() Timeline {
        return .{};
    }

    pub fn deinit(self: *Timeline, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }
};

pub const EventStore = struct {
    allocator: Allocator,
    events: std.AutoHashMap(EventId, EventRecord),

    pub fn init(allocator: Allocator) EventStore {
        return .{ .allocator = allocator, .events = std.AutoHashMap(EventId, EventRecord).init(allocator) };
    }

    pub fn deinit(self: *EventStore) void {
        var it = self.events.iterator();
        while (it.next()) |entry| {
            var record = entry.value_ptr.*;
            record.deinit();
        }
        self.events.deinit();
    }
};

pub const Store = struct {
    allocator: Allocator,
    timelines: std.AutoHashMap(PubKey, Timeline),
    events: EventStore,
    max_entries: usize = 2000,

    pub fn init(allocator: Allocator, max_entries: usize) Store {
        return .{
            .allocator = allocator,
            .timelines = std.AutoHashMap(PubKey, Timeline).init(allocator),
            .events = EventStore.init(allocator),
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.timelines.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.timelines.deinit();
        self.events.deinit();
    }

    pub fn getTimeline(self: *Store, npub: PubKey) ?*Timeline {
        return self.timelines.getPtr(npub);
    }

    pub fn ensureTimeline(self: *Store, npub: PubKey) !*Timeline {
        if (self.timelines.getPtr(npub)) |existing| return existing;
        const gop = try self.timelines.put(npub, Timeline.init());
        return gop.value_ptr;
    }
};

pub const InsertError = Allocator.Error;

pub fn insertEvent(
    store: *Store,
    npub: PubKey,
    entry: TimelineEntry,
    record_payload: []const u8,
) InsertError!void {
    var timeline = try store.ensureTimeline(npub);

    // Skip if event already known
    if (store.events.events.contains(entry.event_id)) {
        return;
    }

    // Persist event record
    var payload_copy = try store.allocator.dupe(u8, record_payload);
    errdefer store.allocator.free(payload_copy);

    var record = EventRecord{
        .allocator = store.allocator,
        .payload = payload_copy,
        .created_at = entry.created_at,
        .author = entry.author,
    };

    const gop = try store.events.events.getOrPut(entry.event_id);
    if (gop.found_existing) {
        record.deinit();
        return;
    }
    gop.value_ptr.* = record;

    const allocator = store.allocator;

    // Determine insert position (descending created_at, then event_id)
    const items = timeline.entries.items;
    var index: usize = 0;
    while (index < items.len) : (index += 1) {
        const existing = items[index];
        if (existing.created_at < entry.created_at) break;
        if (existing.created_at == entry.created_at) {
            if (std.mem.lessThan(u8, existing.event_id[0..], entry.event_id[0..])) break;
            if (std.mem.eql(u8, existing.event_id[0..], entry.event_id[0..])) {
                return;
            }
        }
    }

    try timeline.entries.insert(allocator, index, entry);

    // Trim excess entries
    while (timeline.entries.items.len > store.max_entries) {
        const removed = timeline.entries.pop();
        if (store.events.events.fetchRemove(removed.event_id)) |kv| {
            var rec = kv.value;
            rec.deinit();
        }
    }

    if (timeline.meta.latest_created_at < entry.created_at) {
        timeline.meta.latest_created_at = entry.created_at;
    }
}

pub fn latestCreatedAt(self: *Store, npub: PubKey) u64 {
    if (self.timelines.getPtr(npub)) |timeline| {
        return timeline.meta.latest_created_at;
    }
    return 0;
}

pub fn getEvent(self: *Store, id: EventId) ?*const EventRecord {
    return self.events.events.getPtr(id);
}
