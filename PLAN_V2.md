# Megalith (nostrdb-zig → Monorepo) MVP Plan

Goal: Evolve nostrdb-zig into a monorepo (Megalith) that ingests Nostr events server‑side to produce a posts‑only timeline for an SSR app. Keep using nostrdb-zig as the ingestion core; add only the minimum networking and protocol layers needed. Strong, library‑sourced tests included.

## Scope

- Posts‑only SSR ingestion for a fixed npub.
- Fetch contact list (kind 3) → follow set.
- Fetch posts (kind 1) for followed authors.
- Ingest via nostrdb‑zig (signatures validated there).
- Maintain in‑memory KV for timeline: `contacts:<npub>`, `timeline:<npub>`, `timeline_meta:<npub>`, `event:<id>`.
- Exclude replies/reactions/reposts/zaps/DMs from MVP.

## Repo Shape (evolve in‑place)

- Keep existing: `src/` (nostrdb‑zig code)
- Add:
  - `proto/` (npub decode, REQ/CLOSE builders, filter JSON)
  - `net/` (websocket client + relay pool)
  - `contacts/` (kind‑3 parsing, follow set storage)
  - `ingest/` (EVENT → Ndb.processEvent → KV updates)
  - `timeline/` (in‑memory KV + read API)
  - `cli/` (megalith CLI)
  - `tests/` (unit + integration; ports from rust‑nostr, enostr, go‑nostr)
  - `build.zig` (wire megalith target)

## Phase 0 — Bootstrap

Implement
- Add module skeletons and a `megalith` build target.
- CLI scaffold: `megalith ingest --npub <npub> --relays <wss://...,...> --limit 500`.

Acceptance
- `zig build megalith` produces a binary.
- CLI echoes parsed args.

## Phase 1 — Nostr Primitives (proto/)

Implement
- NIP‑19 `npub` decode (bech32 → 32‑byte pubkey).
- Filter JSON builders:
  - Contacts: `[{"authors":["<hex>"],"kinds":[3],"limit":1}]`
  - Posts: `[{"authors":[...],"kinds":[1],"limit":L,"since":S?}]` (authors chunking supported).
- REQ/CLOSE builders and subid generator.

Acceptance (tests to port/build)
- Port npub decode vectors from rust‑nostr (~/code/nostr) and go‑nostr (~/code/go-nostr/nip19).
- Unit tests: filter JSON must match expected strings for contacts/posts (with and without `since`).
- Subid generator uniqueness over 10k samples.

## Phase 2 — WebSocket + Relay Client (net/)

Implement
- Single relay client: connect, send REQ/CLOSE (text), receive text frames.
- Parse inbound: EVENT (extract `subid` and raw event JSON), EOSE (`subid`), NOTICE (string).
- RelayPool: manage N relays; per‑relay sub registry; simple retry/backoff.

Acceptance (tests to port/build)
- Port enostr RelayMessage parsing table (EOSE/NOTICE/OK/EVENT) from notedeck’s enostr (crates/enostr/src/relay/message.rs tests).
- Integration test: MockRelayServer → on REQ, sends 2 EVENTs then EOSE; client surfaces 2 events and flags EOSE.
- Unit tests: ignore non‑text frames; tolerate malformed JSON; log NOTICE.

## Phase 3 — Contacts (contacts/)

Implement
- For the target npub: build contact REQ via proto; send to all relays; ingest each EVENT via `Ndb.processEvent`.
- Pick the latest kind‑3 by `created_at`.
- Parse `p` tags → follow set (ignore hashtags for MVP).
- Store in‑memory: `contacts:<npub> = set<[32]>`; `contacts_meta:<npub> = {event_id, created_at}`.

Acceptance (tests to port/build)
- Port/construct kind‑3 tag parsing vectors from rust‑nostr/go‑nostr. Verify `p` tags decoded to expected pubkeys.
- Integration: MockRelay emits two contact lists with increasing `created_at`; latest wins; follow set and meta update accordingly.

## Phase 4 — Ingestion + Timeline (ingest/ + timeline/)

Implement
- Ingest handler:
  - On EVENT: `Ndb.processEvent(json)`.
  - If `kind==1` AND author ∈ follow set → insert event id into `timeline:<npub>` (sorted desc by `created_at`), cap window (e.g., 2000).
  - Store `event:<id>` = raw JSON (+ cached parsed fields). Update `timeline_meta.latest_created_at`.
- Posts subscription:
  - After contacts EOSE, build posts filters via proto; REQ to all relays.
  - On posts EOSE per relay, open live REQ with `since = latest_created_at`.

Acceptance (tests to port/build)
- Port go‑nostr event vectors (~/code/go-nostr/event_test.go):
  - Valid events pass; invalid signatures are rejected by nostrdb (assert not inserted into timeline).
- Port/align with go‑nostr filter tests (filter_test.go) to ensure posts filter JSON (authors/kinds/limit/since) is correct.
- Integration: MockRelay mixes posts from followed and non‑followed authors; only followed author posts land in `timeline:<npub>` in desc order.
- Integration: Multiple relays EOSE; switch to live since; new events appear at head with correct ordering.

## Phase 5 — Bootstrap + Live Strategy

Implement
- Initial posts fetch:
  - If timeline empty → omit `since` for backfill (limit controls volume).
  - If timeline has ≥ limit entries → enable `since` optimization.
- Live handling:
  - On EOSE → immediately open “since” REQ with `latest_created_at`.
- Optional: periodic backfill windows if `timeline` length < target window.

Acceptance (tests to build)
- Deterministic MockRelay: send backfill (3 past posts) + EOSE → client opens live since → send 2 newer posts → timeline order correct and only new posts appended in live.
- Ingest 5k events quickly; operations remain fast; window cap enforced.

## Phase 6 — CLI (cli/)

Implement
- `megalith ingest --npub <npub> --relays <wss://...,..> --limit 500`
- Pipeline: contacts fetch → posts fetch → live mode.
- Output: top N rows with `created_at`, `id`, optional `pubkey`/content preview.

Acceptance
- Manual: run against a known npub and small relay set; outputs plausible posts timeline.
- Scripted: run against MockRelay; snapshot of printed timeline matches expected order; exit code 0.

## Phase 7 — Hardening (minimal)

Implement
- Authors chunking (e.g., 256 authors per filter) with deterministic subids.
- Relay backoff/reconnect (exponential backoff).
- Optional: config file at `~/.megalith/config.json`.
- Optional: persist KV to disk later (LMDB or JSON snapshot), but keep MVP in‑memory for speed.

Acceptance
- Unit tests: chunking partitions author lists exactly; reproduce filter batches.
- Fault injection: one relay flaps; pool recovers; live since resumes.
- Config test: CLI reads relays from config if no flag.

## Test Sources to Port (targeted)

- rust‑nostr (~/code/nostr)
  - NIP‑19 npub vectors; basic event serialization/signature/id tests (use as parse/validation guidance).
- enostr (from Notedeck)
  - RelayMessage parsing tests (EVENT/EOSE/OK/NOTICE) → mirror behavior in net message parser.
- go‑nostr (~/code/go-nostr)
  - event_test.go: ID/signature/created_at vectors (feed to relays; verify ingestion outcomes).
  - filter_test.go: ensure filter JSON shape alignment.
  - subscription/eose tests as behavioral inspiration for MockRelay.

## Milestones

- M1 (Phases 0–2): build + relay message parser passes enostr vectors; MockRelay EOSE flow verified.
- M2 (Phase 3): contacts parsed; follow set stable across updates.
- M3 (Phases 4–5): end‑to‑end timeline; live since works; acceptance on go‑nostr vectors (valid/invalid).
- M4 (Phases 6–7): CLI usable; chunking/backoff working; config supported.

## Notes

- nostrdb‑zig remains the ingestion core; no API changes needed for MVP.
- We rely on nostrdb for signature/id validation; tests assert rejected events do not reach the timeline.
- SSR layer is out of scope here; the timeline KV and event store are designed to be consumed by SSR quickly.


