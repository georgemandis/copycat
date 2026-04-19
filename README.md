# copycat

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

- `zig-out/bin/copycat` — the CLI executable
- `zig-out/lib/libcopycat.dylib` — the C ABI shared library

## CLI Usage

Running `copycat` with no arguments prints a formatted overview of everything currently on the clipboard:

```
$ copycat
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
| `copycat` | Show clipboard contents (default) |
| `copycat list` | List format names, one per line |
| `copycat read <format>` | Read raw bytes for `<format>` to stdout |
| `copycat read <format> --out <file>` | Write raw bytes to a file |
| `copycat write <format>` | Read data from stdin, write to clipboard |
| `copycat write <format> --data "text"` | Write inline string data |
| `copycat clear` | Clear the clipboard |
| `copycat watch` | Print on every clipboard change (default 500ms poll) |
| `copycat watch --interval <ms>` | Poll with custom interval |
| `copycat help`, `--help`, `-h` | Show usage |

### Global flags

- `--json` — output structured JSON instead of human-readable text (works with the default introspection and `list`)

### Shell completions

Completion scripts for fish, bash, and zsh live in `completions/`. They include dynamic completion for format identifiers: typing `copycat read <TAB>` will complete against whatever is currently on your clipboard (by shelling out to `copycat list`).

> **Note:** Dynamic format completion requires `copycat` to be on your `$PATH`. After `zig build`, either copy or symlink `zig-out/bin/copycat` into a directory on `$PATH` (e.g. `~/.local/bin`).

```sh
# fish
cp completions/copycat.fish ~/.config/fish/completions/

# bash (user)
echo "source $PWD/completions/copycat.bash" >> ~/.bashrc

# zsh — place _copycat on your $fpath, e.g.:
mkdir -p ~/.zfunc
cp completions/_copycat ~/.zfunc/
# then ensure ~/.zshrc has: fpath=(~/.zfunc $fpath) && autoload -Uz compinit && compinit
```

### Pipe-friendly examples

```sh
# Save HTML from clipboard to a file
copycat read public.html > page.html

# Copy a file's contents to clipboard as HTML
cat page.html | copycat write public.html

# Find the format you want
copycat list | grep html

# Diff what an app puts on the clipboard between two states
copycat --json > before.json
# ... do the thing ...
copycat --json > after.json
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

The shared library can be loaded from any language with FFI support. Here's a complete example using Bun:

```ts
import { dlopen, FFIType, suffix, ptr, toBuffer, CString } from "bun:ffi";

const lib = dlopen(`./zig-out/lib/libcopycat.${suffix}`, {
  clipboard_list_formats: {
    args: [],
    returns: FFIType.ptr,
  },
  clipboard_read_format_ex: {
    args: [FFIType.cstring, FFIType.ptr, FFIType.ptr, FFIType.ptr],
    returns: FFIType.void,
  },
  clipboard_write_format: {
    args: [FFIType.cstring, FFIType.ptr, FFIType.u64],
    returns: FFIType.i32,
  },
  clipboard_clear: {
    args: [],
    returns: FFIType.i32,
  },
  clipboard_change_count: {
    args: [],
    returns: FFIType.i64,
  },
  clipboard_free: {
    args: [FFIType.ptr],
    returns: FFIType.void,
  },
});

const { symbols: clip } = lib;

// List all formats currently on the clipboard
function listFormats(): string[] {
  const rawPtr = clip.clipboard_list_formats();
  if (!rawPtr) return [];
  const json = new CString(rawPtr);
  const formats = JSON.parse(json.toString());
  clip.clipboard_free(rawPtr);
  return formats;
}

// Read raw bytes for a specific format
function readFormat(format: string): Buffer | null {
  const outData = new BigInt64Array(1);
  const outLen = new BigInt64Array(1);
  const outStatus = new Int32Array(1);

  clip.clipboard_read_format_ex(
    Buffer.from(format + "\0"),
    ptr(outData),
    ptr(outLen),
    ptr(outStatus),
  );

  if (outStatus[0] !== 0) return null;
  const len = Number(outLen[0]);
  if (len === 0) return Buffer.alloc(0);

  const dataPtr = Number(outData[0]);
  const buf = Buffer.from(toBuffer(dataPtr, 0, len));
  clip.clipboard_free(dataPtr);
  return buf;
}

// Write data to the clipboard under a given format
function writeFormat(format: string, data: string | Buffer): boolean {
  const buf = typeof data === "string" ? Buffer.from(data) : data;
  return clip.clipboard_write_format(
    Buffer.from(format + "\0"),
    buf.length > 0 ? ptr(buf) : 0,
    buf.length,
  ) === 0;
}

// --- Usage ---

// Show what's on the clipboard
console.log("Formats:", listFormats());
console.log("Change count:", Number(clip.clipboard_change_count()));

// Read plain text
const text = readFormat("public.utf8-plain-text");
if (text) console.log("Text:", text.toString());

// Write plain text
writeFormat("public.utf8-plain-text", "Hello from Bun FFI!");
console.log("After write:", readFormat("public.utf8-plain-text")?.toString());
```

The `_ex` variant of `clipboard_read_format` uses out-pointers instead of returning a struct, which is more compatible with Bun's FFI. The regular `clipboard_read_format` returns a struct by value and works better with languages that support that calling convention (C, Rust, etc.).

### Node.js FFI example

Node.js doesn't have built-in FFI, but [koffi](https://koffi.dev/) makes it straightforward (`npm install koffi` — no C compiler needed):

```js
import koffi from "koffi";

const lib = koffi.load("./zig-out/lib/libcopycat.dylib");

const clipboard_list_formats = lib.func("clipboard_list_formats", "str", []);
const clipboard_write_format = lib.func("clipboard_write_format", "int32", [
  "str", "const void *", "uint64",
]);
const clipboard_change_count = lib.func("clipboard_change_count", "int64", []);

// List formats
const formats = JSON.parse(clipboard_list_formats());
console.log(formats); // ["public.utf8-plain-text", "public.html", ...]

// Write text
const msg = Buffer.from("Hello from Node!");
clipboard_write_format("public.utf8-plain-text", msg, msg.length);
```

### Runnable examples

Complete, runnable versions of both examples live in [`examples/`](examples/):

```sh
zig build                              # build the shared library first

bun run examples/bun-ffi.ts            # Bun (built-in FFI, zero deps)

npm install koffi                      # Node.js (install koffi first)
node examples/node-ffi.mjs
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
examples/
├── bun-ffi.ts            # Bun FFI example (list, read, write)
└── node-ffi.mjs          # Node.js FFI example (using koffi)
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

Apps may also register custom UTIs (e.g. `com.google.docs.clipboard`, `com.adobe.photoshop.image`). Use `copycat list` to see what's actually on the clipboard at any moment.

## Roadmap

- [x] macOS backend (NSPasteboard)
- [x] CLI tool with introspection, list, read, write, clear, watch
- [x] C ABI shared library
- [ ] Windows backend (`OpenClipboard` / `EnumClipboardFormats` / `GetClipboardData`)
- [ ] Linux backend (X11 selections + Wayland data-device)
- [ ] Multi-item clipboard support (currently reads only the first item)
- [ ] Image format conversion helpers (e.g. TIFF ↔ PNG on macOS)
