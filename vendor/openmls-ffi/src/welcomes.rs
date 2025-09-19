use std::os::raw::c_void;
use std::ptr;

use openmls::framing::{MlsMessageBodyIn, MlsMessageIn};
use openmls::group::{MlsGroupJoinConfig, StagedWelcome};
use openmls::prelude::tls_codec::{Deserialize, Serialize};
use openmls::treesync::RatchetTreeIn;

use crate::buffer::{read_buffer_slice, OpenmlsFfiBuffer};
use crate::provider::provider_mut;
use crate::status::{
    openmls_status_t, OPENMLS_STATUS_ERROR, OPENMLS_STATUS_INVALID_ARGUMENT,
    OPENMLS_STATUS_NULL_POINTER, OPENMLS_STATUS_OK,
};

pub(crate) struct FfiStagedWelcome {
    pub(crate) staged: Option<StagedWelcome>,
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
    let provider = match provider_mut(provider) {
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
    let provider = match provider_mut(provider) {
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
