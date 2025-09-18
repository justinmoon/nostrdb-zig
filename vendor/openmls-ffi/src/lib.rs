mod status;

use std::convert::TryFrom;
use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;
use std::slice;
use std::sync::OnceLock;

use openmls::extensions::{
    Extension, ExtensionType, Extensions, RequiredCapabilitiesExtension, UnknownExtension,
};
use openmls::key_packages::{KeyPackage, KeyPackageIn};
use openmls::prelude::*;
use openmls::treesync::RatchetTreeIn;
use openmls::versions::ProtocolVersion;
use openmls_basic_credential::SignatureKeyPair;
use openmls_memory_storage::MemoryStorage;
use tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};

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

#[repr(C)]
pub struct OpenmlsExtensionInput {
    pub extension_type: u16,
    pub data: OpenmlsFfiBuffer,
}

struct FfiStagedWelcome {
    staged: Option<StagedWelcome>,
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

unsafe fn read_buffer_slice<'a>(buffer: &OpenmlsFfiBuffer) -> Result<&'a [u8], openmls_status_t> {
    if buffer.len == 0 {
        if buffer.data.is_null() {
            return Ok(&[]);
        }
    }

    if buffer.data.is_null() && buffer.len > 0 {
        return Err(OPENMLS_STATUS_NULL_POINTER);
    }

    Ok(slice::from_raw_parts(buffer.data, buffer.len))
}

unsafe fn buffer_to_vec(buffer: &OpenmlsFfiBuffer) -> Result<Vec<u8>, openmls_status_t> {
    Ok(read_buffer_slice(buffer)?.to_vec())
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

    let mut extension_types_vec: Vec<ExtensionType> = extensions_slice
        .iter()
        .map(|ext| ExtensionType::from(*ext))
        .collect();
    if mark_as_last_resort && !extension_types_vec.contains(&ExtensionType::LastResort) {
        extension_types_vec.push(ExtensionType::LastResort);
    }

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

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_group_create(
    provider: *mut c_void,
    creator_identity_hex: *const c_char,
    ciphersuite_value: u16,
    required_extension_types: *const u16,
    required_extension_len: usize,
    additional_extensions: *const OpenmlsExtensionInput,
    additional_extensions_len: usize,
    key_packages: *const OpenmlsFfiBuffer,
    key_package_len: usize,
    use_ratchet_tree_extension: bool,
    out_group_id: *mut OpenmlsFfiBuffer,
    out_commit_message: *mut OpenmlsFfiBuffer,
    out_welcome_message: *mut OpenmlsFfiBuffer,
    out_group_info: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match ffi_provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if creator_identity_hex.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    if key_packages.is_null() && key_package_len > 0 {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let creator_identity = match CStr::from_ptr(creator_identity_hex).to_str() {
        Ok(s) => s,
        Err(_) => return OPENMLS_STATUS_INVALID_ARGUMENT,
    };

    let ciphersuite = match Ciphersuite::try_from(ciphersuite_value) {
        Ok(cs) => cs,
        Err(_) => return OPENMLS_STATUS_INVALID_ARGUMENT,
    };

    let required_extension_types_slice = if required_extension_types.is_null() {
        &[][..]
    } else {
        slice::from_raw_parts(required_extension_types, required_extension_len)
    };

    let additional_extensions_slice = if additional_extensions.is_null() {
        &[][..]
    } else {
        slice::from_raw_parts(additional_extensions, additional_extensions_len)
    };

    let key_package_slice = if key_package_len == 0 {
        &[][..]
    } else {
        slice::from_raw_parts(key_packages, key_package_len)
    };

    let credential = BasicCredential::new(creator_identity.as_bytes().to_vec());
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

    let required_extension_types_vec: Vec<ExtensionType> = required_extension_types_slice
        .iter()
        .map(|ext| ExtensionType::from(*ext))
        .collect();

    let mut capability_extension_types = required_extension_types_vec.clone();
    for extension in additional_extensions_slice {
        let ext_type = ExtensionType::from(extension.extension_type);
        if !capability_extension_types.contains(&ext_type) {
            capability_extension_types.push(ext_type);
        }
    }

    let capabilities = if capability_extension_types.is_empty() {
        Capabilities::new(None, Some(&[ciphersuite]), None, None, None)
    } else {
        Capabilities::new(
            None,
            Some(&[ciphersuite]),
            Some(capability_extension_types.as_slice()),
            None,
            None,
        )
    };

    let mut group_extensions: Vec<Extension> = Vec::new();
    if !required_extension_types_vec.is_empty() {
        let required_extension =
            RequiredCapabilitiesExtension::new(required_extension_types_vec.as_slice(), &[], &[]);
        group_extensions.push(Extension::RequiredCapabilities(required_extension));
    }

    for extension in additional_extensions_slice {
        let data = match buffer_to_vec(&extension.data) {
            Ok(vec) => vec,
            Err(status) => return status,
        };
        group_extensions.push(Extension::Unknown(
            extension.extension_type,
            UnknownExtension(data),
        ));
    }

    let mut group_config_builder = MlsGroupCreateConfig::builder()
        .ciphersuite(ciphersuite)
        .use_ratchet_tree_extension(use_ratchet_tree_extension)
        .capabilities(capabilities);

    if !group_extensions.is_empty() {
        match Extensions::from_vec(group_extensions) {
            Ok(extensions) => {
                group_config_builder =
                    match group_config_builder.with_group_context_extensions(extensions) {
                        Ok(builder) => builder,
                        Err(_) => return OPENMLS_STATUS_ERROR,
                    }
            }
            Err(_) => return OPENMLS_STATUS_ERROR,
        }
    }

    let group_config = group_config_builder.build();

    let mut mls_group = match MlsGroup::new(
        provider,
        &signature_keypair,
        &group_config,
        credential_with_key,
    ) {
        Ok(group) => group,
        Err(_) => return OPENMLS_STATUS_ERROR,
    };

    let mut parsed_key_packages = Vec::with_capacity(key_package_slice.len());
    for buffer in key_package_slice.iter() {
        let key_package_bytes = match buffer_to_vec(buffer) {
            Ok(vec) => vec,
            Err(status) => return status,
        };
        let mut cursor = key_package_bytes.as_slice();
        let key_package_in = match KeyPackageIn::tls_deserialize(&mut cursor) {
            Ok(kp) => kp,
            Err(_) => return OPENMLS_STATUS_ERROR,
        };
        let key_package = match key_package_in.validate(provider.crypto(), ProtocolVersion::Mls10) {
            Ok(kp) => kp,
            Err(_) => return OPENMLS_STATUS_ERROR,
        };
        parsed_key_packages.push(key_package);
    }

    let (commit_message, welcome_message, group_info) =
        match mls_group.add_members(provider, &signature_keypair, &parsed_key_packages) {
            Ok(result) => result,
            Err(_) => return OPENMLS_STATUS_ERROR,
        };

    if mls_group.merge_pending_commit(provider).is_err() {
        return OPENMLS_STATUS_ERROR;
    }

    if !out_group_id.is_null() {
        let group_id = mls_group.group_id().to_vec();
        ptr::write(out_group_id, OpenmlsFfiBuffer::from_vec(group_id));
    }

    if !out_commit_message.is_null() {
        let commit_bytes = match commit_message.tls_serialize_detached() {
            Ok(bytes) => bytes,
            Err(_) => return OPENMLS_STATUS_ERROR,
        };
        ptr::write(out_commit_message, OpenmlsFfiBuffer::from_vec(commit_bytes));
    }

    if !out_welcome_message.is_null() {
        let welcome_bytes = match welcome_message.tls_serialize_detached() {
            Ok(bytes) => bytes,
            Err(_) => return OPENMLS_STATUS_ERROR,
        };
        ptr::write(
            out_welcome_message,
            OpenmlsFfiBuffer::from_vec(welcome_bytes),
        );
    }

    if !out_group_info.is_null() {
        if let Some(group_info) = group_info {
            let info_bytes = match group_info.tls_serialize_detached() {
                Ok(bytes) => bytes,
                Err(_) => return OPENMLS_STATUS_ERROR,
            };
            ptr::write(out_group_info, OpenmlsFfiBuffer::from_vec(info_bytes));
        } else {
            ptr::write(
                out_group_info,
                OpenmlsFfiBuffer {
                    data: ptr::null_mut(),
                    len: 0,
                },
            );
        }
    }

    OPENMLS_STATUS_OK
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_welcome_parse(
    provider: *mut c_void,
    welcome_message: *const OpenmlsFfiBuffer,
    ratchet_tree: *const OpenmlsFfiBuffer,
    use_ratchet_tree_extension: bool,
    out_staged_welcome: *mut *mut c_void,
    out_group_context: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match ffi_provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if welcome_message.is_null() || out_staged_welcome.is_null() || out_group_context.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let welcome_slice = match read_buffer_slice(&*welcome_message) {
        Ok(slice) => slice,
        Err(status) => return status,
    };

    if welcome_slice.is_empty() {
        return OPENMLS_STATUS_INVALID_ARGUMENT;
    }

    let mut cursor = welcome_slice;
    let message_in = match MlsMessageIn::tls_deserialize(&mut cursor) {
        Ok(msg) => msg,
        Err(err) => {
            eprintln!("openmls_ffi_welcome_parse: deserialize error: {:?}", err);
            return OPENMLS_STATUS_ERROR;
        }
    };

    let welcome = match message_in.extract() {
        MlsMessageBodyIn::Welcome(welcome) => welcome,
        other => {
            eprintln!(
                "openmls_ffi_welcome_parse: unexpected message body: {:?}",
                other
            );
            return OPENMLS_STATUS_INVALID_ARGUMENT;
        }
    };

    let join_config = MlsGroupJoinConfig::builder()
        .use_ratchet_tree_extension(use_ratchet_tree_extension)
        .build();

    let ratchet_tree_option = if ratchet_tree.is_null() || (*ratchet_tree).len == 0 {
        None
    } else {
        let tree_slice = match read_buffer_slice(&*ratchet_tree) {
            Ok(slice) => slice,
            Err(status) => return status,
        };
        match RatchetTreeIn::tls_deserialize_exact(tree_slice) {
            Ok(tree) => Some(tree),
            Err(err) => {
                eprintln!("openmls_ffi_welcome_parse: ratchet tree error: {:?}", err);
                return OPENMLS_STATUS_ERROR;
            }
        }
    };

    let staged_welcome =
        match StagedWelcome::new_from_welcome(provider, &join_config, welcome, ratchet_tree_option)
        {
            Ok(staged) => staged,
            Err(err) => {
                eprintln!("openmls_ffi_welcome_parse: staged welcome error: {:?}", err);
                return OPENMLS_STATUS_ERROR;
            }
        };

    let group_context_bytes = match staged_welcome.group_context().tls_serialize_detached() {
        Ok(bytes) => bytes,
        Err(_) => return OPENMLS_STATUS_ERROR,
    };

    ptr::write(
        out_group_context,
        OpenmlsFfiBuffer::from_vec(group_context_bytes),
    );

    let staged = Box::new(FfiStagedWelcome {
        staged: Some(staged_welcome),
    });
    ptr::write(out_staged_welcome, Box::into_raw(staged) as *mut c_void);

    OPENMLS_STATUS_OK
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_welcome_join(
    provider: *mut c_void,
    staged_welcome: *mut c_void,
    out_group_id: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match ffi_provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if staged_welcome.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let staged = &mut *(staged_welcome as *mut FfiStagedWelcome);
    let staged_welcome = match staged.staged.take() {
        Some(staged) => staged,
        None => return OPENMLS_STATUS_ERROR,
    };

    let group = match staged_welcome.into_group(provider) {
        Ok(group) => group,
        Err(_) => return OPENMLS_STATUS_ERROR,
    };

    if !out_group_id.is_null() {
        let group_id = group.group_id().to_vec();
        ptr::write(out_group_id, OpenmlsFfiBuffer::from_vec(group_id));
    }

    OPENMLS_STATUS_OK
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_welcome_free(staged_welcome: *mut c_void) {
    if !staged_welcome.is_null() {
        drop(Box::from_raw(staged_welcome as *mut FfiStagedWelcome));
    }
}
