const std = @import("std");
const apple_sdk = @import("build/apple_sdk.zig");

fn configureAppleSdk(b: *std.Build, step: *std.Build.Step.Compile) void {
    apple_sdk.addPaths(b, step) catch |err| {
        std.debug.print("error: failed to configure Apple SDK: {s}\n", .{@errorName(err)});
        @panic("Apple SDK setup failed");
    };
}

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

    b.installArtifact(lib);

    // Add libxev dependency (used by net module and tests)
    const xev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    const websocket_pkg = b.dependency("websocket", .{
        .target = target,
        .optimize = optimize,
    });

    const proto_module = b.createModule(.{
        .root_source_file = b.path("proto/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const c_module = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_module.addIncludePath(b.path("nostrdb/src"));
    c_module.addIncludePath(b.path("nostrdb/ccan"));
    c_module.addIncludePath(b.path("nostrdb/deps/lmdb"));
    c_module.addIncludePath(b.path("nostrdb/deps/flatcc/include"));
    c_module.addIncludePath(b.path("nostrdb/deps/secp256k1/include"));
    if (target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .aarch64_be) {
        c_module.addIncludePath(b.path("src/override"));
    }
    proto_module.addImport("c", c_module);
    const ndb_module = b.createModule(.{
        .root_source_file = b.path("src/ndb.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .aarch64_be) {
        ndb_module.addIncludePath(b.path("src/override"));
    }
    ndb_module.addIncludePath(b.path("nostrdb/src"));
    ndb_module.addIncludePath(b.path("nostrdb/src/bindings/c"));
    ndb_module.addIncludePath(b.path("nostrdb/ccan"));
    ndb_module.addIncludePath(b.path("nostrdb/deps/lmdb"));
    ndb_module.addIncludePath(b.path("nostrdb/deps/flatcc/include"));
    ndb_module.addIncludePath(b.path("nostrdb/deps/secp256k1/include"));
    proto_module.addImport("ndb", ndb_module);
    ndb_module.addImport("c", c_module);

    const net_module = b.createModule(.{
        .root_source_file = b.path("net/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    net_module.addImport("xev", xev.module("xev"));
    net_module.addImport("websocket", websocket_pkg.module("websocket"));

    const diag_module = b.createModule(.{
        .root_source_file = b.path("ingest/diag.zig"),
        .target = target,
        .optimize = optimize,
    });

    const contacts_module = b.createModule(.{
        .root_source_file = b.path("contacts/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    contacts_module.addIncludePath(b.path("nostrdb/deps/lmdb"));
    contacts_module.addImport("proto", proto_module);
    contacts_module.addImport("net", net_module);
    contacts_module.addImport("ndb", ndb_module);
    contacts_module.addImport("ingdiag", diag_module);

    const timeline_module = b.createModule(.{
        .root_source_file = b.path("timeline/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    timeline_module.addIncludePath(b.path("nostrdb/deps/lmdb"));

    const ingest_module = b.createModule(.{
        .root_source_file = b.path("ingest/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    ingest_module.addImport("proto", proto_module);
    ingest_module.addImport("net", net_module);
    ingest_module.addImport("contacts", contacts_module);
    ingest_module.addImport("timeline", timeline_module);
    ingest_module.addImport("ndb", ndb_module);
    ingest_module.addImport("ingdiag", diag_module);

    const megalith = b.addExecutable(.{
        .name = "megalith",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    megalith.root_module.addImport("proto", proto_module);
    megalith.root_module.addImport("net", net_module);
    megalith.root_module.addImport("contacts", contacts_module);
    megalith.root_module.addImport("timeline", timeline_module);
    megalith.root_module.addImport("ingest", ingest_module);
    megalith.root_module.addImport("ndb", ndb_module);
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, megalith);
        megalith.linkFramework("Security");
    }
    megalith.linkLibrary(lib);

    const install_megalith = b.addInstallArtifact(megalith, .{});
    const megalith_step = b.step("megalith", "Build the Megalith CLI");
    megalith_step.dependOn(&install_megalith.step);

    const ssr_demo = b.addExecutable(.{
        .name = "ssr-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ssr/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ssr_demo.root_module.addImport("ndb", ndb_module);
    ssr_demo.root_module.addImport("proto", proto_module);
    ssr_demo.root_module.addImport("net", net_module);
    ssr_demo.root_module.addImport("contacts", contacts_module);
    ssr_demo.root_module.addImport("timeline", timeline_module);
    ssr_demo.root_module.addImport("ingest", ingest_module);
    ssr_demo.root_module.addImport("ingdiag", diag_module);
    if (target.result.cpu.arch == .aarch64 or target.result.cpu.arch == .aarch64_be) {
        ssr_demo.root_module.addIncludePath(b.path("src/override"));
    }
    ssr_demo.root_module.addIncludePath(b.path("nostrdb/src"));
    ssr_demo.root_module.addIncludePath(b.path("nostrdb/ccan"));
    ssr_demo.root_module.addIncludePath(b.path("nostrdb/deps/lmdb"));
    ssr_demo.root_module.addIncludePath(b.path("nostrdb/deps/flatcc/include"));
    ssr_demo.root_module.addIncludePath(b.path("nostrdb/deps/secp256k1/include"));
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, ssr_demo);
        ssr_demo.linkFramework("Security");
    }
    ssr_demo.linkLibrary(lib);
    const install_ssr = b.addInstallArtifact(ssr_demo, .{});
    const ssr_step = b.step("ssr-demo", "Build the SSR timeline demo server");
    ssr_step.dependOn(&install_ssr.step);

    // Minimal websocket smoke client (no repo code) for relay debugging
    const ws_smoke = b.addExecutable(.{
        .name = "ws-smoke",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/ws_smoke.zig"), .target = target, .optimize = optimize }),
    });
    ws_smoke.root_module.addImport("websocket", websocket_pkg.module("websocket"));
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, ws_smoke);
        ws_smoke.linkFramework("Security");
    }
    const install_ws_smoke = b.addInstallArtifact(ws_smoke, .{});
    const ws_smoke_step = b.step("ws-smoke", "Build the websocket smoke tester");
    ws_smoke_step.dependOn(&install_ws_smoke.step);

    // Contacts + posts minimal client
    const ws_contacts = b.addExecutable(.{
        .name = "ws-contacts",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/ws_contacts.zig"), .target = target, .optimize = optimize }),
    });
    ws_contacts.root_module.addImport("websocket", websocket_pkg.module("websocket"));
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, ws_contacts);
        ws_contacts.linkFramework("Security");
    }
    const install_ws_contacts = b.addInstallArtifact(ws_contacts, .{});
    const ws_contacts_step = b.step("ws-contacts", "Build the contacts+posts smoke client");
    ws_contacts_step.dependOn(&install_ws_contacts.step);

    const ws_contacts_server = b.addExecutable(.{
        .name = "ws-contacts-server",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/ws_contacts_server.zig"), .target = target, .optimize = optimize }),
    });
    ws_contacts_server.root_module.addImport("websocket", websocket_pkg.module("websocket"));
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, ws_contacts_server);
        ws_contacts_server.linkFramework("Security");
    }
    const install_ws_contacts_server = b.addInstallArtifact(ws_contacts_server, .{});
    const ws_contacts_server_step = b.step("ws-contacts-server", "Build the contacts+posts SSR demo server");
    ws_contacts_server_step.dependOn(&install_ws_contacts_server.step);

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
    tests.root_module.addImport("net", net_module);
    tests.root_module.addImport("contacts", contacts_module);
    tests.root_module.addImport("timeline", timeline_module);
    tests.root_module.addImport("ingest", ingest_module);
    tests.root_module.addImport("ingdiag", diag_module);
    tests.root_module.addImport("ndb", ndb_module);
    tests.root_module.addImport("c", c_module);
    const proto_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/proto_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("proto_tests", proto_tests_module);
    const net_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/net_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("net_tests", net_tests_module);
    tests.root_module.addImport("xev", xev.module("xev"));
    tests.root_module.addImport("websocket", websocket_pkg.module("websocket"));

    const contacts_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/contacts_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("contacts_tests", contacts_tests_module);

    const timeline_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/timeline_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("timeline_tests", timeline_tests_module);

    const ingest_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/ingest_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("ingest_tests", ingest_tests_module);

    const cli_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/cli_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("cli_tests", cli_tests_module);
    const handshake_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/handshake_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("handshake_tests", handshake_tests_module);
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, tests);
        tests.linkFramework("Security");
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Phase 1 tests");
    test_step.dependOn(&run_tests.step);

    // E2E SSR runner (exec), depends on building ssr-demo
    const ssr_e2e = b.addExecutable(.{
        .name = "ssr-e2e",
        .root_module = b.createModule(.{ .root_source_file = b.path("tests/ssr_e2e.zig"), .target = target, .optimize = optimize }),
    });
    ssr_e2e.root_module.addImport("net", net_module);
    ssr_e2e.root_module.addImport("proto", proto_module);
    ssr_e2e.linkLibrary(lib);
    if (target.result.os.tag == .macos) {
        configureAppleSdk(b, ssr_e2e);
        ssr_e2e.linkFramework("Security");
    }
    const install_e2e = b.addInstallArtifact(ssr_e2e, .{});
    const e2e_run = b.addRunArtifact(ssr_e2e);
    // Ensure ssr-demo is built before running the e2e runner
    e2e_run.step.dependOn(&install_ssr.step);
    const e2e_step = b.step("ssr-e2e", "Run SSR end-to-end test against a mock relay");
    e2e_step.dependOn(&install_e2e.step);
    e2e_step.dependOn(&e2e_run.step);
}
