use std::ffi::{c_char, c_void, CString};
use std::sync::OnceLock;

use openmls::prelude::*;
use openmls_memory_storage::MemoryStorage;

use crate::status::{openmls_status_t, OPENMLS_STATUS_OK};

static VERSION_CSTRING: OnceLock<CString> = OnceLock::new();

#[derive(Debug)]
pub(crate) struct FfiProvider {
    pub(crate) crypto: openmls_rust_crypto::RustCrypto,
    pub(crate) storage: MemoryStorage,
}

impl FfiProvider {
    pub(crate) fn new_default() -> Self {
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

pub(crate) fn provider_mut<'a>(provider: *mut c_void) -> Option<&'a mut FfiProvider> {
    (!provider.is_null()).then(|| unsafe { &mut *(provider as *mut FfiProvider) })
}

#[no_mangle]
pub extern "C" fn openmls_ffi_version() -> *const c_char {
    VERSION_CSTRING
        .get_or_init(|| {
            CString::new(env!("CARGO_PKG_VERSION"))
                .expect("crate version should not contain null bytes")
        })
        .as_ptr()
}

#[no_mangle]
pub extern "C" fn openmls_ffi_smoketest() -> openmls_status_t {
    let provider = FfiProvider::new_default();
    let _ = provider;
    OPENMLS_STATUS_OK
}

#[no_mangle]
pub extern "C" fn openmls_ffi_provider_new_default() -> *mut c_void {
    let provider = Box::new(FfiProvider::new_default());
    Box::into_raw(provider) as *mut c_void
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_provider_free(provider: *mut c_void) {
    if !provider.is_null() {
        drop(Box::from_raw(provider as *mut FfiProvider));
    }
}
