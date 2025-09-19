# Megalith Plan V3 — Demo‑Ready SSR With Fast, Concurrent Ingestion

Goal: Deliver a smooth live demo on a Nix server (e.g., mega.justinmoon.com) where ~20 concurrent users can enter their npubs and see a usable feed (posts from their follows) within ~1 minute. While ingesting, the app should quickly surface recent posts and show clear progress signals so nobody waits in silence.

This plan builds on V1/V2 and the work completed in lmdb‑phase7 (LMDB stores for contacts/timeline, ingest pipeline, relay client, CLI, tests).

--------------------------------------------------------------------------------

Current State (Deeper Dive)

- Core libs
  - proto/: npub decode, REQ/CLOSE builders, posts/contacts filter builders with authors chunking and optional since.
  - net/: WebSocket client with background reader, message parser, MockRelay for tests. Basic client retry/backoff exists per caller; a simple pool abstraction is present, not yet used by ingest.
  - contacts/: kind‑3 parser + LMDB store for contact lists keyed by author pubkey (latest wins by created_at/id).
  - ingest/: single‑user pipeline: fetch follows (from contacts store), post subscriptions across relays, ingest via nostrdb, and timeline insertions for kind 1 if author ∈ follows. Handles initial backfill and live “since” re‑subscription per relay.
  - timeline/: LMDB store for event payloads and per‑user timeline (keys prefix by npub), with insert + cap + meta (latest_created_at, count). Supports reading snapshots and fetching stored event payload by id.
  - ndb/: Thin Zig wrapper around nostrdb C library. Used for signature/ID validation and SSR read paths.

- CLI
  - megalith ingest target scaffolding is present and exercises ingest over relays; currently uses a temporary db path in CLI but serves as a working integration test.

- SSR (ssr/main.zig)
  - Renders activity by author directly from nostrdb (kinds=1, author==npub, limit=N). No connection to LMDB timeline/contacts stores. No ingestion or status endpoints. Output is HTML with a basic form and static CSS.
  - Currently only imports `ndb` and `proto` in build; will need to import `timeline`, `contacts`, `ingest`, and `net` to integrate feeds and status.

- Tests/CI
  - Rich unit/integration test coverage for proto/net/contacts/ingest/timeline with MockRelay.
  - CI needs to ensure zig fmt/build/test run inside Nix. Formatting pass was fixed and pushed in lmdb‑phase7.

- Observations/Gaps
  - SSR must switch from “author == npub” to feed of follows via the LMDB timeline store; keep author query only as a fallback/debug mode.
  - No ingestion manager for concurrent, per‑npub jobs initiated by SSR. Pipeline exists but is not exposed as a long‑lived job.
  - No status JSON/SSE endpoints. No progress plumbing from `ingest.Pipeline` (no callbacks today).
  - `build.zig` does not import `timeline/contacts/ingest/net` for ssr‑demo.
  - `flake.nix` CI script currently disables build/test. We can (and should) enable it inside Nix dev shell where the Security framework paths are configured and the nostrdb submodule is initialized.

--------------------------------------------------------------------------------

Demo Requirements And Constraints

- Ingestion
  - Kick off ingestion on demand when a user enters an npub.
  - Backfill quickly enough to show a decent feed (<~60s for first screen). Use authors chunking and “since” efficiently.
  - Support ~20 concurrent users without falling over (e.g., 3 relays × 20 users ≈ 60 WS connections; acceptable on Hetzner).

- SSR
  - Show a simple text‑only feed of posts for the user’s follows.
  - Provide immediate feedback (“ingesting…”, partial results as soon as available) and avoid blank waits.

- Deployment (Nix)
  - Build/package ssr‑demo and run as a service on the server.
  - Configure a persistent LMDB directory.
  - Provide a minimal config for relays and sensible limits.

- Reliability/Speed
  - Solid tests (unit/integration) and CI checks.
  - Basic perf sanity and log/metrics for visibility.

--------------------------------------------------------------------------------

Plan (Phased, Minimal To Demo → Hardening)

Phase A — SSR Reads From LMDB Timeline (Feed of Follows)

- Replace SSR’s author==npub query path with timeline store reads:
  - build.zig: add imports for `timeline`, `contacts`, `ingest`, and `net` to `ssr_demo.root_module` (mirroring CLI/megalith wiring).
  - ssr/main.zig: open LMDB `contacts.Store` and `timeline.Store` at server startup (singletons), alongside `ndb.Ndb` (for potential profile lookups later).
  - SSR GET `/timeline?npub=…`
    - Decode npub → pubkey (proto.decodeNpub).
    - Load snapshot: `timeline.loadTimeline(pubkey)`; for each entry fetch payload by ID `timeline.getEvent(id)` and render `content` field (JSON parse is already in CLI’s `writeContentPreview`; we can factor a tiny JSON content extractor here too).
    - If empty, render a banner “No posts yet — ingestion may be in progress.” and link to `/start?npub=…`.
  - Keep `ndb` author query route behind an optional query flag for debugging (`/timeline?npub=…&mode=author`).

Acceptance
- SSR renders a valid feed for any npub that was ingested previously by the CLI/pipeline.
- No dependency on static dumps for the feed; LMDB only.

Phase B — Ingestion Manager In SSR (On‑Demand, Concurrent)

- Add an IngestionManager (new file `ssr/ingest_service.zig`) owned by the HTTP app:
  - Holds single shared LMDB `contacts.Store` and `timeline.Store` and a global relay list + limits (from config/env).
  - Job table: `std.AutoHashMap([32]u8, *Job)` with a mutex + condvar.
  - Job struct: npub, phase (.contacts, .posts_backfill, .live, .finished, .failed), timestamps, per‑relay state (EOSE seen, error), counters (events_ingested, first_post_ms), and last_error.
  - `ensureJob(npub)`: if not found, spawn a job thread that:
    1) builds contacts filter and fetches latest kind‑3 across relays (reuse contacts.Fetcher code path or embed minimal logic),
    2) kicks `ingest.Pipeline` with follows and relays to populate timeline,
    3) records per‑relay EOSE and overall phase transitions.
  - Concurrency: limit jobs to e.g., 24; enqueue extras with FIFO. Each job uses 1 thread per relay (via RelayClient reader thread) which is acceptable at demo scale.
  - Backoff/timeouts: respect RelayClient connect timeout, and have a max job wall‑time (e.g., 3 minutes) before moving to .finished.

- HTTP endpoints for status and partial results in ssr/main.zig:
  - GET `/start?npub=…` → `ensureJob(npub)` then 302 → `/timeline?npub=…`.
  - GET `/status?npub=…` → JSON `{ phase, events_ingested, latest_created_at, last_error, relays: [{url, eose, errors}], first_post_ms }`.
  - Optional: `/events?npub=…` Server‑Sent Events (SSE) for live progress; start with polling for simplicity.

- Timeline freshness UI (HTML only; no heavy framework):
  - Banner with `<meta http-equiv=refresh>` fallback and a minimal `<script>` to poll `/status` every 600ms while phase!=finished; update banner text + reload the page when `events_ingested` increases or after first_post_ms is set.
  - Defer fancy hydration; keep to 1–2KB of inline JS.

Acceptance
- Entering an npub triggers ingestion and the page begins to show posts within ~60s from at least one relay, then fills in as more arrive.
- With ~20 concurrent distinct npubs, resource use remains bounded and responsive.

Phase C — Backfill + Live Strategy Tuning

- Backfill/live refinements (ingest/Pipeline):
  - Keep current behavior: no `since` on first request if timeline not full, then `since=latest_created_at` on live.
  - Verify authors chunking is 256 (proto.PostsFilterOptions.chunk_size) and plumb a config knob.
  - Add relay connect retry with exponential backoff in RelayClient consumer (simple sleep loop with cap set by net/relay_pool.zig Config).

- SSR user experience tweaks:
  - If snapshot empty after a few seconds, display “Fetching contacts… / Fetching posts…” steps (based on status fields).
  - Prefer showing newest content first; paginate by limit.

Acceptance
- Typical user sees first posts <~60s; timeline updates live for a few minutes during the demo.

Phase D — Packaging + Nix Deployment

- Flake outputs
  - Add a `packages.ssr-demo` target that builds and installs `ssr-demo` (already in build.zig); add `apps.ssr-demo` so `nix run` can launch it.
  - Provide NixOS module `services.megalith-ssr` with options: `dbDir`, `relays`, `port`, `limit`, `chunkSize`, `logLevel`. Render a systemd unit and environment file.
  - Add example nginx vhost for `mega.justinmoon.com` proxying to 127.0.0.1:8080 with gzip and small cache.

- Ops docs
  - One‑pager: build/deploy, setting relays, wiping DB safely (stop service → remove LMDB dirs), collecting logs, increasing map_size.

Acceptance
- “nixos-rebuild switch” produces a running service reachable at mega.justinmoon.com.

Phase E — Reliability, Tests, CI

- Tests
  - SSR unit tests: `findQueryValue`, `splitTarget`, HTML rendering helpers.
  - SSR integration: spin MockRelays; start IngestionManager with 2 relays; `ensureJob(npub)`; wait for partial EOSE; GET `/timeline?npub=…` and assert content present and ordered by created_at desc.
  - Concurrency: start 20 jobs with staggered start; ensure status JSON is consistent and process completes under a bounded time.

- CI
  - Enable build/test in `flake.nix` CI script (currently disabled). Run inside Nix with submodule init and the macOS framework path preconfigured where applicable.
  - Add a smoke `zig build test` plus an SSR minimal test target that compiles the new ingestion manager and basic handlers.

Acceptance
- CI green on formatting, build, tests, and smoke ingest.

Phase F — Performance + Observability

- Metrics/logging
  - Add simple counters and timestamps in IngestionManager; expose as fields in `/status`.
  - LMDB stats: dump map size and page usage on startup and once per N minutes (debug).

- Perf passes
  - Bench harness that ingests N events via MockRelays to profile CPU/allocs.
  - LMDB map_size sizing and cursor iteration cost checks; ensure we batch writes sanely.
  - Tune chunk sizes and parallelism per relay.

Acceptance
- For demo‑scale traffic: stable CPU/memory and “first content” in ~60s for 20 concurrent users.

--------------------------------------------------------------------------------

Design Notes And Rationale

- Single LMDB environments for contacts/timeline are multi‑tenant by design:
  - timeline keys are prefixed by npub, so many users can share the same store safely.
  - contacts are keyed by author (npub), same property holds.
  - This keeps disk I/O and mmap usage efficient and simplifies deployment.

- Concurrency model
  - Simple and robust: one pipeline per active npub; each pipeline fans out to its configured relay set.
  - Connection count is predictable (relays × active npubs). We can cap global jobs and queue the rest.
  - Future: a RelayPool shared across jobs could multiplex better, but not necessary for the demo.

- Fast feedback UX
  - Users should see something as soon as the first relay EOSEs the initial REQ.
  - The status endpoint (or SSE) plus polling offers a small effort, high impact path for the demo.

--------------------------------------------------------------------------------

Implementation Checklist (Actionable, File‑Level)

1) SSR feed from LMDB
   - build.zig: for `ssr_demo.root_module` add imports: `timeline`, `contacts`, `ingest`, `net`.
   - ssr/main.zig: open `contacts.Store` and `timeline.Store` at startup; add tiny JSON content extractor to avoid duplicating CLI logic.
   - ssr/main.zig: render `/timeline` from `timeline.loadTimeline(pubkey)` in created_at desc (already sorted by store); for each entry, `timeline.getEvent(id)` and render content.

2) IngestionManager
   - Add `ssr/ingest_service.zig` with `IngestionManager` as described; spawn per‑npub job using `ingest.Pipeline`.
   - ssr/main.zig: wire `/start` and `/status`; add banner polling logic.

3) UX polish
   - Inline CSS badge for `phase` and a subtle spinner.
   - Cap displayed posts to `limit` and show `count/meta.latest_created_at` in header.

4) Nix packaging
   - flake.nix: add `apps.ssr-demo` and a `packages.ssr-demo` alias; create a NixOS module under `nix/` with systemd unit.
   - Provide example nginx vhost. Add `README-DEPLOY.md` with steps.

5) CI upgrades
   - Turn on `zig build` and `zig build test` in `ci` script; fail if submodule missing or LMDB headers not found.
   - Add a smoke mock‑ingest test that runs fast (<5s).

6) Perf + logs
   - Counters: events_ingested/job, relays_eose_count, first_post_ms, total_duration_ms.
   - Bench tool under `minimal_test/` to push 5k events through ingest in‑memory MockRelays and report durations.

--------------------------------------------------------------------------------

Milestones

- M1: SSR reads from LMDB timeline; manual LMDB preseed shows feed.
- M2: SSR starts ingestion; /status polling; first post <~60s for one user.
- M3: 20 concurrent users stable; bounded resource use; demo rehearsal.
- M4: Nix deployable service; CI green; basic metrics; demo day.

--------------------------------------------------------------------------------

Parallelization Plan (Agents)

This breaks the work into concurrent tracks with minimal overlap. Each agent has clear file boundaries and a shared interface where needed.

Agent 1 — Ingestion Manager (new module)
- Files: ssr/ingest_service.zig (new), tests/ingest_service_test.zig (new)
- Purpose: Run ingest.Pipeline per-npub, track progress, expose status, and cap concurrency (~24 jobs).
- API (stable contract for Agent 2):
  - pub const Phase = enum { initial, contacts, posts_backfill, live, finished, failed };
  - pub const RelayStatus = struct { url: []const u8, eose: bool, error: ?[]const u8 };
  - pub const Status = struct {
      phase: Phase,
      events_ingested: u64,
      latest_created_at: u64,
      first_post_ms: ?u64,
      last_error: ?[]const u8,
      relays: []RelayStatus,
    };
  - pub fn init(allocator: std.mem.Allocator, relays: []const []const u8, limit: u32, contacts_store: *contacts.Store, timeline_store: *timeline.Store) !IngestionManager
  - pub fn deinit(self: *IngestionManager) void
  - pub fn ensureJob(self: *IngestionManager, npub: [32]u8) !void
  - pub fn status(self: *IngestionManager, npub: [32]u8, allocator: std.mem.Allocator) !Status
- Notes: Implement simple exponential backoff on relay connect failures within job threads. Respect per-job wall-time (e.g., 3 min) and set phase accordingly.

Agent 2 — SSR Main + Build wiring
- Files: ssr/main.zig (modify), build.zig (modify to import timeline/contacts/ingest/net for ssr_demo)
- Purpose: Switch SSR to LMDB timeline (feed of follows) and add endpoints + minimal polling UI.
- Tasks:
  - Open LMDB contacts.Store and timeline.Store singletons at server startup.
  - Route GET /timeline?npub=…: load timeline snapshot + entries via timeline.getEvent(); render content text (parse JSON content field locally).
  - Route GET /start?npub=…: call Agent‑1’s ensureJob(); redirect to /timeline.
  - Route GET /status?npub=…: call Agent‑1’s status() and return JSON with the Status schema above.
  - Add a small inline banner + script to poll /status every ~600ms until phase==finished; reload content when counts change.
  - Keep an optional author==npub path behind a mode=author query param for debugging.
- Coordination: If Agent‑1 is not yet complete, stub status with a static JSON using the agreed schema so UI work can proceed.

Agent 3 — Nix Packaging & Deployment
- Files: flake.nix (modify), nix/module.nix (new), README-DEPLOY.md (new)
- Purpose: Make ssr-demo deployable and configurable.
- Tasks:
  - Add packages.ssr-demo and apps.ssr-demo outputs.
  - NixOS module: services.megalith-ssr with options { dbDir, relays, port, limit, chunkSize, logLevel } → systemd unit.
  - Example nginx vhost for mega.justinmoon.com proxying to 127.0.0.1:8080.
  - Deployment README with steps and safety notes (LMDB sizing, wiping, logs).

Agent 4 — Performance Harness & Counters
- Files: minimal_test/* (new), optional counters in ssr/ingest_service.zig
- Purpose: Validate speed and throughput before demo.
- Tasks:
  - MockRelay-based tool that pushes N events and reports: time-to-first-post, total duration, events/second.
  - Add basic counters to IngestionManager (events_ingested, first_post_ms), surfaced via /status.

Agent 5 — CI Enhancements
- Files: flake.nix (modify)
- Purpose: Harden CI and enable checks without interfering with packaging work.
- Tasks:
  - Keep zig fmt check always.
  - Optionally enable build/test behind env flag ENABLE_BUILD_TEST=1 to avoid surprises during early packaging; later, make it default.
  - Ensure submodule init occurs; run tests in nix dev shell.

Coordination Notes
- Status JSON schema (above) is the contract between Agents 1 and 2 (and 3 for monitoring). Avoid refactors that change it during this iteration.
- File boundaries:
  - Agent 1: new files only; no changes to existing SSR routes.
  - Agent 2: ssr/main.zig and build.zig; avoid touching flake.nix.
  - Agent 3/5 both change flake.nix. Prefer Agent 5 to add env-guarded build/test first; Agent 3 adds packaging/module; or coordinate sequential commits.
- Branching: Each agent can branch off lmdb-phase7 and open dedicated PRs; integrate sequentially with minimal conflict.
