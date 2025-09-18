#include "openmls_ffi.h"
#include <stdio.h>
#include <string.h>

int main(void) {
    const char *version = openmls_ffi_version();
    if (version == NULL) {
        fprintf(stderr, "version pointer was NULL\n");
        return 1;
    }

    void *provider_alice = openmls_ffi_provider_new_default();
    if (provider_alice == NULL) {
        fprintf(stderr, "failed to create alice provider\n");
        return 1;
    }

    void *provider_bob = openmls_ffi_provider_new_default();
    if (provider_bob == NULL) {
        fprintf(stderr, "failed to create bob provider\n");
        openmls_ffi_provider_free(provider_alice);
        return 1;
    }

    openmls_status_t status = openmls_ffi_smoketest();
    if (status != 0) {
        fprintf(stderr, "smoketest failed: %d\n", status);
        openmls_ffi_provider_free(provider_bob);
        openmls_ffi_provider_free(provider_alice);
        return (int)status;
    }

    const char *alice_identity = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const char *bob_identity = "884704bd421671e01c13f854d2ce23ce2a5bfe9562f4f297ad2bc921ba30c3a6";
    uint16_t ciphersuite = 0x0001; /* MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519 */
    OpenmlsFfiBuffer bob_key_package = {0};

    status = openmls_ffi_key_package_create(
        provider_bob,
        bob_identity,
        ciphersuite,
        NULL,
        0,
        true,
        &bob_key_package
    );

    if (status != OPENMLS_STATUS_OK) {
        fprintf(stderr, "key package creation failed: %d\n", status);
        openmls_ffi_provider_free(provider_bob);
        openmls_ffi_provider_free(provider_alice);
        return (int)status;
    }

    printf("key package produced with %zu bytes\n", bob_key_package.len);

    OpenmlsFfiBuffer group_id = {0};
    OpenmlsFfiBuffer commit_message = {0};
    OpenmlsFfiBuffer welcome_message = {0};
    OpenmlsFfiBuffer group_info = {0};

    status = openmls_ffi_group_create(
        provider_alice,
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
        openmls_ffi_provider_free(provider_bob);
        openmls_ffi_provider_free(provider_alice);
        return (int)status;
    }

    printf("group id length: %zu\n", group_id.len);
    printf("commit message length: %zu\n", commit_message.len);
    printf("welcome message length: %zu\n", welcome_message.len);

    void *staged_welcome = NULL;
    OpenmlsFfiBuffer group_context = {0};
    status = openmls_ffi_welcome_parse(
        provider_bob,
        &welcome_message,
        NULL,
        true,
        &staged_welcome,
        &group_context
    );

    if (status != OPENMLS_STATUS_OK) {
        fprintf(stderr, "welcome parse failed: %d\n", status);
        openmls_ffi_buffer_free(group_context);
        openmls_ffi_buffer_free(group_id);
        openmls_ffi_buffer_free(commit_message);
        openmls_ffi_buffer_free(welcome_message);
        openmls_ffi_buffer_free(group_info);
        openmls_ffi_buffer_free(bob_key_package);
        openmls_ffi_provider_free(provider_bob);
        openmls_ffi_provider_free(provider_alice);
        return (int)status;
    }

    OpenmlsFfiBuffer bob_group_id = {0};
    status = openmls_ffi_welcome_join(provider_bob, staged_welcome, &bob_group_id);

    if (status != OPENMLS_STATUS_OK) {
        fprintf(stderr, "welcome join failed: %d\n", status);
        openmls_ffi_welcome_free(staged_welcome);
        openmls_ffi_buffer_free(group_context);
        openmls_ffi_buffer_free(group_id);
        openmls_ffi_buffer_free(commit_message);
        openmls_ffi_buffer_free(welcome_message);
        openmls_ffi_buffer_free(group_info);
        openmls_ffi_buffer_free(bob_key_package);
        openmls_ffi_provider_free(provider_bob);
        openmls_ffi_provider_free(provider_alice);
        return (int)status;
    }

    openmls_ffi_welcome_free(staged_welcome);

    printf("bob group id length: %zu\n", bob_group_id.len);

    const char *message = "Hi Bob!";
    OpenmlsFfiBuffer plaintext = { (uint8_t *)message, strlen(message) };
    OpenmlsFfiBuffer ciphertext = {0};

    status = openmls_ffi_message_encrypt(
        provider_alice,
        &group_id,
        &plaintext,
        &ciphertext
    );

    if (status != OPENMLS_STATUS_OK) {
        fprintf(stderr, "message encrypt failed: %d\n", status);
        openmls_ffi_buffer_free(group_context);
        openmls_ffi_buffer_free(group_id);
        openmls_ffi_buffer_free(commit_message);
        openmls_ffi_buffer_free(welcome_message);
        openmls_ffi_buffer_free(group_info);
        openmls_ffi_buffer_free(bob_key_package);
        openmls_ffi_buffer_free(bob_group_id);
        openmls_ffi_provider_free(provider_bob);
        openmls_ffi_provider_free(provider_alice);
        return (int)status;
    }

    OpenmlsFfiBuffer decrypted = {0};
    OpenmlsProcessedMessageType message_type = Other;
    status = openmls_ffi_message_decrypt(
        provider_bob,
        &bob_group_id,
        &ciphertext,
        &decrypted,
        &message_type
    );

    if (status != OPENMLS_STATUS_OK) {
        fprintf(stderr, "message decrypt failed: %d\n", status);
        openmls_ffi_buffer_free(ciphertext);
        openmls_ffi_buffer_free(group_context);
        openmls_ffi_buffer_free(group_id);
        openmls_ffi_buffer_free(commit_message);
        openmls_ffi_buffer_free(welcome_message);
        openmls_ffi_buffer_free(group_info);
        openmls_ffi_buffer_free(bob_key_package);
        openmls_ffi_buffer_free(bob_group_id);
        openmls_ffi_provider_free(provider_bob);
        openmls_ffi_provider_free(provider_alice);
        return (int)status;
    }

    printf("message type: %d\n", message_type);
    if (decrypted.len > 0) {
        printf("decrypted message: %.*s\n", (int)decrypted.len, decrypted.data);
        openmls_ffi_buffer_free(decrypted);
    }
    openmls_ffi_buffer_free(ciphertext);

    openmls_ffi_buffer_free(bob_group_id);
    openmls_ffi_buffer_free(group_context);
    openmls_ffi_buffer_free(group_id);
    openmls_ffi_buffer_free(commit_message);
    openmls_ffi_buffer_free(welcome_message);
    openmls_ffi_buffer_free(group_info);
    openmls_ffi_buffer_free(bob_key_package);
    openmls_ffi_provider_free(provider_bob);
    openmls_ffi_provider_free(provider_alice);

    printf("openmls-ffi version: %s\n", version);
    return 0;
}
