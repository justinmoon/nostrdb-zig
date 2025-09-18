#include <stdio.h>

extern const char *openmls_ffi_version(void);
extern int openmls_ffi_smoketest(void);

int main(void) {
    const char *version = openmls_ffi_version();
    if (version == NULL) {
        fprintf(stderr, "version pointer was NULL\n");
        return 1;
    }

    int status = openmls_ffi_smoketest();
    if (status != 0) {
        fprintf(stderr, "smoketest failed: %d\n", status);
        return status;
    }

    printf("openmls-ffi version: %s\n", version);
    return 0;
}
