const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the C library sources from nostrdb at the pinned commit
    const lib = b.addLibrary(.{ .name = "nostrdb_c", .linkage = .static, .root_module = b.createModule(.{ .target = target, .optimize = optimize }) });

    // Common include paths for all C code
    // On ARM64, add our override directory first to provide a fixed config.h
    if (target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .aarch64_be) {
        lib.addIncludePath(b.path("src/override")); // Our config.h override comes first
    }
    lib.addIncludePath(b.path("nostrdb/src"));
    lib.addIncludePath(b.path("nostrdb/src/bindings/c")); // For profile_reader.h
    lib.addIncludePath(b.path("nostrdb/ccan"));
    lib.addIncludePath(b.path("nostrdb/deps/lmdb"));
    lib.addIncludePath(b.path("nostrdb/deps/flatcc/include"));
    lib.addIncludePath(b.path("nostrdb/deps/secp256k1/include"));
    lib.addIncludePath(b.path("nostrdb/deps/secp256k1/src"));

    // Core C sources mirroring nostrdb-rs/build.rs
    lib.addCSourceFiles(.{
        .files = &.{
            "nostrdb/src/nostrdb.c",
            "nostrdb/src/invoice.c",
            "nostrdb/src/nostr_bech32.c",
            "nostrdb/src/content_parser.c",
            "nostrdb/src/bolt11/bech32.c",
            "nostrdb/src/block.c",
            "nostrdb/deps/flatcc/src/runtime/json_parser.c",
            "nostrdb/deps/flatcc/src/runtime/verifier.c",
            "nostrdb/deps/flatcc/src/runtime/builder.c",
            "nostrdb/deps/flatcc/src/runtime/emitter.c",
            "nostrdb/deps/flatcc/src/runtime/refmap.c",
            "nostrdb/deps/lmdb/mdb.c",
            "nostrdb/deps/lmdb/midl.c",
            "src/profile_shim.c", // Profile field accessor shim
        },
        .flags = &.{
            "-Wno-sign-compare",
            "-Wno-misleading-indentation",
            "-Wno-unused-function",
            "-Wno-unused-parameter",
        },
    });
    // Build CCAN sha256
    lib.addCSourceFiles(.{
        .files = &.{
            "nostrdb/ccan/ccan/crypto/sha256/sha256.c",
        },
        .flags = &.{
            "-Wno-unused-function",
            "-Wno-unused-parameter",
        },
    });

    // CCAN sha256 compiled with default config (from nostrdb/src/config.h)

    // Non-Windows-only bolt11 deps (we mirror build.rs behavior)
    if (target.result.os.tag != .windows) {
        lib.addCSourceFiles(.{
            .files = &.{
                "nostrdb/ccan/ccan/likely/likely.c",
                "nostrdb/ccan/ccan/list/list.c",
                "nostrdb/ccan/ccan/mem/mem.c",
                "nostrdb/ccan/ccan/str/debug.c",
                "nostrdb/ccan/ccan/str/str.c",
                "nostrdb/ccan/ccan/take/take.c",
                "nostrdb/ccan/ccan/tal/str/str.c",
                "nostrdb/ccan/ccan/tal/tal.c",
                "nostrdb/ccan/ccan/utf8/utf8.c",
                "nostrdb/src/bolt11/bolt11.c",
                "nostrdb/src/bolt11/amount.c",
                "nostrdb/src/bolt11/hash_u5.c",
            },
            .flags = &.{
                "-Wno-sign-compare",
                "-Wno-misleading-indentation",
                "-Wno-unused-function",
                "-Wno-unused-parameter",
            },
        });
    }

    // secp256k1 sources and defines
    lib.addCSourceFiles(.{
        .files = &.{
            "nostrdb/deps/secp256k1/contrib/lax_der_parsing.c",
            "nostrdb/deps/secp256k1/src/precomputed_ecmult_gen.c",
            "nostrdb/deps/secp256k1/src/precomputed_ecmult.c",
            "nostrdb/deps/secp256k1/src/secp256k1.c",
        },
        .flags = &.{
            "-Wno-unused-function",
            "-Wno-unused-parameter",
        },
    });
    lib.root_module.addCMacro("SECP256K1_STATIC", "1");
    lib.root_module.addCMacro("ENABLE_MODULE_ECDH", "1");
    lib.root_module.addCMacro("ENABLE_MODULE_SCHNORRSIG", "1");
    lib.root_module.addCMacro("ENABLE_MODULE_EXTRAKEYS", "1");

    // Debug flags similar to build.rs
    switch (optimize) {
        .Debug => {
            lib.root_module.addCMacro("DEBUG", "1");
            lib.addCSourceFiles(.{ .files = &.{}, .flags = &.{"-O1"} });
        },
        else => {},
    }

    // macOS: link Security framework like build.rs
    if (target.result.os.tag == .macos) {
        lib.linkFramework("Security");
    }

    b.installArtifact(lib);

    const proto_module = b.createModule(.{
        .root_source_file = b.path("proto/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const megalith = b.addExecutable(.{
        .name = "megalith",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    megalith.root_module.addImport("proto", proto_module);
    megalith.linkLibrary(lib);

    const install_megalith = b.addInstallArtifact(megalith, .{});
    const megalith_step = b.step("megalith", "Build the Megalith CLI");
    megalith_step.dependOn(&install_megalith.step);

    // Add libxev dependency
    const xev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    // Unit tests target for Zig wrappers and Phase 1 tests
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/test.zig"), .target = target, .optimize = optimize }) });

    // Ensure @cImport("nostrdb.h") resolves for tests
    // On ARM64, add our override directory first to provide a fixed config.h
    if (target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .aarch64_be) {
        tests.root_module.addIncludePath(b.path("src/override"));
    }
    tests.root_module.addIncludePath(b.path("nostrdb/src"));
    tests.root_module.addIncludePath(b.path("nostrdb/ccan"));
    tests.root_module.addIncludePath(b.path("nostrdb/deps/lmdb"));
    tests.root_module.addIncludePath(b.path("nostrdb/deps/flatcc/include"));
    tests.root_module.addIncludePath(b.path("nostrdb/deps/secp256k1/include"));
    tests.linkLibrary(lib);
    tests.root_module.addImport("proto", proto_module);
    const proto_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/proto_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("proto_tests", proto_tests_module);
    tests.root_module.addImport("xev", xev.module("xev"));
    if (target.result.os.tag == .macos) {
        tests.linkFramework("Security");
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Phase 1 tests");
    test_step.dependOn(&run_tests.step);
}
