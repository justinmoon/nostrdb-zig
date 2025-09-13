const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add libxev dependency
    const xev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });

    // Create demo executable
    const exe = b.addExecutable(.{
        .name = "libxev-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("xev", xev.module("xev"));
    b.installArtifact(exe);
    
    // Create rearm test executable
    const rearm_exe = b.addExecutable(.{
        .name = "rearm-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rearm_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    rearm_exe.root_module.addImport("xev", xev.module("xev"));
    b.installArtifact(rearm_exe);
    
    // Working solution executable
    const solution_exe = b.addExecutable(.{
        .name = "solution",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/working_solution.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    solution_exe.root_module.addImport("xev", xev.module("xev"));
    b.installArtifact(solution_exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the demo");
    run_step.dependOn(&run_cmd.step);
    
    // Rearm test run command
    const run_rearm = b.addRunArtifact(rearm_exe);
    run_rearm.step.dependOn(b.getInstallStep());
    const rearm_step = b.step("rearm", "Run rearm test");
    rearm_step.dependOn(&run_rearm.step);
    
    // Solution run command
    const run_solution = b.addRunArtifact(solution_exe);
    run_solution.step.dependOn(b.getInstallStep());
    const solution_step = b.step("solution", "Run working solution");
    solution_step.dependOn(&run_solution.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("xev", xev.module("xev"));

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}