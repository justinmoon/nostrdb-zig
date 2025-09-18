use openmls::group::{GroupId, MlsGroup};
use openmls::prelude::OpenMlsProvider;
use openmls_basic_credential::SignatureKeyPair;

use crate::buffer::{read_buffer_slice, OpenmlsFfiBuffer};
use crate::provider::FfiProvider;
use crate::status::{OPENMLS_STATUS_ERROR, OPENMLS_STATUS_INVALID_ARGUMENT};

pub fn load_group_and_id(
    provider: &mut FfiProvider,
    group_id_buffer: &OpenmlsFfiBuffer,
) -> Result<(MlsGroup, GroupId), i32> {
    let group_id_bytes = read_buffer_slice(group_id_buffer)?;
    if group_id_bytes.is_empty() {
        return Err(OPENMLS_STATUS_INVALID_ARGUMENT);
    }
    let group_id = GroupId::from_slice(group_id_bytes);
    let group = MlsGroup::load(provider.storage(), &group_id)
        .map_err(|_| OPENMLS_STATUS_ERROR)?
        .ok_or(OPENMLS_STATUS_ERROR)?;
    Ok((group, group_id))
}

pub fn load_signer(provider: &FfiProvider, group: &MlsGroup) -> Result<SignatureKeyPair, i32> {
    let own_leaf = group.own_leaf().ok_or(OPENMLS_STATUS_ERROR)?;
    let public_key = own_leaf.signature_key().as_slice();
    SignatureKeyPair::read(
        provider.storage(),
        public_key,
        group.ciphersuite().signature_algorithm(),
    )
    .ok_or(OPENMLS_STATUS_ERROR)
}
