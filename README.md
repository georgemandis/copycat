# clipboard

A standalone, generic clipboard library and CLI tool written in Zig. Reads and writes **arbitrary** clipboard formats by their native identifier (UTI on macOS, MIME type on Linux, format ID on Windows) — not just text and images.

Ships as both a CLI executable and a C ABI shared library, so it's usable directly from a shell or via FFI from any language that can load a `.dylib` (Bun, Node, Python, Rust, etc.).

## Status

| Platform | Status |
|----------|--------|
| macOS    | ✅ Implemented (NSPasteboard via Objective-C runtime) |
| Windows  | 🚧 Planned |
| Linux    | 🚧 Planned (X11 + Wayland) |

Built and tested against **Zig 0.15.2**.

## Why

Most clipboard libraries expose a fixed set of types — text, image, files. But the system clipboard is actually a generic key-value store: applications routinely put a dozen representations of the same data on it (plain text, RTF, HTML, app-specific binary formats like Google Docs' `com.google.docs.clipboard`, etc.). This library treats the clipboard as what it is: a map from format identifiers to raw bytes, which you can list, read, and write directly.

## Build

```sh
zig build
```

This produces two artifacts:

- `zig-out/bin/clipboard` — the CLI executable
- `zig-out/lib/libclipboard.dylib` — the C ABI shared library

## CLI Usage

Running `clipboard` with no arguments prints a formatted overview of everything currently on the clipboard:

```
$ clipboard
Clipboard contents (3 formats, changeCount: 142):

  public.utf8-plain-text    28 bytes
  "Hello, world! This is a test"

  public.html               1204 bytes
  "<div style=\"font-family:sans-serif\">Hello..."

  public.png                24381 bytes
  [89 50 4E 47 0D 0A 1A 0A] ... (PNG image)
```

### Subcommands

| Command | Description |
|---------|-------------|
| `clipboard` | Show clipboard contents (default) |
| `clipboard list` | List format names, one per line |
| `clipboard read <format>` | Read raw bytes for `<format>` to stdout |
| `clipboard read <format> --out <file>` | Write raw bytes to a file |
| `clipboard write <format>` | Read data from stdin, write to clipboard |
| `clipboard write <format> --data "text"` | Write inline string data |
| `clipboard clear` | Clear the clipboard |
| `clipboard watch` | Print on every clipboard change (default 500ms poll) |
| `clipboard watch --interval <ms>` | Poll with custom interval |
| `clipboard help`, `--help`, `-h` | Show usage |

### Global flags

- `--json` — output structured JSON instead of human-readable text (works with the default introspection and `list`)

### Shell completions

Completion scripts for fish, bash, and zsh live in `completions/`. They include dynamic completion for format identifiers: typing `clipboard read <TAB>` will complete against whatever is currently on your clipboard (by shelling out to `clipboard list`).

> **Note:** Dynamic format completion requires `clipboard` to be on your `$PATH`. After `zig build`, either copy or symlink `zig-out/bin/clipboard` into a directory on `$PATH` (e.g. `~/.local/bin`).

```sh
# fish
cp completions/clipboard.fish ~/.config/fish/completions/

# bash (user)
echo "source $PWD/completions/clipboard.bash" >> ~/.bashrc

# zsh — place _clipboard on your $fpath, e.g.:
mkdir -p ~/.zfunc
cp completions/_clipboard ~/.zfunc/
# then ensure ~/.zshrc has: fpath=(~/.zfunc $fpath) && autoload -Uz compinit && compinit
```

### Pipe-friendly examples

```sh
# Save HTML from clipboard to a file
clipboard read public.html > page.html

# Copy a file's contents to clipboard as HTML
cat page.html | clipboard write public.html

# Find the format you want
clipboard list | grep html

# Diff what an app puts on the clipboard between two states
clipboard --json > before.json
# ... do the thing ...
clipboard --json > after.json
diff before.json after.json
```

## C ABI

The shared library exposes a small, never-panicking C ABI. All errors are reported through return values — there are no aborts or signals raised by the library itself. This is critical for embedding in host processes (Bun, Electron, etc.) where a panic would take down the host.

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

// List formats. Returns a JSON array string. NULL on error.
// Caller must clipboard_free() the returned pointer.
const char* clipboard_list_formats(void);

// Read bytes for a format.
// status 0:  success — caller must clipboard_free(.data)
// status 1:  format not present
// status -1: error
ClipboardData clipboard_read_format(const char* format);

// Write a single format. Clears the clipboard first.
// When len == 0, data may be any value (it is not dereferenced).
int32_t clipboard_write_format(const char* format, const uint8_t* data, size_t len);

// Write multiple formats atomically. Clears once, then writes all.
int32_t clipboard_write_multiple(const ClipboardFormatPair* pairs, uint32_t count);

int32_t clipboard_clear(void);

// Monotonically increments on every clipboard modification.
// Useful for polling-based change detection. Returns -1 if unavailable.
int64_t clipboard_change_count(void);

// Free a pointer previously returned by this library. Safe with NULL.
void clipboard_free(void* ptr);
```

### Bun FFI example

```ts
import { dlopen, FFIType, suffix } from "bun:ffi";

const lib = dlopen(`./zig-out/lib/libclipboard.${suffix}`, {
  clipboard_list_formats: { args: [], returns: FFIType.cstring },
  clipboard_change_count: { args: [], returns: FFIType.i64 },
  clipboard_free: { args: [FFIType.ptr], returns: FFIType.void },
  // ... etc
});

const formats = JSON.parse(lib.symbols.clipboard_list_formats().toString());
console.log(formats); // ["public.utf8-plain-text", "public.html", ...]
```

## Project Structure

```
src/
├── clipboard.zig         # Public Zig API; dispatches to platform backend
├── lib.zig               # C ABI exports for the shared library
├── main.zig              # CLI entry point
├── objc.zig              # Objective-C runtime helpers (msgSend, NSString/NSData/NSArray bridging)
└── platform/
    └── macos.zig         # NSPasteboard backend
completions/              # Shell completions (fish, bash, zsh)
build.zig                 # Builds both the CLI executable and the .dylib
```

The platform backend is selected at compile time via `builtin.os.tag`. Adding a new platform means dropping in `platform/windows.zig` or `platform/linux.zig` and adding a switch arm in `clipboard.zig`.

### Architecture

```
   CLI (main.zig) ─┐
                    ├─► clipboard.zig ──► platform/<os>.zig ──► system clipboard API
   FFI (lib.zig) ──┘
```

Both the CLI and the FFI shim depend only on the public `clipboard.zig` API. Neither knows or cares which platform backend is in use.

## Format identifiers

On macOS, formats are [Uniform Type Identifiers](https://developer.apple.com/documentation/uniformtypeidentifiers) (UTIs). Common ones:

| Format | UTI |
|--------|-----|
| Plain text | `public.utf8-plain-text` |
| HTML | `public.html` |
| RTF | `public.rtf` |
| PNG | `public.png` |
| TIFF | `public.tiff` |
| File URL | `public.file-url` |

Apps may also register custom UTIs (e.g. `com.google.docs.clipboard`, `com.adobe.photoshop.image`). Use `clipboard list` to see what's actually on the clipboard at any moment.

## Roadmap

- [x] macOS backend (NSPasteboard)
- [x] CLI tool with introspection, list, read, write, clear, watch
- [x] C ABI shared library
- [ ] Windows backend (`OpenClipboard` / `EnumClipboardFormats` / `GetClipboardData`)
- [ ] Linux backend (X11 selections + Wayland data-device)
- [ ] Multi-item clipboard support (currently reads only the first item)
- [ ] Image format conversion helpers (e.g. TIFF ↔ PNG on macOS)
