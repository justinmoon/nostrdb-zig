use std::os::raw::c_int;

pub type openmls_status_t = c_int;

pub const OPENMLS_STATUS_OK: openmls_status_t = 0;
pub const OPENMLS_STATUS_ERROR: openmls_status_t = 1;
pub const OPENMLS_STATUS_NULL_POINTER: openmls_status_t = 2;
pub const OPENMLS_STATUS_INVALID_ARGUMENT: openmls_status_t = 3;
