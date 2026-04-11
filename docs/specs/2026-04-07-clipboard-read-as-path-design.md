# `clipboard read --as-path` Design Spec

**Date:** 2026-04-07
**Status:** Proposed
**Related:** `2026-04-06-zig-clipboard-library-design.md`

## Goal

Make the `clipboard` CLI compose cleanly with standard Unix file tools (`cp`, `mv`, `open`, `xargs`, …) when the pasteboard holds file references. Today, `clipboard read public.file-url --out foo` writes the raw bytes of the `public.file-url` payload — which is a `file://...` URL string — to `foo`. That's technically correct but rarely what the user wants, and it doesn't compose: there's no clean way to turn the clipboard's file reference into a POSIX path that `cp` or `mv` can consume.

This spec adds a single flag, `--as-path`, to the existing `read` subcommand. When set, `read` decodes file-reference pasteboard formats into POSIX paths and prints them newline-terminated (or NUL-terminated with `-0`). The CLI stays a small, sharp primitive; actually copying, moving, or opening the referenced files is left to the tools that already do that well.

## Non-Goals

Explicitly out of scope for this spec:

- **A `save` / DWIM subcommand** that "figures out what's on the clipboard and dumps it somewhere." We considered this and deferred it. If, after living with `--as-path`, the `cp (clipboard read ... --as-path) dest/` pattern proves tedious, `save` can be added as a thin convenience later. It is not added now.
- **Resolving inlined file data** (e.g. a PNG blob sitting on the pasteboard as raw `public.png` bytes with no file URL anywhere). That case is already solved by plain `clipboard read public.png --out foo.png`; no new concept is needed.
- **Non-`file://` URL schemes.** `public.url` with an `http://`, `mailto:`, etc. scheme is explicitly an error under `--as-path`. This CLI does not fetch, resolve, or otherwise chase network URLs.
- **Changes to `clipboard write`.** Writing paths back to the pasteboard is a separate concern.
- **Any filesystem side effects.** `--as-path` never reads, copies, moves, or touches the referenced files. It only decodes pasteboard bytes into path strings. Downstream tools handle the filesystem.
- **Resolving symlinks, canonicalizing paths, or checking existence.** Paths are emitted exactly as decoded. If the user copied a file and then deleted it, `--as-path` still prints the path — surfacing that as an error is `cp`'s job, not this tool's.

## Background

The `clipboard` CLI (`native/clipboard/`) is a standalone Zig binary that exposes generic pasteboard introspection: list formats, read a format by UTI, write a format, watch for changes. It is the underlying library that the Schrodinger app uses via Bun FFI, but it is also useful on its own as a Unix tool.

The relevant current behavior lives in `native/clipboard/src/main.zig`:

- `cmdRead` accepts `<format>` and an optional `--out <file>`. Reads bytes via `clipboard.readFormat`, writes them to stdout or to the named file.
- The platform layer (`native/clipboard/src/platform/macos.zig`, dispatched through `native/clipboard/src/clipboard.zig`) does the actual NSPasteboard work, including an existing Obj-C bridge (`native/clipboard/src/objc.zig`).

The file already has a clean layering discipline: `clipboard.zig` is a thin public API / platform-dispatch layer (every function is a one-liner forwarding to `platform/macos.zig`), the platform file holds macOS-specific logic, and `main.zig` is the CLI on top. This spec preserves that discipline.

## Design

### The `--as-path` contract

Add a new flag `--as-path` to the existing `clipboard read` subcommand. Updated usage:

```
clipboard read <format> [--out <file>] [--as-path [-0|--null]]
```

When `--as-path` is set:

- The named `<format>` must be one of an allowlist of file-reference UTIs (see below). Anything else → non-zero exit, clear error. No guessing, no fallback.
- Instead of writing raw pasteboard bytes, `read` decodes them into one or more POSIX filesystem paths and prints them to stdout (or to `--out <file>` if given).
- Default separator is `\n`. With `-0` / `--null`, the separator is `\0`. In both cases the final path also gets a terminator — `\n` / `\0` is a terminator, not a separator, matching `ls` and `find -print0`.
- Using `-0` without `--as-path` is an error. It's meaningless on raw bytes.

### File-reference format allowlist

`--as-path` accepts exactly these three UTIs:

1. **`public.file-url`** — the common case. Bytes are a UTF-8 `file://...` URL, possibly NUL-terminated (macOS likes to NUL-terminate some pasteboard strings), possibly percent-encoded. Decoded into one path.

2. **`NSFilenamesPboardType`** — the legacy multi-file format Finder still uses when more than one file is copied. Bytes are a binary property list containing an `NSArray` of `NSString` POSIX paths. Decoded into N paths, in order. This format is technically deprecated by Apple in favor of multiple `public.file-url` items on the pasteboard, but real-world Finder still puts it there, so we have to handle it. This should be noted in a comment at the call site.

3. **`public.url`** — the generic URL UTI. Some apps put file references under this instead of `public.file-url`. Accepted **only** when the decoded URL's scheme is `file://`. If the scheme is anything else (`http`, `https`, `mailto`, `ftp`, …) → error `public.url is not a file:// URL`.

Anything else → error before any pasteboard access:

> `--as-path only supports file-reference formats: public.file-url, NSFilenamesPboardType, public.url`

### Decoding rules

- **`public.file-url` / `public.url`:** strip trailing NUL if present, verify the `file://` prefix (error otherwise), strip the prefix, percent-decode the remainder. Emit one path.
- **`NSFilenamesPboardType`:** parse as a binary property list using `NSPropertyListSerialization` via the existing Obj-C bridge. Extract the top-level `NSArray` of `NSString`s. Emit each as a path, in array order. If the plist is malformed, not an array, or contains non-string elements, error with `Failed to decode NSFilenamesPboardType: <reason>`.
- **No symlink resolution, no `realpath`, no existence check.** Paths are emitted as decoded.
- **No deduplication or sorting.** Order matches the pasteboard's order.

### CLI behavior matrix

| Invocation | Behavior |
|---|---|
| `read <fmt>` | Raw bytes → stdout (unchanged) |
| `read <fmt> --out F` | Raw bytes → file `F` (unchanged) |
| `read <fmt> --as-path` | Decoded path(s), `\n`-terminated, → stdout |
| `read <fmt> --as-path --out F` | Decoded path(s), `\n`-terminated, → file `F` |
| `read <fmt> --as-path -0` | Decoded path(s), `\0`-terminated, → stdout |
| `read <fmt> --as-path -0 --out F` | Decoded path(s), `\0`-terminated, → file `F` |
| `read <fmt> -0` *(no `--as-path`)* | **Error:** `-0 requires --as-path` |
| `read <not-in-allowlist> --as-path` | **Error:** allowlist message (see above) |
| `read public.url --as-path` *(non-file scheme)* | **Error:** `public.url is not a file:// URL` |
| `read <allowed-fmt> --as-path` *(format absent from pasteboard)* | **Error:** `Format not found: <fmt>` (reuses existing error) |
| `read <allowed-fmt> --as-path` *(bytes malformed)* | **Error:** `Failed to decode <fmt>: <reason>` |

Exit codes: `0` on success, `1` on any error. No new exit codes — matches the existing convention in `main.zig`.

### Composition examples

With `--as-path` in place, standard Unix tools handle file operations naturally:

```fish
# Copy the clipboard file(s) to Desktop
cp (clipboard read public.file-url --as-path) ~/Desktop/

# Open them (note: `open` already works with file:// URLs, so this is mostly
# for consistency — but it keeps all clipboard-aware commands symmetrical)
open (clipboard read public.file-url --as-path)

# Safe multi-file copy (paths with spaces or newlines)
clipboard read NSFilenamesPboardType --as-path -0 | xargs -0 cp -t ~/Desktop/

# Pipe into any path-consuming tool
clipboard read public.file-url --as-path | while read path
    ls -lh $path
end
```

The CLI stays a small, sharp primitive; `cp`/`mv`/`xargs`/`while` do the work they already do well. No new bespoke "copy the file" subcommand is needed.

### Help text

Update `printUsage` in `main.zig` to describe the new flag:

```
Usage: clipboard [command] [options]

Commands:
  (none)                          Show clipboard contents (default)
  list                            List format names, one per line
  read <format> [--out <file>]    Read format data to stdout, or to a file
                [--as-path [-0]]  Decode file-reference formats to POSIX paths
  write <format> [--data <text>]  Write inline data, or read from stdin
  clear                           Clear the clipboard
  watch [--interval <ms>]         Watch for clipboard changes (default 500ms)
  help                            Show this help message
```

## Implementation Sketch

The existing layering in `native/clipboard/src/` is:

- `clipboard.zig` — thin public API / platform-dispatch layer. One-liner forwarders only.
- `platform/macos.zig` — macOS-specific pasteboard logic, built on `objc.zig`.
- `objc.zig` — Obj-C bridge.
- `main.zig` — the CLI on top.

We preserve this discipline.

### New file: `native/clipboard/src/paths.zig`

Pure Zig. No `platform`, no `objc`, no OS calls. Exports:

```zig
pub const DecodePathError = error{
    NotFileScheme,
    MalformedUrl,
    InvalidPercentEncoding,
    OutOfMemory,
};

/// Strips a trailing NUL (if present), verifies and strips `file://` prefix,
/// and percent-decodes the remainder. Caller owns the returned slice.
pub fn decodeFileUrl(allocator: Allocator, url_bytes: []const u8) DecodePathError![]u8;

/// Percent-decodes a byte slice (`%20` → ` `, etc.). Caller owns the returned slice.
pub fn percentDecode(allocator: Allocator, input: []const u8) DecodePathError![]u8;
```

Trivially unit-testable with plain byte slices — no pasteboard involved. This is where most of the real-bug surface lives (percent-decode edge cases, NUL handling, bogus URLs), and keeping it OS-free makes those tests fast and deterministic.

### Extend `native/clipboard/src/platform/macos.zig`

Add a new function:

```zig
/// Decodes a file-reference pasteboard format into POSIX paths.
/// Caller owns the returned outer slice and each inner path string.
/// Returns `error.UnsupportedFormat` for formats outside the allowlist —
/// this check happens BEFORE touching the pasteboard.
pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) ![]const []const u8;
```

Dispatch inside:

- **`public.file-url`** → read bytes via the existing `readFormat`, delegate to `paths.decodeFileUrl`, wrap in a single-element slice.
- **`public.url`** → same as above, then verify the decoded path didn't come from a non-`file://` scheme. (Concretely: `paths.decodeFileUrl` already errors on non-`file://` prefixes, so the check is implicit.)
- **`NSFilenamesPboardType`** → read bytes, call `NSPropertyListSerialization propertyListWithData:options:format:error:` via `objc.zig`, extract the top-level `NSArray` of `NSString`s, copy each into an allocator-owned Zig slice.
- **Anything else** → `error.UnsupportedFormat`. Must be checked first, before any pasteboard access, so the error is deterministic and doesn't depend on clipboard state.

The format-not-found case reuses `readFormat`'s existing behavior (it returns `null`, `main.zig` already maps that to the existing "Format not found" error).

**Why `NSPropertyListSerialization` over a hand-rolled `bplist00` parser:**

We lean on Foundation for the plist parse. The codebase already bridges to Obj-C via `objc.zig` and already links Foundation for the pasteboard itself; this is zero net new surface area. Reimplementing binary plist parsing in Zig would be interesting but it's new code to maintain and test for no user-visible benefit, and the philosophy for this library is to be a thin bridge to native clipboard management, not to reinvent Foundation. Percent-decoding is the opposite call — it's trivial, self-contained, and easier to unit-test as pure Zig than as something routed through the Obj-C bridge, so we keep that in `paths.zig`.

### Extend `native/clipboard/src/clipboard.zig`

Add a single forwarder, matching the shape of every other function in the file:

```zig
pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) ![]const []const u8 {
    return platform.decodePathsForFormat(allocator, format);
}
```

This preserves the "thin dispatch layer" rule. `main.zig` calls `clipboard.decodePathsForFormat(...)`; it never touches `paths.zig` or `platform/macos.zig` directly.

### Extend `native/clipboard/src/main.zig`

`cmdRead` currently walks its `args` slice once, recognizing `--out`. Extend the same loop to recognize `--as-path`, `-0`, and `--null` (the last two set the same flag).

After the loop, validate:

1. If `-0` is set but `--as-path` is not → error `-0 requires --as-path`, exit 1.
2. If `--as-path` is set and `format` is not in the allowlist → error with the allowlist message, exit 1.

Both validations happen **before** any pasteboard access. This keeps error behavior deterministic (the user gets the same error regardless of what's on the clipboard) and avoids spurious side effects.

Then dispatch:

- `--as-path` not set → existing behavior (raw bytes, unchanged code path).
- `--as-path` set → call `clipboard.decodePathsForFormat(allocator, format)`. On success, iterate the returned slice, writing each path to the sink (stdout or `--out` file) followed by `\n` or `\0` depending on the `-0` flag. Reuse the existing stdout/file-writing helpers in `cmdRead`.

The existing raw-bytes code path is not refactored. `--as-path` is strictly additive.

### Tests

Two test surfaces:

1. **Pure unit tests on `paths.zig`.** Fast, deterministic, no pasteboard. At minimum:
   - `decodeFileUrl` happy path (simple path, no encoding, no trailing NUL)
   - `decodeFileUrl` with trailing NUL
   - `decodeFileUrl` with percent-encoded spaces (`%20`)
   - `decodeFileUrl` with percent-encoded non-ASCII (`%E2%98%83` → `☃`)
   - `decodeFileUrl` rejects missing `file://` prefix
   - `decodeFileUrl` rejects `http://` prefix
   - `percentDecode` rejects invalid hex (`%ZZ`)
   - `percentDecode` rejects truncated escape (`%2`)

2. **Integration tests** that put known content on the real pasteboard and read it back via `clipboard read --as-path`. The existing test setup (`clipboard-snapshot.test.ts`, `clipboard-ffi.test.ts`) uses this style on the Bun side; for the Zig CLI, the equivalent is a shell-driven test that copies a fixture file, runs the binary, and asserts on output. Exact shape depends on what `native/clipboard/` currently does for tests — to be confirmed during plan writing. If no integration test harness exists yet, the pure unit tests in `paths.zig` are the minimum bar; integration tests are strongly preferred and will be added if feasible.

Minimum integration cases if the harness supports them:

- Single file via `public.file-url`, default newline output
- Single file via `public.file-url`, `-0` output
- Multi-file via `NSFilenamesPboardType` (copy 3 files in Finder as a fixture, or equivalent)
- `-0` without `--as-path` → error, non-zero exit
- Unsupported format (e.g. `public.utf8-plain-text`) with `--as-path` → error, non-zero exit
- `public.url` with `https://` scheme → error, non-zero exit

## Summary of Files Touched

- **New:** `native/clipboard/src/paths.zig` — pure helpers (`decodeFileUrl`, `percentDecode`, `DecodePathError`).
- **Modified:** `native/clipboard/src/platform/macos.zig` — add `decodePathsForFormat`, use `NSPropertyListSerialization` for the plist case, delegate to `paths.zig` for URL decoding.
- **Modified:** `native/clipboard/src/clipboard.zig` — one-line forwarder for `decodePathsForFormat`.
- **Modified:** `native/clipboard/src/main.zig` — extend `cmdRead` arg parsing, add `--as-path` / `-0` / `--null` handling, update `printUsage`, reuse existing stdout/file sinks.
- **New (maybe):** tests for `paths.zig` (pure unit tests) and integration tests for `cmdRead --as-path`, shape TBD based on existing harness.
