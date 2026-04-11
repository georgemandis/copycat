# `clipboard read --as-path` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--as-path` flag to the existing `clipboard read` subcommand that decodes file-reference pasteboard formats (`public.file-url`, `NSFilenamesPboardType`, `public.url` with `file://` scheme) into POSIX paths, so the CLI composes with standard Unix tools like `cp`, `mv`, `xargs`, and `open`.

**Architecture:** Pure-Zig helpers for URL / percent-decode logic live in a new `paths.zig`, fully unit-testable with no OS dependencies. macOS-specific decoding (binary plist via `NSPropertyListSerialization`) lives in `platform/macos.zig` as a new `decodePathsForFormat` function, delegating to `paths.zig` for the URL cases. `clipboard.zig` gets a one-line dispatch forwarder matching the file's existing pattern. `main.zig`'s `cmdRead` gains `--as-path`, `-0`, and `--null` flag parsing with pre-pasteboard validation, then dispatches to either the existing raw-bytes path (unchanged) or the new path-decoding branch. A minimal Zig test runner is added to `build.zig` so `paths.zig` can be unit-tested without an integration harness.

**Tech Stack:** Zig 0.15.2, Foundation framework (via existing `objc.zig` bridge), no new dependencies.

**Spec reference:** `docs/superpowers/specs/2026-04-07-clipboard-read-as-path-design.md`

---

## Repository Layout Notice (read this first)

**`native/clipboard/` is its own git repository**, nested inside the parent `clipboard-manager` repo. The parent repo's `.gitignore` has a blanket `native` entry, so nothing under `native/` is tracked by the parent — all Zig source, build config, and history lives in the inner repo.

**Consequence for every task in this plan:**

- All `git add` / `git commit` commands run **inside `native/clipboard/`**, not at the project root.
- Commit paths in the plan are written as if you're already in the project root (e.g. `native/clipboard/build.zig`) for clarity, but the actual `git add` / `git commit` invocations below use paths relative to `native/clipboard/`.
- The inner repo is on branch `main` and has prior history (its own `main` is independent of the parent repo's `main`).
- The inner repo's README.md may have small unrelated modifications (shell-completions documentation) and a `completions/` directory may be untracked. **Including those in your Task 1 commit is fine** — they're a self-contained unit that the user has explicitly OK'd rolling into the first commit. Tasks 2+ should only stage their own files.

When a task says "commit your changes", interpret it as:

```bash
cd native/clipboard
git add <paths relative to native/clipboard>
git commit -m "..."
cd -   # back to project root
```

---

## File Structure Overview

### New files
- `native/clipboard/src/paths.zig` — Pure Zig helpers: `decodeFileUrl`, `percentDecode`, `DecodePathError`. No `platform`, no `objc`, no OS calls. Unit tests live inline via `test "..."` blocks.

### Modified files
- `native/clipboard/build.zig` — Add a `test` step that runs Zig unit tests against `paths.zig` (and, if feasible later, other pure modules).
- `native/clipboard/src/platform/macos.zig` — Add `decodePathsForFormat` and an `UnsupportedFormat` error variant; reuse existing `readFormat` for fetching bytes; call `NSPropertyListSerialization` via `objc.msgSend` for the plist case.
- `native/clipboard/src/clipboard.zig` — Add a one-line `decodePathsForFormat` forwarder and re-export its error set.
- `native/clipboard/src/main.zig` — Extend `cmdRead` to recognize `--as-path`, `-0`, and `--null`; add pre-pasteboard validation for `-0 requires --as-path` and the file-reference allowlist; dispatch to the new path-decoding branch; update `printUsage`.

### Unchanged files (explicitly out of scope)
- `native/clipboard/src/lib.zig` — FFI surface is not touched. `--as-path` is CLI-only.
- `native/clipboard/src/objc.zig` — No new bridge helpers needed; `NSPropertyListSerialization` is reachable via the generic `msgSend` already exported.
- Anything under `src/bun/` or `src/mainview/` — the Schrodinger app doesn't consume this CLI flag.

---

## Task 1: Bootstrap a Zig unit test harness in `build.zig`

**Why this is first:** The spec calls for pure unit tests on `paths.zig`, but `native/clipboard/build.zig` currently has no test step. Without this, we can't do TDD on `paths.zig`. This task adds the minimum viable test runner so every subsequent task can write a failing test first.

**Files:**
- Modify: `native/clipboard/build.zig:44-53` (add new test step after the existing `run_step`)

- [ ] **Step 1: Verify the current state of `build.zig`**

Run: `cat native/clipboard/build.zig`
Expected: File ends with the `run_step` definition around line 53 and contains no `test` step. Confirms the baseline.

- [ ] **Step 2: Add a test step that compiles and runs tests in `paths.zig`**

Append this to `native/clipboard/build.zig`, after the existing `run_step` block (around line 53, just before the closing brace of `build`):

```zig
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
```

- [ ] **Step 3: Verify the test step exists before `paths.zig` is written**

Run: `cd native/clipboard && zig build test 2>&1`
Expected: **FAIL** with an error like `error: unable to load 'src/paths.zig'` or `FileNotFound`. This confirms the test step is wired up and is looking for `paths.zig`. It is expected to fail until Task 2 creates the file.

- [ ] **Step 4: Commit (inside `native/clipboard/`)**

The user has OK'd rolling the pre-existing `README.md` edit and untracked `completions/` directory into this first commit, since they're a self-contained shell-completions unit.

```bash
cd native/clipboard
git add build.zig README.md completions/
git commit -m "build(clipboard): add zig build test step; docs: shell completions"
cd -
```

If `README.md` and `completions/` are not present as untracked/modified when you run this task (e.g. because someone already committed them), just commit `build.zig` on its own:

```bash
cd native/clipboard
git add build.zig
git commit -m "build(clipboard): add zig build test step for pure-Zig modules"
cd -
```

---

## Task 2: Create `paths.zig` with `percentDecode` (TDD, one helper at a time)

**Why second:** Percent-decoding is the smallest, most self-contained piece. Getting it right first means `decodeFileUrl` (Task 3) has a trustworthy building block.

**Files:**
- Create: `native/clipboard/src/paths.zig`

- [ ] **Step 1: Create `paths.zig` with the error set and a failing `percentDecode` test**

Create `native/clipboard/src/paths.zig` with the following content:

```zig
//! Pure Zig helpers for decoding file-reference pasteboard bytes into POSIX paths.
//!
//! This module has NO dependencies on Foundation, Obj-C, or any OS APIs —
//! it operates purely on byte slices. That makes it trivially unit-testable
//! and portable if the clipboard library ever targets non-macOS platforms
//! (percent decoding and file:// parsing are platform-agnostic).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodePathError = error{
    /// Input did not begin with `file://`.
    NotFileScheme,
    /// URL was malformed in a way we can't recover from (e.g. empty after prefix).
    MalformedUrl,
    /// A `%` escape was truncated or contained non-hex characters.
    InvalidPercentEncoding,
    /// Allocator ran out of memory.
    OutOfMemory,
};

/// Percent-decodes a byte slice: `%20` → ` `, `%E2%98%83` → `☃` (UTF-8 passthrough).
/// A lone `%` or a `%` followed by fewer than two hex characters is an error.
/// Caller owns the returned slice.
pub fn percentDecode(allocator: Allocator, input: []const u8) DecodePathError![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, input.len);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '%') {
            try out.append(input[i]);
            continue;
        }
        if (i + 2 >= input.len) return DecodePathError.InvalidPercentEncoding;
        const hi = std.fmt.charToDigit(input[i + 1], 16) catch return DecodePathError.InvalidPercentEncoding;
        const lo = std.fmt.charToDigit(input[i + 2], 16) catch return DecodePathError.InvalidPercentEncoding;
        try out.append((hi << 4) | lo);
        i += 2;
    }

    return try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "percentDecode passes through plain ASCII unchanged" {
    const result = try percentDecode(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "percentDecode decodes %20 to space" {
    const result = try percentDecode(std.testing.allocator, "a%20b");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a b", result);
}

test "percentDecode decodes multi-byte UTF-8 sequence" {
    // %E2%98%83 is U+2603 SNOWMAN (☃) in UTF-8
    const result = try percentDecode(std.testing.allocator, "%E2%98%83");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\xE2\x98\x83", result);
}

test "percentDecode handles uppercase and lowercase hex" {
    const upper = try percentDecode(std.testing.allocator, "%2F");
    defer std.testing.allocator.free(upper);
    try std.testing.expectEqualStrings("/", upper);

    const lower = try percentDecode(std.testing.allocator, "%2f");
    defer std.testing.allocator.free(lower);
    try std.testing.expectEqualStrings("/", lower);
}

test "percentDecode rejects truncated escape at end" {
    try std.testing.expectError(
        DecodePathError.InvalidPercentEncoding,
        percentDecode(std.testing.allocator, "abc%2"),
    );
}

test "percentDecode rejects lone percent sign" {
    try std.testing.expectError(
        DecodePathError.InvalidPercentEncoding,
        percentDecode(std.testing.allocator, "%"),
    );
}

test "percentDecode rejects non-hex characters in escape" {
    try std.testing.expectError(
        DecodePathError.InvalidPercentEncoding,
        percentDecode(std.testing.allocator, "%ZZ"),
    );
}
```

- [ ] **Step 2: Run the tests**

Run: `cd native/clipboard && zig build test 2>&1`
Expected: **All 7 tests pass.** Output should contain something like `All 7 tests passed.` If it fails, the error message will point at the specific test.

Note: because the implementation and tests are being added together (the file must exist before the test step can compile), this task does not have a separate "write failing test, then implement" step for `percentDecode`. The test-first discipline is enforced at the granularity of the *file* — `paths.zig` exists for the first time here with tests in place, and the subsequent tasks add one function at a time via true red-green cycles.

- [ ] **Step 3: Commit (inside `native/clipboard/`)**

```bash
cd native/clipboard
git add src/paths.zig
git commit -m "feat(clipboard): add paths.zig with percentDecode helper"
cd -
```

---

## Task 3: Add `decodeFileUrl` to `paths.zig` (true TDD cycle)

**Why:** This is the function the CLI actually calls for `public.file-url` and `public.url`. It wraps `percentDecode` with the `file://` prefix check and trailing-NUL handling.

**Files:**
- Modify: `native/clipboard/src/paths.zig` (add function + tests)

- [ ] **Step 1: Add failing tests for `decodeFileUrl`**

Append the following tests to the end of `native/clipboard/src/paths.zig` (before the closing of the file, after the `percentDecode` tests):

```zig
test "decodeFileUrl strips file:// prefix and percent-decodes" {
    const result = try decodeFileUrl(std.testing.allocator, "file:///Users/george/Downloads/thing.pdf");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/Users/george/Downloads/thing.pdf", result);
}

test "decodeFileUrl handles percent-encoded spaces" {
    const result = try decodeFileUrl(std.testing.allocator, "file:///Users/george/My%20Files/thing.pdf");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/Users/george/My Files/thing.pdf", result);
}

test "decodeFileUrl strips trailing NUL byte" {
    const input = "file:///tmp/foo\x00";
    const result = try decodeFileUrl(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/foo", result);
}

test "decodeFileUrl handles UTF-8 in path" {
    // %E2%98%83 is ☃
    const result = try decodeFileUrl(std.testing.allocator, "file:///tmp/%E2%98%83.txt");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/\xE2\x98\x83.txt", result);
}

test "decodeFileUrl rejects http scheme" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeFileUrl(std.testing.allocator, "http://example.com/"),
    );
}

test "decodeFileUrl rejects missing scheme" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeFileUrl(std.testing.allocator, "/plain/path"),
    );
}

test "decodeFileUrl rejects empty input" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeFileUrl(std.testing.allocator, ""),
    );
}

test "decodeFileUrl rejects file:// with empty path" {
    try std.testing.expectError(
        DecodePathError.MalformedUrl,
        decodeFileUrl(std.testing.allocator, "file://"),
    );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd native/clipboard && zig build test 2>&1`
Expected: **FAIL** with `error: use of undeclared identifier 'decodeFileUrl'` or similar. Confirms the tests reference a function that doesn't exist yet.

- [ ] **Step 3: Implement `decodeFileUrl`**

Add this function to `native/clipboard/src/paths.zig` immediately after `percentDecode` and before the test block:

```zig
/// Decodes a `file://...` URL byte slice into a POSIX path.
///
/// Steps:
///   1. Strip a single trailing NUL byte if present (macOS pasteboards sometimes NUL-terminate).
///   2. Verify the input begins with `file://`. Otherwise → `NotFileScheme`.
///   3. Strip the `file://` prefix.
///   4. Reject empty-after-prefix inputs → `MalformedUrl`.
///   5. Percent-decode the remainder and return it.
///
/// Note: does NOT canonicalize, resolve symlinks, or check existence.
/// Caller owns the returned slice.
pub fn decodeFileUrl(allocator: Allocator, url_bytes: []const u8) DecodePathError![]u8 {
    // 1. Strip a single trailing NUL if present.
    var trimmed: []const u8 = url_bytes;
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == 0) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }

    // 2. Verify `file://` prefix.
    const prefix = "file://";
    if (trimmed.len < prefix.len or !std.mem.eql(u8, trimmed[0..prefix.len], prefix)) {
        return DecodePathError.NotFileScheme;
    }

    // 3 + 4. Strip prefix, reject empty remainder.
    const after_prefix = trimmed[prefix.len..];
    if (after_prefix.len == 0) return DecodePathError.MalformedUrl;

    // 5. Percent-decode.
    return try percentDecode(allocator, after_prefix);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd native/clipboard && zig build test 2>&1`
Expected: **All 15 tests pass.**

- [ ] **Step 5: Commit (inside `native/clipboard/`)**

```bash
cd native/clipboard
git add src/paths.zig
git commit -m "feat(clipboard): add decodeFileUrl to paths.zig"
cd -
```

---

## Task 4: Add `decodePathsForFormat` skeleton with allowlist gate in `platform/macos.zig`

**Why:** This is the entry point `main.zig` will eventually call. We build it in two passes: first the skeleton that handles the allowlist gate and the two URL-based formats (delegating to `paths.zig`), then Task 5 adds the `NSFilenamesPboardType` plist branch. Splitting lets each step stay small.

**Files:**
- Modify: `native/clipboard/src/platform/macos.zig:19-23` (extend `ClipboardError` enum)
- Modify: `native/clipboard/src/platform/macos.zig:end-of-file` (add `decodePathsForFormat`)

- [ ] **Step 1: Extend the `ClipboardError` set**

In `native/clipboard/src/platform/macos.zig`, update the `ClipboardError` declaration to add three new variants:

```zig
pub const ClipboardError = error{
    PasteboardUnavailable,
    NoItems,
    WriteFailed,
    UnsupportedFormat,
    FormatNotFound,
    MalformedPlist,
};
```

(`UnsupportedFormat` for the allowlist gate; `FormatNotFound` for the "allowed format but not on pasteboard" case; `MalformedPlist` for Task 5.)

- [ ] **Step 2: Add the `decodePathsForFormat` skeleton**

Append this function to the end of `native/clipboard/src/platform/macos.zig`:

```zig
// ---------------------------------------------------------------------------
// Path decoding for file-reference formats
// ---------------------------------------------------------------------------

const paths = @import("../paths.zig");

/// The allowlist of UTIs that `decodePathsForFormat` will accept.
/// Anything else returns `ClipboardError.UnsupportedFormat`.
///
/// `NSFilenamesPboardType` is deprecated by Apple in favor of multiple
/// `public.file-url` items on the pasteboard, but real-world Finder still
/// uses it when more than one file is copied, so we support it.
const file_ref_allowlist = [_][]const u8{
    "public.file-url",
    "NSFilenamesPboardType",
    "public.url",
};

fn isFileRefFormat(format: []const u8) bool {
    for (file_ref_allowlist) |allowed| {
        if (std.mem.eql(u8, format, allowed)) return true;
    }
    return false;
}

/// Decodes a file-reference pasteboard format into one or more POSIX paths.
///
/// Returns `ClipboardError.UnsupportedFormat` for any format not in the
/// allowlist — this check happens BEFORE any pasteboard access, so the error
/// is deterministic regardless of clipboard state.
///
/// Returns `ClipboardError.FormatNotFound` if the format is in the allowlist
/// but absent from the current pasteboard.
///
/// Caller owns the returned outer slice AND each inner path string.
pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) ![]const []const u8 {
    // Allowlist gate — before touching the pasteboard.
    if (!isFileRefFormat(format)) return ClipboardError.UnsupportedFormat;

    // Fetch raw bytes via the existing readFormat.
    const raw = try readFormat(allocator, format) orelse return ClipboardError.FormatNotFound;
    defer allocator.free(raw);

    // Dispatch by format.
    if (std.mem.eql(u8, format, "public.file-url") or std.mem.eql(u8, format, "public.url")) {
        const path = try paths.decodeFileUrl(allocator, raw);
        errdefer allocator.free(path);

        const result = try allocator.alloc([]const u8, 1);
        result[0] = path;
        return result;
    }

    // NSFilenamesPboardType — implemented in Task 5.
    if (std.mem.eql(u8, format, "NSFilenamesPboardType")) {
        return ClipboardError.MalformedPlist; // placeholder until Task 5
    }

    unreachable; // allowlist check above guarantees one of the branches matches
}
```

- [ ] **Step 3: Verify the file compiles**

Run: `cd native/clipboard && zig build 2>&1`
Expected: **Build succeeds.** (No tests to run for this task — `platform/macos.zig` is not in the test step because it links Foundation.)

- [ ] **Step 4: Commit (inside `native/clipboard/`)**

```bash
cd native/clipboard
git add src/platform/macos.zig
git commit -m "feat(clipboard): add decodePathsForFormat skeleton with allowlist gate"
cd -
```

---

## Task 5: Implement the `NSFilenamesPboardType` plist branch

**Why:** Multi-file copy from Finder is the most common real-world multi-path case. We parse the binary plist via Foundation's `NSPropertyListSerialization` and extract an `NSArray` of `NSString` paths.

**Files:**
- Modify: `native/clipboard/src/platform/macos.zig` (replace the Task 4 placeholder with the real plist branch)

- [ ] **Step 1: Replace the `NSFilenamesPboardType` placeholder with real plist parsing**

In `native/clipboard/src/platform/macos.zig`, replace this block inside `decodePathsForFormat`:

```zig
    // NSFilenamesPboardType — implemented in Task 5.
    if (std.mem.eql(u8, format, "NSFilenamesPboardType")) {
        return ClipboardError.MalformedPlist; // placeholder until Task 5
    }
```

…with this real implementation:

```zig
    if (std.mem.eql(u8, format, "NSFilenamesPboardType")) {
        return try decodeFilenamesPlist(allocator, raw);
    }
```

Then, immediately after `decodePathsForFormat`, add the helper:

```zig
/// Parse an `NSFilenamesPboardType` binary plist (bytes from the pasteboard)
/// and return an allocator-owned slice of allocator-owned POSIX path strings.
///
/// Uses `NSPropertyListSerialization propertyListWithData:options:format:error:`
/// from Foundation, which handles both binary and XML plist formats.
fn decodeFilenamesPlist(allocator: Allocator, bytes: []const u8) ![]const []const u8 {
    // Wrap the bytes in an NSData (autoreleased).
    const nsdata = if (bytes.len == 0)
        objc.nsDataEmpty()
    else
        objc.nsDataFromBytes(bytes.ptr, bytes.len);

    // Call [NSPropertyListSerialization propertyListWithData:options:format:error:]
    // Signature: + (id)propertyListWithData:(NSData *)data
    //                              options:(NSPropertyListReadOptions)opt
    //                               format:(NSPropertyListFormat *)format
    //                                error:(out NSError **)error;
    //
    // We pass 0 for options (NSPropertyListImmutable), and null for both
    // out-pointers — we don't care which plist format it was, and if it fails
    // we just need to know the call returned nil.
    const NSPropertyListSerialization = objc.getClass("NSPropertyListSerialization") orelse return ClipboardError.MalformedPlist;

    const plist: ?objc.id = objc.msgSend(
        ?objc.id,
        NSPropertyListSerialization,
        objc.sel("propertyListWithData:options:format:error:"),
        .{ nsdata, @as(objc.NSUInteger, 0), @as(?*anyopaque, null), @as(?*anyopaque, null) },
    );
    const plist_id = plist orelse return ClipboardError.MalformedPlist;

    // Must be an NSArray.
    const NSArray = objc.getClass("NSArray") orelse return ClipboardError.MalformedPlist;
    const is_array = objc.msgSend(bool, plist_id, objc.sel("isKindOfClass:"), .{NSArray});
    if (!is_array) return ClipboardError.MalformedPlist;

    const count = objc.nsArrayCount(plist_id);
    var result = try allocator.alloc([]const u8, count);
    errdefer allocator.free(result);

    // Track how many inner strings we've successfully allocated, so a later
    // allocation failure can free only the ones we own. Zig runs errdefers
    // in reverse order, so on error this fires BEFORE `allocator.free(result)`
    // above — inner strings freed first, then the outer slice.
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |s| allocator.free(s);
    }

    const NSString = objc.getClass("NSString") orelse return ClipboardError.MalformedPlist;
    for (0..count) |i| {
        const elem = objc.nsArrayObjectAtIndex(plist_id, i);
        const is_str = objc.msgSend(bool, elem, objc.sel("isKindOfClass:"), .{NSString});
        if (!is_str) return ClipboardError.MalformedPlist;

        const cstr = objc.fromNSString(elem) orelse return ClipboardError.MalformedPlist;
        const len = std.mem.len(cstr);
        const copy = try allocator.alloc(u8, len);
        @memcpy(copy, cstr[0..len]);
        result[filled] = copy;
        filled += 1;
    }

    return result;
}
```

**Note on `msgSend` variadic count:** `objc.zig`'s `MsgSendFnType` currently supports up to 3 argument fields. This call passes 4 arguments (`data`, `options`, `format`, `error`), so you must extend `MsgSendFnType` and the `msgSend` switch to handle `4 => ...` before Step 2 will compile.

- [ ] **Step 2: Extend `objc.zig` to support 4-argument `msgSend` calls**

In `native/clipboard/src/objc.zig`, update `MsgSendFnType` (around line 41) to add a 4th case:

```zig
return switch (fields.len) {
    0 => *const fn (id, SEL) callconv(.c) ReturnType,
    1 => *const fn (id, SEL, fields[0].type) callconv(.c) ReturnType,
    2 => *const fn (id, SEL, fields[0].type, fields[1].type) callconv(.c) ReturnType,
    3 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) ReturnType,
    4 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type, fields[3].type) callconv(.c) ReturnType,
    else => @compileError("msgSendFn: too many arguments, add more cases"),
};
```

And update the `msgSend` dispatch switch (around line 62) to add the 4-arg case:

```zig
return switch (fields.len) {
    0 => func(target_as_id, selector),
    1 => func(target_as_id, selector, args[0]),
    2 => func(target_as_id, selector, args[0], args[1]),
    3 => func(target_as_id, selector, args[0], args[1], args[2]),
    4 => func(target_as_id, selector, args[0], args[1], args[2], args[3]),
    else => @compileError("msgSend: too many arguments"),
};
```

- [ ] **Step 3: Verify the file compiles**

Run: `cd native/clipboard && zig build 2>&1`
Expected: **Build succeeds.**

- [ ] **Step 4: Manual smoke test — single file**

```bash
# In Finder, copy any single file (⌘C). Then:
cd native/clipboard
zig build
# Verify the format is on the pasteboard:
./zig-out/bin/clipboard list | grep -E "public.file-url|NSFilenamesPboardType"
# Should print at least `public.file-url`.
```

Expected: `public.file-url` appears in the output. (`NSFilenamesPboardType` may or may not — single-file copies usually only use `public.file-url`.)

- [ ] **Step 5: Manual smoke test — multi-file**

```bash
# In Finder, select 2+ files and copy (⌘C). Then:
./zig-out/bin/clipboard list | grep NSFilenamesPboardType
```

Expected: `NSFilenamesPboardType` appears in the output. If it doesn't, document this in the task comments — modern Finder may have dropped it entirely, in which case the multi-file case is handled by iterating multiple `public.file-url` items (out of scope for this task but good to know).

- [ ] **Step 6: Commit (inside `native/clipboard/`)**

```bash
cd native/clipboard
git add src/platform/macos.zig src/objc.zig
git commit -m "feat(clipboard): decode NSFilenamesPboardType plist via NSPropertyListSerialization"
cd -
```

---

## Task 6: Add the `decodePathsForFormat` forwarder to `clipboard.zig`

**Why:** The existing layering keeps `clipboard.zig` as a thin public API that only dispatches to `platform/`. We match that pattern exactly.

**Files:**
- Modify: `native/clipboard/src/clipboard.zig:33-35` (add forwarder after `getChangeCount`)

- [ ] **Step 1: Add the forwarder**

Append the following to `native/clipboard/src/clipboard.zig`, after the `getChangeCount` function (around line 36):

```zig
/// Decodes a file-reference pasteboard format (e.g. `public.file-url`,
/// `NSFilenamesPboardType`, `public.url` with file:// scheme) into one or
/// more POSIX paths. Caller owns the outer slice AND each inner path string.
pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) ![]const []const u8 {
    return platform.decodePathsForFormat(allocator, format);
}
```

- [ ] **Step 2: Verify the library still builds**

Run: `cd native/clipboard && zig build 2>&1`
Expected: **Build succeeds.**

- [ ] **Step 3: Commit (inside `native/clipboard/`)**

```bash
cd native/clipboard
git add src/clipboard.zig
git commit -m "feat(clipboard): add decodePathsForFormat forwarder to public API"
cd -
```

---

## Task 7: Wire `--as-path`, `-0`, `--null` into `cmdRead` in `main.zig`

**Why:** Final task — the user-facing CLI surface. This is the biggest single edit because `cmdRead` currently parses only `--out` in a single loop, and we need to extend that loop, add validation, then branch into the new path-decoding code path. Help text is updated in the same commit so the CLI is always internally consistent.

**Files:**
- Modify: `native/clipboard/src/main.zig:76-93` (extend `printUsage`)
- Modify: `native/clipboard/src/main.zig:224-270` (extend `cmdRead`)

- [ ] **Step 1: Update `printUsage` to document the new flag**

In `native/clipboard/src/main.zig`, locate the `printUsage` function (starts around line 75). Change the `read` line in the usage string so the command table shows the new option. Replace:

```
        \\  read <format> [--out <file>]    Read format data to stdout, or to a file
```

with:

```
        \\  read <format> [--out <file>]    Read format data to stdout, or to a file
        \\                [--as-path [-0]]  Decode file-reference formats to POSIX paths
```

- [ ] **Step 2: Rewrite `cmdRead` to handle the new flags**

Replace the entire `cmdRead` function in `native/clipboard/src/main.zig` (starting at the line with `fn cmdRead(allocator: Allocator, args: []const []const u8) !void {` around line 224, ending at its closing brace around line 270) with this new version:

```zig
fn cmdRead(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Usage: clipboard read <format> [--out <file>] [--as-path [-0]]\n", .{});
        try ew.interface.flush();
        std.process.exit(1);
    }

    const format = args[0];
    var out_file: ?[]const u8 = null;
    var as_path = false;
    var null_sep = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_file = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--as-path")) {
            as_path = true;
        } else if (std.mem.eql(u8, args[i], "-0") or std.mem.eql(u8, args[i], "--null")) {
            null_sep = true;
        }
        // Unknown flags are ignored, matching the existing (lax) behavior.
    }

    // --- Validation (runs BEFORE any pasteboard access) ---

    if (null_sep and !as_path) {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Error: -0 requires --as-path\n", .{});
        try ew.interface.flush();
        std.process.exit(1);
    }

    if (as_path and !isAllowlistedFileRef(format)) {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print(
            "Error: --as-path only supports file-reference formats: public.file-url, NSFilenamesPboardType, public.url\n",
            .{},
        );
        try ew.interface.flush();
        std.process.exit(1);
    }

    // --- Dispatch ---

    if (!as_path) {
        // Existing raw-bytes path — unchanged.
        const data = try clipboard.readFormat(allocator, format);
        if (data) |bytes| {
            defer allocator.free(bytes);

            if (out_file) |path| {
                const file = try std.fs.cwd().createFile(path, .{});
                defer file.close();
                try file.writeAll(bytes);
                const stderr_file = std.fs.File.stderr();
                var errbuf: [4096]u8 = undefined;
                var ew = stderr_file.writer(&errbuf);
                try ew.interface.print("Wrote {d} bytes to {s}\n", .{ bytes.len, path });
                try ew.interface.flush();
            } else {
                const stdout_file = std.fs.File.stdout();
                try stdout_file.writeAll(bytes);
            }
        } else {
            const stderr_file = std.fs.File.stderr();
            var errbuf: [4096]u8 = undefined;
            var ew = stderr_file.writer(&errbuf);
            try ew.interface.print("Format not found: {s}\n", .{format});
            try ew.interface.flush();
            std.process.exit(1);
        }
        return;
    }

    // --- --as-path path ---

    const paths_result = clipboard.decodePathsForFormat(allocator, format) catch |err| {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        switch (err) {
            error.FormatNotFound => try ew.interface.print("Format not found: {s}\n", .{format}),
            error.NotFileScheme => try ew.interface.print("Error: {s} is not a file:// URL\n", .{format}),
            error.MalformedUrl => try ew.interface.print("Error: failed to decode {s}: malformed URL\n", .{format}),
            error.InvalidPercentEncoding => try ew.interface.print("Error: failed to decode {s}: invalid percent-encoding\n", .{format}),
            error.MalformedPlist => try ew.interface.print("Error: failed to decode {s}: malformed plist\n", .{format}),
            else => try ew.interface.print("Error: failed to decode {s}: {s}\n", .{ format, @errorName(err) }),
        }
        try ew.interface.flush();
        std.process.exit(1);
    };
    defer {
        for (paths_result) |p| allocator.free(p);
        allocator.free(paths_result);
    }

    const terminator: u8 = if (null_sep) 0 else '\n';

    if (out_file) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        for (paths_result) |p| {
            try file.writeAll(p);
            try file.writeAll(&[_]u8{terminator});
        }
    } else {
        const stdout_file = std.fs.File.stdout();
        for (paths_result) |p| {
            try stdout_file.writeAll(p);
            try stdout_file.writeAll(&[_]u8{terminator});
        }
    }
}

/// Duplicated from platform/macos.zig on purpose: main.zig is the CLI layer
/// and needs to reject unsupported formats BEFORE calling into the clipboard
/// API, so the error message is emitted from the CLI and not surfaced via
/// the generic `UnsupportedFormat` error code. The list is small and tightly
/// coupled to the spec; if it diverges, a single test will catch it.
fn isAllowlistedFileRef(format: []const u8) bool {
    const allowed = [_][]const u8{ "public.file-url", "NSFilenamesPboardType", "public.url" };
    for (allowed) |a| {
        if (std.mem.eql(u8, format, a)) return true;
    }
    return false;
}
```

- [ ] **Step 3: Build**

Run: `cd native/clipboard && zig build 2>&1`
Expected: **Build succeeds** with no warnings.

- [ ] **Step 4: Run existing unit tests to verify no regressions**

Run: `cd native/clipboard && zig build test 2>&1`
Expected: **All 15 `paths.zig` tests still pass.** No new tests added here; the path-decoding core is already covered.

- [ ] **Step 5: Manual smoke test — single file via `public.file-url`**

```bash
# In Finder, copy a single file (⌘C). Then:
./zig-out/bin/clipboard read public.file-url --as-path
```

Expected: One line, the absolute POSIX path of the copied file, newline-terminated. Example: `/Users/george/Downloads/thing.pdf` followed by a newline.

- [ ] **Step 6: Manual smoke test — `cp` composition**

```bash
# With a file still copied in Finder:
cp (./zig-out/bin/clipboard read public.file-url --as-path) /tmp/
ls /tmp/ | tail -5
```

Expected: The copied file appears in `/tmp/`. (Use `$(...)` instead of `(...)` if running in bash rather than fish.)

- [ ] **Step 7: Manual smoke test — `-0` without `--as-path` errors**

```bash
./zig-out/bin/clipboard read public.utf8-plain-text -0; echo "exit=$status"
```

Expected: stderr prints `Error: -0 requires --as-path`, exit status is 1. (Use `$?` in bash.)

- [ ] **Step 8: Manual smoke test — unsupported format with `--as-path` errors**

```bash
./zig-out/bin/clipboard read public.utf8-plain-text --as-path; echo "exit=$status"
```

Expected: stderr prints `Error: --as-path only supports file-reference formats: public.file-url, NSFilenamesPboardType, public.url`, exit status is 1. Crucially, this error fires even if `public.utf8-plain-text` is not on the pasteboard — the allowlist check runs before any pasteboard access.

- [ ] **Step 9: Manual smoke test — `public.url` with non-file scheme**

```bash
# Copy an http:// URL from a browser (as a URL, not text), then:
./zig-out/bin/clipboard read public.url --as-path; echo "exit=$status"
```

Expected: stderr prints `Error: public.url is not a file:// URL`, exit status is 1. (If the browser doesn't put `public.url` on the pasteboard, you'll see `Format not found: public.url` instead — also acceptable.)

- [ ] **Step 10: Manual smoke test — multi-file via `NSFilenamesPboardType`**

```bash
# In Finder, select 2+ files and copy (⌘C). Then:
./zig-out/bin/clipboard read NSFilenamesPboardType --as-path
```

Expected: Each copied file's path on its own line, newline-terminated. If `NSFilenamesPboardType` is not present on the pasteboard (modern Finder may omit it), the command will print `Format not found: NSFilenamesPboardType` and exit 1 — this is acceptable and documents the reality.

- [ ] **Step 11: Manual smoke test — `-0` null-delimited output**

```bash
# With a file copied in Finder:
./zig-out/bin/clipboard read public.file-url --as-path -0 | xxd | head -5
```

Expected: The output ends with a NUL byte (`00`), not a newline (`0a`).

- [ ] **Step 12: Run the full help to confirm formatting**

```bash
./zig-out/bin/clipboard --help
```

Expected: The `read` line is followed by a continuation line showing `[--as-path [-0]]`. Columns line up reasonably with the rest of the command table.

- [ ] **Step 13: Commit (inside `native/clipboard/`)**

```bash
cd native/clipboard
git add src/main.zig
git commit -m "feat(clipboard): add read --as-path flag with -0/--null for file refs"
cd -
```

---

## Task 8: Verification sweep

**Why:** Final confidence check before declaring done. Runs everything one more time in a clean state.

**Files:** None modified.

- [ ] **Step 1: Clean build**

```bash
cd native/clipboard && rm -rf zig-out .zig-cache && zig build 2>&1
```

Expected: Build succeeds from scratch.

- [ ] **Step 2: Full test suite**

Run: `cd native/clipboard && zig build test 2>&1`
Expected: **All 15 tests pass.** (7 `percentDecode` + 8 `decodeFileUrl`.)

- [ ] **Step 3: Regression smoke — existing `read` without `--as-path`**

```bash
# In Finder, copy some plain text. Then:
./zig-out/bin/clipboard read public.utf8-plain-text
```

Expected: The copied text prints to stdout. (This verifies Task 7's rewrite of `cmdRead` didn't break the existing raw-bytes path.)

- [ ] **Step 4: Regression smoke — `read --out` without `--as-path`**

```bash
./zig-out/bin/clipboard read public.utf8-plain-text --out /tmp/clip.txt
cat /tmp/clip.txt
```

Expected: stderr: `Wrote N bytes to /tmp/clip.txt`. Cat shows the copied text. (This verifies `--out` still works for raw bytes.)

- [ ] **Step 5: Regression smoke — `list`, `write`, `watch`, `clear`**

```bash
./zig-out/bin/clipboard list | head -5
./zig-out/bin/clipboard write public.utf8-plain-text --data "hello from test"
./zig-out/bin/clipboard read public.utf8-plain-text
```

Expected: `list` prints formats; `write` succeeds silently; the final `read` prints `hello from test`. (`watch` and `clear` require manual interaction and don't need to be part of this sweep.)

- [ ] **Step 6: Check git log (inside `native/clipboard/`)**

```bash
cd native/clipboard
git log --oneline -10
cd -
```

Expected: The last 7 commits are the ones from this plan (Tasks 1–7), in order, with no stray commits. Remember: the Zig work lives in the inner `native/clipboard/` repo, not the parent `clipboard-manager` repo.

- [ ] **Step 7: No lingering TODO / FIXME / XXX in the changed files**

Run: (use your editor's search or `grep -rn "TODO\|FIXME\|XXX" native/clipboard/src/paths.zig native/clipboard/src/platform/macos.zig native/clipboard/src/clipboard.zig native/clipboard/src/main.zig native/clipboard/src/objc.zig native/clipboard/build.zig`)

Expected: No output (or only pre-existing markers from before this plan). Any new `TODO` / `FIXME` markers must be resolved or converted into follow-up issues before declaring done.

---

## Out-of-scope reminders

These are explicitly NOT part of this plan. If you find yourself tempted to add them, stop and surface them as a follow-up.

- **A `save` / DWIM subcommand.** Spec says no; the `cp (clipboard read ... --as-path)` composition pattern is the story.
- **FFI exports for path decoding.** `lib.zig` is not touched. Schrodinger's Bun side does not consume this flag.
- **Canonicalization, symlink resolution, or existence checks** on decoded paths.
- **Handling `http://`, `mailto:`, etc. URLs** under `public.url`. These error out with `NotFileScheme`, intentionally.
- **Cross-platform ports** (Linux, Windows). A separate initiative tracked outside this plan — see memory `project_cross_platform_roadmap.md`.
- **Refactoring the existing `cmdRead` raw-bytes path** beyond what Task 7 requires. The new branch is strictly additive.
- **Tightening `cmdRead`'s silent-unknown-arg behavior.** Preserved as-is for compatibility; can be a separate follow-up if desired.
