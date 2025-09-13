# NostrDB Rust to Zig Porting Plan V5 - Pure Test-Driven Development

## Workspace Repos (for reference)
- zig-search (reference app/tests): `../zig-search`
- rust bindings repo: `../zig-search/nostrdb-rs/`
- nostrdb C repo (direct checkout): `../nostrdb`

Note: For this port, use the nostrdb C source exactly as pinned by the rust bindings via a git submodule (see below). Do not mix versions.

## 🎯 Core Philosophy
**Port one Rust test at a time. Implement only what's needed to make that test pass.**

No copying broken code. No speculative features. Just make the test green, then move to the next.

## ⚠️ Important Notes
- Use git submodule to fetch nostrdb C sources and pin to the exact commit used by nostrdb-rs.
- Exact nostrdb commit (from nostrdb-rs submodule pointer): `9f9d4d87d596a24de7c150cddb50071850a6bb31`.
- No shims or fakes. Always bind and link the real C library.
- The ../zig-search project can be referenced for ideas, but do not copy its implementation.

---

# Phase 0: Minimal Setup (30 minutes)

## Setup Tasks
1. Add nostrdb as a git submodule in this repo and pin it to the exact commit used by nostrdb-rs:
   - `git submodule add https://github.com/damus-io/nostrdb nostrdb`
   - `git -C nostrdb checkout 9f9d4d87d596a24de7c150cddb50071850a6bb31`
   - `git add .gitmodules nostrdb && git commit -m "Add nostrdb submodule pinned to rust version"`
2. Create build.zig that compiles the C library from the submodule, mirroring the file list and defines used in nostrdb-rs/build.rs (no deviations).
3. Create minimal @cImport for nostrdb.h (from the submodule include path).
4. Set up test runner.
5. Add a .gitignore to exclude Zig build artifacts (`.zig-cache/`, `zig-out/`, and common binary outputs) and sub-deps outputs (e.g., `nostrdb/deps/secp256k1/.libs/`).

---

# Phase 1: Core Database Tests (MVP Path - 6 tests)

## Test 1: `ndb_init_works`
**Source**: `nostrdb-rs/src/ndb.rs:501-509`

**Required implementations**:
- Ndb struct with init/deinit
- Config struct with defaults
- Basic error enum
- C binding for ndb_init and ndb_destroy

**Notes**: 
- C functions return 1 for success, 0 for failure
- Config must be zero-initialized before use

---

## Test 2: `process_event_works`
**Source**: `nostrdb-rs/src/ndb.rs:714-733`

**Required implementations**:
- Ndb.processEvent() method
- C binding for ndb_process_event
- Test event constants (copy from test_events.zig or create minimal ones)

**Notes**:
- Events are JSON strings in Nostr relay format: `["EVENT", "subid", {...}]`
- No need for CString conversion, just pass pointer and length

---

## Test 3: `poll_note_works`
**Source**: `nostrdb-rs/src/ndb.rs:691-711`

**Required implementations**:
- Filter struct (minimal - just kinds field)
- FilterBuilder pattern with .kinds() and .build()
- Subscription type (wraps u64)
- Ndb.subscribe() method
- Ndb.pollForNotes() method
- NoteKey type (wraps u64)

**Notes**:
- Must sleep ~150ms after process_event for background indexing
- This test forces you to implement the subscription system early

---

## Test 4: Transaction lifecycle test
**Source**: Create simple test based on usage patterns

**Required implementations**:
- Transaction struct
- Transaction.init() using ndb_begin_query
- Transaction.deinit() using ndb_end_query
- Proper relationship between Ndb and Transaction

**Notes**:
- Transactions are required for queries
- Use defer pattern for cleanup

---

## Test 5: Get note by ID
**Source**: Derived from `process_event_works` verification

**Required implementations**:
- Ndb.getNoteById() method
- Note struct with pointer to C ndb_note
- Note.kind() accessor
- Note.content() accessor
- Hex string to [32]u8 conversion

**Notes**:
- Note IDs are 32-byte arrays, usually provided as 64-char hex strings
- Content strings need null termination handling

---

## Test 6: `query_works`
**Source**: `nostrdb-rs/src/ndb.rs:512-535`

**Required implementations**:
- Ndb.query() method taking Transaction, Filters array, and limit
- QueryResult struct
- Converting Zig Filter to C ndb_filter
- Result array handling

**Notes**:
- This completes the MVP! You can now insert and query events
- Query requires an active transaction

**🎉 MVP COMPLETE - You have a working event database! 🎉**

---

# Phase 2: Extended Filter Tests (Tests 7-11)

## Test 7: `filter_limit_iter_works`
**Source**: `nostrdb-rs/src/filter.rs:1275-1284`

**Required implementations**:
- Filter.limit() method
- Filter field iteration
- Ability to inspect filter contents

---

## Test 8: `filter_id_iter_works`
**Source**: `nostrdb-rs/src/filter.rs:1337-1355`

**Required implementations**:
- Filter.ids() method for filtering by event IDs
- ID element support in filters
- Multiple IDs in single filter

---

## Test 9: `filter_since_mut_works`
**Source**: `nostrdb-rs/src/filter.rs:1310-1334`

**Required implementations**:
- Filter.since() for timestamp filtering
- Mutable filter modification
- Time-based queries

---

## Test 10: `filter_int_iter_works`
**Source**: `nostrdb-rs/src/filter.rs:1358-1368`

**Required implementations**:
- Kinds array iteration
- Integer element handling in filters

---

## Test 11: `filter_multiple_field_iter_works`
**Source**: `nostrdb-rs/src/filter.rs:1371-1391`

**Required implementations**:
- Multiple filter field types in one filter
- Filter.event() method for e-tags
- Complex filter construction

---

# Phase 3: Note Management Tests (Tests 12-15)

## Test 12: `note_builder_works`
**Source**: `nostrdb-rs/src/note.rs` tests

**Required implementations**:
- NoteBuilder struct
- Builder pattern for note construction
- Signing with secp256k1
- Tag building support

**Notes**:
- Requires secp256k1 integration
- This is complex - consider deferring if not needed

### NoteBuilder Signing – Implementation Notes
- nostrdb-rs signs successfully by allocating the builder buffer with `libc::malloc` and passing it to `ndb_builder_init`, then creating a keypair via `ndb_create_keypair` and calling `ndb_builder_finalize(builder, &note, keypair_ptr)`.
- When mirroring this in Zig, prefer `std.heap.c_allocator` (malloc/free) for the builder buffer to match the C/Rust usage and avoid allocator/alignment surprises.
- CCAN sha256 has an unaligned fast path. On some macOS/aarch64 toolchains, feeding an unaligned scratch pointer can trap on 32-bit loads. If encountered:
  - First, ensure the builder buffer uses `malloc` and that we pass it directly to `ndb_builder_init`.
  - If a trap still occurs in your env, compile CCAN sha256 with `HAVE_UNALIGNED_ACCESS=0` (per-file) to force the safe copy path.
- Keep an unsigned finalize path (`finalizeUnsigned`) available only as a temporary workaround during porting; the target is to sign like nostrdb-rs.

---

## Test 13: `note_query_works`
**Source**: `nostrdb-rs/src/note.rs` tests

**Required implementations**:
- Note querying by various fields
- Note comparison
- Note serialization

---

## Test 14: Tag iteration test
**Source**: `nostrdb-rs/src/tags.rs` tests

**Required implementations**:
- Tags struct
- TagIterator
- Tag.get() methods for different indices
- Tag type detection

---

## Test 15: `note_blocks_work`
**Source**: `nostrdb-rs/src/block.rs` tests

**Required implementations**:
- Block parsing for content
- Mention detection
- URL detection
- Block iteration

---

# Phase 4: Profile Tests (Tests 16-17)

## Test 16: `profile_record_works`
**Source**: `nostrdb-rs/src/profile.rs` tests

**Required implementations**:
- ProfileRecord struct
- Profile storage (kind 0 events)
- Profile retrieval by pubkey
- Metadata field access

---

## Test 17: `search_profile_works`
**Source**: `nostrdb-rs/src/ndb.rs:538-582`

**Required implementations**:
- Text search functionality
- Search configuration
- Search result iteration
- Profile-specific search

**Warning**: Text search crashes in zig-search - needs careful implementation

---

# Phase 5: Subscription Tests (Tests 18-22)

## Test 18: `subscribe_event_works`
**Source**: `nostrdb-rs/src/ndb.rs:585-600`

**Required implementations**:
- Async subscription model
- wait_for_notes() method
- Subscription state management

---

## Test 19: `multiple_events_work`
**Source**: `nostrdb-rs/src/ndb.rs:603-643`

**Required implementations**:
- Multiple event processing
- Subscription streams
- Event ordering

---

## Test 20: `multiple_events_with_final_pause_work`
**Source**: `nostrdb-rs/src/ndb.rs:646-688`

**Required implementations**:
- Timing-sensitive subscription handling
- Event buffering

---

## Test 21: `test_unsub_on_drop`
**Source**: `nostrdb-rs/src/ndb.rs:775-806`

**Required implementations**:
- Automatic unsubscribe on drop
- Subscription cleanup
- Reference counting for subscriptions

---

## Test 22: `test_stream`
**Source**: `nostrdb-rs/src/ndb.rs:808-841`

**Required implementations**:
- Stream abstraction for subscriptions
- Async iteration
- Stream cancellation

---

# Phase 6: Advanced Tests (Tests 23-28)

## Test 23: `custom_filter_works`
**Source**: `nostrdb-rs/src/filter.rs:1394-1441`

**Required implementations**:
- Custom filter callbacks
- Closure FFI handling
- Complex filter predicates

**Notes**: Very complex - involves FFI callbacks

---

## Test 24: `transaction_inheritance_fails`
**Source**: `nostrdb-rs/src/transaction.rs` tests

**Required implementations**:
- Transaction isolation
- Nested transaction prevention

---

## Test 25: `process_event_relays_works`
**Source**: `nostrdb-rs/src/relay.rs` tests

**Required implementations**:
- Relay tracking for events
- IngestMetadata support
- Relay URLs per event

---

## Test 26: `nprofile_relays_work`
**Source**: `nostrdb-rs/src/relay.rs` tests

**Required implementations**:
- NProfile bech32 encoding
- Relay list in profiles

---

## Test 27: Platform-specific test (Windows mapsize)
**Source**: `nostrdb-rs/src/ndb.rs:736-772`

**Required implementations**:
- Platform-specific memory mapping
- Fallback for large mapsizes

---

## Test 28: Integration test suite
**Source**: Create comprehensive test

**Required implementations**:
- Full lifecycle test
- All features working together

---

# 📊 Progress Tracking

## MVP Checklist (Tests 1-6)
- [x] Test 1: Database opens and closes
- [ ] Test 2: Events can be ingested
- [ ] Test 3: Subscriptions and polling work
- [ ] Test 4: Transactions work
- [ ] Test 5: Direct note retrieval works
- [ ] Test 6: Query system works

## Extended Features (Tests 7-28)
- [ ] Tests 7-11: Advanced filters
- [ ] Tests 12-15: Note management
- [ ] Tests 16-17: Profiles
- [ ] Tests 18-22: Async subscriptions
- [ ] Tests 23-28: Advanced features

---

# 🚀 Implementation Strategy

1. **Start with Test 1** - Get the database opening
2. **Run test after each change** - Keep the suite green
3. **Implement minimally** - Just enough to pass
4. **Don't skip ahead** - Each test builds on previous ones
5. **Reference Rust code** - The test shows exactly what's needed
6. **Check zig-search for gotchas** - But don't copy its buggy code

## Time Estimates
- Phase 0: 30 minutes (setup)
- Phase 1: 1 day (MVP - 6 tests)
- Phase 2: 1 day (filters - 5 tests)
- Phase 3: 1 day (notes - 4 tests)
- Phase 4: 0.5 days (profiles - 2 tests)
- Phase 5: 2 days (async - 5 tests)
- Phase 6: 2 days (advanced - 6 tests)

**Total: ~1 week for full port, 1 day for MVP**

---

# ⚠️ Known Pitfalls (from zig-search)

1. **Text search crashes** - ndb_text_search has issues, debug carefully
2. **Sleep requirements** - Background indexing needs delays after writes
3. **Return values** - C functions return 1 for success, not 0
4. **Config initialization** - Must zero-init before setting fields
5. **Platform differences** - Windows needs different handling
6. **SHA256 alignment** - On strict-alignment platforms, builder signing may trap if the sha256 input pointer is unaligned. Use malloc-backed buffers like nostrdb-rs and, if necessary, compile CCAN sha256 with `HAVE_UNALIGNED_ACCESS=0`.

---

# 📝 Success Criteria

**You know you're done when:**
- All 28 tests pass
- No memory leaks (test with valgrind)
- Performance comparable to Rust version
- Can be used as a library by other Zig projects

The beauty of this approach: After just 6 tests (1 day), you have a working database. Everything else is optional enhancement!
