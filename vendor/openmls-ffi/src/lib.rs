mod status;

use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::OnceLock;

pub use status::{openmls_status_t, OPENMLS_STATUS_OK};

static VERSION_CSTRING: OnceLock<CString> = OnceLock::new();

/// Returns a pointer to a static, null-terminated string describing the FFI layer version.
/// Caller must not free the returned pointer.
#[no_mangle]
pub extern "C" fn openmls_ffi_version() -> *const c_char {
    VERSION_CSTRING
        .get_or_init(|| {
            CString::new(env!("CARGO_PKG_VERSION"))
                .expect("crate version should not contain null bytes")
        })
        .as_ptr()
}

/// Simple smoketest that instantiates the default crypto provider and returns OK.
#[no_mangle]
pub extern "C" fn openmls_ffi_smoketest() -> openmls_status_t {
    let provider = openmls_rust_crypto::RustCrypto::default();
    let _ = provider; // suppress unused
    OPENMLS_STATUS_OK
}
