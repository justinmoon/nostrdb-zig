# Plan V4 — Real‑Relay E2E To Green (No Mocks)

Goal
- Produce a consistently passing, end‑to‑end test that uses real public relays for a known npub, validates that ingestion completes (contacts + posts) and that at least one post renders in SSR.
- Keep the flow simple and observable so we can iterate quickly: “run → see where it stalls → fix → re‑run”.

Scope
- SSR binary (`ssr-demo`), ingestion manager, contacts/timeline LMDB stores, net/WebSocket client.
- Driver script: `scripts/e2e_ssr.sh` (no mocks). Optional opt‑in Zig handshake test for targeted validation.

Baseline
- `scripts/e2e_ssr.sh` already:
  - Builds `ssr-demo`, starts on a fresh LMDB dir.
  - Hits `/timeline?npub=…` to auto‑start ingestion when empty.
  - Polls `/status?npub=…` until `events_ingested > 0` or timeout, then fetches HTML and asserts at least one `<article class="note">` is rendered.
  - Prints SSR logs on failure.

Phases

1) Instrumentation (Visibility)
- Add per‑relay logs in contacts.Fetcher and ingest.Pipeline:
  - “connect → handshake → REQ sent → EOSE received” with timestamps and relay URL.
  - On failure, log `url`, `phase`, and `error`.
- Extend `/status` JSON with per‑relay fields:
  - `attempts`, `last_error`, `eose` (existing), and optionally `last_change_ms`.
- SSR logs:
  - At job start: log exact relay list.
  - On phase change: log phase + elapsed ms since job start.

2) Handshake fixes (Real Public Relays)
- Add Origin header support in `net.RelayClient`:
  - Options: `.origin: ?[]const u8`; default SSR `--ws-origin=https://nostrdb-ssr.local` (configurable).
  - Pass Origin into `websocket.Client.handshake` so relays that require Origin accept us.
- Verify SNI/Host correctness:
  - Ensure parsed host (without port) is used for SNI and Host.
- Add debug handshake logging (temporary/opt‑in):
  - When we get InvalidHandshakeResponse, log status line and a few response headers.

3) Contacts/Posts Resilience
- Contacts.Fetcher:
  - Continue with clients that connect; skip relays that fail `init/connect/handshake`.
  - If no relays could be initialized, return a clear error (e.g., `NoAvailableRelays`) so `/status` shows it.
- Pipeline.run:
  - Use the subset of relays that connected, not the entire configured list.
  - Continue on per‑relay errors; finish when at least one relay EOSEs or overall timeout.

4) Default Relay Set & Overrides
- Expand the default relay list (8–10 stable relays), keep it configurable via `--relays`.
- The e2e script defaults to a small, commonly reachable set; allow local override via `RELAYS=...`.

5) Iterate with the Driver
- Run `scripts/e2e_ssr.sh`.
- On timeout:
  - Print `/status` per‑relay summaries (attempts, last_error).
  - Print SSR tail logs.
  - Adjust Origin and/or relay list; re‑run until we see contacts EOSE and posts insertions.
- Commit small, focused changes as we progress.

6) Targeted Zig Test (Opt‑In)
- Add a small Zig handshake test (skipped unless `RELAY_URL` env is provided) to isolate handshake from pipeline.
  - Asserts we can `connect()` with Origin set and cleanly `close()`.

7) Tighten Assertions (Post‑Green)
- E2E assertions:
  - Confirm `events_ingested >= N` (start with N=1), then increase once stable.
  - Optionally assert that rendered posts’ authors ∈ contacts list (via a debug JSON endpoint or lightweight HTML parsing).
- Time to first post SLA (log + assert upper bound in the script, e.g., <60–90s with the chosen relays).

Acceptance Criteria
- `scripts/e2e_ssr.sh` passes end‑to‑end with the default relay list and the provided npub on a clean environment.
- Logs clearly show which relays were attempted, which connected, and when EOSE occurred.
- `/status` JSON returns per‑relay diagnostics.

Risks & Mitigations
- Relay policy changes / rate limits: Keep multiple relays in the default set; continue on per‑relay failure.
- Network flakiness: Extend timeouts modestly; add exponential backoff.
- Environment discrepancies (TLS/Origin): Make Origin configurable and log handshake details on failure.

Deliverables
- Code: Origin support in `net.RelayClient`, per‑relay logging, `/status` diagnostics, resilient contacts/pipeline init.
- Script: `scripts/e2e_ssr.sh` updated to print per‑relay errors and pass reliably.
- (Optional) Zig handshake test (opt‑in via env) for manual debugging.

Timeline (Iterative)
- Day 1: Instrumentation + Origin support + status diagnostics; run e2e; capture failures.
- Day 2: Resilience changes; expand defaults; re‑run; adjust; get to first green.
- Day 3: Tighten assertions; clean up logs; land plan as default smoke.

Notes
- No mocks for the primary e2e path; mocks are still useful in unit/integration tests not covered by this plan.
- Keep changes small and observable; re‑run the shell test after each step.

