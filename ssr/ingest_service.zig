const std = @import("std");
const contacts = @import("contacts");
const ingest = @import("ingest");
const timeline = @import("timeline");
const ndb = @import("ndb");

pub const Allocator = std.mem.Allocator;

pub const Phase = enum { initial, contacts, posts_backfill, live, finished, failed };

pub const RelayStatus = struct {
    url: []const u8,
    eose: bool,
    err: ?[]const u8,
};

pub const Status = struct {
    phase: Phase,
    events_ingested: u64,
    latest_created_at: u64,
    first_post_ms: ?u64,
    last_error: ?[]const u8,
    relays: []RelayStatus,
};

pub const IngestionManager = struct {
    allocator: Allocator,
    relays: []const []const u8,
    limit: u32,
    contacts_store: *contacts.Store,
    timeline_store: *timeline.Store,
    db: *ndb.Ndb,

    // concurrency control
    max_jobs: usize = 24,
    mutex: std.Thread.Mutex = .{},
    jobs: std.AutoHashMap(timeline.PubKey, *Job),
    running_count: usize = 0,
    queue: std.ArrayList(timeline.PubKey),

    pub fn init(
        allocator: Allocator,
        relays: []const []const u8,
        limit: u32,
        contacts_store: *contacts.Store,
        timeline_store: *timeline.Store,
        db: *ndb.Ndb,
    ) !IngestionManager {
        // copy relay URLs to owned memory
        var rel_copy = try allocator.alloc([]const u8, relays.len);
        errdefer allocator.free(rel_copy);
        for (relays, 0..) |url, i| {
            rel_copy[i] = try allocator.dupe(u8, url);
        }

        return .{
            .allocator = allocator,
            .relays = rel_copy,
            .limit = limit,
            .contacts_store = contacts_store,
            .timeline_store = timeline_store,
            .db = db,
            .jobs = std.AutoHashMap(timeline.PubKey, *Job).init(allocator),
            .queue = std.ArrayList(timeline.PubKey).empty,
        };
    }

    pub fn deinit(self: *IngestionManager) void {
        // join all threads and free jobs
        var it = self.jobs.iterator();
        while (it.next()) |entry| {
            const job = entry.value_ptr.*;
            job.join();
            job.deinit(self.allocator);
            self.allocator.destroy(job);
        }
        self.jobs.deinit();

        // free relays
        for (self.relays) |url| self.allocator.free(url);
        self.allocator.free(self.relays);

        self.queue.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensureJob(self: *IngestionManager, npub: timeline.PubKey) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.jobs.get(npub)) |_| {
            return; // already enqueued or running
        }

        var job = try self.allocator.create(Job);
        errdefer self.allocator.destroy(job);
        job.* = try Job.init(self.allocator, npub, self.relays);

        try self.jobs.put(npub, job);

        if (self.running_count < self.max_jobs) {
            self.running_count += 1;
            job.start(self) catch |err| {
                self.running_count -= 1;
                _ = self.jobs.remove(npub);
                job.deinit(self.allocator);
                self.allocator.destroy(job);
                return err;
            };
        } else {
            // queue for later
            try self.queue.append(self.allocator, npub);
        }
    }

    pub fn status(self: *IngestionManager, npub: timeline.PubKey, allocator: Allocator) !Status {
        // snapshot shared job state under lock
        var phase: Phase = .finished;
        var last_error: ?[]const u8 = null;
        var first_post_ms: ?u64 = null;
        var job_ptr: ?*Job = null;
        self.mutex.lock();
        if (self.jobs.get(npub)) |job| {
            phase = job.phase;
            if (job.last_error) |e| {
                // copy into request-scoped allocator to avoid races
                last_error = allocator.dupe(u8, e) catch null;
            }
            first_post_ms = job.first_post_ms;
            job_ptr = job;
        }
        self.mutex.unlock();

        // live read from timeline for progress
        const meta = timeline.getMeta(self.timeline_store, npub) catch timeline.TimelineMeta{};

        // opportunistically set first_post_ms when we first observe events
        if (first_post_ms == null and meta.count > 0) {
            self.mutex.lock();
            if (self.jobs.get(npub)) |job| {
                if (job.first_post_ms == null) {
                    const now_ms: u64 = @intCast(std.time.milliTimestamp());
                    job.first_post_ms = now_ms - job.start_ms;
                    first_post_ms = job.first_post_ms;
                } else {
                    first_post_ms = job.first_post_ms;
                }
            }
            self.mutex.unlock();
        }

        // render relay statuses snapshot
        var relay_stats = try allocator.alloc(RelayStatus, self.relays.len);
        var i: usize = 0;
        while (i < self.relays.len) : (i += 1) {
            relay_stats[i] = RelayStatus{
                .url = self.relays[i],
                .eose = if (job_ptr) |j| j.phase == .finished else true,
                .err = null,
            };
        }

        return Status{
            .phase = phase,
            .events_ingested = @intCast(meta.count),
            .latest_created_at = meta.latest_created_at,
            .first_post_ms = first_post_ms,
            .last_error = last_error,
            .relays = relay_stats,
        };
    }

    fn onJobFinished(self: *IngestionManager, finished_pub: timeline.PubKey) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // start next queued if capacity
        if (self.running_count > 0) self.running_count -= 1;

        if (self.queue.items.len > 0) {
            const next_pub = self.queue.orderedRemove(0);
            if (self.jobs.get(next_pub)) |job| {
                self.running_count += 1;
                job.start(self) catch {
                    // failed to start; drop job
                    _ = self.jobs.remove(next_pub);
                    job.deinit(self.allocator);
                    self.allocator.destroy(job);
                };
            }
        }

        // cleanup finished job entry (keep entry for status until caller stops polling?)
        // For now, leave job in map so /status still works; no immediate removal.
        _ = finished_pub; // not used currently for removal
    }
};

const Job = struct {
    npub: timeline.PubKey,
    phase: Phase = .initial,
    start_ms: u64 = 0,
    first_post_ms: ?u64 = null,
    last_error: ?[]const u8 = null,

    thread: ?std.Thread = null,

    // snapshot of configured relays (borrowed from manager)
    relays_view: []const []const u8,

    fn init(allocator: Allocator, npub: timeline.PubKey, relays: []const []const u8) !Job {
        _ = allocator;
        return .{
            .npub = npub,
            .phase = .initial,
            .start_ms = @intCast(std.time.milliTimestamp()),
            .first_post_ms = null,
            .last_error = null,
            .thread = null,
            .relays_view = relays,
        };
    }

    fn deinit(self: *Job, allocator: Allocator) void {
        if (self.last_error) |e| allocator.free(e);
        self.* = undefined;
    }

    fn start(self: *Job, manager: *IngestionManager) !void {
        const th = try std.Thread.spawn(.{}, jobMain, .{ self, manager });
        self.thread = th;
    }

    fn join(self: *Job) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

fn jobMain(job: *Job, manager: *IngestionManager) void {
    // contacts stage with simple retry/backoff
    manager.mutex.lock();
    job.phase = .contacts;
    manager.mutex.unlock();
    var backoff_ms: u64 = 200;
    const deadline_ms = job.start_ms + 3 * 60 * 1000; // 3 minutes

    var fetcher = contacts.Fetcher.init(manager.allocator, manager.contacts_store);
    defer fetcher.deinit();

    while (true) {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        if (now_ms >= deadline_ms) {
            manager.mutex.lock();
            job.phase = .failed;
            manager.mutex.unlock();
            storeError(job, manager.allocator, "contacts timeout");
            manager.onJobFinished(job.npub);
            return;
        }

        fetcher.fetchContacts(job.npub, manager.relays, manager.db) catch |err| {
            storeError(job, manager.allocator, @errorName(err));
            std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            backoff_ms = @min(backoff_ms * 2, 2_000);
            continue;
        };

        break;
    }

    // posts stage
    manager.mutex.lock();
    job.phase = .posts_backfill;
    manager.mutex.unlock();

    var pipeline = ingest.Pipeline.init(manager.allocator, job.npub, manager.limit, manager.contacts_store, manager.timeline_store, manager.db);

    backoff_ms = 200;
    while (true) {
        const now_ms: u64 = @intCast(std.time.milliTimestamp());
        if (now_ms >= deadline_ms) {
            manager.mutex.lock();
            job.phase = .failed;
            manager.mutex.unlock();
            storeError(job, manager.allocator, "posts timeout");
            manager.onJobFinished(job.npub);
            return;
        }

        if (pipeline.run(manager.relays)) {
            manager.mutex.lock();
            job.phase = .finished;
            manager.mutex.unlock();
            manager.onJobFinished(job.npub);
            return;
        } else |err| switch (err) {
            ingest.PipelineError.NoFollowSet => {
                manager.mutex.lock();
                job.phase = .finished;
                manager.mutex.unlock();
                manager.onJobFinished(job.npub);
                return;
            },
            else => {
                storeError(job, manager.allocator, @errorName(err));
                std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
                backoff_ms = @min(backoff_ms * 2, 2_000);
                continue;
            },
        }
    }
}

fn storeError(job: *Job, allocator: Allocator, msg: []const u8) void {
    if (job.last_error) |e| allocator.free(e);
    job.last_error = allocator.dupe(u8, msg) catch null;
}
