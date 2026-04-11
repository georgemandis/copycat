# Zig Clipboard Library + CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone Zig library and CLI tool that can list, read, write, and clear arbitrary clipboard formats on macOS via NSPasteboard.

**Architecture:** A single Zig project at `native/clipboard/` with two build targets (shared library + CLI executable) sharing a core module. The core delegates to a platform-specific backend (`platform/macos.zig`) that calls NSPasteboard through the Objective-C runtime. An `objc.zig` module provides type-safe wrappers around `objc_msgSend`.

**Tech Stack:** Zig 0.15.2, macOS NSPasteboard (via Objective-C runtime FFI), libobjc, AppKit framework

**Spec:** `docs/superpowers/specs/2026-04-06-zig-clipboard-library-design.md`

---

## Zig 0.15.2 API Notes

These APIs changed from earlier Zig versions. All code in this plan uses the verified 0.15.2 patterns:

- **stdout/stderr/stdin:** `std.fs.File.stdout()` / `.stderr()` / `.stdin()` (NOT `std.io.getStdOut()`)
- **Buffered writer:** `file.writer(&buf)` returns a `File.Writer`; use `w.interface.print(...)` and `w.interface.flush()`
- **Raw byte output:** `std.fs.File.stdout().writeAll(bytes)` still works directly on `File`
- **ArrayList (managed):** `std.array_list.Managed(T).init(allocator)` (NOT `std.ArrayList(T).init(allocator)` — `std.ArrayList` is now the unmanaged variant)
- **Shared library:** `b.addLibrary(.{ .linkage = .dynamic, ... })` (NOT `addSharedLibrary`)

---

## File Map

| File | Responsibility |
|------|---------------|
| `native/clipboard/build.zig` | Build config: shared lib + CLI executable, links libobjc + AppKit |
| `native/clipboard/src/objc.zig` | Obj-C runtime types and helpers: Class, SEL, id, msgSend wrappers, NSString/NSData/NSArray bridging |
| `native/clipboard/src/platform/macos.zig` | macOS backend: NSPasteboard calls for list/read/write/clear/changeCount |
| `native/clipboard/src/clipboard.zig` | Public API: delegates to platform backend based on `builtin.os.tag` |
| `native/clipboard/src/lib.zig` | C ABI exports for shared library (wraps clipboard.zig for FFI consumers) |
| `native/clipboard/src/main.zig` | CLI entry point: arg parsing, output formatting, subcommands |

---

## Task 1: Project Scaffold + Build System

**Files:**
- Create: `native/clipboard/build.zig`
- Create: `native/clipboard/src/main.zig`
- Create: `native/clipboard/src/lib.zig`
- Create: `native/clipboard/src/clipboard.zig`
- Create: `native/clipboard/src/objc.zig`
- Create: `native/clipboard/src/platform/macos.zig`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p native/clipboard/src/platform
```

- [ ] **Step 2: Create build.zig**

```zig
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
}
```

Note: libobjc and AppKit are linked on `clipboard_mod` which propagates to both the library and executable modules that import it.

- [ ] **Step 3: Create stub files**

`src/objc.zig` — empty, just a comment:
```zig
// Objective-C runtime bindings for Zig.
// Provides type-safe wrappers around objc_msgSend, NSString, NSData, NSArray.
```

`src/platform/macos.zig` — empty stub:
```zig
// macOS clipboard backend using NSPasteboard via Objective-C runtime.
```

`src/clipboard.zig` — minimal public API stub. Note: `writeFormat` and `writeMultiple` include allocator params from the start (needed internally for null-terminating format strings for Obj-C):
```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FormatDataPair = struct {
    format: []const u8,
    data: []const u8,
};

pub fn listFormats(allocator: Allocator) ![][]const u8 {
    _ = allocator;
    return &.{};
}

pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    _ = allocator;
    _ = format;
    return null;
}

pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    _ = allocator;
    _ = format;
    _ = data;
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    _ = allocator;
    _ = pairs;
}

pub fn clear() !void {}

pub fn getChangeCount() i64 {
    return 0;
}
```

`src/lib.zig` — minimal C ABI stub:
```zig
const clipboard = @import("clipboard");

export fn clipboard_change_count() i64 {
    return clipboard.getChangeCount();
}
```

`src/main.zig` — minimal CLI stub:
```zig
const std = @import("std");

pub fn main() !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);
    try w.interface.print("clipboard: not yet implemented\n", .{});
    try w.interface.flush();
}
```

- [ ] **Step 4: Verify the build works**

```bash
cd native/clipboard && zig build
```

Expected: builds both `zig-out/lib/libclipboard.dylib` and `zig-out/bin/clipboard` without errors.

- [ ] **Step 5: Verify CLI runs**

```bash
cd native/clipboard && zig build run
```

Expected: prints "clipboard: not yet implemented"

- [ ] **Step 6: Commit**

```bash
git add native/clipboard/
git commit -m "feat: scaffold Zig clipboard library and CLI project"
```

---

## Task 2: Objective-C Runtime Bindings (objc.zig)

**Files:**
- Modify: `native/clipboard/src/objc.zig`

This is the foundation everything else builds on. We need type-safe wrappers around `objc_msgSend` and helpers for NSString, NSData, and NSArray bridging.

- [ ] **Step 1: Define core Obj-C runtime types and extern functions**

`src/objc.zig`:
```zig
const std = @import("std");

// Opaque Objective-C types
pub const Class = *opaque {};
pub const SEL = *opaque {};
pub const id = *opaque {};
pub const NSUInteger = usize;
pub const NSInteger = isize;

// Objective-C runtime functions (from libobjc)
extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;

/// Look up an Objective-C class by name. Returns null if not found.
pub fn getClass(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

/// Register/look up a selector by name.
pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Cast objc_msgSend to a typed function pointer.
pub fn msgSendFn(comptime ReturnType: type, comptime ArgTypes: type) MsgSendFnType(ReturnType, ArgTypes) {
    return @ptrCast(&objc_msgSend);
}

fn MsgSendFnType(comptime ReturnType: type, comptime ArgTypes: type) type {
    const args_info = @typeInfo(ArgTypes);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => *const fn (id, SEL) callconv(.c) ReturnType,
        1 => *const fn (id, SEL, fields[0].type) callconv(.c) ReturnType,
        2 => *const fn (id, SEL, fields[0].type, fields[1].type) callconv(.c) ReturnType,
        3 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) ReturnType,
        else => @compileError("msgSendFn: too many arguments, add more cases"),
    };
}

/// Send a message to an Objective-C object.
/// All calls in this project return object pointers or integer types, so only
/// objc_msgSend is needed. If future extensions return structs by value on x86_64,
/// objc_msgSend_stret would be required (ARM64 does not use it).
pub fn msgSend(comptime ReturnType: type, target: anytype, selector: SEL, args: anytype) ReturnType {
    const target_as_id: id = @ptrCast(target);
    const ArgsType = @TypeOf(args);
    const func = msgSendFn(ReturnType, ArgsType);

    const args_info = @typeInfo(ArgsType);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => func(target_as_id, selector),
        1 => func(target_as_id, selector, args[0]),
        2 => func(target_as_id, selector, args[0], args[1]),
        3 => func(target_as_id, selector, args[0], args[1], args[2]),
        else => @compileError("msgSend: too many arguments"),
    };
}
```

- [ ] **Step 2: Add NSString bridging helpers**

Append to `src/objc.zig`:
```zig
/// Create an NSString from a Zig slice. The NSString is autoreleased.
pub fn nsString(str: [*:0]const u8) id {
    const NSString = getClass("NSString") orelse unreachable;
    return msgSend(id, NSString, sel("stringWithUTF8String:"), .{str});
}

/// Read a UTF-8 C string from an NSString. The pointer is valid as long as the NSString lives.
pub fn fromNSString(nsstr: id) ?[*:0]const u8 {
    return msgSend(?[*:0]const u8, nsstr, sel("UTF8String"), .{});
}

/// Get the length of an NSString (number of UTF-16 code units).
pub fn nsStringLength(nsstr: id) NSUInteger {
    return msgSend(NSUInteger, nsstr, sel("length"), .{});
}
```

- [ ] **Step 3: Add NSData bridging helpers**

Append to `src/objc.zig`:
```zig
/// Get the raw bytes pointer from an NSData object.
pub fn nsDataBytes(nsdata: id) ?[*]const u8 {
    return msgSend(?[*]const u8, nsdata, sel("bytes"), .{});
}

/// Get the length of an NSData object.
pub fn nsDataLength(nsdata: id) NSUInteger {
    return msgSend(NSUInteger, nsdata, sel("length"), .{});
}

/// Create an NSData from a Zig byte slice. The NSData is autoreleased.
/// For zero-length data, pass any valid pointer (the bytes won't be read).
pub fn nsDataFromBytes(bytes: [*]const u8, len: NSUInteger) id {
    const NSData = getClass("NSData") orelse unreachable;
    return msgSend(id, NSData, sel("dataWithBytes:length:"), .{ bytes, len });
}

/// Create an empty NSData. Autoreleased.
pub fn nsDataEmpty() id {
    const NSData = getClass("NSData") orelse unreachable;
    return msgSend(id, NSData, sel("data"), .{});
}
```

- [ ] **Step 4: Add NSArray helpers**

Append to `src/objc.zig`:
```zig
/// Get the count of an NSArray.
pub fn nsArrayCount(nsarray: id) NSUInteger {
    return msgSend(NSUInteger, nsarray, sel("count"), .{});
}

/// Get an object from an NSArray at a given index.
pub fn nsArrayObjectAtIndex(nsarray: id, index: NSUInteger) id {
    return msgSend(id, nsarray, sel("objectAtIndex:"), .{index});
}
```

- [ ] **Step 5: Verify build still compiles**

```bash
cd native/clipboard && zig build
```

Expected: compiles without errors.

- [ ] **Step 6: Commit**

```bash
git add native/clipboard/src/objc.zig
git commit -m "feat: add Objective-C runtime bindings for Zig (objc.zig)"
```

---

## Task 3: macOS Platform Backend — listFormats + getChangeCount

**Files:**
- Modify: `native/clipboard/src/platform/macos.zig`
- Modify: `native/clipboard/src/clipboard.zig`

Start with the two read-only operations: listing formats and getting the change count. These are the simplest NSPasteboard calls and will validate the entire objc_msgSend chain.

- [ ] **Step 1: Implement getChangeCount in macos.zig**

`src/platform/macos.zig`:
```zig
const std = @import("std");
const objc = @import("../objc.zig");

const Allocator = std.mem.Allocator;

/// Get the NSPasteboard generalPasteboard singleton. Returns null if unavailable (e.g. daemon context).
fn getPasteboard() ?objc.id {
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return null;
    return objc.msgSend(?objc.id, NSPasteboard, objc.sel("generalPasteboard"), .{});
}

/// Returns the pasteboard change count. Returns -1 if pasteboard is unavailable.
/// Note: NSPasteboard.changeCount returns NSInteger (isize), which is i64 on 64-bit macOS.
pub fn getChangeCount() i64 {
    const pb = getPasteboard() orelse return -1;
    return objc.msgSend(objc.NSInteger, pb, objc.sel("changeCount"), .{});
}
```

- [ ] **Step 2: Implement listFormats in macos.zig**

Append to `src/platform/macos.zig`:
```zig
pub const ClipboardError = error{
    PasteboardUnavailable,
    NoItems,
    WriteFailed,
};

/// List all format identifiers (UTIs) on the clipboard.
/// Caller owns the returned slice and each string within it.
pub fn listFormats(allocator: Allocator) ![][]const u8 {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;

    // Get pasteboard items
    const items: ?objc.id = objc.msgSend(?objc.id, pb, objc.sel("pasteboardItems"), .{});
    const items_array = items orelse return &.{};

    const items_count = objc.nsArrayCount(items_array);
    if (items_count == 0) return &.{};

    // Get first item's types
    const first_item = objc.nsArrayObjectAtIndex(items_array, 0);
    const types: ?objc.id = objc.msgSend(?objc.id, first_item, objc.sel("types"), .{});
    const types_array = types orelse return &.{};

    const count = objc.nsArrayCount(types_array);
    if (count == 0) return &.{};

    var result = try allocator.alloc([]const u8, count);
    var actual_count: usize = 0;

    for (0..count) |i| {
        const nsstr = objc.nsArrayObjectAtIndex(types_array, i);
        const cstr = objc.fromNSString(nsstr) orelse continue;
        const len = std.mem.len(cstr);
        const copy = try allocator.alloc(u8, len);
        @memcpy(copy, cstr[0..len]);
        result[actual_count] = copy;
        actual_count += 1;
    }

    // Shrink if we skipped any
    if (actual_count < count) {
        result = allocator.realloc(result, actual_count) catch result[0..actual_count];
    }

    return result[0..actual_count];
}
```

- [ ] **Step 3: Wire up clipboard.zig to delegate to macos backend**

Replace `src/clipboard.zig` with:
```zig
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos.zig"),
    else => @compileError("Unsupported platform. Currently only macOS is implemented."),
};

pub const FormatDataPair = struct {
    format: []const u8,
    data: []const u8,
};

pub const ClipboardError = platform.ClipboardError;

pub fn listFormats(allocator: Allocator) ![][]const u8 {
    return platform.listFormats(allocator);
}

pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    _ = allocator;
    _ = format;
    return null; // TODO: implement in Task 4
}

pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    _ = allocator;
    _ = format;
    _ = data;
    // TODO: implement in Task 5
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    _ = allocator;
    _ = pairs;
    // TODO: implement in Task 5
}

pub fn clear() !void {
    // TODO: implement in Task 5
}

pub fn getChangeCount() i64 {
    return platform.getChangeCount();
}
```

- [ ] **Step 4: Update main.zig to test listFormats**

Replace `src/main.zig` with a temporary test that just lists formats:
```zig
const std = @import("std");
const clipboard = @import("clipboard");

pub fn main() !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const change_count = clipboard.getChangeCount();
    try w.interface.print("changeCount: {d}\n", .{change_count});

    const formats = try clipboard.listFormats(allocator);
    defer {
        for (formats) |f| allocator.free(f);
        allocator.free(formats);
    }

    try w.interface.print("Formats ({d}):\n", .{formats.len});
    for (formats) |format| {
        try w.interface.print("  {s}\n", .{format});
    }
    try w.interface.flush();
}
```

- [ ] **Step 5: Build and test**

```bash
cd native/clipboard && zig build run
```

Expected: prints the change count and lists UTIs currently on the clipboard. Copy some text first to ensure there's something there. Example output:
```
changeCount: 42
Formats (3):
  public.utf8-plain-text
  public.utf16-plain-text
  org.chromium.web-custom-data
```

- [ ] **Step 6: Commit**

```bash
git add native/clipboard/src/
git commit -m "feat: implement listFormats and getChangeCount via NSPasteboard"
```

---

## Task 4: macOS Platform Backend — readFormat

**Files:**
- Modify: `native/clipboard/src/platform/macos.zig`
- Modify: `native/clipboard/src/clipboard.zig`

- [ ] **Step 1: Implement readFormat in macos.zig**

Append to `src/platform/macos.zig`:
```zig
/// Read raw bytes for a given format (UTI) from the clipboard.
/// Returns null if the format is not present.
/// Caller owns the returned slice.
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;

    const items: ?objc.id = objc.msgSend(?objc.id, pb, objc.sel("pasteboardItems"), .{});
    const items_array = items orelse return null;

    const items_count = objc.nsArrayCount(items_array);
    if (items_count == 0) return null;

    const first_item = objc.nsArrayObjectAtIndex(items_array, 0);

    // Create NSString for the format UTI — need null-terminated copy
    const format_z = try allocator.dupeZ(u8, format);
    defer allocator.free(format_z);

    const format_nsstr = objc.nsString(format_z);

    // Call [item dataForType:]
    const nsdata: ?objc.id = objc.msgSend(?objc.id, first_item, objc.sel("dataForType:"), .{format_nsstr});
    const data = nsdata orelse return null;

    const len = objc.nsDataLength(data);
    if (len == 0) {
        // Zero-length data is valid — return empty owned slice
        return try allocator.alloc(u8, 0);
    }

    const bytes = objc.nsDataBytes(data) orelse return null;

    // Copy bytes into Zig-owned memory
    const result = try allocator.alloc(u8, len);
    @memcpy(result, bytes[0..len]);
    return result;
}
```

- [ ] **Step 2: Wire up readFormat in clipboard.zig**

In `src/clipboard.zig`, replace the `readFormat` stub:
```zig
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    return platform.readFormat(allocator, format);
}
```

- [ ] **Step 3: Update main.zig to test readFormat**

Replace `src/main.zig` to show a preview of each format:
```zig
const std = @import("std");
const clipboard = @import("clipboard");

pub fn main() !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const change_count = clipboard.getChangeCount();
    const formats = try clipboard.listFormats(allocator);
    defer {
        for (formats) |f| allocator.free(f);
        allocator.free(formats);
    }

    try w.interface.print("Clipboard contents ({d} formats, changeCount: {d}):\n\n", .{ formats.len, change_count });

    for (formats) |format| {
        const data = try clipboard.readFormat(allocator, format);
        if (data) |bytes| {
            defer allocator.free(bytes);
            try w.interface.print("  {s}    {d} bytes\n", .{ format, bytes.len });

            if (isLikelyText(format)) {
                const preview_len = @min(bytes.len, 80);
                try w.interface.print("  \"{s}", .{bytes[0..preview_len]});
                if (bytes.len > 80) try w.interface.print("...", .{});
                try w.interface.print("\"\n\n", .{});
            } else {
                const hex_len = @min(bytes.len, 8);
                try w.interface.print("  [", .{});
                for (bytes[0..hex_len], 0..) |byte, i| {
                    if (i > 0) try w.interface.print(" ", .{});
                    try w.interface.print("{X:0>2}", .{byte});
                }
                try w.interface.print("]", .{});
                if (bytes.len > 8) try w.interface.print(" ...", .{});
                try w.interface.print("\n\n", .{});
            }
        } else {
            try w.interface.print("  {s}    (not readable)\n\n", .{format});
        }
    }
    try w.interface.flush();
}

fn isLikelyText(format: []const u8) bool {
    const text_formats = [_][]const u8{
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.html",
        "public.rtf",
        "public.file-url",
    };
    for (text_formats) |tf| {
        if (std.mem.eql(u8, format, tf)) return true;
    }
    return false;
}
```

- [ ] **Step 4: Build and test**

Copy some text and HTML (e.g. from a browser), then:
```bash
cd native/clipboard && zig build run
```

Expected: shows each format with byte count and a text/hex preview.

- [ ] **Step 5: Commit**

```bash
git add native/clipboard/src/
git commit -m "feat: implement readFormat with smart text/hex preview in CLI"
```

---

## Task 5: macOS Platform Backend — writeFormat, writeMultiple, clear

**Files:**
- Modify: `native/clipboard/src/platform/macos.zig`
- Modify: `native/clipboard/src/clipboard.zig`

- [ ] **Step 1: Implement clear in macos.zig**

Append to `src/platform/macos.zig`:
```zig
/// Clear the clipboard.
pub fn clear() !void {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;
    _ = objc.msgSend(objc.NSInteger, pb, objc.sel("clearContents"), .{});
}
```

- [ ] **Step 2: Implement writeFormat in macos.zig**

Append to `src/platform/macos.zig`:
```zig
/// Write a single format to the clipboard. Clears the clipboard first.
pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;

    // Clear first (required by macOS — writes fail without prior clearContents)
    _ = objc.msgSend(objc.NSInteger, pb, objc.sel("clearContents"), .{});

    const format_z = try allocator.dupeZ(u8, format);
    defer allocator.free(format_z);

    const format_nsstr = objc.nsString(format_z);

    // Handle zero-length data safely (avoid sending undefined pointer through FFI)
    const nsdata = if (data.len == 0)
        objc.nsDataEmpty()
    else
        objc.nsDataFromBytes(data.ptr, data.len);

    // [pasteboard setData:forType:] returns BOOL
    const success = objc.msgSend(bool, pb, objc.sel("setData:forType:"), .{ nsdata, format_nsstr });
    if (!success) return ClipboardError.WriteFailed;
}
```

- [ ] **Step 3: Implement writeMultiple in macos.zig**

`writeMultiple` needs `FormatDataPair` but we don't want a circular import between `clipboard.zig` and `macos.zig`. Instead, define the pair type locally in `macos.zig`:

Append to `src/platform/macos.zig`:
```zig
pub const FormatDataPair = struct {
    format: []const u8,
    data: []const u8,
};

/// Write multiple formats atomically. Clears clipboard once, then writes all.
pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;

    // Clear once
    _ = objc.msgSend(objc.NSInteger, pb, objc.sel("clearContents"), .{});

    // Write each format
    for (pairs) |pair| {
        const format_z = try allocator.dupeZ(u8, pair.format);
        defer allocator.free(format_z);

        const format_nsstr = objc.nsString(format_z);
        const nsdata = if (pair.data.len == 0)
            objc.nsDataEmpty()
        else
            objc.nsDataFromBytes(pair.data.ptr, pair.data.len);

        const success = objc.msgSend(bool, pb, objc.sel("setData:forType:"), .{ nsdata, format_nsstr });
        if (!success) return ClipboardError.WriteFailed;
    }
}
```

- [ ] **Step 4: Wire up write functions in clipboard.zig**

Update `src/clipboard.zig` — replace the stubs for `writeFormat`, `writeMultiple`, and `clear`:

```zig
pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    return platform.writeFormat(allocator, format, data);
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    // Convert clipboard.FormatDataPair to platform.FormatDataPair
    // These are structurally identical, so we can @ptrCast the slice
    const platform_pairs: []const platform.FormatDataPair = @ptrCast(pairs);
    return platform.writeMultiple(allocator, platform_pairs);
}

pub fn clear() !void {
    return platform.clear();
}
```

- [ ] **Step 5: Test write via CLI manually**

Add a quick test to main.zig (temporary) — after the existing introspection output, write a test value and read it back:
```zig
// Quick write test — write text, read it back
try clipboard.writeFormat(allocator, "public.utf8-plain-text", "Hello from Zig clipboard!");
const readback = try clipboard.readFormat(allocator, "public.utf8-plain-text");
if (readback) |rb| {
    defer allocator.free(rb);
    try w.interface.print("Write test: \"{s}\"\n", .{rb});
    try w.interface.flush();
}
```

```bash
cd native/clipboard && zig build run
```

Expected: at the end of output, prints `Write test: "Hello from Zig clipboard!"`. Also verify by pasting in another app — should paste "Hello from Zig clipboard!".

- [ ] **Step 6: Remove the temporary write test from main.zig**

Remove the write test lines added in step 5.

- [ ] **Step 7: Commit**

```bash
git add native/clipboard/src/
git commit -m "feat: implement writeFormat, writeMultiple, and clear"
```

---

## Task 6: Full CLI with Subcommands

**Files:**
- Modify: `native/clipboard/src/main.zig`

Replace the temporary test CLI with the full subcommand interface.

- [ ] **Step 1: Implement arg parsing and command dispatch**

Replace `src/main.zig` entirely:
```zig
const std = @import("std");
const clipboard = @import("clipboard");

const Allocator = std.mem.Allocator;

// Buffered writer type for stdout/stderr
const StdoutWriter = std.fs.File.Writer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for --json global flag
    var json_output = false;
    var filtered_args = std.array_list.Managed([]const u8).init(allocator);
    defer filtered_args.deinit();

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else {
            try filtered_args.append(arg);
        }
    }

    const cmd_args = filtered_args.items;

    if (cmd_args.len == 0) {
        return introspect(allocator, json_output);
    }

    const command = cmd_args[0];

    if (std.mem.eql(u8, command, "list")) {
        return cmdList(allocator, json_output);
    } else if (std.mem.eql(u8, command, "read")) {
        return cmdRead(allocator, cmd_args[1..]);
    } else if (std.mem.eql(u8, command, "write")) {
        return cmdWrite(allocator, cmd_args[1..]);
    } else if (std.mem.eql(u8, command, "clear")) {
        return cmdClear();
    } else if (std.mem.eql(u8, command, "watch")) {
        return cmdWatch(allocator, cmd_args[1..], json_output);
    } else {
        const stderr_file = std.fs.File.stderr();
        var buf: [4096]u8 = undefined;
        var w = stderr_file.writer(&buf);
        try w.interface.print("Unknown command: {s}\n", .{command});
        try printUsage(&w.interface);
        try w.interface.flush();
        std.process.exit(1);
    }
}

fn printUsage(writer: *std.io.Writer) !void {
    try writer.print(
        \\Usage: clipboard [command] [options]
        \\
        \\Commands:
        \\  (none)              Show clipboard contents (default)
        \\  list                List format names, one per line
        \\  read <format>       Read format data to stdout
        \\  write <format>      Write data from stdin to clipboard
        \\  clear               Clear the clipboard
        \\  watch               Watch for clipboard changes
        \\
        \\Global flags:
        \\  --json              Output as JSON
        \\
    , .{});
}
```

- [ ] **Step 2: Implement introspect (default command)**

Append to `src/main.zig`:
```zig
fn introspect(allocator: Allocator, json_output: bool) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);

    const change_count = clipboard.getChangeCount();
    const formats = try clipboard.listFormats(allocator);
    defer {
        for (formats) |f| allocator.free(f);
        allocator.free(formats);
    }

    if (json_output) {
        try jsonIntrospect(allocator, &w.interface, formats, change_count);
        try w.interface.flush();
        return;
    }

    try w.interface.print("Clipboard contents ({d} format{s}, changeCount: {d}):\n\n", .{
        formats.len,
        if (formats.len != 1) "s" else "",
        change_count,
    });

    for (formats) |format| {
        const data = try clipboard.readFormat(allocator, format);
        if (data) |bytes| {
            defer allocator.free(bytes);
            try printFormatPreview(&w.interface, format, bytes);
        } else {
            try w.interface.print("  {s}    (not readable)\n\n", .{format});
        }
    }
    try w.interface.flush();
}

fn printFormatPreview(writer: *std.io.Writer, format: []const u8, bytes: []const u8) !void {
    try writer.print("  {s}    {d} bytes\n", .{ format, bytes.len });

    if (isLikelyText(format)) {
        const preview_len = @min(bytes.len, 80);
        // Replace newlines with spaces for preview
        var preview_buf: [80]u8 = undefined;
        const preview = bytes[0..preview_len];
        for (preview, 0..) |c, i| {
            preview_buf[i] = if (c == '\n' or c == '\r') ' ' else c;
        }
        try writer.print("  \"{s}", .{preview_buf[0..preview_len]});
        if (bytes.len > 80) try writer.print("...", .{});
        try writer.print("\"\n\n", .{});
    } else {
        const hex_len = @min(bytes.len, 8);
        try writer.print("  [", .{});
        for (bytes[0..hex_len], 0..) |byte, i| {
            if (i > 0) try writer.print(" ", .{});
            try writer.print("{X:0>2}", .{byte});
        }
        try writer.print("]", .{});
        if (bytes.len > 8) try writer.print(" ...", .{});
        try writer.print(" ({s})\n\n", .{detectType(bytes)});
    }
}

fn isLikelyText(format: []const u8) bool {
    const text_formats = [_][]const u8{
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.html",
        "public.rtf",
        "public.file-url",
    };
    for (text_formats) |tf| {
        if (std.mem.eql(u8, format, tf)) return true;
    }
    return false;
}

fn detectType(bytes: []const u8) []const u8 {
    if (bytes.len >= 4) {
        // PNG magic: 89 50 4E 47
        if (bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47) return "PNG image";
        // TIFF: 49 49 2A 00 or 4D 4D 00 2A
        if ((bytes[0] == 0x49 and bytes[1] == 0x49 and bytes[2] == 0x2A and bytes[3] == 0x00) or
            (bytes[0] == 0x4D and bytes[1] == 0x4D and bytes[2] == 0x00 and bytes[3] == 0x2A)) return "TIFF image";
        // PDF: 25 50 44 46
        if (bytes[0] == 0x25 and bytes[1] == 0x50 and bytes[2] == 0x44 and bytes[3] == 0x46) return "PDF";
    }
    return "binary";
}

fn jsonIntrospect(allocator: Allocator, writer: *std.io.Writer, formats: [][]const u8, change_count: i64) !void {
    // Note: format names (UTIs) typically don't contain special JSON characters.
    // If they do, this output would be invalid JSON. Acceptable for now.
    try writer.print("{{\"changeCount\":{d},\"formats\":[", .{change_count});
    for (formats, 0..) |format, i| {
        if (i > 0) try writer.print(",", .{});
        const data = try clipboard.readFormat(allocator, format);
        const size: usize = if (data) |d| blk: {
            defer allocator.free(d);
            break :blk d.len;
        } else 0;
        try writer.print("{{\"name\":\"{s}\",\"size\":{d}}}", .{ format, size });
    }
    try writer.print("]}}\n", .{});
}
```

- [ ] **Step 3: Implement cmdList**

Append to `src/main.zig`:
```zig
fn cmdList(allocator: Allocator, json_output: bool) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);

    const formats = try clipboard.listFormats(allocator);
    defer {
        for (formats) |f| allocator.free(f);
        allocator.free(formats);
    }

    if (json_output) {
        try w.interface.print("[", .{});
        for (formats, 0..) |format, i| {
            if (i > 0) try w.interface.print(",", .{});
            try w.interface.print("\"{s}\"", .{format});
        }
        try w.interface.print("]\n", .{});
        try w.interface.flush();
        return;
    }

    for (formats) |format| {
        try w.interface.print("{s}\n", .{format});
    }
    try w.interface.flush();
}
```

- [ ] **Step 4: Implement cmdRead**

Append to `src/main.zig`:
```zig
fn cmdRead(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr_file = std.fs.File.stderr();
        var buf: [4096]u8 = undefined;
        var w = stderr_file.writer(&buf);
        try w.interface.print("Usage: clipboard read <format> [--out <file>]\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    }

    const format = args[0];
    var out_file: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_file = args[i + 1];
            i += 1;
        }
    }

    const data = try clipboard.readFormat(allocator, format);
    if (data) |bytes| {
        defer allocator.free(bytes);

        if (out_file) |path| {
            const file = try std.fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(bytes);
            const stderr_file = std.fs.File.stderr();
            var buf: [4096]u8 = undefined;
            var w = stderr_file.writer(&buf);
            try w.interface.print("Wrote {d} bytes to {s}\n", .{ bytes.len, path });
            try w.interface.flush();
        } else {
            const stdout_file = std.fs.File.stdout();
            try stdout_file.writeAll(bytes);
        }
    } else {
        const stderr_file = std.fs.File.stderr();
        var buf: [4096]u8 = undefined;
        var w = stderr_file.writer(&buf);
        try w.interface.print("Format not found: {s}\n", .{format});
        try w.interface.flush();
        std.process.exit(1);
    }
}
```

- [ ] **Step 5: Implement cmdWrite**

Append to `src/main.zig`:
```zig
fn cmdWrite(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr_file = std.fs.File.stderr();
        var buf: [4096]u8 = undefined;
        var w = stderr_file.writer(&buf);
        try w.interface.print("Usage: clipboard write <format> [--data \"text\"]\n", .{});
        try w.interface.flush();
        std.process.exit(1);
    }

    const format = args[0];
    var inline_data: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--data") and i + 1 < args.len) {
            inline_data = args[i + 1];
            i += 1;
        }
    }

    if (inline_data) |data| {
        try clipboard.writeFormat(allocator, format, data);
    } else {
        // Read from stdin
        const stdin_file = std.fs.File.stdin();
        const data = try stdin_file.readToEndAlloc(allocator, 1024 * 1024 * 100); // 100MB max
        defer allocator.free(data);
        try clipboard.writeFormat(allocator, format, data);
    }
}
```

- [ ] **Step 6: Implement cmdClear**

Append to `src/main.zig`:
```zig
fn cmdClear() !void {
    try clipboard.clear();
}
```

- [ ] **Step 7: Implement cmdWatch**

Append to `src/main.zig`:
```zig
fn cmdWatch(allocator: Allocator, args: []const []const u8, json_output: bool) !void {
    var interval_ms: u64 = 500;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--interval") and i + 1 < args.len) {
            interval_ms = std.fmt.parseInt(u64, args[i + 1], 10) catch 500;
            i += 1;
        }
    }

    const stderr_file = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = stderr_file.writer(&stderr_buf);
    try stderr_w.interface.print("Watching clipboard (interval: {d}ms, Ctrl+C to stop)...\n\n", .{interval_ms});
    try stderr_w.interface.flush();

    var last_count = clipboard.getChangeCount();

    while (true) {
        std.time.sleep(interval_ms * std.time.ns_per_ms);
        const current_count = clipboard.getChangeCount();
        if (current_count != last_count) {
            last_count = current_count;
            try introspect(allocator, json_output);
            const stdout_file = std.fs.File.stdout();
            var stdout_buf: [4096]u8 = undefined;
            var stdout_w = stdout_file.writer(&stdout_buf);
            try stdout_w.interface.print("---\n\n", .{});
            try stdout_w.interface.flush();
        }
    }
}
```

- [ ] **Step 8: Build and test all subcommands**

```bash
cd native/clipboard && zig build
```

Test each command:
```bash
# Default introspection
./zig-out/bin/clipboard

# List formats
./zig-out/bin/clipboard list

# Read specific format
./zig-out/bin/clipboard read public.utf8-plain-text

# Write text
./zig-out/bin/clipboard write public.utf8-plain-text --data "test from zig"

# Verify write worked
./zig-out/bin/clipboard read public.utf8-plain-text

# Clear
./zig-out/bin/clipboard clear
./zig-out/bin/clipboard list

# JSON output
./zig-out/bin/clipboard --json

# Watch (Ctrl+C to stop after copying something)
./zig-out/bin/clipboard watch --interval 1000
```

- [ ] **Step 9: Commit**

```bash
git add native/clipboard/src/main.zig
git commit -m "feat: full CLI with list, read, write, clear, watch subcommands"
```

---

## Task 7: C ABI Shared Library Exports

**Files:**
- Modify: `native/clipboard/src/lib.zig`

Wire up the C ABI exports so the `.dylib` can be consumed by Bun FFI or any C/C++ consumer. The library never panics — all failures return error codes.

- [ ] **Step 1: Implement all C ABI exports**

Replace `src/lib.zig`:
```zig
const std = @import("std");
const clipboard = @import("clipboard");

const allocator = std.heap.c_allocator;

pub const ClipboardData = extern struct {
    data: ?[*]const u8,
    len: usize,
    status: i32, // 0 = success, 1 = not found, -1 = error
};

pub const ClipboardFormatPair = extern struct {
    format: [*:0]const u8,
    data: [*]const u8,
    len: usize,
};

export fn clipboard_list_formats() ?[*:0]u8 {
    const formats = clipboard.listFormats(allocator) catch return null;
    defer {
        for (formats) |f| allocator.free(f);
        allocator.free(formats);
    }

    // Build JSON array string
    // Note: UTI format names typically don't contain JSON special characters.
    var json = std.array_list.Managed(u8).init(allocator);
    defer json.deinit();

    json.append('[') catch return null;
    for (formats, 0..) |format, i| {
        if (i > 0) json.append(',') catch return null;
        json.append('"') catch return null;
        json.appendSlice(format) catch return null;
        json.append('"') catch return null;
    }
    json.append(']') catch return null;

    // Return null-terminated owned copy (caller must clipboard_free)
    const result = allocator.allocSentinel(u8, json.items.len, 0) catch return null;
    @memcpy(result[0..json.items.len], json.items);
    return result;
}

export fn clipboard_read_format(format: [*:0]const u8) ClipboardData {
    const format_slice = std.mem.sliceTo(format, 0);
    const result = clipboard.readFormat(allocator, format_slice) catch {
        return .{ .data = null, .len = 0, .status = -1 };
    };

    if (result) |bytes| {
        return .{ .data = bytes.ptr, .len = bytes.len, .status = 0 };
    } else {
        return .{ .data = null, .len = 0, .status = 1 };
    }
}

export fn clipboard_write_format(format: [*:0]const u8, data: [*]const u8, len: usize) i32 {
    const format_slice = std.mem.sliceTo(format, 0);
    clipboard.writeFormat(allocator, format_slice, data[0..len]) catch return -1;
    return 0;
}

export fn clipboard_write_multiple(pairs: [*]const ClipboardFormatPair, count: u32) i32 {
    var zig_pairs = allocator.alloc(clipboard.FormatDataPair, count) catch return -1;
    defer allocator.free(zig_pairs);

    for (0..count) |i| {
        zig_pairs[i] = .{
            .format = std.mem.sliceTo(pairs[i].format, 0),
            .data = pairs[i].data[0..pairs[i].len],
        };
    }

    clipboard.writeMultiple(allocator, zig_pairs) catch return -1;
    return 0;
}

export fn clipboard_clear() i32 {
    clipboard.clear() catch return -1;
    return 0;
}

export fn clipboard_change_count() i64 {
    return clipboard.getChangeCount();
}

export fn clipboard_free(ptr: ?*anyopaque) void {
    // c_allocator delegates to malloc/free, so we can free by pointer alone.
    if (ptr) |p| {
        std.c.free(p);
    }
}
```

- [ ] **Step 2: Build and verify the dylib exports**

```bash
cd native/clipboard && zig build
nm -gU zig-out/lib/libclipboard.dylib | grep clipboard_
```

Expected: all exported symbols are listed:
```
_clipboard_change_count
_clipboard_clear
_clipboard_free
_clipboard_list_formats
_clipboard_read_format
_clipboard_write_format
_clipboard_write_multiple
```

- [ ] **Step 3: Commit**

```bash
git add native/clipboard/src/lib.zig
git commit -m "feat: C ABI shared library exports for FFI consumers"
```

---

## Summary

| Task | What it builds | Milestone |
|------|---------------|-----------|
| 1 | Project scaffold, build.zig, stubs | `zig build` works, CLI prints hello |
| 2 | objc.zig: Obj-C runtime bindings | Foundation for all macOS calls |
| 3 | listFormats + getChangeCount | First real NSPasteboard interaction — CLI lists UTIs |
| 4 | readFormat | Can read any format's raw bytes |
| 5 | writeFormat, writeMultiple, clear | Full clipboard read/write cycle |
| 6 | Full CLI with subcommands | Usable standalone tool |
| 7 | C ABI exports (lib.zig) | Shared library ready for Bun FFI |
