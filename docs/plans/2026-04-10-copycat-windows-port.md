# Copycat Windows Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Windows 10+ support to the Copycat clipboard library, CLI, and C ABI shared library.

**Architecture:** A new `platform/windows.zig` backend using Win32 clipboard API (`OpenClipboard`, `GetClipboardData`, `SetClipboardData`, etc.) behind the existing platform dispatch in `clipboard.zig`. Format IDs mapped to human-readable strings. Subscribe via `AddClipboardFormatListener` on a message-only window. File path decoding via pure-Zig `decodeHDrop` in `paths.zig`.

**Tech Stack:** Zig, Win32 API (kernel32, user32), cross-compiled from macOS, tested on Windows 11 VM.

**Spec:** `docs/specs/2026-04-10-copycat-windows-port-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `src/platform/windows.zig` | Create | Win32 clipboard backend — all platform functions |
| `src/paths.zig` | Modify | Add `decodeHDrop()` for CF_HDROP parsing |
| `src/clipboard.zig` | Modify (line 7) | Add `.windows` arm to platform switch |
| `src/main.zig` | Modify (line 185) | Add Windows format names to `isLikelyText()` |
| `build.zig` | Modify (line 40) | Add `.windows` linking (kernel32, user32) |

---

### Task 1: `decodeHDrop` in paths.zig (pure Zig, no OS deps)

Start here because it's unit-testable on macOS — no VM needed.

**Files:**
- Modify: `src/paths.zig`

- [ ] **Step 1: Write failing tests for `decodeHDrop`**

Add at the bottom of `src/paths.zig`, in the test block area:

```zig
test "decodeHDrop: single wide-char path" {
    // DROPFILES header: pFiles=20, pt=(0,0), fNC=0, fWide=1
    // Followed by "C:\test.txt\0\0" in UTF-16LE
    const header = [_]u8{
        0x14, 0x00, 0x00, 0x00, // pFiles = 20
        0x00, 0x00, 0x00, 0x00, // pt.x = 0
        0x00, 0x00, 0x00, 0x00, // pt.y = 0
        0x00, 0x00, 0x00, 0x00, // fNC = 0
        0x01, 0x00, 0x00, 0x00, // fWide = 1 (Unicode)
    };
    // "C:\test.txt" in UTF-16LE + null + null (double-null terminator)
    const path_data = [_]u8{
        'C', 0, ':', 0, '\\', 0, 't', 0, 'e', 0, 's', 0, 't', 0, '.', 0, 't', 0, 'x', 0, 't', 0,
        0, 0, // null terminator
        0, 0, // double-null terminator
    };
    const data = header ++ path_data;

    const paths = try decodeHDrop(std.testing.allocator, &data);
    defer {
        for (paths) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("C:\\test.txt", paths[0]);
}

test "decodeHDrop: multiple wide-char paths" {
    const header = [_]u8{
        0x14, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
    };
    // "A\0" + null + "B\0" + null + double-null
    const path_data = [_]u8{
        'A', 0, 0, 0, // "A" + null
        'B', 0, 0, 0, // "B" + null
        0, 0,         // double-null terminator
    };
    const data = header ++ path_data;

    const paths = try decodeHDrop(std.testing.allocator, &data);
    defer {
        for (paths) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("A", paths[0]);
    try std.testing.expectEqualStrings("B", paths[1]);
}

test "decodeHDrop: data too short for header" {
    const short = [_]u8{ 0x14, 0x00 };
    try std.testing.expectError(error.MalformedHDrop, decodeHDrop(std.testing.allocator, &short));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1`
Expected: Compilation error — `decodeHDrop` not defined yet.

- [ ] **Step 3: Add `MalformedHDrop` to `DecodePathError` and implement `decodeHDrop`**

In `src/paths.zig`, add `MalformedHDrop` to the `DecodePathError` enum (around line 11), then add the function:

```zig
/// Decode a Windows CF_HDROP (DROPFILES) blob into UTF-8 file paths.
/// The blob starts with a 20-byte DROPFILES header; `pFiles` gives the
/// offset from byte 0 to the start of the null-terminated path strings.
/// When `fWide` is non-zero the paths are UTF-16LE; otherwise ANSI.
pub fn decodeHDrop(allocator: Allocator, data: []const u8) ![]const []const u8 {
    if (data.len < 20) return error.MalformedHDrop;

    // Read pFiles (little-endian u32 at offset 0)
    const p_files = std.mem.readInt(u32, data[0..4], .little);
    // Read fWide (little-endian u32 at offset 16)
    const f_wide = std.mem.readInt(u32, data[16..20], .little);

    if (p_files > data.len) return error.MalformedHDrop;

    const payload = data[p_files..];
    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |p| allocator.free(p);
        result.deinit();
    }

    if (f_wide != 0) {
        // UTF-16LE paths, null-separated, double-null terminated
        var i: usize = 0;
        while (i + 1 < payload.len) {
            // Check for double-null terminator
            if (payload[i] == 0 and payload[i + 1] == 0) break;

            // Find end of this null-terminated UTF-16LE string
            var end = i;
            while (end + 1 < payload.len) {
                if (payload[end] == 0 and payload[end + 1] == 0) break;
                end += 2;
            }

            // Convert UTF-16LE slice to UTF-8
            const wide_bytes = payload[i..end];
            if (wide_bytes.len % 2 != 0) return error.MalformedHDrop;
            const wide_slice = std.mem.bytesAsSlice(u16, @as([]align(1) const u16, @alignCast(wide_bytes)));
            // actually we need to handle unaligned reads
            var wide_buf = try allocator.alloc(u16, wide_bytes.len / 2);
            defer allocator.free(wide_buf);
            for (wide_buf, 0..) |*w, idx| {
                w.* = std.mem.readInt(u16, wide_bytes[idx * 2 ..][0..2], .little);
            }

            const utf8_len = std.unicode.utf16CountCodepoints(wide_buf) catch return error.MalformedHDrop;
            var utf8_buf = try allocator.alloc(u8, utf8_len);
            errdefer allocator.free(utf8_buf);
            const written = std.unicode.utf16LeToUtf8(utf8_buf, wide_buf) catch return error.MalformedHDrop;
            if (written < utf8_buf.len) {
                utf8_buf = allocator.realloc(utf8_buf, written) catch utf8_buf;
            }
            try result.append(utf8_buf[0..written]);

            i = end + 2; // skip past null terminator
        }
    } else {
        // ANSI paths — treat as raw bytes (single-byte encoding)
        var i: usize = 0;
        while (i < payload.len) {
            if (payload[i] == 0) break; // double-null (first of pair)
            const start = i;
            while (i < payload.len and payload[i] != 0) : (i += 1) {}
            const path_bytes = try allocator.dupe(u8, payload[start..i]);
            try result.append(path_bytes);
            if (i < payload.len) i += 1; // skip null terminator
        }
    }

    return result.toOwnedSlice();
}
```

Note: The UTF-16 to UTF-8 conversion approach above is approximate — the implementer should verify the exact `std.unicode` API available in their Zig version and adjust. The key contract is: read `pFiles` offset from byte 0, read `fWide` from byte 16, parse null-terminated strings from `data[pFiles..]`, convert to UTF-8 if wide.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1`
Expected: All tests pass including the new `decodeHDrop` tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager/copycat
git add src/paths.zig
git commit -m "feat(paths): add decodeHDrop for Windows CF_HDROP parsing"
```

---

### Task 2: Add `MalformedHDrop` to all backend error sets

Must happen before wiring the Windows backend, since `ClipboardError` must be union-compatible across platforms.

**Files:**
- Modify: `src/platform/macos.zig` (line ~46, `ClipboardError` enum)
- Modify: `src/platform/linux/mod.zig` (line ~5, `ClipboardError` enum)

- [ ] **Step 1: Add `MalformedHDrop` to macOS and Linux error sets**

Add `MalformedHDrop` to the `ClipboardError` enum in both files. It will never be returned on those platforms, but is needed for error set union compatibility.

- [ ] **Step 2: Run tests on macOS to verify no regression**

Run: `zig build test 2>&1`
Expected: All existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add src/platform/macos.zig src/platform/linux/mod.zig
git commit -m "chore: add MalformedHDrop to all platform error sets for union compat"
```

---

### Task 3: Windows platform backend — types, format mapping, core read operations

**Files:**
- Create: `src/platform/windows.zig`
- Modify: `src/clipboard.zig` (line 7)
- Modify: `build.zig` (line 40)

- [ ] **Step 1: Create `platform/windows.zig` with type exports and Win32 extern declarations**

Create `src/platform/windows.zig` with the same type exports as `platform/linux/mod.zig` (lines 5-26). Include Win32 `extern` declarations for the clipboard functions (these are NOT in `std.os.windows`):

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../paths.zig");

// -- Public types (must match other backends for clipboard.zig re-export) --

pub const ClipboardError = error{
    PasteboardUnavailable,
    FormatNotFound,
    UnsupportedFormat,
    NoDisplayServer,
    SubscribeFailed,
    MalformedPlist,
    MalformedUriList,
    MalformedHDrop,
};

pub const FormatDataPair = struct {
    format: []const u8,
    data: []const u8,
};

pub const SubscribeCallback = *const fn (userdata: ?*anyopaque) void;

pub const SubscribeHandle = struct {
    id: u64,
};

// -- Win32 extern declarations --

const BOOL = std.os.windows.BOOL;
const UINT = std.os.windows.UINT;
const HANDLE = std.os.windows.HANDLE;
const HWND = std.os.windows.HWND;
const LPVOID = *anyopaque;
const DWORD = std.os.windows.DWORD;
const LPCWSTR = [*:0]const u16;

extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.C) BOOL;
extern "user32" fn CloseClipboard() callconv(.C) BOOL;
extern "user32" fn EmptyClipboard() callconv(.C) BOOL;
extern "user32" fn EnumClipboardFormats(format: UINT) callconv(.C) UINT;
extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.C) ?HANDLE;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) callconv(.C) ?HANDLE;
extern "user32" fn GetClipboardFormatNameW(format: UINT, lpszFormatName: [*]u16, cchMaxCount: c_int) callconv(.C) c_int;
extern "user32" fn RegisterClipboardFormatW(lpszFormat: LPCWSTR) callconv(.C) UINT;
extern "user32" fn GetClipboardSequenceNumber() callconv(.C) DWORD;

extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.C) ?LPVOID;
extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.C) BOOL;
extern "kernel32" fn GlobalSize(hMem: HANDLE) callconv(.C) usize;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.C) ?HANDLE;

const GMEM_MOVEABLE: UINT = 0x0002;

// -- Standard format lookup table --

const FormatEntry = struct { id: UINT, name: []const u8 };

const standard_formats = [_]FormatEntry{
    .{ .id = 1, .name = "CF_TEXT" },
    .{ .id = 2, .name = "CF_BITMAP" },
    .{ .id = 7, .name = "CF_OEMTEXT" },
    .{ .id = 8, .name = "CF_DIB" },
    .{ .id = 13, .name = "CF_UNICODETEXT" },
    .{ .id = 15, .name = "CF_HDROP" },
    .{ .id = 16, .name = "CF_LOCALE" },
    .{ .id = 17, .name = "CF_DIBV5" },
};

// TODO: implement helper functions:
// fn formatIdToName(allocator, id) — lookup table then GetClipboardFormatNameW
// fn formatNameToId(name) — reverse lookup then RegisterClipboardFormatW
```

This is the skeleton. The implementer fills in the helper functions and public API in subsequent steps.

- [ ] **Step 2: Wire the platform switch and build system**

In `src/clipboard.zig` line 7, change:
```zig
    else => @compileError("Unsupported platform. Supported: macOS, Linux."),
```
to:
```zig
    .windows => @import("platform/windows.zig"),
    else => @compileError("Unsupported platform. Supported: macOS, Linux, Windows."),
```

In `build.zig`, before the `else` clause (around line 40), add:
```zig
.windows => {
    clipboard_module.linkSystemLibrary("kernel32");
    clipboard_module.linkSystemLibrary("user32");
},
```

- [ ] **Step 3: Implement format ID ↔ name helpers**

In `platform/windows.zig`, implement:
- `formatIdToName(allocator, id) ![]const u8` — scan `standard_formats` table, fall back to `GetClipboardFormatNameW` (UTF-16LE → UTF-8 conversion), return duped string
- `formatNameToId(name) !UINT` — reverse scan of `standard_formats`, fall back to `RegisterClipboardFormatW` (UTF-8 → UTF-16LE conversion)

- [ ] **Step 4: Implement `getChangeCount`**

```zig
pub fn getChangeCount() i64 {
    const seq = GetClipboardSequenceNumber();
    if (seq == 0) return -1; // failure sentinel, consistent with macOS
    return @as(i64, @intCast(seq));
}
```

- [ ] **Step 5: Implement `listFormats`**

```zig
pub fn listFormats(allocator: Allocator) ![][]const u8 {
    if (OpenClipboard(null) == 0) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();

    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |name| allocator.free(name);
        result.deinit();
    }

    var format: UINT = EnumClipboardFormats(0);
    while (format != 0) : (format = EnumClipboardFormats(format)) {
        const name = try formatIdToName(allocator, format);
        try result.append(name);
    }

    return result.toOwnedSlice();
}
```

- [ ] **Step 6: Implement `readFormat`**

```zig
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    const id = formatNameToId(format) catch return null;

    if (OpenClipboard(null) == 0) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();

    const handle = GetClipboardData(id) orelse return null;
    const ptr = GlobalLock(handle) orelse return null;
    defer _ = GlobalUnlock(handle);

    const size = GlobalSize(handle);
    if (size == 0) return null;

    const src: [*]const u8 = @ptrCast(ptr);
    const copy = try allocator.alloc(u8, size);
    @memcpy(copy, src[0..size]);
    return copy;
}
```

- [ ] **Step 7: Cross-compile to verify syntax**

Run: `zig build -Dtarget=x86_64-windows 2>&1`
Expected: Compiles without errors (cannot run, but verifies all types and extern declarations resolve).

- [ ] **Step 8: Commit**

```bash
git add src/platform/windows.zig src/clipboard.zig build.zig
git commit -m "feat(windows): add platform skeleton with types, format mapping, listFormats, readFormat"
```

---

### Task 4: Windows write operations and clear

**Files:**
- Modify: `src/platform/windows.zig`

- [ ] **Step 1: Implement `writeFormat`**

```zig
pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    _ = allocator;
    const id = try formatNameToId(format);

    if (OpenClipboard(null) == 0) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();

    _ = EmptyClipboard();

    const hmem = GlobalAlloc(GMEM_MOVEABLE, data.len) orelse return error.PasteboardUnavailable;
    const dest = GlobalLock(hmem) orelse return error.PasteboardUnavailable;
    const dest_slice: [*]u8 = @ptrCast(dest);
    @memcpy(dest_slice[0..data.len], data);
    _ = GlobalUnlock(hmem);

    if (SetClipboardData(id, hmem) == null) return error.PasteboardUnavailable;
    // SetClipboardData takes ownership — do NOT free hmem
}
```

- [ ] **Step 2: Implement `writeMultiple`**

```zig
pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    _ = allocator;
    if (OpenClipboard(null) == 0) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();

    _ = EmptyClipboard();

    for (pairs) |pair| {
        const id = formatNameToId(pair.format) catch continue;
        const data = pair.data;

        const hmem = GlobalAlloc(GMEM_MOVEABLE, data.len) orelse continue;
        const dest = GlobalLock(hmem) orelse continue;
        const dest_slice: [*]u8 = @ptrCast(dest);
        @memcpy(dest_slice[0..data.len], data);
        _ = GlobalUnlock(hmem);

        _ = SetClipboardData(id, hmem);
    }
}
```

- [ ] **Step 3: Implement `clear`**

```zig
pub fn clear() !void {
    if (OpenClipboard(null) == 0) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
}
```

- [ ] **Step 4: Cross-compile to verify**

Run: `zig build -Dtarget=x86_64-windows 2>&1`
Expected: Compiles without errors.

- [ ] **Step 5: Commit**

```bash
git add src/platform/windows.zig
git commit -m "feat(windows): implement writeFormat, writeMultiple, clear"
```

---

### Task 5: Windows `decodePathsForFormat`

**Files:**
- Modify: `src/platform/windows.zig`

- [ ] **Step 1: Implement `decodePathsForFormat` with CF_HDROP allowlist**

```zig
const file_ref_allowlist = [_][]const u8{"CF_HDROP"};

fn isFileRefFormat(format: []const u8) bool {
    for (file_ref_allowlist) |allowed| {
        if (std.mem.eql(u8, format, allowed)) return true;
    }
    return false;
}

pub fn decodePathsForFormat(allocator: Allocator, format: []const u8) ![]const []const u8 {
    if (!isFileRefFormat(format)) return error.UnsupportedFormat;

    const format_z = try allocator.dupeZ(u8, format);
    defer allocator.free(format_z);
    const data = try readFormat(allocator, format) orelse return error.FormatNotFound;
    defer allocator.free(data);

    return paths.decodeHDrop(allocator, data);
}
```

- [ ] **Step 2: Cross-compile to verify**

Run: `zig build -Dtarget=x86_64-windows 2>&1`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add src/platform/windows.zig
git commit -m "feat(windows): implement decodePathsForFormat with CF_HDROP allowlist"
```

---

### Task 6: Windows subscribe/unsubscribe

**Files:**
- Modify: `src/platform/windows.zig`

- [ ] **Step 1: Implement subscribe with message-only window + background thread**

Add subscription state (matching macOS/Linux pattern):
```zig
var subscribe_mutex: std.Thread.Mutex = .{};
var subscribers: std.ArrayListUnmanaged(Subscriber) = .{};
var next_subscriber_id: u64 = 1;
var msg_thread: ?std.Thread = null;
var should_exit: bool = false;

const Subscriber = struct {
    id: u64,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
};
```

Implement `subscribe` and `unsubscribe`:
- `subscribe(allocator, callback, userdata)`: Lock mutex, append callback + userdata, if first subscriber → spawn background thread that creates a message-only window (`CreateWindowExW` with `HWND_MESSAGE`), calls `AddClipboardFormatListener`, and runs `GetMessageW`/`DispatchMessageW` loop. Window procedure on `WM_CLIPBOARDUPDATE` fires all registered callbacks.
- `unsubscribe`: Lock mutex, remove by handle ID, if last subscriber → set `should_exit = true`, `PostMessageW(hwnd, WM_QUIT, 0, 0)`. Thread exit is async — stale thread joined on next `subscribe` call.

This requires additional extern declarations:
```zig
extern "user32" fn CreateWindowExW(...) callconv(.C) ?HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.C) BOOL;
extern "user32" fn GetMessageW(...) callconv(.C) BOOL;
extern "user32" fn TranslateMessage(...) callconv(.C) BOOL;
extern "user32" fn DispatchMessageW(...) callconv(.C) BOOL;
extern "user32" fn PostMessageW(...) callconv(.C) BOOL;
extern "user32" fn DefWindowProcW(...) callconv(.C) isize;
extern "user32" fn RegisterClassExW(...) callconv(.C) u16;
extern "user32" fn AddClipboardFormatListener(hWnd: HWND) callconv(.C) BOOL;
extern "user32" fn RemoveClipboardFormatListener(hWnd: HWND) callconv(.C) BOOL;
```

The exact parameter types for message/window structs will need to be defined — reference Win32 documentation. The implementer should define `WNDCLASSEXW`, `MSG`, and related structs inline.

- [ ] **Step 2: Cross-compile to verify**

Run: `zig build -Dtarget=x86_64-windows 2>&1`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add src/platform/windows.zig
git commit -m "feat(windows): implement subscribe/unsubscribe with message-only window"
```

---

### Task 7: CLI adjustments for Windows

**Files:**
- Modify: `src/main.zig`

- [ ] **Step 1: Add Windows format names to `isLikelyText`**

In `src/main.zig` around line 185, add Windows text format names to the `text_formats` array:

```zig
fn isLikelyText(format: []const u8) bool {
    const text_formats = [_][]const u8{
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.html",
        "public.rtf",
        "public.file-url",
        // Linux
        "UTF8_STRING",
        "text/plain",
        "text/html",
        "text/uri-list",
        // Windows
        "CF_TEXT",
        "CF_UNICODETEXT",
        "CF_OEMTEXT",
        "HTML Format",
    };
    for (text_formats) |tf| {
        if (std.mem.eql(u8, format, tf)) return true;
    }
    return false;
}
```

Note: `CF_UNICODETEXT` is raw UTF-16LE bytes which will display as garbage in a terminal. The preview in `printFormatPreview` may need a UTF-16LE detection path in the future, but for now matching the existing "show raw bytes with binary indicator" behavior for non-ASCII is acceptable.

- [ ] **Step 2: Cross-compile to verify**

Run: `zig build -Dtarget=x86_64-windows 2>&1`
Expected: Compiles without errors.

- [ ] **Step 3: Commit**

```bash
git add src/main.zig
git commit -m "feat(cli): add Windows format names to isLikelyText"
```

---

### Task 8: Integration testing on Windows VM

**Files:**
- No new files — testing existing code on Windows 11 VM

- [ ] **Step 1: Build on Windows VM**

Transfer source to Windows VM and build:
```
zig build
```
Or cross-compile on macOS and transfer the binary:
```
zig build -Dtarget=x86_64-windows
```
Then copy `zig-out/bin/clipboard.exe` to the VM.

- [ ] **Step 2: Smoke test — introspect**

On Windows, copy some text in Notepad, then run:
```
clipboard.exe
```
Expected: Shows `CF_UNICODETEXT`, `CF_TEXT`, `CF_LOCALE`, and possibly other formats with byte sizes.

- [ ] **Step 3: Smoke test — read/write round-trip**

```
echo hello | clipboard.exe write CF_TEXT
clipboard.exe read CF_TEXT
```
Expected: Outputs `hello`.

- [ ] **Step 4: Smoke test — file path decoding**

Copy a file in File Explorer, then:
```
clipboard.exe list
clipboard.exe read CF_HDROP --as-path
```
Expected: `list` shows `CF_HDROP` among formats. `read --as-path` outputs the file path (e.g., `C:\Users\george\Documents\file.txt`).

- [ ] **Step 5: Smoke test — subscribe**

```
clipboard.exe watch
```
Then copy different items. Expected: Each clipboard change triggers a line of output.

- [ ] **Step 6: Smoke test — shared library**

Verify `zig-out/lib/clipboard.dll` (or `clipboard.lib`) is produced and can be loaded by an external program.

- [ ] **Step 7: Fix any issues found and commit**

```bash
git add -A
git commit -m "fix(windows): address issues found in integration testing"
```

