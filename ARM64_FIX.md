# ARM64 (Apple Silicon) Fix Required

## Problem
On ARM64/aarch64 platforms (like Apple Silicon Macs), the CCAN sha256 implementation crashes with unaligned memory access when signing notes that contain tags.

## Solution
Edit `nostrdb/src/config.h` and change line 12:
```c
#define HAVE_UNALIGNED_ACCESS 1
```
to:
```c
#define HAVE_UNALIGNED_ACCESS 0
```

## Why This Happens
- The config.h file is generated and assumes unaligned access is allowed
- ARM64 processors trap on unaligned access to 32-bit values
- The sha256 code tries to cast unaligned byte arrays to uint32_t* when HAVE_UNALIGNED_ACCESS=1
- Setting it to 0 forces the use of safe memcpy operations instead

## Future Fix
Ideally, the build system should detect ARM64 and override this setting automatically. However, since config.h is a generated file that's checked into the repo, and preprocessor directives can't easily override an existing #define, the manual edit is currently required.

## Testing
After making this change, run:
```bash
zig build test
```

All tests should pass, including the signing tests (Test 12, 14, etc.).