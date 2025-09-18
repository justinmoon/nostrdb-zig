#include "openmls_ffi.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    const char *version = openmls_ffi_version();
    if (version == NULL) {
        fprintf(stderr, "version pointer was NULL\n");
        return 1;
    }

    void *provider = openmls_ffi_provider_new_default();
    if (provider == NULL) {
        fprintf(stderr, "failed to create provider\n");
        return 1;
    }

    openmls_status_t status = openmls_ffi_smoketest();
    if (status != 0) {
        fprintf(stderr, "smoketest failed: %d\n", status);
        openmls_ffi_provider_free(provider);
        return (int)status;
    }

    const char *identity = "884704bd421671e01c13f854d2ce23ce2a5bfe9562f4f297ad2bc921ba30c3a6";
    uint16_t ciphersuite = 0x0001; /* MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519 */
    OpenmlsFfiBuffer key_package = {0};

    status = openmls_ffi_key_package_create(
        provider,
        identity,
        ciphersuite,
        NULL,
        0,
        true,
        &key_package
    );

    if (status != OPENMLS_STATUS_OK) {
        fprintf(stderr, "key package creation failed: %d\n", status);
        openmls_ffi_provider_free(provider);
        return (int)status;
    }

    printf("key package produced with %zu bytes\n", key_package.len);
    openmls_ffi_buffer_free(key_package);
    openmls_ffi_provider_free(provider);

    printf("openmls-ffi version: %s\n", version);
    return 0;
}
