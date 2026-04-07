const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Shared module for clipboard core logic
    const clipboard_mod = b.createModule(.{
        .root_source_file = b.path("src/clipboard.zig"),
        .target = target,
        .optimize = optimize,
    });
    clipboard_mod.linkSystemLibrary("objc", .{});
    clipboard_mod.linkFramework("AppKit", .{});

    // Shared library (C ABI for Bun FFI)
    const lib = b.addLibrary(.{
        .name = "clipboard",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clipboard", .module = clipboard_mod },
            },
        }),
    });
    b.installArtifact(lib);

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "clipboard",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clipboard", .module = clipboard_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step for CLI
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the clipboard CLI");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // Unit tests for pure Zig modules (no OS dependencies).
    // Run with: `zig build test`
    //
    // Only modules that are safe to compile without linking Foundation
    // belong here. `paths.zig` is pure Zig; other modules that call into
    // Obj-C should NOT be added to this step unless they also link the
    // appropriate system libraries.
    // -------------------------------------------------------------------
    const paths_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/paths.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_paths_tests = b.addRunArtifact(paths_tests);

    const test_step = b.step("test", "Run pure-Zig unit tests");
    test_step.dependOn(&run_paths_tests.step);
}
