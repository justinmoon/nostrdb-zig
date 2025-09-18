use std::ffi::{c_char, CStr};
use std::os::raw::c_void;
use std::ptr;
use std::slice;

use openmls::extensions::{
    Extension, ExtensionType, Extensions, RequiredCapabilitiesExtension, UnknownExtension,
};
use openmls::key_packages::KeyPackageIn;
use openmls::prelude::tls_codec::{Deserialize, Serialize};
use openmls::prelude::*;
use openmls::versions::ProtocolVersion;
use openmls_basic_credential::SignatureKeyPair;

use crate::buffer::{buffer_to_vec, OpenmlsExtensionInput, OpenmlsFfiBuffer};
use crate::provider::provider_mut;
use crate::status::{
    openmls_status_t, OPENMLS_STATUS_ERROR, OPENMLS_STATUS_INVALID_ARGUMENT,
    OPENMLS_STATUS_NULL_POINTER, OPENMLS_STATUS_OK,
};

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
    let provider = match provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if creator_identity_hex.is_null() || (key_packages.is_null() && key_package_len > 0) {
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
            Err(err) => {
                eprintln!(
                    "openmls_ffi_group_create: key package validation error: {:?}",
                    err
                );
                return OPENMLS_STATUS_ERROR;
            }
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
            ptr::write(out_group_info, OpenmlsFfiBuffer::empty());
        }
    }

    OPENMLS_STATUS_OK
}
