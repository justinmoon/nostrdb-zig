# OpenMLS FFI Surface Plan

## Reference Flow: `nostr/mls/nostr-mls/examples/mls_memory.rs`

The example drives three participants (Alice, Bob, Charlie) through the following MLS operations:

1. **Identity bootstrap** – create local providers, generate credentials, and publish key packages (`mls_memory.rs:19-44`).
2. **Group creation** – Alice builds an MLS group, adds Bob, merges the initial commit, and distributes welcomes (`mls_memory.rs:51-95`).
3. **Messaging** – Alice encrypts a message; Bob processes it, decrypts, and stores state (`mls_memory.rs:102-168`).
4. **Welcome handling** – Bob and later Charlie process/accept welcome messages and instantiate local MLS state (`mls_memory.rs:116-156`, `177-210`).
5. **Membership changes** – Alice issues add/remove commits; members merge commits and update local metadata (`mls_memory.rs:177-244`).
6. **Leaving** – Bob issues a leave proposal and Alice processes the resulting message (`mls_memory.rs:252-279`).

Everything the Zig port must call stems from these stages; the lists below are derived directly from the Rust implementation that backs each call site.

## Required OpenMLS Primitives to Expose

### Provider & Storage
- Construct a provider backed by `openmls_rust_crypto::RustCrypto` + `openmls_memory_storage::MemoryStorage` (`vendor/openmls-ffi/src/lib.rs`, `nostr-mls/src/lib.rs:69-112`).
- Access to `OpenMlsProvider::storage/crypto/rand` so MLS objects can load and persist (`groups.rs:302`, `messages.rs:107`).

### Identity & Credentials
- `BasicCredential::new` and `CredentialWithKey` construction (`key_packages.rs:153-166`).
- `SignatureKeyPair::new`, `.store`, `.public`, `.read` for signer management (`key_packages.rs:158-166`, `groups.rs:279-288`).
- `NewSignerBundle` and `LeafNodeParameters::builder` for self-updates (`groups.rs:314-363`).

### Key Packages
- `KeyPackage::builder`, `.leaf_node_capabilities`, `.mark_as_last_resort`, `.build` (`key_packages.rs:47-55`).
- `KeyPackageBundle::key_package()` and TLS serialization via `tls_codec` (`key_packages.rs:57, 83-100`).
- `KeyPackageIn::tls_deserialize` + `.validate` with `ProtocolVersion::Mls10` (`key_packages.rs:94-99`).
- `KeyPackage::hash_ref` for storage cleanup (`key_packages.rs:122-127`).

### Group Configuration & Extensions
- `Capabilities::new` and `RequiredCapabilitiesExtension::new` (`lib.rs:107-141`, `groups.rs:861`).
- `Extension::Unknown`, `Extensions::from_vec` for embedding `NostrGroupDataExtension` (`groups.rs:860-867`, `extension.rs:193-205`).
- `MlsGroupCreateConfig::builder` setters (`groups.rs:870-877`).
- Random group IDs handled via `GroupContext`/extension serialization (`extension.rs:23-220`).

### Group Lifecycle & Membership
- `MlsGroup::new` (`groups.rs:885-887`).
- `MlsGroup::load`, `.group_id`, `.epoch` (`groups.rs:302-304`, `messages.rs:557-569`).
- `MlsGroup::add_members`, `.remove_members`, `.leave_group` (`groups.rs:895-918`, `485-520`, `374-416`).
- `MlsGroup::merge_pending_commit`, `.merge_staged_commit` (`groups.rs:900, 1117`; `messages.rs:475-487`).
- `MlsGroup::members`, `.member_at`, `.own_leaf` for admin checks (`groups.rs:562-577`, `add_members` loop).
- `LeafNodeIndex::new` for removals (`groups.rs:503-516`).
- `MlsGroup::commit_to_pending_proposals`, `.store_pending_proposal` (`messages.rs:392-410`).

### Messaging
- `MlsGroup::create_message` and TLS serialization of `MlsMessageOut` (`messages.rs:119-123`).
- `MlsMessageIn::tls_deserialize_exact`, `.try_into_protocol_message` (`messages.rs:235-244`).
- `MlsGroup::process_message` returning `ProcessedMessage` (`messages.rs:245-253`).
- `ProcessedMessage::into_content` variants: `ApplicationMessage`, `QueuedProposal`, `StagedCommit`, `ExternalJoinProposal` (`messages.rs:256-318, 360-488`).
- `ApplicationMessage::into_bytes` for Nostr event reconstruction (`messages.rs:282-296`).

### Welcome / Join Pipeline
- `MlsMessageIn::tls_deserialize` and `MlsMessageBodyIn::Welcome` (`welcomes.rs:243-267`).
- `MlsGroupJoinConfig::builder` (`welcomes.rs:254-263`).
- `StagedWelcome::new_from_welcome`, `.group_context`, `.into_group` (`welcomes.rs:260-278`).
- `GroupContext::group_id`, `.epoch`, `.extensions` for extension extraction (`welcomes.rs:263-268`, `extension.rs:182-219`).

### Exporter Secrets & Encryption Helpers
- `MlsGroup::export_secret` for `GroupExporterSecret` derivation (`groups.rs:320-352`, `messages.rs:897-916`).
- Access to epochs for backfill decryption (`messages.rs:833-867`).

### Error & Type Surfaces
- Map `ProcessMessageError`, `ValidationError`, `MlsGroupStateError` used in control flow (`messages.rs:205-215, 698-773`).
- Support enums `Sender`, `QueuedProposal`, `StagedCommit`, `Welcome`, `GroupInfo` as opaque handles or tagged unions exposed through the FFI results (`messages.rs:364-415`, `groups.rs:895-918`).
- TLS helpers from `tls_codec` for (de)serialization of messages, welcomes, group info, and extensions.

## Implementation Phases & Progress

> Status: Phase 4 completed after wiring membership mutation FFI and Zig coverage; phases 5-6 remain.


1. **Identity Foundations** *(complete)*
   - ✅ `openmls_ffi_provider_*` exposes RustCrypto + memory storage.
   - ✅ `openmls_ffi_key_package_create` handles credential + signer generation and TLS serialization.
   - ✅ Zig test harness imports the header and exercises provider/key package creation.

2. **Group Creation & Persistence** *(complete)*
   - ✅ `openmls_ffi_group_create` wraps `MlsGroup::new`, member addition, welcome serialization, and TLS output.
   - ✅ Crate refactored into focused modules (`buffer`, `provider`, `key_packages`, `groups`, `welcomes`, `messages`, `helpers`) to keep files short.

3. **Welcome Handling & Messaging Pipeline** *(complete for application messages)*
   - ✅ `openmls_ffi_welcome_parse`, `_welcome_join`, `_welcome_free` expose the staged join flow.
   - ✅ `openmls_ffi_message_encrypt` / `_message_decrypt` round-trip application messages.
   - ✅ Zig test (`tests/openmls_ffi.zig`) covers group creation, welcome join, and encrypt/decrypt.

4. **Membership Mutations** *(complete for staged commits)*
   - ✅ FFI exports wrap add/remove/self-update/leave plus merge helpers and hand back commit/welcome/group-info payloads.
   - ✅ Zig integration test now exercises add->welcome join, removal, self-update, and leave flows.
   - ✅ `nix run .#ci` bootstraps the OpenMLS workspace, builds the Rust bridge, and runs the Zig FFI test end-to-end.

5. **Exporter Secrets & Multi-Epoch Support** *(planned)*
   - TODO: Expose exporter secret helpers so Zig can manage NIP-44 keys and multi-epoch decrypt attempts.

6. **Error Surfaces & Utilities** *(ongoing)*
   - TODO: Map OpenMLS error enums into richer FFI status codes; provide convenience serializers for group metadata.
   - TODO: Polish Linux libc discovery so CI runs without extra environment overrides.

This progress log mirrors every OpenMLS interaction exercised by `mls_memory.rs`. Completing the remaining phases will let us reproduce the entire flow from Zig.
