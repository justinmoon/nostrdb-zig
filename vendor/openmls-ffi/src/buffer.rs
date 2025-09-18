use std::ptr;

use crate::status::{OPENMLS_STATUS_NULL_POINTER, OPENMLS_STATUS_OK};

#[repr(C)]
#[derive(Copy, Clone)]
pub struct OpenmlsFfiBuffer {
    pub data: *mut u8,
    pub len: usize,
}

impl OpenmlsFfiBuffer {
    pub fn from_vec(vec: Vec<u8>) -> Self {
        let mut boxed = vec.into_boxed_slice();
        let data = boxed.as_mut_ptr();
        let len = boxed.len();
        std::mem::forget(boxed);
        Self { data, len }
    }

    pub fn empty() -> Self {
        Self {
            data: ptr::null_mut(),
            len: 0,
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct OpenmlsExtensionInput {
    pub extension_type: u16,
    pub data: OpenmlsFfiBuffer,
}

#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum OpenmlsProcessedMessageType {
    Application = 0,
    Proposal = 1,
    Commit = 2,
    ExternalJoinProposal = 3,
    Other = 255,
}

pub fn read_buffer_slice(buffer: &OpenmlsFfiBuffer) -> Result<&[u8], i32> {
    if buffer.len == 0 {
        if buffer.data.is_null() {
            return Ok(&[]);
        }
    }

    if buffer.data.is_null() && buffer.len > 0 {
        return Err(OPENMLS_STATUS_NULL_POINTER);
    }

    unsafe { Ok(std::slice::from_raw_parts(buffer.data, buffer.len)) }
}

pub fn buffer_to_vec(buffer: &OpenmlsFfiBuffer) -> Result<Vec<u8>, i32> {
    Ok(read_buffer_slice(buffer)?.to_vec())
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_buffer_free(buffer: OpenmlsFfiBuffer) {
    if !buffer.data.is_null() && buffer.len > 0 {
        drop(Vec::from_raw_parts(buffer.data, buffer.len, buffer.len));
    }
}

#[no_mangle]
pub unsafe extern "C" fn openmls_ffi_buffer_init_empty(out_buffer: *mut OpenmlsFfiBuffer) -> i32 {
    if out_buffer.is_null() {
        return OPENMLS_STATUS_NULL_POINTER;
    }

    ptr::write(out_buffer, OpenmlsFfiBuffer::empty());
    OPENMLS_STATUS_OK
}
