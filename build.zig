const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    // Shared module for clipboard core logic
    const clipboard_mod = b.createModule(.{
        .root_source_file = b.path("src/clipboard.zig"),
        .target = target,
        .optimize = optimize,
    });

    // When cross-compiling for macOS (e.g. -Dtarget=x86_64-macos on an aarch64
    // host), Zig doesn't auto-discover the SDK paths. Pass -Dmacos-sdk=/path/to/sdk
    // to provide them.
    const is_native = target.query.isNativeOs() and target.query.isNativeCpu();
    if (!is_native and target_os == .macos) {
        const macos_sdk = b.option([]const u8, "macos-sdk", "Path to macOS SDK for cross-compilation");
        if (macos_sdk) |sdk| {
            clipboard_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk}) });
            clipboard_mod.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk}) });
        }
    }

    switch (target_os) {
        .macos => {
            clipboard_mod.linkSystemLibrary("objc", .{});
            clipboard_mod.linkFramework("AppKit", .{});
        },
        .linux => {
            clipboard_mod.link_libc = true;
            clipboard_mod.linkSystemLibrary("X11", .{});
            clipboard_mod.linkSystemLibrary("wayland-client", .{});

            // Generate the wlr-data-control client header and private code
            // from the vendored XML via wayland-scanner (which is required
            // to be on PATH on Linux builds; it ships in the libwayland-bin
            // package on Debian/Ubuntu).
            const wl_scanner_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
            wl_scanner_header.addFileArg(b.path("vendor/wayland-protocols/wlr-data-control-unstable-v1.xml"));
            const wl_header = wl_scanner_header.addOutputFileArg("wlr-data-control-unstable-v1-client-protocol.h");

            const wl_scanner_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
            wl_scanner_code.addFileArg(b.path("vendor/wayland-protocols/wlr-data-control-unstable-v1.xml"));
            const wl_code = wl_scanner_code.addOutputFileArg("wlr-data-control-unstable-v1-protocol.c");

            clipboard_mod.addCSourceFile(.{ .file = wl_code, .flags = &.{} });
            clipboard_mod.addIncludePath(wl_header.dirname());
        },
        .windows => {
            clipboard_mod.link_libc = true;
            clipboard_mod.linkSystemLibrary("kernel32", .{});
            clipboard_mod.linkSystemLibrary("user32", .{});
        },
        else => {
            // Other platforms are not supported by the library yet; the
            // clipboard.zig @compileError still enforces that at the Zig
            // level. build.zig stays silent so `zig build --help` still works.
        },
    }

    // Shared library (C ABI for Bun FFI and other consumers)
    const lib = b.addLibrary(.{
        .name = "copycat",
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

    // Static library for embedding (e.g. Tauri/Rust)
    const lib_static = b.addLibrary(.{
        .name = "copycat",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clipboard", .module = clipboard_mod },
            },
        }),
    });
    b.installArtifact(lib_static);

    // Shared module for web custom data parsing (pure Zig, no OS deps)
    const web_custom_data_mod = b.createModule(.{
        .root_source_file = b.path("src/web_custom_data.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "copycat",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clipboard", .module = clipboard_mod },
                .{ .name = "web_custom_data", .module = web_custom_data_mod },
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

    const run_step = b.step("run", "Run the copycat CLI");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------
    // Unit tests for pure Zig modules (no OS dependencies).
    // Run with: `zig build test`
    //
    // Only paths.zig is in this step. platform/* files link to platform
    // libraries that are not present in the pure-Zig test binary.
    // -------------------------------------------------------------------
    const paths_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/paths.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const web_custom_data_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web_custom_data.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_paths_tests = b.addRunArtifact(paths_tests);
    const run_web_custom_data_tests = b.addRunArtifact(web_custom_data_tests);

    const test_step = b.step("test", "Run pure-Zig unit tests");
    test_step.dependOn(&run_paths_tests.step);
    test_step.dependOn(&run_web_custom_data_tests.step);
}
