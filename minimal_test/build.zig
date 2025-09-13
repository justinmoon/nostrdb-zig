const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "test_signing",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link the prebuilt library from parent directory (use newest one)
    exe.addObjectFile(b.path("../.zig-cache/o/620827c1aa5fff10834f5b66ba96adae/libnostrdb_c.a"));
    exe.addIncludePath(b.path("../nostrdb/src"));
    exe.addIncludePath(b.path("../nostrdb/ccan"));
    exe.addIncludePath(b.path("../nostrdb/deps/secp256k1/include"));
    
    // macOS needs Security framework
    if (target.result.os.tag == .macos) {
        exe.linkFramework("Security");
    }
    
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    
    // Test 2 with Zig allocators
    const exe2 = b.addExecutable(.{
        .name = "test_signing2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe2.addObjectFile(b.path("../.zig-cache/o/620827c1aa5fff10834f5b66ba96adae/libnostrdb_c.a"));
    exe2.addIncludePath(b.path("../nostrdb/src"));
    exe2.addIncludePath(b.path("../nostrdb/ccan"));
    exe2.addIncludePath(b.path("../nostrdb/deps/secp256k1/include"));
    if (target.result.os.tag == .macos) {
        exe2.linkFramework("Security");
    }
    exe2.linkLibC();
    
    const run_cmd2 = b.addRunArtifact(exe2);
    const run_step2 = b.step("run2", "Run test 2");
    run_step2.dependOn(&run_cmd2.step);
    
    // Test 3 - comprehensive alignment test
    const exe3 = b.addExecutable(.{
        .name = "test_signing3",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main3.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe3.addObjectFile(b.path("../.zig-cache/o/18fa68ee732a8e4fd688d13e6e75fd6b/libnostrdb_c.a"));
    exe3.addIncludePath(b.path("../nostrdb/src"));
    exe3.addIncludePath(b.path("../nostrdb/ccan"));
    exe3.addIncludePath(b.path("../nostrdb/deps/secp256k1/include"));
    if (target.result.os.tag == .macos) {
        exe3.linkFramework("Security");
    }
    exe3.linkLibC();
    
    const run_cmd3 = b.addRunArtifact(exe3);
    const run_step3 = b.step("run3", "Run test 3");
    run_step3.dependOn(&run_cmd3.step);
    
    // Test 4 - reproduce Test 14 exactly
    const exe4 = b.addExecutable(.{
        .name = "test_signing4",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main4.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe4.addObjectFile(b.path("../.zig-cache/o/18fa68ee732a8e4fd688d13e6e75fd6b/libnostrdb_c.a"));
    exe4.addIncludePath(b.path("../nostrdb/src"));
    exe4.addIncludePath(b.path("../nostrdb/ccan"));
    exe4.addIncludePath(b.path("../nostrdb/deps/secp256k1/include"));
    if (target.result.os.tag == .macos) {
        exe4.linkFramework("Security");
    }
    exe4.linkLibC();
    
    const run_cmd4 = b.addRunArtifact(exe4);
    const run_step4 = b.step("run4", "Run test 4");
    run_step4.dependOn(&run_cmd4.step);
}