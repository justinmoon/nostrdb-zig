use std::ffi::{c_char, CStr};
use std::os::raw::c_void;
use std::ptr;
use std::slice;

use openmls::extensions::ExtensionType;
use openmls::prelude::tls_codec::Serialize;
use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;

use crate::buffer::OpenmlsFfiBuffer;
use crate::provider::provider_mut;
use crate::status::{
    openmls_status_t, OPENMLS_STATUS_ERROR, OPENMLS_STATUS_INVALID_ARGUMENT,
    OPENMLS_STATUS_NULL_POINTER, OPENMLS_STATUS_OK,
};

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
    let provider = match provider_mut(provider) {
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
