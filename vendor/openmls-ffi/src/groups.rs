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
use crate::helpers::{load_group_and_id, load_signer};
use crate::provider::{provider_mut, FfiProvider};
use crate::status::{
    openmls_status_t, OPENMLS_STATUS_ERROR, OPENMLS_STATUS_INVALID_ARGUMENT,
    OPENMLS_STATUS_NULL_POINTER, OPENMLS_STATUS_OK,
};

fn parse_key_packages(
    provider: &FfiProvider,
    buffers: &[OpenmlsFfiBuffer],
) -> Result<Vec<KeyPackage>, openmls_status_t> {
    let mut parsed = Vec::with_capacity(buffers.len());
    for buffer in buffers {
        let key_package_bytes = buffer_to_vec(buffer)?;
        let mut cursor = key_package_bytes.as_slice();
        let key_package_in =
            KeyPackageIn::tls_deserialize(&mut cursor).map_err(|_| OPENMLS_STATUS_ERROR)?;
        let key_package = key_package_in
            .validate(provider.crypto(), ProtocolVersion::Mls10)
            .map_err(|err| {
                eprintln!("parse_key_packages: validation error: {:?}", err);
                OPENMLS_STATUS_ERROR
            })?;
        parsed.push(key_package);
    }
    Ok(parsed)
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

    let parsed_key_packages = match parse_key_packages(provider, key_package_slice) {
        Ok(list) => list,
        Err(status) => return status,
    };

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

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_group_add_members(
    provider: *mut c_void,
    group_id: *const OpenmlsFfiBuffer,
    key_packages: *const OpenmlsFfiBuffer,
    key_package_len: usize,
    out_commit_message: *mut OpenmlsFfiBuffer,
    out_welcome_message: *mut OpenmlsFfiBuffer,
    out_group_info: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if group_id.is_null() || (key_packages.is_null() && key_package_len > 0) {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let key_package_slice = if key_package_len == 0 {
        &[][..]
    } else {
        slice::from_raw_parts(key_packages, key_package_len)
    };

    let (mut group, _) = match load_group_and_id(provider, &*group_id) {
        Ok(value) => value,
        Err(status) => return status,
    };

    let signer = match load_signer(&*provider, &group) {
        Ok(signer) => signer,
        Err(status) => return status,
    };

    let parsed_key_packages = match parse_key_packages(&*provider, key_package_slice) {
        Ok(list) => list,
        Err(status) => return status,
    };

    let (commit_message, welcome_message, group_info) =
        match group.add_members(&*provider, &signer, &parsed_key_packages) {
            Ok(result) => result,
            Err(err) => {
                eprintln!(
                    "openmls_ffi_group_add_members: add_members error: {:?}",
                    err
                );
                return OPENMLS_STATUS_ERROR;
            }
        };

    if !out_commit_message.is_null() {
        let commit_bytes = match commit_message.tls_serialize_detached() {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!(
                    "openmls_ffi_group_add_members: commit serialize error: {:?}",
                    err
                );
                return OPENMLS_STATUS_ERROR;
            }
        };
        ptr::write(out_commit_message, OpenmlsFfiBuffer::from_vec(commit_bytes));
    }

    if !out_welcome_message.is_null() {
        let welcome_bytes = match welcome_message.tls_serialize_detached() {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!(
                    "openmls_ffi_group_add_members: welcome serialize error: {:?}",
                    err
                );
                return OPENMLS_STATUS_ERROR;
            }
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
                Err(err) => {
                    eprintln!(
                        "openmls_ffi_group_add_members: group info serialize error: {:?}",
                        err
                    );
                    return OPENMLS_STATUS_ERROR;
                }
            };
            ptr::write(out_group_info, OpenmlsFfiBuffer::from_vec(info_bytes));
        } else {
            ptr::write(out_group_info, OpenmlsFfiBuffer::empty());
        }
    }

    OPENMLS_STATUS_OK
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_group_remove_members(
    provider: *mut c_void,
    group_id: *const OpenmlsFfiBuffer,
    leaf_indices: *const u32,
    leaf_indices_len: usize,
    out_commit_message: *mut OpenmlsFfiBuffer,
    out_welcome_message: *mut OpenmlsFfiBuffer,
    out_group_info: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if group_id.is_null() || (leaf_indices.is_null() && leaf_indices_len > 0) {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    if leaf_indices_len == 0 {
        return OPENMLS_STATUS_INVALID_ARGUMENT;
    }

    let indices_slice = slice::from_raw_parts(leaf_indices, leaf_indices_len);
    let mut members = Vec::with_capacity(indices_slice.len());
    for index in indices_slice {
        members.push(LeafNodeIndex::new(*index));
    }

    let (mut group, _) = match load_group_and_id(provider, &*group_id) {
        Ok(value) => value,
        Err(status) => return status,
    };

    let signer = match load_signer(&*provider, &group) {
        Ok(signer) => signer,
        Err(status) => return status,
    };

    let (commit_message, welcome_message, group_info) =
        match group.remove_members(&*provider, &signer, &members) {
            Ok(result) => result,
            Err(err) => {
                eprintln!(
                    "openmls_ffi_group_remove_members: remove_members error: {:?}",
                    err
                );
                return OPENMLS_STATUS_ERROR;
            }
        };

    if !out_commit_message.is_null() {
        let commit_bytes = match commit_message.tls_serialize_detached() {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!(
                    "openmls_ffi_group_remove_members: commit serialize error: {:?}",
                    err
                );
                return OPENMLS_STATUS_ERROR;
            }
        };
        ptr::write(out_commit_message, OpenmlsFfiBuffer::from_vec(commit_bytes));
    }

    if !out_welcome_message.is_null() {
        if let Some(welcome) = welcome_message {
            let welcome_bytes = match welcome.tls_serialize_detached() {
                Ok(bytes) => bytes,
                Err(err) => {
                    eprintln!(
                        "openmls_ffi_group_remove_members: welcome serialize error: {:?}",
                        err
                    );
                    return OPENMLS_STATUS_ERROR;
                }
            };
            ptr::write(
                out_welcome_message,
                OpenmlsFfiBuffer::from_vec(welcome_bytes),
            );
        } else {
            ptr::write(out_welcome_message, OpenmlsFfiBuffer::empty());
        }
    }

    if !out_group_info.is_null() {
        if let Some(group_info) = group_info {
            let info_bytes = match group_info.tls_serialize_detached() {
                Ok(bytes) => bytes,
                Err(err) => {
                    eprintln!(
                        "openmls_ffi_group_remove_members: group info serialize error: {:?}",
                        err
                    );
                    return OPENMLS_STATUS_ERROR;
                }
            };
            ptr::write(out_group_info, OpenmlsFfiBuffer::from_vec(info_bytes));
        } else {
            ptr::write(out_group_info, OpenmlsFfiBuffer::empty());
        }
    }

    OPENMLS_STATUS_OK
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_group_self_update(
    provider: *mut c_void,
    group_id: *const OpenmlsFfiBuffer,
    out_commit_message: *mut OpenmlsFfiBuffer,
    out_welcome_message: *mut OpenmlsFfiBuffer,
    out_group_info: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if group_id.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let (mut group, _) = match load_group_and_id(provider, &*group_id) {
        Ok(value) => value,
        Err(status) => return status,
    };

    let current_signer = match load_signer(&*provider, &group) {
        Ok(signer) => signer,
        Err(status) => return status,
    };

    let own_leaf = match group.own_leaf() {
        Some(leaf) => leaf.clone(),
        None => return OPENMLS_STATUS_ERROR,
    };

    let new_signature_keypair =
        match SignatureKeyPair::new(group.ciphersuite().signature_algorithm()) {
            Ok(pair) => pair,
            Err(err) => {
                eprintln!(
                    "openmls_ffi_group_self_update: keypair create error: {:?}",
                    err
                );
                return OPENMLS_STATUS_ERROR;
            }
        };

    if new_signature_keypair.store(provider.storage()).is_err() {
        return OPENMLS_STATUS_ERROR;
    }

    let new_basic_credential = match BasicCredential::try_from(own_leaf.credential().clone()) {
        Ok(credential) => credential,
        Err(err) => {
            eprintln!(
                "openmls_ffi_group_self_update: credential conversion error: {:?}",
                err
            );
            return OPENMLS_STATUS_ERROR;
        }
    };

    let new_credential_with_key = CredentialWithKey {
        credential: new_basic_credential.into(),
        signature_key: new_signature_keypair.public().into(),
    };

    let new_signer_bundle = NewSignerBundle {
        signer: &new_signature_keypair,
        credential_with_key: new_credential_with_key.clone(),
    };

    let leaf_node_params = LeafNodeParameters::builder()
        .with_credential_with_key(new_credential_with_key)
        .with_capabilities(own_leaf.capabilities().clone())
        .with_extensions(own_leaf.extensions().clone())
        .build();

    let bundle = match group.self_update_with_new_signer(
        &*provider,
        &current_signer,
        new_signer_bundle,
        leaf_node_params,
    ) {
        Ok(bundle) => bundle,
        Err(err) => {
            eprintln!(
                "openmls_ffi_group_self_update: self_update error: {:?}",
                err
            );
            return OPENMLS_STATUS_ERROR;
        }
    };

    if !out_commit_message.is_null() {
        let commit_bytes = match bundle.commit().tls_serialize_detached() {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!(
                    "openmls_ffi_group_self_update: commit serialize error: {:?}",
                    err
                );
                return OPENMLS_STATUS_ERROR;
            }
        };
        ptr::write(out_commit_message, OpenmlsFfiBuffer::from_vec(commit_bytes));
    }

    if !out_welcome_message.is_null() {
        if let Some(welcome) = bundle.to_welcome_msg() {
            let welcome_bytes = match welcome.tls_serialize_detached() {
                Ok(bytes) => bytes,
                Err(err) => {
                    eprintln!(
                        "openmls_ffi_group_self_update: welcome serialize error: {:?}",
                        err
                    );
                    return OPENMLS_STATUS_ERROR;
                }
            };
            ptr::write(
                out_welcome_message,
                OpenmlsFfiBuffer::from_vec(welcome_bytes),
            );
        } else {
            ptr::write(out_welcome_message, OpenmlsFfiBuffer::empty());
        }
    }

    if !out_group_info.is_null() {
        if let Some(group_info) = bundle.group_info() {
            let info_bytes = match group_info.tls_serialize_detached() {
                Ok(bytes) => bytes,
                Err(err) => {
                    eprintln!(
                        "openmls_ffi_group_self_update: group info serialize error: {:?}",
                        err
                    );
                    return OPENMLS_STATUS_ERROR;
                }
            };
            ptr::write(out_group_info, OpenmlsFfiBuffer::from_vec(info_bytes));
        } else {
            ptr::write(out_group_info, OpenmlsFfiBuffer::empty());
        }
    }

    OPENMLS_STATUS_OK
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_group_leave(
    provider: *mut c_void,
    group_id: *const OpenmlsFfiBuffer,
    out_message: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if group_id.is_null() || out_message.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let (mut group, _) = match load_group_and_id(provider, &*group_id) {
        Ok(value) => value,
        Err(status) => return status,
    };

    let signer = match load_signer(&*provider, &group) {
        Ok(signer) => signer,
        Err(status) => return status,
    };

    let message = match group.leave_group(&*provider, &signer) {
        Ok(message) => message,
        Err(err) => {
            eprintln!("openmls_ffi_group_leave: leave_group error: {:?}", err);
            return OPENMLS_STATUS_ERROR;
        }
    };

    let serialized = match message.tls_serialize_detached() {
        Ok(bytes) => bytes,
        Err(err) => {
            eprintln!("openmls_ffi_group_leave: serialize error: {:?}", err);
            return OPENMLS_STATUS_ERROR;
        }
    };

    ptr::write(out_message, OpenmlsFfiBuffer::from_vec(serialized));
    OPENMLS_STATUS_OK
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_group_merge_pending_commit(
    provider: *mut c_void,
    group_id: *const OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if group_id.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let (mut group, _) = match load_group_and_id(provider, &*group_id) {
        Ok(value) => value,
        Err(status) => return status,
    };

    if let Err(err) = group.merge_pending_commit(&*provider) {
        eprintln!(
            "openmls_ffi_group_merge_pending_commit: merge error: {:?}",
            err
        );
        return OPENMLS_STATUS_ERROR;
    }

    OPENMLS_STATUS_OK
}
