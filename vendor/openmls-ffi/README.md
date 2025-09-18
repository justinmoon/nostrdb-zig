# openmls-ffi

This crate wraps the Rust OpenMLS implementation with a C-compatible interface. Building the
crate (e.g. via `cargo build --release`) generates two artifacts:

- `target/{debug,release}/libopenmls_ffi.{a,dylib,so}` – link this static or dynamic library into
  the Zig project.
- `include/openmls_ffi.h` – a generated header produced by `cbindgen` that defines the exported
  symbols and status codes.

To use from Zig:

1. Call `cargo build --release -p openmls-ffi` from the repository root (the `build.zig` script can
   spawn this step during the link phase).
2. Add `vendor/openmls-ffi/include` to the include search path and import the header with
   `@cImport({ @cInclude("openmls_ffi.h"); });`.
3. Link against `openmls_ffi` by adding the appropriate library search path and `-lopenmls_ffi`.

The library currently exposes discovery helpers (`openmls_ffi_version`,
`openmls_ffi_smoketest`), a default provider constructor
(`openmls_ffi_provider_new_default` / `openmls_ffi_provider_free`), key package construction
(`openmls_ffi_key_package_create`, `openmls_ffi_buffer_free`), initial group creation
(`openmls_ffi_group_create`), welcome processing (`openmls_ffi_welcome_parse`,
`openmls_ffi_welcome_join`, `openmls_ffi_welcome_free`), and basic message handling
(`openmls_ffi_message_encrypt`, `openmls_ffi_message_decrypt`). Additional bindings will extend
the header automatically when new APIs are exported.
