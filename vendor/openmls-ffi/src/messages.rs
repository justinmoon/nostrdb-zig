use std::os::raw::c_void;
use std::ptr;

use openmls::framing::{MlsMessageIn, ProcessedMessageContent};
use openmls::prelude::tls_codec::{Deserialize, Serialize};

use crate::buffer::{read_buffer_slice, OpenmlsFfiBuffer, OpenmlsProcessedMessageType};
use crate::helpers::{load_group_and_id, load_signer};
use crate::provider::provider_mut;
use crate::status::{
    openmls_status_t, OPENMLS_STATUS_ERROR, OPENMLS_STATUS_NULL_POINTER, OPENMLS_STATUS_OK,
};

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_message_encrypt(
    provider: *mut c_void,
    group_id: *const OpenmlsFfiBuffer,
    plaintext: *const OpenmlsFfiBuffer,
    out_ciphertext: *mut OpenmlsFfiBuffer,
) -> openmls_status_t {
    let provider = match provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if group_id.is_null() || plaintext.is_null() || out_ciphertext.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    let (mut group, _) = match load_group_and_id(provider, &*group_id) {
        Ok(value) => value,
        Err(status) => return status,
    };

    let signer = match load_signer(provider, &group) {
        Ok(signer) => signer,
        Err(status) => return status,
    };

    let plaintext_slice = match read_buffer_slice(&*plaintext) {
        Ok(slice) => slice,
        Err(status) => return status,
    };

    let message = match group.create_message(provider, &signer, plaintext_slice) {
        Ok(message) => message,
        Err(_) => return OPENMLS_STATUS_ERROR,
    };

    let ciphertext = match message.tls_serialize_detached() {
        Ok(bytes) => bytes,
        Err(_) => return OPENMLS_STATUS_ERROR,
    };

    ptr::write(out_ciphertext, OpenmlsFfiBuffer::from_vec(ciphertext));
    OPENMLS_STATUS_OK
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_message_decrypt(
    provider: *mut c_void,
    group_id: *const OpenmlsFfiBuffer,
    ciphertext: *const OpenmlsFfiBuffer,
    out_plaintext: *mut OpenmlsFfiBuffer,
    out_message_type: *mut OpenmlsProcessedMessageType,
) -> openmls_status_t {
    let provider = match provider_mut(provider) {
        Some(provider) => provider,
        None => return OPENMLS_STATUS_NULL_POINTER,
    };

    if group_id.is_null() || ciphertext.is_null() || out_message_type.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    if !out_plaintext.is_null() {
        (*out_plaintext).data = ptr::null_mut();
        (*out_plaintext).len = 0;
    }

    let (mut group, _) = match load_group_and_id(provider, &*group_id) {
        Ok(value) => value,
        Err(status) => return status,
    };

    let ciphertext_slice = match read_buffer_slice(&*ciphertext) {
        Ok(slice) => slice,
        Err(status) => return status,
    };

    let mls_message = match MlsMessageIn::tls_deserialize_exact(ciphertext_slice) {
        Ok(message) => message,
        Err(err) => {
            eprintln!("openmls_ffi_message_decrypt: deserialize error: {:?}", err);
            return OPENMLS_STATUS_ERROR;
        }
    };

    let protocol_message = match mls_message.try_into_protocol_message() {
        Ok(message) => message,
        Err(err) => {
            eprintln!(
                "openmls_ffi_message_decrypt: protocol conversion error: {:?}",
                err
            );
            return OPENMLS_STATUS_ERROR;
        }
    };

    let processed = match group.process_message(provider, protocol_message) {
        Ok(processed) => processed,
        Err(err) => {
            eprintln!("openmls_ffi_message_decrypt: process error: {:?}", err);
            return OPENMLS_STATUS_ERROR;
        }
    };

    match processed.into_content() {
        ProcessedMessageContent::ApplicationMessage(application_message) => {
            if !out_plaintext.is_null() {
                let bytes = application_message.into_bytes();
                ptr::write(out_plaintext, OpenmlsFfiBuffer::from_vec(bytes));
            }
            ptr::write(out_message_type, OpenmlsProcessedMessageType::Application);
        }
        ProcessedMessageContent::ProposalMessage(_) => {
            ptr::write(out_message_type, OpenmlsProcessedMessageType::Proposal);
        }
        ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
            if group.merge_staged_commit(provider, *staged_commit).is_err() {
                return OPENMLS_STATUS_ERROR;
            }
            ptr::write(out_message_type, OpenmlsProcessedMessageType::Commit);
        }
        ProcessedMessageContent::ExternalJoinProposalMessage(_) => {
            ptr::write(
                out_message_type,
                OpenmlsProcessedMessageType::ExternalJoinProposal,
            );
        }
    }

    OPENMLS_STATUS_OK
}
