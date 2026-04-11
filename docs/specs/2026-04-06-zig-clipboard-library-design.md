# Zig Clipboard Library + CLI — Design Spec

## Overview

A standalone, cross-platform clipboard library and CLI tool written in Zig. Exposes a generic clipboard API (list formats, read/write arbitrary formats by UTI/MIME) via both a C ABI shared library and a command-line tool. macOS first, then Windows and Linux.

Lives at `native/clipboard/` within the Schrodinger repo but has zero dependencies on it — designed to be extracted into its own repo.

## Priority Order

1. macOS implementation
2. Windows/Linux implementations
3. Schrodinger (Electrobun app) integration

## Project Structure

```
native/clipboard/
├── build.zig
├── src/
│   ├── clipboard.zig      # Public API (delegates to platform backend)
│   ├── platform/
│   │   └── macos.zig      # NSPasteboard via objc_msgSend
│   ├── objc.zig           # Obj-C runtime helpers (macOS only)
│   ├── main.zig           # CLI entry point (arg parsing, output formatting)
│   └── lib.zig            # C ABI exports for shared library (Bun FFI target)
```

Start with `platform/` directory from day one so Windows/Linux backends slot in without restructuring.

Two build targets from one `build.zig`:
- `libclipboard.dylib` — shared library for FFI consumers
- `clipboard` — CLI executable

## Core Zig API (clipboard.zig)

```zig
const FormatDataPair = struct {
    format: []const u8,
    data: []const u8,
};

pub fn listFormats(allocator: Allocator) ![]const []const u8
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8
pub fn writeFormat(format: []const u8, data: []const u8) !void
pub fn writeMultiple(pairs: []const FormatDataPair) !void
pub fn getChangeCount() i64
```

## C ABI Exports (lib.zig)

```c
typedef struct {
    const uint8_t* data;  // NULL on error or format-not-found
    size_t len;           // 0 on error or format-not-found
    int32_t status;       // 0 = success, 1 = format not found, -1 = error
} ClipboardData;

typedef struct {
    const char* format;
    const uint8_t* data;
    size_t len;
} ClipboardFormatPair;

// List all format identifiers (UTIs on macOS). Returns JSON array string.
// Returns NULL on error (pasteboard inaccessible). Caller must call clipboard_free() on non-NULL result.
const char* clipboard_list_formats();

// Read raw bytes for a given format.
// status 0: success (.data valid, caller must clipboard_free() it)
// status 1: format not found (.data is NULL)
// status -1: error (.data is NULL)
// Zero-length data with status 0 is valid (non-NULL .data, .len == 0).
ClipboardData clipboard_read_format(const char* format);

// Write a single format. Clears clipboard first, then writes. Returns 0 on success, non-zero on error.
int32_t clipboard_write_format(const char* format, const uint8_t* data, size_t len);

// Write multiple formats atomically. Clears clipboard once, then writes all formats. Returns 0 on success.
// All pointers in `pairs` must remain valid for the duration of the call. The library does not retain references after return.
int32_t clipboard_write_multiple(const ClipboardFormatPair* pairs, uint32_t count);

// Clear the clipboard.
int32_t clipboard_clear();

// Returns the pasteboard change count (for polling-based change detection).
int64_t clipboard_change_count();

// Free memory allocated by clipboard_list_formats or clipboard_read_format.
void clipboard_free(void* ptr);
```

### Error handling philosophy

The library never panics. All failures are communicated through return values (status codes, NULL pointers). This is critical for the shared library target — a panic would crash the host process (Bun/Electrobun).

### Write semantics

- `clipboard_write_format`: clears the clipboard, then writes the single format. This is required by macOS (writes fail without a prior `clearContents`).
- `clipboard_write_multiple`: clears the clipboard once, then writes all formats. This is how apps set multiple representations (e.g., HTML + plain text together).
- There is no "append" semantic. If needed later, it would be a separate function.

## CLI Interface

### Default mode (no args): introspection

Running `clipboard` with no arguments dumps a formatted overview of everything on the clipboard:

```
Clipboard contents (5 formats, changeCount: 42):

  public.utf8-plain-text    28 bytes
  "Hello, world! This is a…"

  public.html               1,204 bytes
  "<div style=\"font-family…"

  public.png                24,381 bytes
  [89 50 4E 47 0D 0A 1A 0A] (PNG image)

  public.file-url           94 bytes
  file:///Users/george/doc.pdf

  com.google.docs.clipboard 8,912 bytes
  [08 12 A0 3F 00 1C 88 02] (binary)
```

Smart preview logic:
- **Text formats** (`public.utf8-plain-text`, `public.html`, `public.rtf`): show first ~80 characters, quoted, truncated with ellipsis
- **File URL formats** (`public.file-url`): decode and show the file paths
- **Binary formats** (everything else): show first 8 bytes as hex + a type hint if the magic bytes are recognizable (PNG, TIFF, PDF, etc.)

### Subcommands

| Command | Description |
|---------|-------------|
| `clipboard list` | Format names only, one per line. Scriptable. |
| `clipboard read <format>` | Raw bytes to stdout. Pipeable. |
| `clipboard read <format> --out <file>` | Write raw bytes to a file. |
| `clipboard write <format>` | Read data from stdin, write to clipboard. |
| `clipboard write <format> --data "text"` | Write inline string data. |
| `clipboard clear` | Clear the clipboard. |
| `clipboard watch` | Poll and print on every change. Uses `getChangeCount()` for detection. Default interval 500ms. |
| `clipboard watch --interval <ms>` | Poll with custom interval. |

Global flags:
- `--json` — output structured JSON instead of human-readable text (works with default introspection and `list`)

### Scriptability

`list` and `read` are designed for piping:
```sh
# Save HTML from clipboard to file
clipboard read public.html > page.html

# Copy file contents as HTML to clipboard
cat page.html | clipboard write public.html

# List formats as plain text for scripting
clipboard list | grep html
```

## macOS Implementation Details (objc.zig)

### Obj-C Runtime Approach

Zig calls Objective-C APIs through the C runtime functions:
- `objc_getClass("NSPasteboard")` — look up a class by name
- `sel_registerName("generalPasteboard")` — register/look up a selector
- `objc_msgSend` — cast to the appropriate function pointer signature per call

Link against: `libobjc`, `AppKit` framework (for NSPasteboard type constants).

All calls in this API return object pointers or integer types, so only `objc_msgSend` is needed. If future extensions return structs by value on x86_64, `objc_msgSend_stret` would be required (ARM64 does not use it).

### NSPasteboard Call Map

Reading uses `pasteboardItems` (per-item access), writing uses methods on the pasteboard object directly. This asymmetry is how NSPasteboard works — reads are item-based, writes are pasteboard-level.

| Operation | Obj-C | Zig approach |
|-----------|-------|--------------|
| Get clipboard | `[NSPasteboard generalPasteboard]` | `objc_msgSend(class, sel("generalPasteboard"))` |
| Get items | `[pb pasteboardItems]` | `objc_msgSend(pb, sel("pasteboardItems"))` |
| Get first item | `[items objectAtIndex:0]` | `objc_msgSend(items, sel("objectAtIndex:"), 0)` |
| List types | `[item types]` | `objc_msgSend(item, sel("types"))` → NSArray of NSString |
| Read data | `[item dataForType:uti]` | `objc_msgSend(item, sel("dataForType:"), nsstring)` → NSData |
| Clear | `[pb clearContents]` | `objc_msgSend(pb, sel("clearContents"))` |
| Write data | `[pb setData:d forType:uti]` | `objc_msgSend(pb, sel("setData:forType:"), nsdata, nsstring)` |
| Change count | `[pb changeCount]` | `objc_msgSend(pb, sel("changeCount"))` → i64 |

### NSString / NSData Bridging

- Create NSString from Zig `[]const u8`: `objc_msgSend(NSString, sel("stringWithUTF8String:"), ptr)`
- Read NSString to Zig: `objc_msgSend(nsstr, sel("UTF8String"))` → `[*:0]const u8`
- Read NSData bytes: `objc_msgSend(nsdata, sel("bytes"))` → `[*]const u8`, length via `sel("length")`
- Create NSData from Zig: `objc_msgSend(NSData, sel("dataWithBytes:length:"), ptr, len)`

### Edge Cases

- `generalPasteboard` can return null in daemon/launchd contexts — check and return error
- `pasteboardItems` can have multiple items — use first item only for reads
- `changeCount` is an integer that increments on every clipboard modification — use for polling
- Some UTIs may have zero-length data — return empty slice, not error

## Build Configuration

```
$ cd native/clipboard
$ zig build              # builds both library and CLI
$ ./zig-out/bin/clipboard              # run CLI
$ ls ./zig-out/lib/libclipboard.dylib  # shared library
```

`build.zig` defines two artifacts:
1. `addSharedLibrary` → `libclipboard.dylib` from `src/lib.zig`
2. `addExecutable` → `clipboard` from `src/main.zig`

Both link `libobjc` and `AppKit` framework on macOS.

## Not In Scope (this phase)

- Windows implementation (`OpenClipboard` / `GetClipboardData` / `EnumClipboardFormats`)
- Linux implementation (X11 selections / Wayland data-device)
- Bun FFI TypeScript wrapper
- Schrodinger integration (polling loop, ClipEntry expansion, tray submenus)
- Image format conversion (TIFF to PNG)
- Multi-item clipboard support (read all items, not just first)

## Future: Cross-Platform

The `platform/` directory is structured from day one to accept new backends:

```
src/platform/
├── macos.zig      # NSPasteboard via objc_msgSend (phase 1)
├── windows.zig    # Win32 clipboard API (phase 2)
└── linux.zig      # X11/Wayland (phase 2)
```

`clipboard.zig` picks the right backend at comptime based on `builtin.os.tag`.
