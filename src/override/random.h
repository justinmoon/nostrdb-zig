/*************************************************************************
 * Override for macOS to avoid Security/SecRandom.h in Nix builds.      *
 * We use getentropy(2) which is available on macOS and avoids linking   *
 * Apple Security framework. For other platforms, we mirror upstream.    *
 *************************************************************************/

#if defined(_WIN32)
#include <windows.h>
#include <ntstatus.h>
#include <bcrypt.h>
#elif defined(__ANDROID__)
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#elif defined(__linux__) || defined(__FreeBSD__)
#include <sys/random.h>
#elif defined(__OpenBSD__)
#include <unistd.h>
#elif defined(__APPLE__)
#include <sys/random.h>
#else
#error "Couldn't identify the OS"
#endif

#include <stddef.h>
#include <limits.h>
#include <stdio.h>

/* Returns 1 on success, and 0 on failure. */
static int fill_random(unsigned char* data, size_t size) {
#if defined(_WIN32)
    NTSTATUS res = BCryptGenRandom(NULL, data, size, BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    if (res != STATUS_SUCCESS || size > ULONG_MAX) {
        return 0;
    } else {
        return 1;
    }
#elif defined(__ANDROID__)
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        return 0; // Failed to open /dev/urandom
    }
    ssize_t read_bytes = 0;
    while (size > 0) {
        read_bytes = read(fd, data, size);
        if (read_bytes <= 0) {
            if (errno == EINTR) {
                continue; // If interrupted by signal, try again
            }
            close(fd);
            return 0; // Failed to read
        }
        data += read_bytes;
        size -= read_bytes;
    }
    close(fd);
    return 1;
#elif defined(__linux__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    /* If `getrandom(2)` is not available you should fallback to /dev/urandom */
    ssize_t res = getrandom(data, size, 0);
    if (res < 0 || (size_t)res != size ) {
        return 0;
    } else {
        return 1;
    }
#elif defined(__APPLE__)
    /* Prefer getentropy(2) to avoid Security framework in Nix. getentropy
     * has a 256-byte per call limit on macOS; loop in chunks. */
    size_t off = 0;
    while (off < size) {
        size_t chunk = size - off;
        if (chunk > 256) chunk = 256;
        if (getentropy((void*)(data + off), chunk) != 0) {
            return 0;
        }
        off += chunk;
    }
    return 1;
#endif
    return 0;
}

