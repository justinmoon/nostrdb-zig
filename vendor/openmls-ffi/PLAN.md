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

## Implementation Phases (Suggested Order)

1. **Identity Foundations**
   - Extend FFI with credential/keypair generation, storage access, and key package build/parse APIs.
   - Surface `Capabilities` + extension helpers so Zig can reproduce `create_key_package_for_event`.

2. **Group Creation & Persistence**
   - Bind `MlsGroupCreateConfig`, `MlsGroup::new`, member addition, welcome serialization, and `MlsGroup::load/merge_pending_commit`.
   - Expose helpers to read/write `NostrGroupDataExtension` (raw bytes + convenience parsing).

3. **Messaging Pipeline**
   - Provide message creation (`MlsGroup::create_message`), exporter secret export, and decrypt/process routines (`MlsMessageIn`, `ProcessedMessageContent`).
   - Return structured results so Zig can distinguish application/proposal/commit cases.

4. **Membership Mutations**
   - Bind add/remove/self-update/leave entrypoints, including proposal handling and staged commit merges.
   - Ensure Leaf node/admin checks can be implemented (either via callbacks or extra FFI queries).

5. **Welcome Handling & Multi-epoch Support**
   - Finish welcome parsing/accept flows (`StagedWelcome`), group join configs, and exporter secret caching required for epoch backfill.

6. **Error Surfaces & Utilities**
   - Standardize error enums/structs returned across functions (wrapping `ProcessMessageError`, `ValidationError`, etc.).
   - Add serialization helpers for welcomes, commits, group info to avoid duplicating TLS handling in Zig.

This inventory mirrors every OpenMLS interaction exercised by `mls_memory.rs`. Implementing the phases in order ensures we can re-create the script end-to-end from Zig once each block is complete.
