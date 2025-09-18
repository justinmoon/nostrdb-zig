mod status;

use std::convert::TryFrom;
use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;
use std::slice;
use std::sync::OnceLock;

use openmls::extensions::ExtensionType;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_memory_storage::MemoryStorage;
use tls_codec::Serialize as TlsSerialize;

pub use status::{
    openmls_status_t, OPENMLS_STATUS_ERROR, OPENMLS_STATUS_INVALID_ARGUMENT,
    OPENMLS_STATUS_NULL_POINTER, OPENMLS_STATUS_OK,
};

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

#[repr(C)]
pub struct OpenmlsFfiBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl OpenmlsFfiBuffer {
    fn from_vec(vec: Vec<u8>) -> Self {
        let mut boxed = vec.into_boxed_slice();
        let data = boxed.as_mut_ptr();
        let len = boxed.len();
        std::mem::forget(boxed);
        Self { data, len }
    }
}

fn ffi_provider_mut<'a>(provider: *mut c_void) -> Option<&'a mut FfiProvider> {
    (!provider.is_null()).then(|| unsafe { &mut *(provider as *mut FfiProvider) })
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

/// Releases memory owned by the FFI layer.
#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_buffer_free(buffer: OpenmlsFfiBuffer) {
    if !buffer.data.is_null() && buffer.len > 0 {
        drop(Vec::from_raw_parts(buffer.data, buffer.len, buffer.len));
    }
}

/// Builds a key package for publishing to relays.
#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_key_package_create(
    provider: *mut c_void,
    identity_hex: *const c_char,
    ciphersuite_value: u16,
    extension_types: *const u16,
    extension_len: usize,
    mark_as_last_resort: bool,
    out_key_package: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match ffi_provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if identity_hex.is_null() || out_key_package.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let identity_str = match CStr::from_ptr(identity_hex).to_str() {
        Ok(s) => s,
        Err(_) => return OPENMLS_STATUS_INVALID_ARGUMENT,
    };

    let ciphersuite = match Ciphersuite::try_from(ciphersuite_value) {
        Ok(cs) => cs,
        Err(_) => return OPENMLS_STATUS_INVALID_ARGUMENT,
    };

    let extensions_slice = if extension_types.is_null() {
        &[][..]
    } else {
        slice::from_raw_parts(extension_types, extension_len)
    };

    let extension_types_vec: Vec<ExtensionType> = extensions_slice
        .iter()
        .map(|ext| ExtensionType::from(*ext))
        .collect();

    let credential = BasicCredential::new(identity_str.as_bytes().to_vec());
    let signature_scheme = ciphersuite.signature_algorithm();

    let signature_keypair = match SignatureKeyPair::new(signature_scheme) {
        Ok(pair) => pair,
        Err(_) => return OPENMLS_STATUS_ERROR,
    };

    if signature_keypair.store(provider.storage()).is_err() {
        return OPENMLS_STATUS_ERROR;
    }

    let credential_with_key = CredentialWithKey {
        credential: credential.clone().into(),
        signature_key: signature_keypair.public().into(),
    };

    let capabilities = if extension_types_vec.is_empty() {
        Capabilities::new(None, Some(&[ciphersuite]), None, None, None)
    } else {
        Capabilities::new(
            None,
            Some(&[ciphersuite]),
            Some(extension_types_vec.as_slice()),
            None,
            None,
        )
    };

    let mut builder = KeyPackage::builder().leaf_node_capabilities(capabilities);
    if mark_as_last_resort {
        builder = builder.mark_as_last_resort();
    }

    let key_package_bundle = match builder.build(
        ciphersuite,
        provider,
        &signature_keypair,
        credential_with_key,
    ) {
        Ok(bundle) => bundle,
        Err(_) => return OPENMLS_STATUS_ERROR,
    };

    let serialized = match key_package_bundle.key_package().tls_serialize_detached() {
        Ok(bytes) => bytes,
        Err(_) => return OPENMLS_STATUS_ERROR,
    };

    ptr::write(out_key_package, OpenmlsFfiBuffer::from_vec(serialized));
    OPENMLS_STATUS_OK
}
