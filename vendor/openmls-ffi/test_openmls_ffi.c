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

    const char *alice_identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *bob_identity = "884704bd421671e01c13f854d2ce23ce2a5bfe9562f4f297ad2bc921ba30c3a6";
    uint16_t ciphersuite = 0x0001; /* MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519 */
    OpenmlsFfiBuffer bob_key_package = {0};

    status = openmls_ffi_key_package_create(
        provider,
        bob_identity,
        ciphersuite,
        NULL,
        0,
        true,
        &bob_key_package
    );

    if (status != OPENMLS_STATUS_OK) {
        fprintf(stderr, "key package creation failed: %d\n", status);
        openmls_ffi_provider_free(provider);
        return (int)status;
    }

    printf("key package produced with %zu bytes\n", bob_key_package.len);

    OpenmlsFfiBuffer group_id = {0};
    OpenmlsFfiBuffer commit_message = {0};
    OpenmlsFfiBuffer welcome_message = {0};
    OpenmlsFfiBuffer group_info = {0};

    status = openmls_ffi_group_create(
        provider,
        alice_identity,
        ciphersuite,
        NULL,
        0,
        NULL,
        0,
        &bob_key_package,
        1,
        true,
        &group_id,
        &commit_message,
        &welcome_message,
        &group_info
    );

    if (status != OPENMLS_STATUS_OK) {
        fprintf(stderr, "group creation failed: %d\n", status);
        openmls_ffi_buffer_free(bob_key_package);
        openmls_ffi_provider_free(provider);
        return (int)status;
    }

    printf("group id length: %zu\n", group_id.len);
    printf("commit message length: %zu\n", commit_message.len);
    printf("welcome message length: %zu\n", welcome_message.len);

    openmls_ffi_buffer_free(group_id);
    openmls_ffi_buffer_free(commit_message);
    openmls_ffi_buffer_free(welcome_message);
    openmls_ffi_buffer_free(group_info);
    openmls_ffi_buffer_free(bob_key_package);
    openmls_ffi_provider_free(provider);

    printf("openmls-ffi version: %s\n", version);
    return 0;
}
