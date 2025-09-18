#include "openmls_ffi.h"
#include <stdio.h>

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

    openmls_ffi_provider_free(provider);

    printf("openmls-ffi version: %s\n", version);
    return 0;
}
