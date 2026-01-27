const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get raylib dependency (direct from raylib repo)
    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_artifact = raylib_dep.artifact("raylib");

    // Create the zgb module (emulator core library)
    const mod = b.addModule("zgb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "zgb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zgb", .module = mod },
            },
        }),
    });

    // Link raylib C library and add include path for @cImport
    exe.root_module.linkLibrary(raylib_artifact);
    exe.root_module.addIncludePath(raylib_dep.path("src"));

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the emulator");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const check_step = b.step("check", "Check the executable");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&run_mod_tests.step);
    check_step.dependOn(&run_exe_tests.step);
}
