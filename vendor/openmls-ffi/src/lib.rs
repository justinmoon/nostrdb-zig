mod status;

use std::ffi::{c_char, c_void, CString};
use std::sync::OnceLock;

use openmls::prelude::OpenMlsProvider;
use openmls_memory_storage::MemoryStorage;

pub use status::{openmls_status_t, OPENMLS_STATUS_OK};

static VERSION_CSTRING: OnceLock<CString> = OnceLock::new();

struct FfiProvider {
    crypto: openmls_rust_crypto::RustCrypto,
    storage: MemoryStorage,
}

impl FfiProvider {
    fn new_default() -> Self {
        Self {
            crypto: openmls_rust_crypto::RustCrypto::default(),
            storage: MemoryStorage::default(),
        }
    }
}

impl OpenMlsProvider for FfiProvider {
    type CryptoProvider = openmls_rust_crypto::RustCrypto;
    type RandProvider = openmls_rust_crypto::RustCrypto;
    type StorageProvider = MemoryStorage;

    fn storage(&self) -> &Self::StorageProvider {
        &self.storage
    }

    fn crypto(&self) -> &Self::CryptoProvider {
        &self.crypto
    }

    fn rand(&self) -> &Self::RandProvider {
        &self.crypto
    }
}

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
    let provider = FfiProvider::new_default();
    let _ = provider; // suppress unused
    OPENMLS_STATUS_OK
}

/// Creates a new provider backed by RustCrypto and in-memory storage.
///
/// The caller takes ownership of the returned pointer and must release it with
/// [`openmls_ffi_provider_free`].
#[no_mangle]
pub extern "C" fn openmls_ffi_provider_new_default() -> *mut c_void {
    let provider = Box::new(FfiProvider::new_default());
    Box::into_raw(provider) as *mut c_void
}

/// Releases a provider created by [`openmls_ffi_provider_new_default`].
#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_provider_free(provider: *mut c_void) {
    if !provider.is_null() {
        drop(Box::from_raw(provider as *mut FfiProvider));
    }
}
