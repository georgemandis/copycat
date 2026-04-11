# Copycat Windows Port — Design Spec

**Date:** 2026-04-10
**Status:** Approved

## Goal

Add Windows 10+ support to the Copycat clipboard library and CLI, completing the third platform alongside macOS and Linux (X11). A single `platform/windows.zig` backend implementing the full clipboard API surface.

## Non-Goals

- OLE clipboard (drag-and-drop integration)
- Delayed rendering (`SetClipboardData(format, NULL)`)
- Native Wayland backend (deferred — XWayland covers Linux Wayland desktops)
- Backward compatibility below Windows 10

## Format Identifiers

Windows uses integer format IDs. To keep the public API uniform (all platforms use `[]const u8` string format names):

- **Standard formats** map to well-known string names via a lookup table:
  - `CF_UNICODETEXT` (13) → `"CF_UNICODETEXT"`
  - `CF_TEXT` (1) → `"CF_TEXT"`
  - `CF_BITMAP` (2) → `"CF_BITMAP"`
  - `CF_DIB` (8) → `"CF_DIB"`
  - `CF_DIBV5` (17) → `"CF_DIBV5"`
  - `CF_HDROP` (15) → `"CF_HDROP"`
  - `CF_LOCALE` (16) → `"CF_LOCALE"`
  - `CF_OEMTEXT` (7) → `"CF_OEMTEXT"`
  - (and other standard CF_* constants)
- **Registered formats** (via `RegisterClipboardFormatW`) already have string names — these pass through directly (e.g., `"HTML Format"`, `"Rich Text Format"`)
- **Unknown registered formats** are queried via `GetClipboardFormatNameW` and returned as their registered string

A reverse lookup (string → integer ID) is needed for read/write operations. Standard names use the same lookup table in reverse; registered names use `RegisterClipboardFormatW` (which returns the existing ID if already registered).

## Required Type Exports

`windows.zig` must export the same public types as the other backends for `clipboard.zig` to re-export:
- `FormatDataPair` — struct for `writeMultiple` pairs
- `ClipboardError` — must be a superset including all platform-agnostic variants (`MalformedPlist`, `MalformedUriList`, `NoDisplayServer`, etc.) even when unused on Windows, for error set union compatibility. May add `MalformedHDrop` (which would then need stub entries in other backends).
- `SubscribeCallback` — callback function type
- `SubscribeHandle` — opaque handle with sentinel id=0

Additionally, `clipboard.zig` needs a `.windows` arm added to the `switch (builtin.os.tag)` on line 5 (currently `@compileError`).

## Raw Bytes Philosophy

`readFormat` returns raw bytes on all platforms. On Windows, `CF_UNICODETEXT` data is UTF-16LE with a null terminator — `readFormat("CF_UNICODETEXT")` returns those raw UTF-16LE bytes, not UTF-8. This is consistent with how macOS returns raw bytes for any UTI. The CLI and FFI consumers are responsible for decoding. The CLI's `isLikelyText` heuristic in `main.zig` may need a Windows-specific entry to detect UTF-16LE for preview display.

## Core Operations

All operations follow the existing pattern from macOS/Linux backends:

### `listFormats`
- `OpenClipboard(NULL)` → `EnumClipboardFormats(0)` loop → map each ID to string name → `CloseClipboard`
- Returns `[][]const u8` (allocated string slices)

### `readFormat`
- Resolve format string to integer ID
- `OpenClipboard(NULL)` → `GetClipboardData(id)` → `GlobalLock` → copy bytes → `GlobalUnlock` → `CloseClipboard`
- Returns `?[]const u8` (null if format not present)
- Note: `GetClipboardData` returns a global memory handle, not a pointer — must lock/copy/unlock

### `writeFormat` / `writeMultiple`
- Resolve format string(s) to integer ID(s)
- `OpenClipboard(NULL)` → `EmptyClipboard` → for each format: `GlobalAlloc(GMEM_MOVEABLE)` → `GlobalLock` → copy data in → `GlobalUnlock` → `SetClipboardData(id, handle)` → `CloseClipboard`
- `SetClipboardData` takes ownership of the global memory handle — do NOT free it after

### `clear`
- `OpenClipboard(NULL)` → `EmptyClipboard` → `CloseClipboard`

### `getChangeCount`
- `GetClipboardSequenceNumber()` — returns a monotonically increasing `DWORD`
- Cast to `i64` for API compatibility with macOS/Linux
- Returns -1 on failure (function returns 0 when clipboard unavailable) for consistency with macOS sentinel

## Subscribe

Windows has `AddClipboardFormatListener` (Vista+), which delivers `WM_CLIPBOARDUPDATE` messages to a window. Implementation:

1. Background thread creates a **message-only window** (`CreateWindowExW` with `HWND_MESSAGE` parent)
2. Call `AddClipboardFormatListener(hwnd)`
3. Run a message loop (`GetMessageW` / `DispatchMessageW`)
4. Window procedure receives `WM_CLIPBOARDUPDATE` → fire registered callbacks
5. On unsubscribe (last callback removed): signal exit flag, `PostMessageW(WM_QUIT)` to unblock the message loop. Thread exit is **asynchronous** — the stale thread is joined on the next `subscribe` call, matching the macOS/Linux pattern where `unsubscribe` never blocks.

This is event-driven (no polling), cleaner than the macOS/X11 approach. Uses the same `SubscribeHandle` and callback registry pattern.

## File Path Decoding

Windows file copies put `CF_HDROP` (format ID 15) on the clipboard. The data is a `DROPFILES` struct:

```
struct DROPFILES {
    pFiles: DWORD,   // offset from start of struct to file list
    pt: POINT,       // drop point (unused for clipboard)
    fNC: BOOL,       // non-client area flag (unused)
    fWide: BOOL,     // 1 = Unicode paths, 0 = ANSI
};
// Followed by: null-terminated path strings, double-null terminated
// e.g., "C:\Users\foo\bar.txt\0C:\Users\foo\baz.pdf\0\0"
```

The platform-level `decodePathsForFormat` function in `windows.zig` must:
- Allowlist `"CF_HDROP"` (the only file-reference format on Windows)
- Call `readFormat` to get the raw bytes
- Delegate to `paths.decodeHDrop`

Implementation of `decodeHDrop`:
- Add `decodeHDrop(data: []const u8) ![]const []const u8` to `paths.zig` (pure Zig, no OS deps, unit-testable)
- Read `pFiles` field from the struct header to determine the offset to the string data (do NOT hardcode 20 — read the actual value)
- Read `fWide` flag to determine UTF-16LE vs ANSI encoding
- Advance `pFiles` bytes from the start of the data blob to reach the file list
- Parse null-terminated strings until double-null terminator
- Convert UTF-16LE → UTF-8 if wide (use `std.unicode.utf16LeToUtf8Alloc` or manual conversion)
- The `--as-path` allowlist gets `CF_HDROP` added for Windows

## Build System Changes

In `build.zig`:
- Windows target links: `kernel32` (clipboard API), `user32` (window/message API)
- `shell32` may not be needed if `DROPFILES` is defined inline in Zig (the pure-Zig `decodeHDrop` parser doesn't need `DragQueryFileW`)
- No framework linking needed (unlike macOS AppKit)
- Note: `std.os.windows` does NOT include clipboard-specific functions (`OpenClipboard`, `GetClipboardData`, etc.). These need manual `extern` declarations or `@cImport(@cInclude("windows.h"))`. Format name functions like `GetClipboardFormatNameW` and `RegisterClipboardFormatW` take/return wide strings, requiring UTF-8 ↔ UTF-16LE conversion at the boundary.

## Dev/Test Environment

- Cross-compile on macOS: `zig build -Dtarget=x86_64-windows` (or `aarch64-windows` if ARM VM)
- Test on Windows 11 VM (being set up)
- CI can cross-compile for syntax/type checking; functional tests require a Windows environment

## Error Handling

Windows clipboard API functions signal errors differently than POSIX:
- Most return `BOOL` (0 = failure) or `NULL` handle
- Specific error via `GetLastError()`
- Map to existing error set: `error.PasteboardUnavailable` when `OpenClipboard` fails (clipboard locked by another process), `error.FormatNotFound` when format ID doesn't resolve

The clipboard can be locked by another process — `OpenClipboard` may fail transiently. A single retry with a short delay (e.g., 10ms) is acceptable; beyond that, return error.

## Testing Strategy

1. **Unit tests (cross-platform):** `decodeHDrop` in `paths.zig` — pure Zig, runs anywhere
2. **Integration tests (Windows VM):** round-trip read/write, format listing, subscribe/unsubscribe
3. **Smoke tests:** copy text in Notepad → `clipboard list` → `clipboard read CF_UNICODETEXT`; copy file in Explorer → `clipboard read CF_HDROP --as-path`
