const std = @import("std");
const ndb = @import("ndb");
const proto = @import("proto");
const contacts = @import("contacts");
const timeline = @import("timeline");
const ingest = @import("ingest");
const net = @import("net");
const ingest_service = @import("ingest_service.zig");

const CliError = error{
    MissingValue,
    UnknownArgument,
    InvalidPort,
    InvalidLimit,
    LimitOutOfRange,
    HelpRequested,
    OutOfMemory,
};

const Settings = struct {
    db_path: []const u8,
    port: u16,
    limit: u32,
    relays: []const []const u8,
    ws_origin: []const u8,
};

const App = struct {
    allocator: std.mem.Allocator,
    db: *ndb.Ndb,
    contacts_store: *contacts.Store,
    timeline_store: *timeline.Store,
    ingestion: *ingest_service.IngestionManager,
    limit: u32,

    fn handleConnection(self: *App, conn: *std.net.Server.Connection) !void {
        defer conn.stream.close();

        var read_buf: [16 * 1024]u8 = undefined;
        var write_buf: [16 * 1024]u8 = undefined;
        var reader = std.net.Stream.reader(conn.stream, &read_buf);
        var writer = std.net.Stream.writer(conn.stream, &write_buf);

        var server = std.http.Server.init(reader.interface(), &writer.interface);
        var req = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            error.HttpHeadersInvalid => return,
            else => return err,
        };

        self.route(&req) catch |err| {
            std.log.err("request failed: {s}", .{@errorName(err)});
            const body = "<!DOCTYPE html><html><body><h1>500 Internal Server Error</h1><p>Something went wrong.</p></body></html>";
            _ = req.respond(body, .{
                .status = .internal_server_error,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            }) catch {};
        };
    }

    fn route(self: *App, req: *std.http.Server.Request) !void {
        if (req.head.method != .GET) {
            const body = "<!DOCTYPE html><html><body><h1>405 Method Not Allowed</h1><p>Only GET is supported.</p></body></html>";
            try req.respond(body, .{
                .status = .method_not_allowed,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
            });
            return;
        }

        const target = req.head.target;
        const parts = splitTarget(target);

        const path = if (parts.path.len == 0) "/" else parts.path;
        if (std.mem.eql(u8, path, "/")) {
            try self.respondHome(req, null, null);
            return;
        }

        if (std.mem.eql(u8, path, "/timeline")) {
            try self.respondTimeline(req, parts.query);
            return;
        }

        if (std.mem.eql(u8, path, "/start")) {
            try self.respondStart(req, parts.query);
            return;
        }

        if (std.mem.eql(u8, path, "/status")) {
            try self.respondStatus(req, parts.query);
            return;
        }

        try self.respondHome(req, null, "Unknown path — use the form below.");
    }

    fn respondHome(self: *App, req: *std.http.Server.Request, npub_value: ?[]const u8, message: ?[]const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const body = try renderHome(arena.allocator(), npub_value, message);
        try req.respond(body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }

    fn respondTimeline(self: *App, req: *std.http.Server.Request, query: []const u8) !void {
        const npub = findQueryValue(query, "npub") orelse {
            try self.respondHome(req, null, "Provide an npub to render a timeline.");
            return;
        };
        if (npub.len == 0) {
            try self.respondHome(req, npub, "npub cannot be empty.");
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const pubkey = proto.decodeNpub(npub) catch {
            try self.respondHome(req, npub, "Could not decode that npub.");
            return;
        };

        // Auto-start ingestion if we have nothing stored yet for this npub
        const meta = timeline.getMeta(self.timeline_store, pubkey) catch timeline.TimelineMeta{};
        if (meta.count == 0) {
            std.log.info("auto-starting ingestion for npub (empty timeline)", .{});
            self.ingestion.ensureJob(pubkey) catch |err| {
                std.log.warn("failed to ensure ingestion job: {s}", .{@errorName(err)});
            };
        }

        const mode = findQueryValue(query, "mode");
        if (mode) |m| {
            if (std.ascii.eqlIgnoreCase(m, "author")) {
                try self.respondAuthorTimeline(req, alloc, npub, pubkey);
                return;
            }
        }

        // Default: timeline feed from LMDB timeline store
        try self.respondFeedTimeline(req, alloc, npub, pubkey);
    }

    fn respondAuthorTimeline(self: *App, req: *std.http.Server.Request, alloc: std.mem.Allocator, npub_str: []const u8, pubkey: [32]u8) !void {
        var txn = try ndb.Transaction.begin(self.db);
        defer txn.end();

        var filter = try ndb.Filter.init();
        defer filter.deinit();

        var builder = ndb.FilterBuilder.init(&filter);
        _ = try builder.kinds(&.{1});
        _ = try builder.authors(&.{pubkey});
        _ = try builder.limit(self.limit);
        try builder.build();

        const cap = @as(usize, @intCast(self.limit));
        var results = try alloc.alloc(ndb.QueryResult, cap);
        defer alloc.free(results);

        var filters = [_]ndb.Filter{filter};
        const count = try ndb.queryWithAllocator(&txn, filters[0..], results, alloc);
        std.mem.sort(ndb.QueryResult, results[0..count], {}, orderByCreatedDesc);

        const body = try renderTimelinePageAuthor(alloc, npub_str, pubkey, results[0..count]);
        try req.respond(body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }

    fn respondFeedTimeline(self: *App, req: *std.http.Server.Request, alloc: std.mem.Allocator, npub_str: []const u8, pubkey: [32]u8) !void {
        var snapshot = try timeline.loadTimeline(self.timeline_store, pubkey);
        defer snapshot.deinit();

        const total = snapshot.entries.len;
        const display: usize = @min(@as(usize, @intCast(self.limit)), total);

        var list = std.ArrayList(u8).empty;
        errdefer list.deinit(alloc);
        var w = list.writer(alloc);

        try writePageHead(&w, "nostr timeline");
        try w.writeAll("<main>\n");
        try writeLookupForm(&w, npub_str);
        try writeModeToggle(&w, npub_str, true);

        var pubkey_buf: [64]u8 = undefined;
        const pubkey_hex = try hexEncodeLower(&pubkey_buf, pubkey[0..]);
        try w.print(
            "<section class=\"timeline\">\n<h2>Feed for <code>{s}</code></h2>\n<p class=\"meta\">pubkey hex: <code>{s}</code> &mdash; {d} stored, showing up to {d}</p>\n",
            .{ npub_str, pubkey_hex, total, display },
        );

        try writeStatusBanner(&w, npub_str);

        if (display == 0) {
            try w.writeAll("<p class=\"empty\">No posts yet — ingestion may be in progress. <a href=\"#\" id=\"start-link\">Start ingestion</a>.</p>\n");
        } else {
            var i: usize = 0;
            while (i < display) : (i += 1) {
                const entry = snapshot.entries[i];
                if (try timeline.getEvent(self.timeline_store, entry.event_id)) |record_val| {
                    var record = record_val;
                    defer record.deinit();
                    const content = extractContent(alloc, record.payload) orelse record.payload;
                    try writeEvent(&w, entry.created_at, entry.event_id, content);
                }
            }
        }

        try w.writeAll("</section>\n");
        try writeSampleDataHelp(&w);
        try w.writeAll("</main>\n</body></html>");

        const body = try list.toOwnedSlice(alloc);

        try req.respond(body, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        });
    }

    fn respondStart(self: *App, req: *std.http.Server.Request, query: []const u8) !void {
        const npub = findQueryValue(query, "npub") orelse {
            try self.respondHome(req, null, "Provide an npub to start ingestion.");
            return;
        };
        const pubkey = proto.decodeNpub(npub) catch {
            try self.respondHome(req, npub, "Could not decode that npub.");
            return;
        };
        // Start job
        self.ingestion.ensureJob(pubkey) catch {};
        // Redirect to /timeline
        const location = try std.fmt.allocPrint(self.allocator, "/timeline?npub={s}", .{npub});
        defer self.allocator.free(location);
        _ = try req.respond("", .{
            .status = .found,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "location", .value = location },
                .{ .name = "content-type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    fn respondStatus(self: *App, req: *std.http.Server.Request, query: []const u8) !void {
        const npub = findQueryValue(query, "npub") orelse {
            const msg = "{\"error\":\"missing npub\"}";
            _ = try req.respond(msg, .{
                .status = .bad_request,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        };
        const pubkey = proto.decodeNpub(npub) catch {
            const msg = "{\"error\":\"invalid npub\"}";
            _ = try req.respond(msg, .{
                .status = .bad_request,
                .keep_alive = false,
                .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
            });
            return;
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const st = try self.ingestion.status(pubkey, alloc);
        const json = try renderStatusJson(alloc, st);
        defer alloc.free(json);
        _ = try req.respond(json, .{
            .status = .ok,
            .keep_alive = false,
            .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        });
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const settings = parseSettings(arena.allocator()) catch |err| switch (err) {
        CliError.HelpRequested => return,
        CliError.MissingValue => {
            std.log.err("missing value for flag", .{});
            return err;
        },
        CliError.UnknownArgument => {
            std.log.err("unknown argument", .{});
            return err;
        },
        CliError.InvalidPort => {
            std.log.err("invalid port", .{});
            return err;
        },
        CliError.InvalidLimit => {
            std.log.err("invalid limit", .{});
            return err;
        },
        CliError.LimitOutOfRange => {
            std.log.err("limit must be between 1 and 1024", .{});
            return err;
        },
        CliError.OutOfMemory => {
            std.log.err("out of memory while parsing arguments", .{});
            return err;
        },
    };

    try std.fs.cwd().makePath(settings.db_path);

    var cfg = ndb.Config.initDefault();
    var db = try ndb.Ndb.init(allocator, settings.db_path, &cfg);
    defer db.deinit();

    // Open LMDB contacts and timeline stores under db_path
    const contacts_dir = try std.fs.path.join(allocator, &.{ settings.db_path, "contacts" });
    defer allocator.free(contacts_dir);
    try std.fs.cwd().makePath(contacts_dir);
    var contacts_store = try contacts.Store.init(allocator, .{ .path = contacts_dir });
    defer contacts_store.deinit();

    const timeline_dir = try std.fs.path.join(allocator, &.{ settings.db_path, "timeline" });
    defer allocator.free(timeline_dir);
    try std.fs.cwd().makePath(timeline_dir);
    var timeline_store = try timeline.Store.init(allocator, .{ .path = timeline_dir, .max_entries = @intCast(settings.limit) });
    defer timeline_store.deinit();

    // Initialize ingestion manager
    var ingestion_manager = try ingest_service.IngestionManager.init(allocator, settings.relays, settings.limit, &contacts_store, &timeline_store, &db, settings.ws_origin);
    defer ingestion_manager.deinit();

    const address = try std.net.Address.parseIp("0.0.0.0", settings.port);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.log.info(
        "nostrdb SSR demo listening on http://0.0.0.0:{d} (db: {s}, limit: {d})",
        .{ settings.port, settings.db_path, settings.limit },
    );

    var app = App{
        .allocator = allocator,
        .db = &db,
        .contacts_store = &contacts_store,
        .timeline_store = &timeline_store,
        .ingestion = &ingestion_manager,
        .limit = settings.limit,
    };

    while (true) {
        var conn = server.accept() catch |err| {
            std.log.warn("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        app.handleConnection(&conn) catch |err| {
            std.log.warn("connection handling failed: {s}", .{@errorName(err)});
        };
    }
}

fn parseSettings(allocator: std.mem.Allocator) CliError!Settings {
    var iter = try std.process.argsWithAllocator(allocator);
    defer iter.deinit();

    _ = iter.next(); // skip program name

    var db_path = allocator.dupe(u8, "demo-db") catch return CliError.OutOfMemory;
    var port: u16 = 8080;
    var limit: u32 = 100;
    var relays_list = std.ArrayList([]const u8).empty;
    var ws_origin: []const u8 = allocator.dupe(u8, "https://nostrdb-ssr.local") catch return CliError.OutOfMemory;

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--db-path")) {
            const value = iter.next() orelse return CliError.MissingValue;
            db_path = allocator.dupe(u8, value) catch return CliError.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, arg, "--port")) {
            const value = iter.next() orelse return CliError.MissingValue;
            port = std.fmt.parseUnsigned(u16, value, 10) catch return CliError.InvalidPort;
            continue;
        }

        if (std.mem.eql(u8, arg, "--limit")) {
            const value = iter.next() orelse return CliError.MissingValue;
            limit = std.fmt.parseUnsigned(u32, value, 10) catch return CliError.InvalidLimit;
            if (limit == 0 or limit > 1024) return CliError.LimitOutOfRange;
            continue;
        }

        if (std.mem.eql(u8, arg, "--relays")) {
            const value = iter.next() orelse return CliError.MissingValue;
            // parse comma-separated relays
            var it = std.mem.splitScalar(u8, value, ',');
            while (it.next()) |item| {
                const trimmed = std.mem.trim(u8, item, " ");
                if (trimmed.len == 0) continue;
                // simple validation: expect ws:// or wss:// and at least one dot
                if (std.mem.indexOf(u8, trimmed, "ws://") == null and std.mem.indexOf(u8, trimmed, "wss://") == null) continue;
                if (std.mem.indexOfScalar(u8, trimmed, '.') == null) continue;
                const owned = allocator.dupe(u8, trimmed) catch return CliError.OutOfMemory;
                try relays_list.append(allocator, owned);
            }
            continue;
        }

        if (std.mem.eql(u8, arg, "--ws-origin")) {
            const value = iter.next() orelse return CliError.MissingValue;
            ws_origin = allocator.dupe(u8, value) catch return CliError.OutOfMemory;
            continue;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp() catch |io_err| {
                std.log.err("failed to print help: {s}", .{@errorName(io_err)});
            };
            return CliError.HelpRequested;
        }

        return CliError.UnknownArgument;
    }

    var relays = try relays_list.toOwnedSlice(allocator);
    if (relays.len == 0) {
        // allocate defaults into the same allocator-backed slice type
        relays = try allocator.alloc([]const u8, 8);
        relays[0] = try allocator.dupe(u8, "wss://relay.damus.io");
        relays[1] = try allocator.dupe(u8, "wss://nostr.wine");
        relays[2] = try allocator.dupe(u8, "wss://nos.lol");
        relays[3] = try allocator.dupe(u8, "wss://relayable.org");
        relays[4] = try allocator.dupe(u8, "wss://eden.nostr.land");
        relays[5] = try allocator.dupe(u8, "wss://offchain.pub");
        relays[6] = try allocator.dupe(u8, "wss://relay.snort.social");
        relays[7] = try allocator.dupe(u8, "wss://nostr-pub.wellorder.net");
    }
    return .{
        .db_path = db_path,
        .port = port,
        .limit = limit,
        .relays = relays,
        .ws_origin = ws_origin,
    };
}

fn printHelp() !void {
    const message =
        "nostrdb SSR demo\n\n" ++
        "Options:\n" ++
        "  --db-path <dir>   LMDB directory to open or create (default: demo-db)\n" ++
        "  --port <port>     HTTP port to bind (default: 8080)\n" ++
        "  --limit <n>       Max posts to show per request (default: 100, max 1024)\n" ++
        "  --relays <list>   Comma-separated relay URLs (for ingestion manager)\n" ++
        "  --ws-origin <url> Origin header to use for WS handshakes (default: https://nostrdb-ssr.local)\n" ++
        "  --help            Show this message\n\n" ++
        "Example (using sample events):\n" ++
        "  make testdata/many-events.json\n" ++
        "  ndb -d demo-db --skip-verification import testdata/many-events.json\n" ++
        "  zig build ssr-demo\n" ++
        "  ./zig-out/bin/ssr-demo --db-path demo-db\n";
    try std.fs.File.stdout().writeAll(message);
}

const SplitTarget = struct {
    path: []const u8,
    query: []const u8,
};

fn splitTarget(target: []const u8) SplitTarget {
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
        return .{ .path = target[0..idx], .query = target[idx + 1 ..] };
    }
    return .{ .path = target, .query = &.{} };
}

fn findQueryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const k = entry[0..eq];
        if (!std.mem.eql(u8, k, key)) continue;
        return entry[eq + 1 ..];
    }
    return null;
}

fn orderByCreatedDesc(_: void, lhs: ndb.QueryResult, rhs: ndb.QueryResult) bool {
    const a = lhs.note.createdAt();
    const b = rhs.note.createdAt();
    if (a == b) return lhs.note_id > rhs.note_id;
    return a > b;
}

fn renderHome(allocator: std.mem.Allocator, npub_value: ?[]const u8, message: ?[]const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var w = list.writer(allocator);

    try writePageHead(&w, "nostrdb SSR demo");
    try w.writeAll("<main>\n");
    if (message) |msg| try writeMessage(&w, msg);
    try writeHero(&w);
    try writeLookupForm(&w, npub_value);
    try writeSampleDataHelp(&w);
    try w.writeAll("</main>\n</body></html>");

    return try list.toOwnedSlice(allocator);
}

fn renderTimelinePageAuthor(
    allocator: std.mem.Allocator,
    npub_value: []const u8,
    pubkey: [32]u8,
    notes: []ndb.QueryResult,
) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var w = list.writer(allocator);

    try writePageHead(&w, "nostr timeline");
    try w.writeAll("<main>\n");
    try writeLookupForm(&w, npub_value);
    try writeModeToggle(&w, npub_value, false);

    var pubkey_buf: [64]u8 = undefined;
    const pubkey_hex = try hexEncodeLower(&pubkey_buf, pubkey[0..]);
    try w.print(
        "<section class=\"timeline\">\n<h2>Timeline for <code>{s}</code></h2>\n<p class=\"meta\">pubkey hex: <code>{s}</code> &mdash; showing up to {d} text notes</p>\n",
        .{ npub_value, pubkey_hex, notes.len },
    );

    if (notes.len == 0) {
        try w.writeAll("<p class=\"empty\">No posts found in the local database.</p>\n");
    } else {
        for (notes) |result| {
            try writeNote(&w, result.note);
        }
    }

    try w.writeAll("</section>\n");
    try writeSampleDataHelp(&w);
    try w.writeAll("</main>\n</body></html>");

    return try list.toOwnedSlice(allocator);
}

// feed rendering happens in respondFeedTimeline to access the store

fn writePageHead(writer: anytype, title: []const u8) !void {
    try writer.writeAll(
        "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\"/>\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"/>\n<title>",
    );
    try htmlEscape(writer, title);
    try writer.writeAll("</title>\n<style>\nbody{font-family:system-ui, sans-serif;margin:0;padding:24px;background:#0f172a;color:#e2e8f0;}\nmain{max-width:760px;margin:0 auto;}\nheader{margin-bottom:24px;}\nform.lookup{display:flex;flex-wrap:wrap;gap:12px;margin:24px 0;padding:16px;background:#1e293b;border-radius:8px;}\nform.lookup input{flex:1;min-width:220px;padding:8px 12px;font-size:16px;border-radius:6px;border:1px solid #334155;background:#0f172a;color:#e2e8f0;}\nform.lookup button{padding:10px 18px;font-size:16px;border:none;border-radius:6px;background:#38bdf8;color:#0f172a;font-weight:600;cursor:pointer;}\n.hero{background:#1e293b;padding:24px;border-radius:12px;}\n.hero h1{margin:0 0 12px;font-size:28px;}\n.hero p{margin:6px 0;}\n.timeline{margin-top:32px;padding:20px;background:#1e293b;border-radius:12px;}\n.timeline h2{margin-top:0;}\n.timeline .note{margin:0 0 20px;padding:16px;border-radius:10px;background:#0f172a;border:1px solid #334155;}\n.timeline .note time{display:block;font-size:14px;color:#94a3b8;margin-bottom:6px;}\n.timeline .note pre{white-space:pre-wrap;word-break:break-word;font-family:inherit;}\n.sample{margin-top:32px;padding:20px;background:#1e293b;border-radius:12px;}\n.flash{margin:0 0 16px;padding:14px;border-radius:8px;background:#f97316;color:#0f172a;font-weight:600;}\n.empty{padding:12px;border-radius:8px;background:#0f172a;border:1px dashed #334155;}\ncode{background:#0f172a;padding:2px 6px;border-radius:4px;border:1px solid #334155;}\na{color:#38bdf8;}\n.badge{display:inline-block;padding:2px 8px;border-radius:999px;background:#0ea5e9;color:#00111a;font-weight:700;font-size:12px;margin-left:8px;}\n.status{display:flex;align-items:center;gap:10px;margin:10px 0 18px;padding:10px 12px;background:#0f172a;border:1px solid #334155;border-radius:8px;}\n.spinner{width:12px;height:12px;border:2px solid #334155;border-top-color:#38bdf8;border-radius:50%;animation:spin 1s linear infinite;}\n@keyframes spin{to{transform:rotate(360deg)}}\n</style>\n</head>\n<body>\n");
}

fn writeHero(writer: anytype) !void {
    try writer.writeAll(
        "<section class=\"hero\">\n<h1>nostrdb SSR demo</h1>\n<p>This server reads events already stored in nostrdb's LMDB files and renders timelines directly from Zig.</p>\n<p>Point it at a database populated with sample events or your own relay captures to experiment without needing live relay connectivity.</p>\n</section>\n",
    );
}

fn writeLookupForm(writer: anytype, npub_value: ?[]const u8) !void {
    try writer.writeAll("<form class=\"lookup\" method=\"GET\" action=\"/timeline\">\n<label for=\"npub\">npub</label>\n");
    try writer.writeAll("<input id=\"npub\" name=\"npub\" type=\"text\" placeholder=\"npub1...\" value=\"");
    if (npub_value) |value| try htmlEscape(writer, value);
    try writer.writeAll("\"/>\n<button type=\"submit\">Show timeline</button>\n</form>\n");
}

fn writeModeToggle(writer: anytype, npub_value: []const u8, feed_mode: bool) !void {
    try writer.writeAll("<p class=\"meta\">");
    if (feed_mode) {
        try writer.writeAll("Mode: feed <span class=\"badge\">follows</span> — ");
        try writer.writeAll("<a href=\"/timeline?mode=author&npub=");
        try htmlEscape(writer, npub_value);
        try writer.writeAll("\">author debug</a>");
    } else {
        try writer.writeAll("Mode: <span class=\"badge\">author</span> — ");
        try writer.writeAll("<a href=\"/timeline?npub=");
        try htmlEscape(writer, npub_value);
        try writer.writeAll("\">feed of follows</a>");
    }
    try writer.writeAll("</p>\n");
}

fn writeSampleDataHelp(writer: anytype) !void {
    try writer.writeAll(
        "<section class=\"sample\">\n<h2>Try it quickly</h2>\n<p>Use nostrdb's bundled events to seed a demo database:</p>\n<pre><code>make testdata/many-events.json\nndb -d demo-db --skip-verification import testdata/many-events.json</code></pre>\n<p>Then start the server with <code>zig build ssr-demo</code> and run <code>./zig-out/bin/ssr-demo --db-path demo-db</code>.</p>\n</section>\n",
    );
}

fn writeMessage(writer: anytype, msg: []const u8) !void {
    try writer.writeAll("<div class=\"flash\">");
    try htmlEscape(writer, msg);
    try writer.writeAll("</div>\n");
}

const HexEncodeError = error{BufferTooSmall};

fn hexEncodeLower(out: []u8, bytes: []const u8) HexEncodeError![]const u8 {
    if (out.len < bytes.len * 2) return HexEncodeError.BufferTooSmall;
    const table = "0123456789abcdef";
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        const value = bytes[i];
        const hi: usize = @intCast(value >> 4);
        const lo: usize = @intCast(value & 0x0F);
        out[i * 2] = table[hi];
        out[i * 2 + 1] = table[lo];
    }
    return out[0 .. bytes.len * 2];
}

fn writeNote(writer: anytype, note: ndb.Note) !void {
    const id = note.id();
    const created = note.createdAt();
    const content = note.content();

    try writer.writeAll("<article class=\"note\">\n<time>");
    try formatTimestamp(writer, created);
    try writer.writeAll("</time>\n<p><code>");
    var id_buf: [64]u8 = undefined;
    const id_hex = try hexEncodeLower(&id_buf, id[0..]);
    try writer.print("{s}", .{id_hex});
    try writer.writeAll("</code></p>\n<pre>");
    try htmlEscapeMultiline(writer, content);
    try writer.writeAll("</pre>\n</article>\n");
}

fn writeEvent(writer: anytype, created_at: u64, event_id: [32]u8, content: []const u8) !void {
    try writer.writeAll("<article class=\"note\">\n<time>");
    try formatTimestamp(writer, @as(u32, @intCast(created_at)));
    try writer.writeAll("</time>\n<p><code>");
    var id_buf: [64]u8 = undefined;
    const id_hex = try hexEncodeLower(&id_buf, event_id[0..]);
    try writer.print("{s}", .{id_hex});
    try writer.writeAll("</code></p>\n<pre>");
    try htmlEscapeMultiline(writer, content);
    try writer.writeAll("</pre>\n</article>\n");
}

fn htmlEscape(writer: anytype, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '\"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(ch),
    };
}

fn htmlEscapeMultiline(writer: anytype, text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '\n' => try writer.writeAll("<br/>"),
        '\r' => {},
        '\t' => try writer.writeAll("&nbsp;&nbsp;&nbsp;&nbsp;"),
        else => {
            const single = [1]u8{ch};
            try htmlEscape(writer, single[0..]);
        },
    };
}

fn formatTimestamp(writer: anytype, ts: u32) !void {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = ts };
    const day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const secs = epoch_secs.getDaySeconds();
    const month = month_day.month.numeric();
    const dom = @as(u8, month_day.day_index + 1);
    try writer.print(
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC",
        .{
            day.year,
            month,
            dom,
            secs.getHoursIntoDay(),
            secs.getMinutesIntoHour(),
            secs.getSecondsIntoMinute(),
        },
    );
}

// ---- Ingestion status helpers ----
const Phase = ingest_service.Phase;
const RelayStatus = ingest_service.RelayStatus;
const Status = ingest_service.Status;

fn phaseToStr(p: Phase) []const u8 {
    return switch (p) {
        .initial => "initial",
        .contacts => "contacts",
        .posts_backfill => "posts_backfill",
        .live => "live",
        .finished => "finished",
        .failed => "failed",
    };
}

fn renderStatusJson(allocator: std.mem.Allocator, st: Status) ![]u8 {
    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);
    var w = list.writer(allocator);
    try w.writeAll("{");
    try w.print("\"phase\":\"{s}\",", .{phaseToStr(st.phase)});
    try w.print("\"events_ingested\":{d},", .{st.events_ingested});
    try w.print("\"latest_created_at\":{d},", .{st.latest_created_at});
    if (st.first_post_ms) |v| {
        try w.print("\"first_post_ms\":{d},", .{v});
    } else {
        try w.writeAll("\"first_post_ms\":null,");
    }
    if (st.last_error) |e| {
        try w.writeAll("\"last_error\":");
        try jsonEscapeString(&w, e);
        try w.writeAll(",");
    } else {
        try w.writeAll("\"last_error\":null,");
    }
    try w.writeAll("\"relays\":[");
    var i: usize = 0;
    while (i < st.relays.len) : (i += 1) {
        const rs = st.relays[i];
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{");
        try w.writeAll("\"url\":");
        try jsonEscapeString(&w, rs.url);
        try w.print(",\"eose\":{s},", .{if (rs.eose) "true" else "false"});
        try w.print("\"attempts\":{d},", .{rs.attempts});
        if (rs.last_change_ms) |ms| {
            try w.print("\"last_change_ms\":{d},", .{ms});
        } else {
            try w.writeAll("\"last_change_ms\":null,");
        }
        if (rs.err) |err_str| {
            try w.writeAll("\"last_error\":");
            try jsonEscapeString(&w, err_str);
        } else {
            try w.writeAll("\"last_error\":null");
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return try list.toOwnedSlice(allocator);
}

fn jsonEscapeString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}

fn writeStatusBanner(writer: anytype, npub_value: []const u8) !void {
    try writer.writeAll("<div class=\"status\"><div class=\"spinner\" id=\"spin\"></div><div id=\"status-text\">Checking status…</div></div>\n");
    try writer.writeAll("<script>\n");
    try writer.writeAll("(function(){\n");
    try writer.writeAll("  const npub = '");
    try htmlEscape(writer, npub_value);
    try writer.writeAll("';\n");
    try writer.writeAll("  let lastCount = 0;\n");
    try writer.writeAll("  async function poll(){\n");
    try writer.writeAll("    try {\n");
    try writer.writeAll("      const r = await fetch('/status?npub=' + encodeURIComponent(npub));\n");
    try writer.writeAll("      if(!r.ok) throw new Error('http '+r.status);\n");
    try writer.writeAll("      const j = await r.json();\n");
    try writer.writeAll("      let text = 'phase: ' + j.phase + ' — events: ' + j.events_ingested;\n");
    try writer.writeAll("      if (j.last_error) { text += ' — error: ' + j.last_error; }\n");
    try writer.writeAll("      document.getElementById('status-text').textContent = text;\n");
    try writer.writeAll("      if (j.events_ingested > lastCount) { lastCount = j.events_ingested; window.location.reload(); return; }\n");
    try writer.writeAll("      if (j.phase === 'finished') { document.getElementById('spin').style.display='none'; }\n");
    try writer.writeAll("    } catch(e) { document.getElementById('status-text').textContent = 'status unavailable'; }\n");
    try writer.writeAll("    setTimeout(poll, 600);\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("  const start = document.getElementById('start-link'); if (start) { start.addEventListener('click', function(ev){ ev.preventDefault(); window.location.href = '/start?npub=' + encodeURIComponent(npub); }); }\n");
    try writer.writeAll("  poll();\n");
    try writer.writeAll("})();\n");
    try writer.writeAll("</script>\n");
}

fn extractContent(allocator: std.mem.Allocator, payload: []const u8) ?[]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const object = root.object;
    const content = object.get("content") orelse return null;
    if (content != .string) return null;
    return content.string;
}
