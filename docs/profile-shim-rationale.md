# Profile C Shim Rationale

## Problem
The nostrdb C library uses flatbuffers for profile data serialization. The flatbuffer C headers (`profile_reader.h`) define accessor functions as `static inline` macros that:
- Don't create linkable symbols (they're inlined at compile time)
- Perform pointer arithmetic that violates Zig's stricter alignment requirements
- Cause `@ptrCast increases pointer alignment` errors when imported directly into Zig

## Solution Comparison

### Rust Approach (no shim needed)
- Uses flatbuffers compiler to generate native Rust code (`ndb_profile.rs`)
- Rust flatbuffers library handles all parsing safely
- No C interop needed for flatbuffer access

### Zig Options Considered

1. **C Shim (chosen)** ✅
   - Simple ~80 line C file (`profile_shim.c`) with exported functions
   - Compiles inline functions into real symbols Zig can call
   - Handles alignment issues within C where it's permissive
   - Easy to maintain and understand

2. **Generate Zig Flatbuffer Code**
   - Would require flatbuffers compiler Zig backend (doesn't exist yet)
   - Most elegant long-term solution
   - Not currently feasible

3. **Direct Flatbuffer Parsing in Zig**
   - Attempted but complex: requires manual vtable lookups, offset calculations
   - Would need hundreds of lines of intricate parsing code
   - Higher maintenance burden and bug risk

## Decision
Keep the C shim approach because:
- Minimal code overhead (one small C file)
- Zero runtime performance impact (just function calls)
- Isolates C/Zig interop issues in one place
- Working solution that passes all tests
- Can be replaced later if Zig gets flatbuffers support

## Files
- `src/profile_shim.c` - C functions that wrap flatbuffer accessors
- `src/profile.zig` - Zig interface using extern functions from the shim