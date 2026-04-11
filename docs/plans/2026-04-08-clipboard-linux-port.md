# Clipboard Library Linux Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Linux as a first-class platform to the native clipboard library and CLI, alongside the existing macOS implementation, with Wayland (`wlr-data-control-unstable-v1`) and X11 (`libX11`) backends selected at runtime, plus a new `subscribe`/`unsubscribe` primitive that unifies event-driven and polling change detection across all three platforms.

**Architecture:** `src/clipboard.zig` dispatches to `platform/macos.zig` or the new `platform/linux/mod.zig` via `switch (builtin.os.tag)`. `platform/linux/mod.zig` owns backend selection (Wayland first, X11 fallback), the shared subscription registry, and the background thread; `platform/linux/wayland.zig` and `platform/linux/x11.zig` are peer backends behind a shared internal interface. A new `decodeUriList` helper in the pure-Zig `paths.zig` handles RFC 2483 file-reference parsing. `lib.zig` (the Bun FFI C ABI) is deliberately untouched — FFI v2 is a follow-up spec.

**Tech Stack:** Zig 0.15.2, `libwayland-client`, `wayland-scanner`, `libX11`, Cocoa/AppKit (macOS), `wlr-data-control-unstable-v1` protocol, `NSPasteboardDidChangeNotification` (macOS), `std.Thread`, `std.Thread.Mutex`, `std.Thread.Condition`, `std.once.Once`, `std.atomic.Value(bool)`, `std.ArrayListUnmanaged`.

**Spec:** `docs/superpowers/specs/2026-04-08-clipboard-linux-port-design.md` — every architectural decision in this plan comes from that spec. When in doubt, the spec wins.

---

## Working Directory Note

All paths in this plan are relative to the repository root `/Users/georgemandis/Projects/recurse/2026/clipboard-manager/` unless otherwise noted. The Zig project lives at `native/clipboard/`. `zig build` must be run from `native/clipboard/` (it has its own `build.zig`). Git commits land in the outer repo (`clipboard-manager/`), not `native/clipboard/` — there is only one git repository.

## Required Skills

- **superpowers:test-driven-development** — every task with a testable unit (every `paths.zig` change, and the spec review loop output) must follow TDD.
- **superpowers:verification-before-completion** — never check off a task or commit a step without running the verification command and confirming the output.

## Platform Prerequisites for Linux Work

Before running any Linux task (Task 5 onward), the Linux dev machine (UTM VM running Ubuntu 24.04 LTS per the spec's Environment matrix) must have these packages installed. Run once:

```bash
sudo apt update
sudo apt install -y \
    build-essential \
    libx11-dev \
    libwayland-dev \
    libwayland-bin \
    wayland-protocols \
    wl-clipboard \
    xclip \
    sway \
    foot \
    git \
    curl
```

- `libwayland-dev` — provides `libwayland-client.so` and headers.
- `libwayland-bin` — provides `wayland-scanner`, required by the build.
- `wayland-protocols` — not strictly required (we vendor the XML), but handy for reference.
- `wl-clipboard` — provides `wl-copy` / `wl-paste`, used by the smoke tests.
- `xclip` — provides `xclip`, used by the X11 smoke tests.
- `sway` — the Wayland compositor used by Environment 1.
- `foot` — terminal emulator that works inside sway.

Zig 0.15.2 must be installed separately (download from ziglang.org/download, extract, add to PATH). Confirm with `zig version` before starting.

---

## Task Graph Overview

Tasks are ordered so each one is testable on its own and never breaks the build for the next task. The safe ordering is:

1. **Task 1:** `decodeUriList` in `paths.zig` (pure Zig, 16 new tests, runs anywhere).
2. **Task 2:** C-strict allowlist cleanup in `main.zig` + macOS allowlist stays put.
3. **Task 3:** Add `SubscribeCallback` / `SubscribeHandle` types + `subscribe` / `unsubscribe` forwarders in `clipboard.zig` behind a temporary stub in `macos.zig`.
4. **Task 4:** Implement `subscribe` / `unsubscribe` on macOS using `NSPasteboardDidChangeNotification`.
5. **Task 5:** Rewrite `cmdWatch` to use `subscribe`; drop `--interval`; verify macOS still works.
6. **Task 6:** Add `vendor/wayland-protocols/wlr-data-control-unstable-v1.xml` + `build.zig` target-aware linking (macOS still green).
7. **Task 7:** `platform/linux/mod.zig` skeleton with `NoDisplayServer` hardcoded (Linux compiles, all calls return `error.NoDisplayServer`).
8. **Task 8:** `platform/linux/wayland.zig` — connection, registry, format cache via `data_offer`, `readFormat`, `listFormats`, `clear`.
9. **Task 9:** Wayland `writeFormat` + `writeMultiple` (with `send` handler state machine).
10. **Task 10:** Wayland `subscribe` wire-up (dispatch thread + fanout hook).
11. **Task 11:** `platform/linux/x11.zig` — display open, atom cache, `readFormat`, `listFormats`, `clear`.
12. **Task 12:** X11 `writeFormat` + `writeMultiple` (selection-request service loop with 5s timeout).
13. **Task 13:** X11 `subscribe` (poll loop with hash comparison).
14. **Task 14:** `platform/linux/mod.zig` — wire backend selection, forward the six platform functions, wire `subscribe`/`unsubscribe` fanout registry, `getChangeCount`, `decodePathsForFormat` with allowlist.
15. **Task 15:** End-to-end Linux smoke tests across the four environments + macOS regression.
16. **Task 16:** Pre-merge verification checklist and final commit.

Tasks 1–5 can (and should) run on the macOS host. Tasks 6–15 run on the Linux VM. Task 16 verifies both.

---

## Task 1: `decodeUriList` helper in `paths.zig`

**Goal:** Add a pure-Zig function that parses an RFC 2483 `text/uri-list` blob into an owned slice of POSIX paths, reusing the existing `decodeFileUrl` and `percentDecode` helpers. Cover it with 16 unit tests that run on any host via `zig build test`.

**Files:**
- Modify: `native/clipboard/src/paths.zig` (add `decodeUriList` and its tests at the bottom of the test block)

**Context:** `paths.zig` is intentionally pure Zig with zero OS dependencies — it runs in the `test` step on every `zig build test` invocation. This task is safe to run on the macOS host and lays the parser groundwork for the Linux `decodePathsForFormat` path (Task 14).

### Step 1.1 — Write the first failing test

- [ ] Append the following to the test block in `native/clipboard/src/paths.zig` (after the existing `decodeFileUrl rejects file:// with empty path` test):

```zig
test "decodeUriList single file LF" {
    const input = "file:///tmp/foo\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/foo", result[0]);
}
```

### Step 1.2 — Verify the test fails

- [ ] Run from `native/clipboard/`:

```bash
zig build test
```

Expected: compile error referencing `decodeUriList` (not defined). That is the "red" step.

### Step 1.3 — Implement `decodeUriList` (minimal pass)

- [ ] Insert the following just above the `// Tests` comment in `native/clipboard/src/paths.zig`:

```zig
/// Parses a text/uri-list blob (RFC 2483) into POSIX paths.
///
/// Steps:
///   1. Split the input on CRLF or LF (tolerant of both).
///   2. Skip blank lines and comment lines (lines starting with '#').
///   3. For each remaining line, delegate to decodeFileUrl.
///   4. If decodeFileUrl returns NotFileScheme, propagate the error —
///      non-file URIs are not supported by this library.
///
/// Caller owns the outer slice AND each inner path string.
pub fn decodeUriList(
    allocator: Allocator,
    bytes: []const u8,
) DecodePathError![]const []const u8 {
    var out = try std.array_list.Managed([]const u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit();
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= bytes.len) : (i += 1) {
        const at_eol = i == bytes.len or bytes[i] == '\n';
        if (!at_eol) continue;

        // Extract the line, stripping a trailing \r if present (CRLF tolerance).
        var line_end = i;
        if (line_end > start and bytes[line_end - 1] == '\r') line_end -= 1;
        const line = bytes[start..line_end];
        start = i + 1;

        // Skip blanks and comments.
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const decoded = try decodeFileUrl(allocator, line);
        errdefer allocator.free(decoded);
        try out.append(decoded);
    }

    return try out.toOwnedSlice();
}
```

### Step 1.4 — Verify the first test passes

- [ ] Run:

```bash
zig build test
```

Expected: all tests pass, including the new one. If `decodeFileUrl` errors bubble up correctly, the minimal implementation is right.

### Step 1.5 — Add the remaining 15 tests

- [ ] Append the following tests after the single-file LF test in `native/clipboard/src/paths.zig` (order matches the spec's Testing section):

```zig
test "decodeUriList single file CRLF" {
    const input = "file:///tmp/foo\r\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/foo", result[0]);
}

test "decodeUriList single file no trailing newline" {
    const input = "file:///tmp/foo";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/foo", result[0]);
}

test "decodeUriList multiple files LF" {
    const input = "file:///tmp/a\nfile:///tmp/b\nfile:///tmp/c\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
    try std.testing.expectEqualStrings("/tmp/c", result[2]);
}

test "decodeUriList multiple files CRLF" {
    const input = "file:///tmp/a\r\nfile:///tmp/b\r\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
}

test "decodeUriList mixed LF and CRLF" {
    const input = "file:///tmp/a\nfile:///tmp/b\r\nfile:///tmp/c\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
    try std.testing.expectEqualStrings("/tmp/c", result[2]);
}

test "decodeUriList skips comment lines" {
    const input = "# this is a comment\nfile:///tmp/a\n# another comment\nfile:///tmp/b\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
}

test "decodeUriList skips blank lines" {
    const input = "\nfile:///tmp/a\n\n\nfile:///tmp/b\n\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
}

test "decodeUriList percent-encoded spaces" {
    const input = "file:///tmp/My%20Docs/foo.txt\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/My Docs/foo.txt", result[0]);
}

test "decodeUriList UTF-8 percent-encoded" {
    // %E2%98%83 is ☃
    const input = "file:///tmp/%E2%98%83.txt\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/\xE2\x98\x83.txt", result[0]);
}

test "decodeUriList empty input" {
    const result = try decodeUriList(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decodeUriList only comments and blanks" {
    const input = "# hello\n\n# world\n\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decodeUriList rejects http scheme" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeUriList(std.testing.allocator, "http://example.com/\n"),
    );
}

test "decodeUriList rejects mixed file and non-file" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeUriList(std.testing.allocator, "file:///tmp/a\nhttps://b/\n"),
    );
}

test "decodeUriList rejects missing scheme" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeUriList(std.testing.allocator, "/plain/path\n"),
    );
}

test "decodeUriList rejects invalid percent encoding" {
    try std.testing.expectError(
        DecodePathError.InvalidPercentEncoding,
        decodeUriList(std.testing.allocator, "file:///tmp/bad%ZZ\n"),
    );
}
```

### Step 1.6 — Verify all 16 new tests pass

- [ ] Run:

```bash
zig build test
```

Expected: all `paths.zig` tests pass — the pre-existing 16 plus these 16, for 32+ total. If the test runner prints something like `32/32 passed` (actual count depends on the existing tests), you're good.

### Step 1.7 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/paths.zig
git commit -m "feat(paths): add decodeUriList for text/uri-list parsing"
```

---

## Task 2: C-strict allowlist cleanup in `main.zig`

**Goal:** Delete the duplicated `isAllowlistedFileRef` helper in `main.zig`, delete the defense-in-depth `error.UnsupportedFormat` catch arm added in commit `4a134d5`, and replace the macOS-specific allowlist pre-check with a generalized error message that rides on the platform layer's `error.UnsupportedFormat`. Each `platform/*` file (macOS today, Linux in Task 14) owns its own allowlist exclusively.

**Files:**
- Modify: `native/clipboard/src/main.zig` — delete `isAllowlistedFileRef`, delete the pre-check, delete the defense-in-depth catch arm, generalize the `UnsupportedFormat` message.

### Step 2.1 — Delete the pre-check in `cmdRead`

- [ ] In `native/clipboard/src/main.zig`, delete this block (currently lines 264–274):

```zig
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
```

The validation now happens inside `clipboard.decodePathsForFormat`, which returns `error.UnsupportedFormat` if the format is not in the active platform's allowlist.

### Step 2.2 — Delete the defense-in-depth `UnsupportedFormat` catch arm

- [ ] In the catch-switch inside `cmdRead`'s `--as-path` branch, replace:

```zig
            // Defense in depth: if isAllowlistedFileRef ever drifts from
            // file_ref_allowlist in platform/macos.zig, this arm ensures the
            // user still sees the spec-mandated allowlist message instead of
            // a raw "UnsupportedFormat" error name.
            error.UnsupportedFormat => try ew.interface.print(
                "Error: --as-path only supports file-reference formats: public.file-url, NSFilenamesPboardType, public.url\n",
                .{},
            ),
```

with the generalized version:

```zig
            error.UnsupportedFormat => try ew.interface.print(
                "Error: --as-path does not support this format on this platform\n",
                .{},
            ),
```

Rationale: the allowlist is now single-sourced inside each `platform/*` file (macOS: `file_ref_allowlist`; Linux: one entry in `mod.zig`). A generic message keeps `main.zig` platform-agnostic.

### Step 2.3 — Delete `isAllowlistedFileRef`

- [ ] Delete the entire `isAllowlistedFileRef` function from `native/clipboard/src/main.zig`, including its doc comment (the block starting with `/// Duplicated from platform/macos.zig on purpose:`).

### Step 2.4 — Verify the build still compiles

- [ ] Run from `native/clipboard/`:

```bash
zig build
```

Expected: the build succeeds with no warnings. If Zig complains about an unused import or dangling reference, double-check you removed the entire helper and its call site.

### Step 2.5 — Run the unit tests

- [ ] Run:

```bash
zig build test
```

Expected: all `paths.zig` tests still pass (this task doesn't touch tests, but we're verifying we didn't break anything adjacent).

### Step 2.6 — Manual smoke test on macOS

- [ ] Copy a file from Finder (any file).
- [ ] Run:

```bash
./native/clipboard/zig-out/bin/clipboard read public.file-url --as-path
```

Expected: the file's POSIX path prints to stdout, exit 0.

- [ ] Run:

```bash
./native/clipboard/zig-out/bin/clipboard read public.utf8-plain-text --as-path
```

Expected: `Error: --as-path does not support this format on this platform`, exit 1. This confirms the new generic message is wired correctly.

### Step 2.7 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/main.zig
git commit -m "refactor(cli): single-source --as-path allowlist per platform"
```

---

## Task 3: Define `subscribe` / `unsubscribe` API with a macOS stub

**Goal:** Add the new `SubscribeCallback` type, `SubscribeHandle` struct, and `subscribe`/`unsubscribe` forwarders to `src/clipboard.zig`. Back them with a temporary stub in `platform/macos.zig` that returns `SubscribeFailed` so the build compiles and both existing macOS callers + the forthcoming Linux port share the same API shape. The real macOS implementation lands in Task 4.

**Files:**
- Modify: `native/clipboard/src/clipboard.zig`
- Modify: `native/clipboard/src/platform/macos.zig` — add `ClipboardError.SubscribeFailed`, `SubscribeCallback`, `SubscribeHandle`, and stubbed `subscribe`/`unsubscribe`.

### Step 3.1 — Extend `ClipboardError` in `platform/macos.zig`

- [ ] In `native/clipboard/src/platform/macos.zig`, replace the existing `ClipboardError` (currently):

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

with:

```zig
pub const ClipboardError = error{
    PasteboardUnavailable,
    NoItems,
    WriteFailed,
    UnsupportedFormat,
    FormatNotFound,
    MalformedPlist,
    // New for cross-platform (Linux) port; defined on every platform so
    // `clipboard.zig` can re-export a unified error set.
    NoDisplayServer,
    SubscribeFailed,
    MalformedUriList,
};
```

`NoDisplayServer` and `MalformedUriList` are never actually returned on macOS — they exist so that `clipboard.zig`'s re-export is the same type on every platform. This is the simplest way to share an error set across platforms in Zig without a wrapper enum.

### Step 3.2 — Add the subscribe types at the top of `platform/macos.zig`

- [ ] Immediately after the `const Allocator = std.mem.Allocator;` line in `native/clipboard/src/platform/macos.zig`, insert:

```zig
/// Callback invoked when the clipboard changes. Runs on the library's
/// background subscription thread, not the caller's thread.
pub const SubscribeCallback = *const fn (userdata: ?*anyopaque) void;

/// Opaque handle returned by subscribe. `id == 0` is the invalid-handle
/// sentinel; unsubscribe on a zero-initialized handle is a no-op.
pub const SubscribeHandle = struct {
    id: u64,
};
```

### Step 3.3 — Add stub `subscribe` and `unsubscribe` to `platform/macos.zig`

- [ ] At the bottom of `native/clipboard/src/platform/macos.zig`, append:

```zig
/// STUB: replaced by a real NSPasteboardDidChangeNotification implementation
/// in Task 4. Returns `error.SubscribeFailed` so callers fail fast if they
/// try to use it before Task 4 lands.
pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    _ = allocator;
    _ = callback;
    _ = userdata;
    return ClipboardError.SubscribeFailed;
}

/// STUB: no-op until Task 4 wires up real state.
pub fn unsubscribe(handle: SubscribeHandle) void {
    _ = handle;
}
```

### Step 3.4 — Add forwarders + type re-exports to `clipboard.zig`

- [ ] In `native/clipboard/src/clipboard.zig`, after the existing `pub const ClipboardError = platform.ClipboardError;` line, add:

```zig
pub const SubscribeCallback = platform.SubscribeCallback;
pub const SubscribeHandle = platform.SubscribeHandle;
```

- [ ] At the bottom of `native/clipboard/src/clipboard.zig` (after `decodePathsForFormat`), append:

```zig
/// Register a callback that fires on every clipboard change. Spawns a
/// background thread on first subscription; reuses it for subsequent
/// subscribers. The callback runs on the background thread, not the
/// caller's thread — callers must ensure their callback is thread-safe
/// with respect to any state it touches.
///
/// Platform notes:
///   - macOS: event-driven via NSPasteboardDidChangeNotification.
///   - Linux/Wayland: event-driven via zwlr_data_control selection events.
///   - Linux/X11: polling-based (500ms default, tunable via LINUX_X11_POLL_MS).
pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    return platform.subscribe(allocator, callback, userdata);
}

/// Remove a subscription. Idempotent: passing an unknown or already-removed
/// handle (including a zero-initialized one) is a safe no-op. When the last
/// subscription is removed, the background thread is signaled to shut down
/// asynchronously — this call does not block.
pub fn unsubscribe(handle: SubscribeHandle) void {
    platform.unsubscribe(handle);
}
```

### Step 3.5 — Verify the build compiles

- [ ] Run from `native/clipboard/`:

```bash
zig build
```

Expected: compiles cleanly. Zig is strict about unused imports and unused variables; if this fails it's likely a typo.

### Step 3.6 — Verify nothing at the call site accidentally uses `subscribe` yet

- [ ] Run:

```bash
./native/clipboard/zig-out/bin/clipboard watch
```

Expected: still works as before (the existing `cmdWatch` uses the polling loop with `getChangeCount`; Task 5 rewrites it). `subscribe` is defined but unused. If `clipboard watch` fails, something else broke.

### Step 3.7 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/clipboard.zig native/clipboard/src/platform/macos.zig
git commit -m "feat(clipboard): add subscribe/unsubscribe API with macOS stub"
```

---

## Task 4: Implement macOS `subscribe`

**Goal:** Replace the `SubscribeFailed` stub on macOS with a working subscription registry and background thread.

**First-choice implementation (per spec):** register an observer for `NSPasteboardDidChangeNotification` on `NSNotificationCenter.defaultCenter` and run a `CFRunLoop` in the background thread. When the notification fires, call the fanout helper.

**Known risk:** `NSPasteboard` is documented as posting `NSPasteboardDidChangeNotification` but in practice Cocoa has historically been unreliable about cross-process delivery. If Step 4.7's smoke test shows the notification-based approach misses changes, fall back to a 250ms polling loop on `getChangeCount`. The fallback is a drop-in change to `pollLoop` only — the registry, `fanout`, `subscribe`, and `unsubscribe` are identical either way. Document whichever approach actually works in the commit message.

**Files:**
- Modify: `native/clipboard/src/platform/macos.zig` — replace the stub `subscribe`/`unsubscribe` with a real mutex-protected registry + background thread.

**Subagent reminder:** use `superpowers:test-driven-development` for this task — it has real concurrency and is easy to get wrong without exercising it.

### Step 4.1 — Add module-level subscription state to `platform/macos.zig`

- [ ] Near the top of `native/clipboard/src/platform/macos.zig` (after the `SubscribeHandle` type definition), add:

```zig
// ---------------------------------------------------------------------------
// Subscription registry (shared by subscribe/unsubscribe and the background
// polling thread). `next_subscriber_id` starts at 1 so that the zero handle
// is an invalid sentinel (see SubscribeHandle doc comment).
// ---------------------------------------------------------------------------
const Subscriber = struct {
    id: u64,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
};

var subscribe_mutex: std.Thread.Mutex = .{};
var subscribers: std.ArrayListUnmanaged(Subscriber) = .{};
var next_subscriber_id: u64 = 1;
var thread_handle: ?std.Thread = null;
var should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
```

### Step 4.2 — Replace the stub `subscribe`

- [ ] Replace the stub `subscribe` function in `native/clipboard/src/platform/macos.zig` with:

```zig
pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    subscribe_mutex.lock();
    defer subscribe_mutex.unlock();

    const id = next_subscriber_id;
    next_subscriber_id += 1;

    try subscribers.append(allocator, .{
        .id = id,
        .callback = callback,
        .userdata = userdata,
    });

    // Spawn the background thread on first subscriber.
    if (thread_handle == null) {
        should_exit.store(false, .release);
        thread_handle = std.Thread.spawn(.{}, pollLoop, .{allocator}) catch {
            // Roll back the append so the registry state stays consistent.
            _ = subscribers.pop();
            return ClipboardError.SubscribeFailed;
        };
    }

    return SubscribeHandle{ .id = id };
}
```

### Step 4.3 — Replace the stub `unsubscribe`

- [ ] Replace the stub `unsubscribe` function with:

```zig
pub fn unsubscribe(handle: SubscribeHandle) void {
    subscribe_mutex.lock();

    // Find and remove the matching entry. A zero handle, unknown handle, or
    // already-removed handle is a no-op.
    var i: usize = 0;
    while (i < subscribers.items.len) : (i += 1) {
        if (subscribers.items[i].id == handle.id) {
            _ = subscribers.swapRemove(i);
            break;
        }
    }

    const should_stop = subscribers.items.len == 0;
    subscribe_mutex.unlock();

    // If no more subscribers, signal the background thread to exit. We do
    // NOT join here — per the spec, shutdown is asynchronous so callers
    // don't accidentally block on a polling tick.
    if (should_stop) {
        should_exit.store(true, .release);
        // The thread reads should_exit on its next tick and returns. We
        // leave the thread_handle around until the next subscribe() call
        // resets it. This is fine because the thread is detached from
        // the registry's lifetime once it sees should_exit=true.
    }
}
```

### Step 4.4 — Add the background thread body + fanout helper

- [ ] Append to `native/clipboard/src/platform/macos.zig`:

```zig
/// Background thread body. Attempts notification-driven delivery first;
/// falls back to polling if the notification never fires.
///
/// The polling fallback is left in place unconditionally at a 250ms tick.
/// It is cheap (one Obj-C msgSend per tick) and acts as a safety net if
/// NSPasteboardDidChangeNotification proves unreliable on the host macOS
/// version. If Step 4.7's smoke test confirms notifications fire reliably,
/// a follow-up can remove the poll. Until then, having both is the
/// defensive choice.
fn pollLoop(allocator: Allocator) void {
    _ = allocator;
    const tick_ns: u64 = 250 * std.time.ns_per_ms;

    // Initial snapshot so we don't fire a bogus callback on first tick.
    var last_count: i64 = getChangeCount();

    while (!should_exit.load(.acquire)) {
        std.Thread.sleep(tick_ns);
        if (should_exit.load(.acquire)) break;

        const current = getChangeCount();
        if (current != last_count and current != -1) {
            last_count = current;
            fanout();
        }
    }
}

/// Snapshot the current subscriber list under the mutex, then invoke every
/// callback outside the mutex. Releasing the lock before calling user code
/// avoids deadlocks if a callback calls back into the library.
fn fanout() void {
    var snapshot: [64]Subscriber = undefined;
    var count: usize = 0;

    subscribe_mutex.lock();
    for (subscribers.items) |s| {
        if (count >= snapshot.len) break; // hard cap: 64 concurrent subscribers
        snapshot[count] = s;
        count += 1;
    }
    subscribe_mutex.unlock();

    for (snapshot[0..count]) |s| {
        s.callback(s.userdata);
    }
}
```

**Note on `NSPasteboardDidChangeNotification`:** the spec prefers a notification-driven approach over polling. If the current codebase's `objc.zig` bridge already exposes enough of `NSNotificationCenter` + `CFRunLoop` to register an observer and run a loop, wire that up as the primary signal and keep the 250ms poll as a safety net inside the same thread (the poll only fires if the notification mechanism is silent — detect this by tracking "did fanout happen since last tick"). If the bridge does not expose those APIs, extending `objc.zig` to add them is out of scope for this task — ship the polling version and open a follow-up. The spec's architectural goal (a single `subscribe` primitive that works on every platform) is satisfied either way; the notification-vs-polling choice is an implementation detail under the API.

### Step 4.5 — Add a unit test using a local counter

- [ ] At the bottom of `native/clipboard/src/platform/macos.zig`, append:

```zig
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
// Note: these tests only exercise the registry — they do not touch the
// pasteboard. They are safe to run on any macOS host. They are NOT in the
// `test` step in build.zig today because that step is pure-Zig only; they
// can be run ad-hoc with `zig test src/platform/macos.zig` if desired.

test "subscribe allocates monotonic ids and unsubscribe is idempotent" {
    const allocator = std.testing.allocator;

    const noop = struct {
        fn cb(ud: ?*anyopaque) void {
            _ = ud;
        }
    }.cb;

    // Reset module state for the test.
    subscribe_mutex.lock();
    subscribers = .{};
    next_subscriber_id = 1;
    subscribe_mutex.unlock();

    // We can't actually call subscribe() here because it spawns a real thread
    // that touches the pasteboard. Instead, exercise the registry inline.
    subscribe_mutex.lock();
    try subscribers.append(allocator, .{ .id = next_subscriber_id, .callback = noop, .userdata = null });
    next_subscriber_id += 1;
    try subscribers.append(allocator, .{ .id = next_subscriber_id, .callback = noop, .userdata = null });
    next_subscriber_id += 1;
    subscribe_mutex.unlock();

    try std.testing.expectEqual(@as(usize, 2), subscribers.items.len);
    try std.testing.expectEqual(@as(u64, 1), subscribers.items[0].id);
    try std.testing.expectEqual(@as(u64, 2), subscribers.items[1].id);

    // Idempotent unsubscribe of a never-registered handle is a no-op.
    unsubscribe(.{ .id = 0 });
    unsubscribe(.{ .id = 9999 });
    try std.testing.expectEqual(@as(usize, 2), subscribers.items.len);

    // Real removal.
    unsubscribe(.{ .id = 1 });
    try std.testing.expectEqual(@as(usize, 1), subscribers.items.len);

    // Clean up for the next test run.
    subscribers.deinit(allocator);
}
```

Note: this test is inside `platform/macos.zig` and will **not** be exercised by `zig build test` (that step is pure-Zig only). It exists as documentation and as a manual `zig test` target. Do not add it to the `test` step in `build.zig` — doing so would try to link Obj-C/AppKit into the pure-Zig test binary.

### Step 4.6 — Verify the build compiles

- [ ] Run from `native/clipboard/`:

```bash
zig build
```

Expected: compiles. If the compiler rejects `std.ArrayListUnmanaged.append` usage, double-check the signature: the `append(allocator, item)` form is required on unmanaged lists.

### Step 4.7 — Manual smoke test: `subscribe` works end-to-end

- [ ] Write a quick ad-hoc test script at `/tmp/sub-test.sh`:

```bash
#!/usr/bin/env bash
set -e
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager/native/clipboard
zig build -Doptimize=Debug
./zig-out/bin/clipboard watch &
WATCH_PID=$!
sleep 1
echo "hello one" | ./zig-out/bin/clipboard write public.utf8-plain-text
sleep 1
echo "hello two" | ./zig-out/bin/clipboard write public.utf8-plain-text
sleep 1
kill $WATCH_PID 2>/dev/null || true
```

- [ ] Run it. Expected: `clipboard watch` prints two change events within ~1 second of each write, confirming the subscription registry fires callbacks in response to real clipboard changes.

If you see zero events: double-check `pollLoop` is actually spawned (add a debug print temporarily) and that `getChangeCount` is returning different values. If you see too many events (spurious): check that `last_count` is being updated correctly.

- [ ] Delete `/tmp/sub-test.sh` after the smoke test passes.

### Step 4.8 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/macos.zig
git commit -m "feat(macos): implement subscribe with background polling thread"
```

---

## Task 5: Rewrite `cmdWatch` to use `subscribe`

**Goal:** Replace the manual polling loop in `cmdWatch` with a condvar-driven loop backed by `clipboard.subscribe`. Drop the `--interval` flag entirely — change-detection cadence is the library's concern. Update the usage text.

**Files:**
- Modify: `native/clipboard/src/main.zig` — rewrite `cmdWatch` function and update `printUsage`.

### Step 5.1 — Remove `--interval` from the usage text

- [ ] In `native/clipboard/src/main.zig`, replace:

```zig
        \\  watch [--interval <ms>]         Watch for clipboard changes (default 500ms)
```

with:

```zig
        \\  watch                           Watch for clipboard changes (event-driven)
```

### Step 5.2 — Replace `cmdWatch`

- [ ] In `native/clipboard/src/main.zig`, replace the entire `cmdWatch` function with:

```zig
fn cmdWatch(allocator: Allocator, args: []const []const u8, json_output: bool) !void {
    _ = args; // --interval is no longer accepted; unknown args are ignored.

    const stderr_file = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = stderr_file.writer(&stderr_buf);
    try stderr_w.interface.print("Watching clipboard (Ctrl+C to stop)...\n\n", .{});
    try stderr_w.interface.flush();

    var context = WatchContext{
        .allocator = allocator,
        .json_output = json_output,
        .mutex = .{},
        .condition = .{},
        .pending = false,
    };

    const handle = try clipboard.subscribe(allocator, WatchContext.onChange, &context);
    defer clipboard.unsubscribe(handle);

    // Main loop: wait for the callback to signal, introspect, loop until SIGINT.
    // SIGINT handling relies on process termination — see spec's cmdWatch section.
    while (true) {
        context.mutex.lock();
        while (!context.pending) {
            context.condition.wait(&context.mutex);
        }
        context.pending = false;
        context.mutex.unlock();

        try introspect(allocator, json_output);

        const stdout_file = std.fs.File.stdout();
        var stdout_buf: [4096]u8 = undefined;
        var stdout_w = stdout_file.writer(&stdout_buf);
        try stdout_w.interface.print("---\n\n", .{});
        try stdout_w.interface.flush();
    }
}

const WatchContext = struct {
    allocator: Allocator,
    json_output: bool,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    pending: bool,

    fn onChange(userdata: ?*anyopaque) void {
        const ctx: *WatchContext = @ptrCast(@alignCast(userdata.?));
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        ctx.pending = true;
        ctx.condition.signal();
    }
};
```

### Step 5.3 — Verify the build compiles

- [ ] Run from `native/clipboard/`:

```bash
zig build
```

Expected: compiles. If `std.Thread.Mutex` or `std.Thread.Condition` isn't found, confirm the file already uses `const std = @import("std");` (it does — no new imports needed).

### Step 5.4 — Manual smoke test

- [ ] Run this sequence in one terminal:

```bash
./native/clipboard/zig-out/bin/clipboard watch
```

- [ ] In another terminal, change the clipboard contents a few times:

```bash
echo "watch test 1" | ./native/clipboard/zig-out/bin/clipboard write public.utf8-plain-text
sleep 1
echo "watch test 2" | ./native/clipboard/zig-out/bin/clipboard write public.utf8-plain-text
```

Expected: the first terminal prints two `Clipboard contents (...)` blocks separated by `---`. Reaction time should be < 500ms per change (confirms the subscribe-based loop is at least as responsive as the old polling loop).

- [ ] Hit Ctrl-C in the first terminal. Expected: the process exits cleanly (exit code doesn't matter — SIGINT termination is the intended behavior per the spec).

### Step 5.5 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/main.zig
git commit -m "refactor(cli): rewrite cmdWatch to use clipboard.subscribe"
```

---

## Task 6: Vendor `wlr-data-control-unstable-v1.xml` and make `build.zig` target-aware

**Goal:** Commit the `wlr-data-control-unstable-v1.xml` protocol definition under `native/clipboard/vendor/wayland-protocols/` and teach `build.zig` to link `X11` + `wayland-client` and run `wayland-scanner` on Linux targets while leaving macOS builds untouched.

**Files:**
- Create: `native/clipboard/vendor/wayland-protocols/wlr-data-control-unstable-v1.xml`
- Modify: `native/clipboard/build.zig`

**Environment:** this task CAN be run on macOS host (the macOS branch of the build logic runs; the Linux branch is only exercised when building from Linux). But verifying the Linux branch compiles requires the Linux VM — do Step 6.4 on the VM.

### Step 6.1 — Vendor the protocol XML

- [ ] On Linux (or by downloading on macOS), fetch the XML:

```bash
mkdir -p native/clipboard/vendor/wayland-protocols
curl -fsSL \
    https://gitlab.freedesktop.org/wlroots/wlr-protocols/-/raw/master/unstable/wlr-data-control-unstable-v1.xml \
    -o native/clipboard/vendor/wayland-protocols/wlr-data-control-unstable-v1.xml
```

- [ ] Verify the file exists and is ~8KB:

```bash
wc -l native/clipboard/vendor/wayland-protocols/wlr-data-control-unstable-v1.xml
```

Expected: several hundred lines of XML with a `<protocol name="wlr_data_control_unstable_v1">` root element.

**License note:** the wlr-protocols repo uses MIT; vendoring is fine. The repo is the canonical upstream for this unstable protocol (wayland-protocols proper does not include it yet). Record the upstream commit hash if you want full reproducibility — optional.

### Step 6.2 — Replace `build.zig` with target-aware logic

- [ ] Replace the contents of `native/clipboard/build.zig` with:

```zig
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

    switch (target_os) {
        .macos => {
            clipboard_mod.linkSystemLibrary("objc", .{});
            clipboard_mod.linkFramework("AppKit", .{});
        },
        .linux => {
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
        else => {
            // Other platforms are not supported by the library yet; the
            // clipboard.zig @compileError still enforces that at the Zig
            // level. build.zig stays silent so `zig build --help` still works.
        },
    }

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

    const run_paths_tests = b.addRunArtifact(paths_tests);

    const test_step = b.step("test", "Run pure-Zig unit tests");
    test_step.dependOn(&run_paths_tests.step);
}
```

### Step 6.3 — Verify macOS still builds

- [ ] Run on macOS from `native/clipboard/`:

```bash
zig build
zig build test
```

Expected: both succeed with no warnings. If the macOS build now fails, the `switch` is wrong.

### Step 6.4 — Verify Linux still builds (minus the yet-to-be-written platform files)

This step runs on the Linux VM (Environment 1: Ubuntu 24.04 on sway). At this point, `src/clipboard.zig` will refuse to compile because its `@compileError` still fires for non-macOS targets — that's expected. The test step, which only uses `paths.zig`, should still work.

- [ ] On the Linux VM, clone the repo (or rsync from the Mac), then from `native/clipboard/`:

```bash
zig build test
```

Expected: passes (`paths.zig` is OS-free; Task 1's 16 new `decodeUriList` tests all pass on Linux identically).

- [ ] Try the full build (it will fail at the `@compileError`):

```bash
zig build 2>&1 | tail -20
```

Expected: compile error originating from `src/clipboard.zig`'s `@compileError("Unsupported platform. Currently only macOS is implemented.")`. This is the baseline we're about to fix in Task 7. If the error is about anything else (missing `libX11`, missing `wayland-scanner`, missing `libwayland-client`), fix the Linux dev environment before proceeding — re-run the `apt install` from the Prerequisites section.

### Step 6.5 — Commit

- [ ] Run (from macOS or Linux — either works):

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/vendor/wayland-protocols/wlr-data-control-unstable-v1.xml native/clipboard/build.zig
git commit -m "build: target-aware linking + vendored wlr-data-control protocol"
```

---

## Task 7: `platform/linux/mod.zig` skeleton — Linux compiles

**Goal:** Add the smallest `platform/linux/mod.zig` that satisfies the interface `clipboard.zig` expects. Wire `clipboard.zig`'s dispatch to include the `.linux` branch. Every clipboard operation returns `error.NoDisplayServer` for now. After this task, Linux builds compile cleanly; no functionality yet. The real backends come in Tasks 8–13.

**Files:**
- Create: `native/clipboard/src/platform/linux/mod.zig`
- Modify: `native/clipboard/src/clipboard.zig` — replace the `@compileError` with a `.linux` case.

**Environment:** this task must be verified on the Linux VM.

### Step 7.1 — Create the skeleton `platform/linux/mod.zig`

- [ ] Create `native/clipboard/src/platform/linux/mod.zig` with:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ClipboardError = error{
    PasteboardUnavailable,
    NoItems,
    WriteFailed,
    UnsupportedFormat,
    FormatNotFound,
    MalformedPlist,
    NoDisplayServer,
    SubscribeFailed,
    MalformedUriList,
};

/// Format-data pair (same shape as macOS's FormatDataPair).
pub const FormatDataPair = struct {
    format: []const u8,
    data: []const u8,
};

pub const SubscribeCallback = *const fn (userdata: ?*anyopaque) void;

pub const SubscribeHandle = struct {
    id: u64,
};

// ---------------------------------------------------------------------------
// SKELETON: every entry point returns NoDisplayServer. Real backends land in
// Tasks 8-13; this task only wires up the module so the build compiles.
// ---------------------------------------------------------------------------

pub fn listFormats(allocator: Allocator) ![][]const u8 {
    _ = allocator;
    return ClipboardError.NoDisplayServer;
}

pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    _ = allocator;
    _ = format;
    return ClipboardError.NoDisplayServer;
}

pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    _ = allocator;
    _ = format;
    _ = data;
    return ClipboardError.NoDisplayServer;
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    _ = allocator;
    _ = pairs;
    return ClipboardError.NoDisplayServer;
}

pub fn clear() !void {
    return ClipboardError.NoDisplayServer;
}

pub fn getChangeCount() i64 {
    return 0;
}

pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) ![]const []const u8 {
    _ = allocator;
    _ = format;
    return ClipboardError.NoDisplayServer;
}

pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    _ = allocator;
    _ = callback;
    _ = userdata;
    return ClipboardError.NoDisplayServer;
}

pub fn unsubscribe(handle: SubscribeHandle) void {
    _ = handle;
}
```

### Step 7.2 — Wire Linux into `clipboard.zig`

- [ ] In `native/clipboard/src/clipboard.zig`, replace:

```zig
const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos.zig"),
    else => @compileError("Unsupported platform. Currently only macOS is implemented."),
};
```

with:

```zig
const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos.zig"),
    .linux => @import("platform/linux/mod.zig"),
    else => @compileError("Unsupported platform. Supported: macOS, Linux."),
};
```

### Step 7.3 — Verify macOS still builds

- [ ] Run on macOS from `native/clipboard/`:

```bash
zig build
```

Expected: clean build.

### Step 7.4 — Verify Linux compiles end-to-end

- [ ] On the Linux VM, from `native/clipboard/`:

```bash
zig build
```

Expected: the build succeeds and produces `zig-out/bin/clipboard` and `zig-out/lib/libclipboard.so`. If it fails because `X11` or `wayland-client` can't be found at link time, re-check the `apt install` step from the Prerequisites section.

- [ ] Verify the binary runs and reports the expected "no display server" error:

```bash
./zig-out/bin/clipboard list
```

Expected: an error mentioning `NoDisplayServer` (or whatever generic error formatting `main.zig` produces — if there's no catch arm yet, the process exits with an error name). This confirms the dispatch chain `main.zig → clipboard.zig → platform/linux/mod.zig` works end-to-end.

### Step 7.5 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/linux/mod.zig native/clipboard/src/clipboard.zig
git commit -m "feat(linux): add platform skeleton and dispatch wiring"
```

---

## Implementation Notes for Tasks 8–13

Tasks 8–13 implement the two Linux backends (Wayland and X11). They are the heaviest tasks in the plan because they involve real protocol handling. The plan intentionally does **not** inline every C-level call — the implementer should keep these references open while writing the code:

- **Wayland core:** https://wayland.freedesktop.org/docs/html/apb.html (protocol) and https://wayland.freedesktop.org/docs/html/apc.html (libwayland client API).
- **wlr-data-control protocol XML:** `vendor/wayland-protocols/wlr-data-control-unstable-v1.xml` (vendored in Task 6). Read it end-to-end before starting Task 8 — it defines every event and request.
- **Xlib reference:** `man XConvertSelection`, `man XSetSelectionOwner`, `man XChangeProperty`, `man XGetWindowProperty`, and the "Selections" chapter of the Xlib Programming Manual (https://tronche.com/gui/x/xlib/).
- **Working examples:** `wl-clipboard` (`wl-copy` / `wl-paste` — https://github.com/bugaevc/wl-clipboard) uses `wlr-data-control` the same way we will, and `xclip` (https://github.com/astrand/xclip) shows X11 selection handling. Both are MIT/GPL — read but don't copy.

**Common pattern for all six Linux tasks:** each backend file is a module with private state (the display/compositor handles, the format cache, the active selection source, etc.) and a handful of public functions (`tryConnect`, `readFormat`, `writeFormat`, etc.) that `mod.zig` calls. Neither backend file imports the other; neither knows the other exists. All cross-backend coordination happens in `mod.zig`.

**@cImport usage:** the Wayland backend `@cImport`s `<wayland-client.h>` and the generated `wlr-data-control-unstable-v1-client-protocol.h`. The X11 backend `@cImport`s `<X11/Xlib.h>` and `<X11/Xatom.h>`. These imports live at the top of each `.zig` file; `mod.zig` does **not** cImport anything.

---

## Task 8: Wayland backend — connection, registry, and read

**Goal:** Create `platform/linux/wayland.zig` with: connection bootstrapping (`tryConnect`), registry binding to `wl_seat` and `zwlr_data_control_manager_v1`, a `data_offer`-driven format cache, `readFormat`, `listFormats`, and `clear`. Write paths and subscribe come in Tasks 9 and 10.

**Files:**
- Create: `native/clipboard/src/platform/linux/wayland.zig`

**Environment:** Linux VM under sway (Environment 1). Must have a real Wayland session running.

### Step 8.1 — Create the file skeleton with `@cImport`s

- [ ] Create `native/clipboard/src/platform/linux/wayland.zig` starting with:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("wlr-data-control-unstable-v1-client-protocol.h");
});

// Re-use the unified error set declared in mod.zig.
const mod = @import("mod.zig");
const ClipboardError = mod.ClipboardError;
```

### Step 8.2 — Module-level connection state

- [ ] Append:

```zig
var display: ?*c.wl_display = null;
var registry: ?*c.wl_registry = null;
var seat: ?*c.wl_seat = null;
var data_control_manager: ?*c.zwlr_data_control_manager_v1 = null;
var data_device: ?*c.zwlr_data_control_device_v1 = null;

// Format cache: updated by the `selection` event on `data_device`. The
// library-level subscribe thread calls wl_display_dispatch in a loop; every
// dispatch pass can rewrite this cache before fanout.
var cache_mutex: std.Thread.Mutex = .{};
var cached_formats: std.ArrayListUnmanaged([]u8) = .{};
var current_offer: ?*c.zwlr_data_control_offer_v1 = null;
var cache_allocator: ?Allocator = null;
```

### Step 8.3 — `tryConnect` — one-shot bootstrap

`mod.zig` calls `tryConnect` exactly once. It returns `true` if Wayland + `wlr-data-control` are available; otherwise `false`. Implementation plan:

- [ ] Append:

```zig
/// Attempts to connect to the Wayland display and bind wlr-data-control.
/// Returns true on success, false if Wayland is not available on this host
/// or if the compositor does not advertise wlr-data-control. On success, the
/// module is left in a state where readFormat / listFormats / etc. work.
pub fn tryConnect(allocator: Allocator) bool {
    // 1. Refuse if WAYLAND_DISPLAY is not set — libwayland will fail, but
    //    checking explicitly avoids a noisy stderr message from libwayland.
    if (std.posix.getenv("WAYLAND_DISPLAY") == null) return false;

    // 2. Open the connection.
    const d = c.wl_display_connect(null) orelse return false;
    display = d;

    // 3. Get the registry and install a listener that binds wl_seat and
    //    zwlr_data_control_manager_v1 when their globals are announced.
    const reg = c.wl_display_get_registry(d) orelse {
        c.wl_display_disconnect(d);
        display = null;
        return false;
    };
    registry = reg;

    _ = c.wl_registry_add_listener(reg, &registry_listener, null);

    // 4. Roundtrip once so the registry listener fires for every global the
    //    compositor is currently advertising. After this call, seat and
    //    data_control_manager are populated iff they were advertised.
    _ = c.wl_display_roundtrip(d);

    if (seat == null or data_control_manager == null) {
        // Either no seat (unlikely) or no wlr-data-control (GNOME case).
        // Clean up and return false; mod.zig will fall through to X11.
        disconnect();
        return false;
    }

    // 5. Get the data device for the seat.
    data_device = c.zwlr_data_control_manager_v1_get_data_device(data_control_manager, seat) orelse {
        disconnect();
        return false;
    };
    _ = c.zwlr_data_control_device_v1_add_listener(data_device, &device_listener, null);

    // 6. Roundtrip once more so any initial `data_offer` + `selection`
    //    events deliver before we return (so the cache reflects the current
    //    clipboard contents).
    cache_allocator = allocator;
    _ = c.wl_display_roundtrip(d);

    return true;
}

fn disconnect() void {
    if (display) |d| {
        c.wl_display_disconnect(d);
    }
    display = null;
    registry = null;
    seat = null;
    data_control_manager = null;
    data_device = null;
}
```

### Step 8.4 — Registry and device listeners

Wayland's C API uses vtables of function pointers. The registry listener dispatches `global` / `global_remove`; the device listener dispatches `data_offer` / `selection` / `finished`.

- [ ] Append:

```zig
const registry_listener = c.wl_registry_listener{
    .global = onGlobal,
    .global_remove = onGlobalRemove,
};

fn onGlobal(
    data: ?*anyopaque,
    reg: ?*c.wl_registry,
    name: u32,
    interface_c: [*c]const u8,
    version: u32,
) callconv(.C) void {
    _ = data;
    const iface = std.mem.span(interface_c);
    if (std.mem.eql(u8, iface, std.mem.span(c.wl_seat_interface.name))) {
        seat = @ptrCast(c.wl_registry_bind(reg, name, &c.wl_seat_interface, @min(version, 7)));
    } else if (std.mem.eql(u8, iface, std.mem.span(c.zwlr_data_control_manager_v1_interface.name))) {
        data_control_manager = @ptrCast(c.wl_registry_bind(reg, name, &c.zwlr_data_control_manager_v1_interface, @min(version, 2)));
    }
}

fn onGlobalRemove(data: ?*anyopaque, reg: ?*c.wl_registry, name: u32) callconv(.C) void {
    _ = data;
    _ = reg;
    _ = name;
    // We do not handle global removal — if the compositor tears down its
    // data-control manager mid-session, subsequent operations will return
    // error.PasteboardUnavailable via the fail paths in readFormat etc.
}

const device_listener = c.zwlr_data_control_device_v1_listener{
    .data_offer = onDataOffer,
    .selection = onSelection,
    .finished = onFinished,
    .primary_selection = onPrimarySelection,
};

/// Fired when the compositor has a new data_offer for us. We install our own
/// listener on the offer so its `offer` events populate the format cache,
/// and stash the current offer. The offer isn't "live" until `selection`
/// fires with it.
fn onDataOffer(
    data: ?*anyopaque,
    device: ?*c.zwlr_data_control_device_v1,
    offer: ?*c.zwlr_data_control_offer_v1,
) callconv(.C) void {
    _ = data;
    _ = device;
    if (offer == null) return;
    _ = c.zwlr_data_control_offer_v1_add_listener(offer, &offer_listener, null);
}

/// `selection` tells us which offer is currently the clipboard. A null offer
/// means the clipboard is empty.
fn onSelection(
    data: ?*anyopaque,
    device: ?*c.zwlr_data_control_device_v1,
    offer: ?*c.zwlr_data_control_offer_v1,
) callconv(.C) void {
    _ = data;
    _ = device;

    cache_mutex.lock();
    defer cache_mutex.unlock();

    // Destroy the previous offer (Wayland docs: we must destroy offers
    // once we're done with them).
    if (current_offer) |prev| {
        c.zwlr_data_control_offer_v1_destroy(prev);
    }
    current_offer = offer;

    // Note: cached_formats was already populated by the offer_listener's
    // onOffer callbacks between the data_offer and selection events. We
    // don't reset it here because by the time `selection` fires, the cache
    // already reflects the new offer.
}

fn onFinished(data: ?*anyopaque, device: ?*c.zwlr_data_control_device_v1) callconv(.C) void {
    _ = data;
    _ = device;
    // The compositor is shutting down the device. Leave state alone; the
    // next operation will fail and return error.PasteboardUnavailable.
}

fn onPrimarySelection(
    data: ?*anyopaque,
    device: ?*c.zwlr_data_control_device_v1,
    offer: ?*c.zwlr_data_control_offer_v1,
) callconv(.C) void {
    _ = data;
    _ = device;
    // We don't support PRIMARY. Destroy the offer immediately to free it.
    if (offer) |o| c.zwlr_data_control_offer_v1_destroy(o);
}

const offer_listener = c.zwlr_data_control_offer_v1_listener{
    .offer = onOffer,
};

fn onOffer(
    data: ?*anyopaque,
    offer: ?*c.zwlr_data_control_offer_v1,
    mime_type_c: [*c]const u8,
) callconv(.C) void {
    _ = data;
    _ = offer;
    const mime = std.mem.span(mime_type_c);

    cache_mutex.lock();
    defer cache_mutex.unlock();

    const alloc = cache_allocator orelse return;

    // If this is the first offer event since the last selection, clear
    // the cache.
    // (A simple heuristic: if the last entry is from the "previous" offer
    // cycle, we'd need a counter. For now, clear on each onSelection
    // transition is handled by onSelection itself destroying the old
    // offer. Here we just append — duplicates across cycles are rare.)
    const copy = alloc.dupe(u8, mime) catch return;
    cached_formats.append(alloc, copy) catch {
        alloc.free(copy);
    };
}
```

**Important correction to the cache lifecycle:** the above assumes the cache gets cleared at the right time. A cleaner design is to track the cache per-offer: clear `cached_formats` in `onDataOffer` (before the `offer` events fire) and let `onSelection` simply swap the current offer pointer. Update `onDataOffer` to:

```zig
fn onDataOffer(
    data: ?*anyopaque,
    device: ?*c.zwlr_data_control_device_v1,
    offer: ?*c.zwlr_data_control_offer_v1,
) callconv(.C) void {
    _ = data;
    _ = device;
    if (offer == null) return;

    cache_mutex.lock();
    defer cache_mutex.unlock();

    // Clear the format cache in preparation for this new offer's `offer`
    // events.
    if (cache_allocator) |alloc| {
        for (cached_formats.items) |f| alloc.free(f);
        cached_formats.clearRetainingCapacity();
    }

    _ = c.zwlr_data_control_offer_v1_add_listener(offer, &offer_listener, null);
}
```

### Step 8.5 — `listFormats`, `readFormat`, `clear`

- [ ] Append:

```zig
/// Returns an allocator-owned copy of the cached format list. O(1) + alloc.
pub fn listFormats(allocator: Allocator) ![][]const u8 {
    cache_mutex.lock();
    defer cache_mutex.unlock();

    if (cached_formats.items.len == 0) return try allocator.alloc([]const u8, 0);

    var out = try allocator.alloc([]const u8, cached_formats.items.len);
    errdefer allocator.free(out);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) allocator.free(out[j]);
    }
    while (i < cached_formats.items.len) : (i += 1) {
        out[i] = try allocator.dupe(u8, cached_formats.items[i]);
    }
    return out;
}

/// Reads the requested MIME type from the current offer via a pipe(2).
/// Returns null if the format is not advertised; returns an allocator-
/// owned byte slice otherwise.
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    cache_mutex.lock();
    const offer = current_offer;
    var has_format = false;
    for (cached_formats.items) |f| {
        if (std.mem.eql(u8, f, format)) {
            has_format = true;
            break;
        }
    }
    cache_mutex.unlock();

    if (!has_format or offer == null) return null;

    // Create a pipe. Give the write end to the compositor via `receive`.
    var fds: [2]std.posix.fd_t = undefined;
    try std.posix.pipe(&fds);
    const read_fd = fds[0];
    // write_fd is nullable so we can explicitly clear it after closing,
    // preventing the deferred close below from double-closing on the
    // success path. On any error path the defer still runs.
    var write_fd: ?std.posix.fd_t = fds[1];
    defer std.posix.close(read_fd);
    defer if (write_fd) |fd| std.posix.close(fd);

    // Null-terminate the format string for C.
    var buf: [256]u8 = undefined;
    if (format.len + 1 > buf.len) return ClipboardError.UnsupportedFormat;
    @memcpy(buf[0..format.len], format);
    buf[format.len] = 0;

    c.zwlr_data_control_offer_v1_receive(offer, &buf, write_fd.?);
    _ = c.wl_display_flush(display);
    // Close our write end so read(2) gets EOF when the compositor closes its copy.
    std.posix.close(write_fd.?);
    write_fd = null;

    // Drain the read end. The `defer` above closes `read_fd` on every exit
    // path (success and error), so no explicit close is needed inside the
    // loop or on `toOwnedSlice` failure.
    var out = try std.array_list.Managed(u8).initCapacity(allocator, 4096);
    errdefer out.deinit();
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(read_fd, &chunk);
        if (n == 0) break;
        try out.appendSlice(chunk[0..n]);
    }

    return try out.toOwnedSlice();
}

/// Clears the clipboard by setting a null selection.
pub fn clear() !void {
    if (data_device == null) return ClipboardError.PasteboardUnavailable;
    c.zwlr_data_control_device_v1_set_selection(data_device, null);
    _ = c.wl_display_roundtrip(display);
}
```

### Step 8.6 — Wire the new backend into `mod.zig` (temporary, for this task only)

Tasks 8–13 each add pieces to Linux. We don't want `mod.zig` to be fully wired until Task 14. But to verify Task 8 works, we need a temporary `mod.zig` patch.

**Note on allocator lifetime:** Backend connection state (Wayland display handle, atom caches, subscriber registries, data_offer caches) lives until process exit. We use a module-level static `std.heap.c_allocator` for all of this long-lived state rather than threading an allocator through `std.once.Once`. The per-call allocator parameters (`listFormats`, `readFormat`, etc.) are still honored for the results they return — only the *backend's private state* uses the static allocator. This matches Zig 0.15.2's `std.once.Once` signature, which takes a zero-argument function.

- [ ] In `native/clipboard/src/platform/linux/mod.zig`, add at the top (after the existing declarations):

```zig
const wayland = @import("wayland.zig");

/// Static allocator for backend-private state that lives until process exit.
/// Per-call allocators (passed in by the caller) are still used for returned
/// values that the caller owns.
const backend_allocator: Allocator = std.heap.c_allocator;

var wayland_ready: bool = false;

fn initBackends() void {
    wayland_ready = wayland.tryConnect(backend_allocator);
}

/// Lazy initializer. `std.once.Once` is parameterized by the function to run,
/// and `call` takes no arguments — hence the static `backend_allocator`.
var init_once = std.once.once(initBackends);

fn ensureInit() void {
    init_once.call();
}
```

- [ ] Replace the `listFormats`, `readFormat`, and `clear` stubs in `mod.zig` with delegates:

```zig
pub fn listFormats(allocator: Allocator) ![][]const u8 {
    ensureInit();
    if (!wayland_ready) return ClipboardError.NoDisplayServer;
    return wayland.listFormats(allocator);
}

pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    ensureInit();
    if (!wayland_ready) return ClipboardError.NoDisplayServer;
    return wayland.readFormat(allocator, format);
}

pub fn clear() !void {
    ensureInit();
    if (!wayland_ready) return ClipboardError.NoDisplayServer;
    return wayland.clear();
}
```

### Step 8.7 — Verify Wayland read works end-to-end (Environment 1: sway)

- [ ] On the Linux VM under sway, from `native/clipboard/`:

```bash
zig build
```

Expected: builds cleanly. If `@cImport` fails to find `wayland-client.h`, re-check `libwayland-dev` is installed.

- [ ] In one terminal, put something on the clipboard with `wl-copy`:

```bash
echo "hello from wl-copy" | wl-copy
```

- [ ] In the same or another terminal:

```bash
./zig-out/bin/clipboard list
```

Expected: a list including at least `text/plain;charset=utf-8`.

- [ ] Read the text:

```bash
./zig-out/bin/clipboard read 'text/plain;charset=utf-8'
```

Expected: `hello from wl-copy` printed to stdout (no trailing newline beyond what `wl-copy` put there).

- [ ] Clear:

```bash
./zig-out/bin/clipboard clear
wl-paste
```

Expected: `wl-paste` exits with an error or empty output, confirming the clear took effect.

### Step 8.8 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/linux/wayland.zig native/clipboard/src/platform/linux/mod.zig
git commit -m "feat(wayland): connection, format cache, listFormats/readFormat/clear"
```

---

## Task 9: Wayland `writeFormat` and `writeMultiple`

**Goal:** Add write paths to the Wayland backend. A write creates a `zwlr_data_control_source_v1`, announces its MIME types, claims the selection, and serves the `send` event by writing the stored bytes to the provided FD. Because Wayland's `wlr-data-control` does not require daemonization, the CLI can issue the write and exit cleanly; the compositor buffers the data on our behalf, subject to the post-exit caveat in the spec.

**Files:**
- Modify: `native/clipboard/src/platform/linux/wayland.zig`
- Modify: `native/clipboard/src/platform/linux/mod.zig` — wire `writeFormat` and `writeMultiple` delegates.

### Step 9.1 — Add module-level source state

- [ ] At the top of `native/clipboard/src/platform/linux/wayland.zig`, after the existing module state, append:

```zig
// Active write source state. The `send` handler reads these when the
// compositor asks for the data.
var active_source: ?*c.zwlr_data_control_source_v1 = null;
var active_pairs: std.ArrayListUnmanaged(SourcePair) = .{};
var source_allocator: ?Allocator = null;

const SourcePair = struct {
    mime_nul_terminated: [:0]u8, // owned
    data: []u8,                   // owned
};
```

### Step 9.2 — Implement `writeFormat`

- [ ] Append:

```zig
pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    const pair = [_]mod.FormatDataPair{.{ .format = format, .data = data }};
    return writeMultiple(allocator, &pair);
}

pub fn writeMultiple(allocator: Allocator, pairs: []const mod.FormatDataPair) !void {
    if (data_control_manager == null or data_device == null) {
        return ClipboardError.PasteboardUnavailable;
    }

    // Tear down any previous source (rare — only if the caller wrote twice
    // without an intervening external clipboard change).
    if (active_source) |src| {
        c.zwlr_data_control_source_v1_destroy(src);
        active_source = null;
    }
    if (source_allocator) |old_alloc| {
        for (active_pairs.items) |p| {
            old_alloc.free(p.mime_nul_terminated);
            old_alloc.free(p.data);
        }
        active_pairs.deinit(old_alloc);
        active_pairs = .{};
    }
    source_allocator = allocator;

    // Create the source and its listener.
    const source = c.zwlr_data_control_manager_v1_create_data_source(data_control_manager) orelse {
        return ClipboardError.WriteFailed;
    };
    _ = c.zwlr_data_control_source_v1_add_listener(source, &source_listener, null);

    // Copy + offer every pair.
    try active_pairs.ensureTotalCapacity(allocator, pairs.len);
    for (pairs) |p| {
        const mime_buf = try allocator.allocSentinel(u8, p.format.len, 0);
        @memcpy(mime_buf[0..p.format.len], p.format);
        const data_buf = try allocator.dupe(u8, p.data);

        try active_pairs.append(allocator, .{
            .mime_nul_terminated = mime_buf,
            .data = data_buf,
        });
        c.zwlr_data_control_source_v1_offer(source, mime_buf);
    }

    active_source = source;
    c.zwlr_data_control_device_v1_set_selection(data_device, source);

    // Roundtrip so the compositor definitely sees the set_selection before
    // we return. This is the acknowledge point.
    _ = c.wl_display_roundtrip(display);
}
```

### Step 9.3 — Add the source listener

- [ ] Append:

```zig
const source_listener = c.zwlr_data_control_source_v1_listener{
    .send = onSourceSend,
    .cancelled = onSourceCancelled,
};

/// Fired when another client requests a copy of our data. We write the
/// matching pair's bytes to `fd` and close it.
fn onSourceSend(
    data: ?*anyopaque,
    source: ?*c.zwlr_data_control_source_v1,
    mime_c: [*c]const u8,
    fd: i32,
) callconv(.C) void {
    _ = data;
    _ = source;
    const mime = std.mem.span(mime_c);

    // Find the matching pair.
    for (active_pairs.items) |p| {
        const stored_mime = p.mime_nul_terminated[0..std.mem.len(p.mime_nul_terminated.ptr)];
        if (std.mem.eql(u8, stored_mime, mime)) {
            _ = std.posix.write(fd, p.data) catch {};
            break;
        }
    }

    // Always close the FD, whether or not we found a match.
    std.posix.close(fd);
}

/// Fired when the compositor cancels our source (usually because another
/// client claimed the selection). Tear down our state.
fn onSourceCancelled(
    data: ?*anyopaque,
    source: ?*c.zwlr_data_control_source_v1,
) callconv(.C) void {
    _ = data;
    if (source == null) return;

    if (active_source == source) {
        active_source = null;
    }
    c.zwlr_data_control_source_v1_destroy(source);

    if (source_allocator) |alloc| {
        for (active_pairs.items) |p| {
            alloc.free(p.mime_nul_terminated);
            alloc.free(p.data);
        }
        active_pairs.deinit(alloc);
        active_pairs = .{};
    }
}
```

### Step 9.4 — Wire `writeFormat` and `writeMultiple` in `mod.zig`

- [ ] Replace the `writeFormat` and `writeMultiple` stubs in `platform/linux/mod.zig` with:

```zig
pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    ensureInit();
    if (!wayland_ready) return ClipboardError.NoDisplayServer;
    return wayland.writeFormat(allocator, format, data);
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    ensureInit();
    if (!wayland_ready) return ClipboardError.NoDisplayServer;
    return wayland.writeMultiple(allocator, pairs);
}
```

### Step 9.5 — Verify on sway

- [ ] From the Linux VM under sway, from `native/clipboard/`:

```bash
zig build
echo "wayland write test" | ./zig-out/bin/clipboard write 'text/plain;charset=utf-8'
wl-paste
```

Expected: `wl-paste` prints `wayland write test`. If it's empty, the `send` handler is not firing — double-check the listener registration.

### Step 9.6 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/linux/wayland.zig native/clipboard/src/platform/linux/mod.zig
git commit -m "feat(wayland): writeFormat and writeMultiple via data source"
```

---

## Task 10: Wayland `subscribe` — dispatch thread wiring

**Goal:** Hook the `onSelection` event into `mod.zig`'s fanout function. Spawn a background thread (owned by `mod.zig`) that loops on `wl_display_dispatch` so the compositor's events actually flow into our callbacks. When `onSelection` fires, `mod.zig` calls `fanout` and notifies every subscribed callback.

**Files:**
- Modify: `native/clipboard/src/platform/linux/wayland.zig` — expose a `notifySelectionChanged` hook.
- Modify: `native/clipboard/src/platform/linux/mod.zig` — add the subscriber registry, background thread, and fanout (mirror of macOS Task 4).

### Step 10.1 — Expose a hook from `wayland.zig`

- [ ] In `native/clipboard/src/platform/linux/wayland.zig`, add the following near the top:

```zig
// Hook called from the dispatch thread when a `selection` event fires. Set
// by mod.zig at module init; null until then.
pub var on_selection_hook: ?*const fn () void = null;
```

- [ ] In `onSelection`, after the existing offer management logic, add:

```zig
    if (on_selection_hook) |hook| hook();
```

Place it **outside** the `cache_mutex` critical section (after `defer cache_mutex.unlock()`'s scope exits) so the hook cannot deadlock on the cache.

### Step 10.2 — Expose the dispatch entry point

- [ ] Append to `wayland.zig`:

```zig
/// Returns the display FD for poll(2). Returns -1 if not connected.
pub fn displayFd() i32 {
    if (display == null) return -1;
    return c.wl_display_get_fd(display);
}

/// Blocks until at least one event is ready, then processes it. Called in
/// a loop by the subscribe thread. Returns an error if the display is gone.
pub fn dispatchOne() !void {
    if (display == null) return ClipboardError.PasteboardUnavailable;
    // wl_display_dispatch reads + dispatches pending events. It blocks if
    // there are none — that's exactly what we want for the thread body.
    const rc = c.wl_display_dispatch(display);
    if (rc < 0) return ClipboardError.PasteboardUnavailable;
}
```

### Step 10.3 — Add the subscriber registry + background thread to `mod.zig`

- [ ] At the top of `native/clipboard/src/platform/linux/mod.zig` (after the `SubscribeHandle` type declaration), add:

```zig
// ---------------------------------------------------------------------------
// Subscription registry (same shape as macOS). One registry, one background
// thread, shared across whichever backend is active.
// ---------------------------------------------------------------------------
const Subscriber = struct {
    id: u64,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
};

var subscribe_mutex: std.Thread.Mutex = .{};
var subscribers: std.ArrayListUnmanaged(Subscriber) = .{};
var next_subscriber_id: u64 = 1;
var thread_handle: ?std.Thread = null;
var should_exit: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var change_counter: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
```

### Step 10.4 — Implement `fanout` and wire the selection hook

- [ ] Append to `mod.zig`:

```zig
fn fanout() void {
    _ = change_counter.fetchAdd(1, .monotonic);

    var snapshot: [64]Subscriber = undefined;
    var count: usize = 0;

    subscribe_mutex.lock();
    for (subscribers.items) |s| {
        if (count >= snapshot.len) break;
        snapshot[count] = s;
        count += 1;
    }
    subscribe_mutex.unlock();

    for (snapshot[0..count]) |s| {
        s.callback(s.userdata);
    }
}

fn waylandThread() void {
    while (!should_exit.load(.acquire)) {
        wayland.dispatchOne() catch {
            // Display gone; exit the thread. Subsequent operations will
            // return error.PasteboardUnavailable.
            return;
        };
    }
}
```

- [ ] In `mod.zig`'s `initBackends` (added in Task 8.6), after the `wayland_ready = wayland.tryConnect(...)` line, set the selection hook:

```zig
fn initBackends() void {
    wayland_ready = wayland.tryConnect(backend_allocator);
    if (wayland_ready) {
        wayland.on_selection_hook = &fanout;
    }
}
```

### Step 10.5 — Implement `subscribe` / `unsubscribe` / `getChangeCount`

- [ ] Replace the stub `subscribe`, `unsubscribe`, and `getChangeCount` in `mod.zig` with:

```zig
pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    _ = allocator; // subscribers use backend_allocator so the registry lives until process exit
    ensureInit();
    if (!wayland_ready) return ClipboardError.NoDisplayServer;

    subscribe_mutex.lock();
    defer subscribe_mutex.unlock();

    const id = next_subscriber_id;
    next_subscriber_id += 1;

    try subscribers.append(backend_allocator, .{
        .id = id,
        .callback = callback,
        .userdata = userdata,
    });

    if (thread_handle == null) {
        should_exit.store(false, .release);
        thread_handle = std.Thread.spawn(.{}, waylandThread, .{}) catch {
            _ = subscribers.pop();
            return ClipboardError.SubscribeFailed;
        };
    }

    return SubscribeHandle{ .id = id };
}

pub fn unsubscribe(handle: SubscribeHandle) void {
    subscribe_mutex.lock();
    var i: usize = 0;
    while (i < subscribers.items.len) : (i += 1) {
        if (subscribers.items[i].id == handle.id) {
            _ = subscribers.swapRemove(i);
            break;
        }
    }
    const should_stop = subscribers.items.len == 0;
    subscribe_mutex.unlock();

    if (should_stop) {
        should_exit.store(true, .release);
    }
}

pub fn getChangeCount() i64 {
    return change_counter.load(.monotonic);
}
```

### Step 10.6 — Verify on sway

- [ ] From the Linux VM under sway, from `native/clipboard/`:

```bash
zig build
./zig-out/bin/clipboard watch &
sleep 1
echo "sub test 1" | wl-copy
sleep 1
echo "sub test 2" | wl-copy
sleep 1
kill %1 2>/dev/null || true
```

Expected: the `clipboard watch` output includes two change events corresponding to the two `wl-copy` calls, with reaction time well under 500ms (this confirms the subscribe path is truly event-driven on Wayland).

### Step 10.7 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/linux/wayland.zig native/clipboard/src/platform/linux/mod.zig
git commit -m "feat(wayland): subscribe via dispatch thread and fanout hook"
```

---

## Task 11: X11 backend — connection, atom cache, read, list, clear

**Goal:** Create `platform/linux/x11.zig` with display-open, a MIME-type ↔ atom cache, and `readFormat` / `listFormats` / `clear`. Write paths land in Task 12, subscribe in Task 13.

**Files:**
- Create: `native/clipboard/src/platform/linux/x11.zig`

**Environment:** Environment 3 (Ubuntu on Xorg) is the cleanest to test against. Environment 2 (GNOME Wayland + XWayland) will also exercise this path because GNOME does not expose `wlr-data-control`, so backend selection will fall through.

### Step 11.1 — Create the file skeleton

- [ ] Create `native/clipboard/src/platform/linux/x11.zig`:

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
});

const mod = @import("mod.zig");
const ClipboardError = mod.ClipboardError;

var display: ?*c.Display = null;
var our_window: c.Window = 0;
var clipboard_atom: c.Atom = 0;
var targets_atom: c.Atom = 0;
var our_property_atom: c.Atom = 0; // used as the property name for XConvertSelection
var utf8_string_atom: c.Atom = 0;
var incr_atom: c.Atom = 0;

// MIME-type → atom cache. Populated lazily.
const AtomEntry = struct {
    mime: []u8,
    atom: c.Atom,
};
var atom_cache_mutex: std.Thread.Mutex = .{};
var atom_cache: std.ArrayListUnmanaged(AtomEntry) = .{};
// Module-level allocator for backend-private state: atom cache, subscriber
// registry, module-owned format buffers. Set once by `tryOpenDisplay`.
// Long-lived — not freed until process exit (backend state lives forever).
var allocator: ?Allocator = null;
```

### Step 11.2 — `tryOpenDisplay`

- [ ] Append:

```zig
/// Opens the X display, creates an invisible window to use for selection
/// requests, and precaches the core atoms. Returns true on success, false
/// if XOpenDisplay fails. `alloc` is stored in the module-level `allocator`
/// and used for every backend-private allocation for the life of the process.
pub fn tryOpenDisplay(alloc: Allocator) bool {
    const d = c.XOpenDisplay(null) orelse return false;
    display = d;
    allocator = alloc;

    // Precache the atoms we always need.
    clipboard_atom = c.XInternAtom(d, "CLIPBOARD", c.False);
    targets_atom = c.XInternAtom(d, "TARGETS", c.False);
    our_property_atom = c.XInternAtom(d, "_ZIG_CLIPBOARD_PROP", c.False);
    utf8_string_atom = c.XInternAtom(d, "UTF8_STRING", c.False);
    incr_atom = c.XInternAtom(d, "INCR", c.False);

    // Create an unmapped window we own. This window is the selection
    // requester / owner; it never becomes visible.
    const root = c.XDefaultRootWindow(d);
    our_window = c.XCreateSimpleWindow(
        d,
        root,
        0, 0, // x, y
        1, 1, // w, h
        0, // border width
        0, // border pixel
        0, // background pixel
    );
    _ = c.XSelectInput(d, our_window, c.PropertyChangeMask);
    _ = c.XFlush(d);

    return true;
}

/// Look up (or intern) the atom for a MIME type.
fn atomFor(mime: []const u8) ?c.Atom {
    atom_cache_mutex.lock();
    defer atom_cache_mutex.unlock();

    for (atom_cache.items) |e| {
        if (std.mem.eql(u8, e.mime, mime)) return e.atom;
    }

    const d = display orelse return null;
    const alloc = allocator orelse return null;

    // Null-terminate for XInternAtom.
    var buf: [256]u8 = undefined;
    if (mime.len + 1 > buf.len) return null;
    @memcpy(buf[0..mime.len], mime);
    buf[mime.len] = 0;
    const atom = c.XInternAtom(d, &buf, c.False);
    if (atom == c.None) return null;

    const mime_copy = alloc.dupe(u8, mime) catch return atom;
    atom_cache.append(alloc, .{ .mime = mime_copy, .atom = atom }) catch {
        alloc.free(mime_copy);
    };
    return atom;
}
```

### Step 11.3 — `readFormat` via `XConvertSelection`

- [ ] Append:

```zig
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    const d = display orelse return ClipboardError.PasteboardUnavailable;
    const target = atomFor(format) orelse return null;

    const owner = c.XGetSelectionOwner(d, clipboard_atom);
    if (owner == c.None) return null;

    _ = c.XConvertSelection(
        d,
        clipboard_atom,
        target,
        our_property_atom,
        our_window,
        c.CurrentTime,
    );
    _ = c.XFlush(d);

    // Wait up to 2 seconds for the SelectionNotify reply.
    const deadline_ns: u64 = 2 * std.time.ns_per_s;
    const start = std.time.nanoTimestamp();
    var got_notify = false;
    var notify_event: c.XEvent = undefined;

    while (true) {
        const elapsed: u64 = @intCast(@as(i128, @intCast(std.time.nanoTimestamp() - start)));
        if (elapsed >= deadline_ns) break;

        // Drain any pending events; check for SelectionNotify on our window.
        while (c.XPending(d) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(d, &ev);
            if (ev.type == c.SelectionNotify and ev.xselection.requestor == our_window) {
                notify_event = ev;
                got_notify = true;
                break;
            }
        }
        if (got_notify) break;

        // No event ready; poll for one with a small timeout.
        const fd = c.ConnectionNumber(d);
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 50) catch 0;
    }

    if (!got_notify) return null;
    if (notify_event.xselection.property == c.None) return null;

    // Read the property. For small data, one XGetWindowProperty is enough.
    // INCR transfers are out of scope for this spec; if encountered, return
    // null (documented as a known limitation).
    var actual_type: c.Atom = 0;
    var actual_format: c_int = 0;
    var nitems: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var prop_data: [*c]u8 = null;

    _ = c.XGetWindowProperty(
        d,
        our_window,
        our_property_atom,
        0, // offset
        @as(c_long, std.math.maxInt(i32)), // length
        c.True, // delete after read
        c.AnyPropertyType,
        &actual_type,
        &actual_format,
        &nitems,
        &bytes_after,
        &prop_data,
    );

    if (actual_type == incr_atom) {
        if (prop_data != null) _ = c.XFree(prop_data);
        return null; // INCR transfers not supported.
    }

    if (prop_data == null or nitems == 0) {
        if (prop_data != null) _ = c.XFree(prop_data);
        return try allocator.alloc(u8, 0);
    }

    // `nitems` is in units of `actual_format / 8` bytes (8, 16, or 32).
    const elem_bytes: usize = @intCast(@divExact(actual_format, 8));
    const total_bytes = nitems * elem_bytes;

    const out = try allocator.alloc(u8, total_bytes);
    @memcpy(out, prop_data[0..total_bytes]);
    _ = c.XFree(prop_data);

    return out;
}
```

### Step 11.4 — `listFormats` via `TARGETS`

- [ ] Append:

```zig
pub fn listFormats(allocator: Allocator) ![][]const u8 {
    const d = display orelse return ClipboardError.PasteboardUnavailable;

    const owner = c.XGetSelectionOwner(d, clipboard_atom);
    if (owner == c.None) return try allocator.alloc([]const u8, 0);

    _ = c.XConvertSelection(d, clipboard_atom, targets_atom, our_property_atom, our_window, c.CurrentTime);
    _ = c.XFlush(d);

    // Wait for SelectionNotify (same 2s poll as readFormat; factor out if
    // this code duplicates too much).
    const deadline_ns: u64 = 2 * std.time.ns_per_s;
    const start = std.time.nanoTimestamp();
    var got_notify = false;
    var notify_event: c.XEvent = undefined;
    while (true) {
        const elapsed: u64 = @intCast(@as(i128, @intCast(std.time.nanoTimestamp() - start)));
        if (elapsed >= deadline_ns) break;

        while (c.XPending(d) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(d, &ev);
            if (ev.type == c.SelectionNotify and ev.xselection.requestor == our_window) {
                notify_event = ev;
                got_notify = true;
                break;
            }
        }
        if (got_notify) break;

        const fd = c.ConnectionNumber(d);
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 50) catch 0;
    }

    if (!got_notify or notify_event.xselection.property == c.None) {
        return try allocator.alloc([]const u8, 0);
    }

    var actual_type: c.Atom = 0;
    var actual_format: c_int = 0;
    var nitems: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var prop_data: [*c]u8 = null;

    _ = c.XGetWindowProperty(
        d,
        our_window,
        our_property_atom,
        0,
        @as(c_long, std.math.maxInt(i32)),
        c.True,
        c.XA_ATOM,
        &actual_type,
        &actual_format,
        &nitems,
        &bytes_after,
        &prop_data,
    );

    if (prop_data == null or nitems == 0) {
        if (prop_data != null) _ = c.XFree(prop_data);
        return try allocator.alloc([]const u8, 0);
    }

    const atoms_ptr: [*]const c.Atom = @ptrCast(@alignCast(prop_data));
    const atoms = atoms_ptr[0..@intCast(nitems)];

    var out = try std.array_list.Managed([]const u8).initCapacity(allocator, nitems);
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit();
    }

    for (atoms) |atom| {
        const name_c = c.XGetAtomName(d, atom) orelse continue;
        defer _ = c.XFree(name_c);
        const name = std.mem.span(name_c);

        // Filter X11-internal atoms.
        if (std.mem.eql(u8, name, "TARGETS")) continue;
        if (std.mem.eql(u8, name, "MULTIPLE")) continue;
        if (std.mem.eql(u8, name, "TIMESTAMP")) continue;
        if (std.mem.eql(u8, name, "SAVE_TARGETS")) continue;

        const copy = try allocator.dupe(u8, name);
        try out.append(copy);
    }

    _ = c.XFree(prop_data);
    return try out.toOwnedSlice();
}
```

### Step 11.5 — `clear`

- [ ] Append:

```zig
pub fn clear() !void {
    const d = display orelse return ClipboardError.PasteboardUnavailable;
    _ = c.XSetSelectionOwner(d, clipboard_atom, c.None, c.CurrentTime);
    _ = c.XSync(d, c.False);
}
```

### Step 11.6 — Temporary mod.zig wire-up for X11 verification

Since Task 14 does the real backend selection, we need a temporary patch to force X11 selection for this task's verification. The cleanest way is to add an env-var override that `initBackends` reads.

- [ ] In `platform/linux/mod.zig`, extend `initBackends` (the zero-arg function called by `std.once.Once`, added in Task 8.6 and amended in Task 10.4):

```zig
const x11 = @import("x11.zig");

var x11_ready: bool = false;

fn initBackends() void {
    const force_x11 = std.posix.getenv("CLIPBOARD_FORCE_X11") != null;

    if (!force_x11) {
        wayland_ready = wayland.tryConnect(backend_allocator);
        if (wayland_ready) {
            wayland.on_selection_hook = &fanout;
            return;
        }
    }

    x11_ready = x11.tryOpenDisplay(backend_allocator);
}
```

**This is temporary.** Task 14 replaces the `CLIPBOARD_FORCE_X11` env var with spec-correct runtime selection (Wayland first, then X11) that happens regardless of env-var overrides.

- [ ] Update the existing `listFormats`, `readFormat`, `clear` delegates in `mod.zig` to try X11 if Wayland isn't ready:

```zig
pub fn listFormats(allocator: Allocator) ![][]const u8 {
    ensureInit();
    if (wayland_ready) return wayland.listFormats(allocator);
    if (x11_ready) return x11.listFormats(allocator);
    return ClipboardError.NoDisplayServer;
}

pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    ensureInit();
    if (wayland_ready) return wayland.readFormat(allocator, format);
    if (x11_ready) return x11.readFormat(allocator, format);
    return ClipboardError.NoDisplayServer;
}

pub fn clear() !void {
    ensureInit();
    if (wayland_ready) return wayland.clear();
    if (x11_ready) return x11.clear();
    return ClipboardError.NoDisplayServer;
}
```

### Step 11.7 — Verify on Xorg

- [ ] From the Linux VM booted into "Ubuntu on Xorg" (Environment 3), from `native/clipboard/`:

```bash
zig build
xclip -in -selection clipboard <<< "x11 read test"
./zig-out/bin/clipboard list
./zig-out/bin/clipboard read 'UTF8_STRING'
./zig-out/bin/clipboard read 'text/plain'
```

Expected: `list` shows at least `UTF8_STRING` and `text/plain`; at least one of the `read` commands prints `x11 read test`. If both fail, the atom cache is wrong or the `XGetWindowProperty` call is returning `actual_type == INCR` (large transfer, not supported in this spec).

- [ ] Verify `clear`:

```bash
./zig-out/bin/clipboard clear
xclip -out -selection clipboard
```

Expected: `xclip -out` fails or returns empty.

- [ ] Also verify the forced-X11 path on sway (where Wayland would normally win):

```bash
CLIPBOARD_FORCE_X11=1 ./zig-out/bin/clipboard list
```

Expected: prints the clipboard formats via XWayland. Confirms backend selection is working and X11 is reachable from a Wayland session via XWayland.

### Step 11.8 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/linux/x11.zig native/clipboard/src/platform/linux/mod.zig
git commit -m "feat(x11): connection, atom cache, readFormat/listFormats/clear"
```

---

## Task 12: X11 `writeFormat` and `writeMultiple`

**Goal:** Take ownership of the `CLIPBOARD` selection and service incoming `SelectionRequest` events so other X11 clients can paste the bytes we wrote.

**Files:**
- Modify: `native/clipboard/src/platform/linux/x11.zig`
- Modify: `native/clipboard/src/platform/linux/mod.zig`

**Why this is weird:** X11 doesn't store clipboard data. When you "write" the clipboard, you're only claiming ownership of an atom (`CLIPBOARD`). When another app later pastes, the X server sends us a `SelectionRequest` event, and we have to respond by writing the bytes into a property on their window. If we exit before servicing that request, the paste fails. This task implements a **synchronous service loop** that waits up to 5 seconds for a paste, with a short grace period after the first successful service in case the consumer asks for additional formats (e.g. `TARGETS` then the data itself).

**Spec reference:** "X11 writeFormat" in the design doc. Read that section before implementing — the state machine below is a direct encoding of what the spec describes.

### Step 12.1 — Module state for the active write

- [ ] In `native/clipboard/src/platform/linux/x11.zig`, add module-level variables that hold the currently-served selection write. All of these are accessed only from the thread that called `writeFormat`/`writeMultiple` — X11 writes are synchronous and single-threaded in this library (see spec: "X11 writeFormat").

```zig
// The pairs currently being served. Borrowed from the caller for the
// duration of the writeFormat/writeMultiple call.
var write_pairs: []const mod.FormatDataPair = &.{};
// Parallel array of pre-interned atoms for each pair's format string, so the
// SelectionRequest handler doesn't need to re-intern on every paste. Owned
// by the module-level `allocator` for the duration of the write call.
var write_atoms: []c.Atom = &.{};
```

The lifetime of `write_pairs`/`write_atoms` is the duration of the `writeFormat`/`writeMultiple` call — the caller owns the underlying byte slices, and `write_atoms` is freed at the end of the write call via `defer`. The existing module-level `display` and `our_window` (from Task 11) are the targets for `XSetSelectionOwner` — no new state needed beyond the two vars above.

### Step 12.2 — Helper: respond to a single `SelectionRequest`

- [ ] Write a helper `respondToSelectionRequest(event: *c.XSelectionRequestEvent) bool` that encodes the spec's response state machine. This helper uses the module-level `allocator` that Task 11 introduced (renamed from `atom_cache_allocator` in the revised Task 11.1).

```zig
fn respondToSelectionRequest(ev: *c.XSelectionRequestEvent) bool {
    const alloc = allocator orelse return false;

    // Build the SelectionNotify reply we'll send back regardless of success.
    var reply: c.XSelectionEvent = std.mem.zeroes(c.XSelectionEvent);
    reply.type = c.SelectionNotify;
    reply.display = ev.display;
    reply.requestor = ev.requestor;
    reply.selection = ev.selection;
    reply.target = ev.target;
    reply.time = ev.time;
    reply.property = 0; // default: refused

    // If the requestor asked for TARGETS, answer with the list of formats
    // we're currently serving PLUS the always-present TARGETS atom itself.
    // Note: `targets_atom` is the module-level variable cached in Task 11.2.
    if (ev.target == targets_atom) {
        var list = std.array_list.Managed(c.Atom).initCapacity(alloc, write_atoms.len + 1) catch return false;
        defer list.deinit();
        list.append(targets_atom) catch return false;
        for (write_atoms) |a| list.append(a) catch return false;

        _ = c.XChangeProperty(
            ev.display,
            ev.requestor,
            ev.property,
            c.XA_ATOM,
            32,
            c.PropModeReplace,
            @ptrCast(list.items.ptr),
            @intCast(list.items.len),
        );
        reply.property = ev.property;
    } else {
        // Match the request target against one of our stored format atoms.
        var matched: ?usize = null;
        for (write_atoms, 0..) |a, i| {
            if (a == ev.target) {
                matched = i;
                break;
            }
        }
        if (matched) |idx| {
            const bytes = write_pairs[idx].data;
            _ = c.XChangeProperty(
                ev.display,
                ev.requestor,
                ev.property,
                ev.target,
                8,
                c.PropModeReplace,
                bytes.ptr,
                @intCast(bytes.len),
            );
            reply.property = ev.property;
        }
        // If nothing matched, reply.property stays 0 ("refused").
    }

    _ = c.XSendEvent(
        ev.display,
        ev.requestor,
        c.False,
        c.NoEventMask,
        @ptrCast(&reply),
    );
    _ = c.XFlush(ev.display);
    return reply.property != 0;
}
```

### Step 12.3 — Implement the service loop

- [ ] Write a private function `runSelectionServiceLoop()` that encodes the spec's state machine. Timeouts are measured with `std.time.milliTimestamp`.

```zig
const SELECTION_WRITE_TIMEOUT_MS: i64 = 5_000;
const SELECTION_WRITE_GRACE_MS: i64 = 500;

fn runSelectionServiceLoop() !void {
    const d = display orelse return ClipboardError.NoDisplayServer;
    const start = std.time.milliTimestamp();
    var first_service_time: ?i64 = null;

    while (true) {
        // Compute deadline. Before first service: overall timeout.
        // After first service: whichever is sooner — overall timeout or grace window.
        const now = std.time.milliTimestamp();
        if (first_service_time) |t| {
            if (now - t >= SELECTION_WRITE_GRACE_MS) return; // grace exhausted → success
        }
        if (now - start >= SELECTION_WRITE_TIMEOUT_MS) {
            // No one ever pasted. This is still a successful write from the
            // library's point of view — the clipboard is owned.
            return;
        }

        // Poll the X11 connection's fd with a short timeout so we can
        // re-check the deadlines. A poll failure is non-recoverable for
        // this call; map it to PasteboardUnavailable so we don't introduce
        // a new error variant that isn't in the spec's unified set.
        const fd = c.ConnectionNumber(d);
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 100) catch return ClipboardError.PasteboardUnavailable;

        // Drain all pending events.
        while (c.XPending(d) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(d, &ev);
            switch (ev.type) {
                c.SelectionRequest => {
                    const ok = respondToSelectionRequest(&ev.xselectionrequest);
                    if (ok and first_service_time == null) {
                        first_service_time = std.time.milliTimestamp();
                    }
                },
                c.SelectionClear => {
                    // Another client took ownership. That's a successful exit —
                    // we served what we had up until someone else claimed it.
                    return;
                },
                else => {}, // ignore
            }
        }
    }
}
```

### Step 12.4 — Implement `writeFormat` and `writeMultiple`

- [ ] Add the public entry points. These use the module-level `display` and `our_window` from Task 11 (the hidden `InputOnly`-style window created in `tryOpenDisplay`), and the module-level `allocator` for the atoms scratch buffer.

```zig
pub fn writeFormat(alloc: Allocator, format: []const u8, data: []const u8) !void {
    const pair = mod.FormatDataPair{ .format = format, .data = data };
    const pairs = [_]mod.FormatDataPair{pair};
    return writeMultiple(alloc, &pairs);
}

pub fn writeMultiple(alloc: Allocator, pairs: []const mod.FormatDataPair) !void {
    _ = alloc; // unused: we use the module-level allocator for scratch state
    const d = display orelse return ClipboardError.NoDisplayServer;
    const our = allocator orelse return ClipboardError.NoDisplayServer;

    // Intern atoms for every format up front.
    const atoms = try our.alloc(c.Atom, pairs.len);
    defer our.free(atoms);
    for (pairs, 0..) |p, i| {
        const fmt_z = try our.dupeZ(u8, p.format);
        defer our.free(fmt_z);
        atoms[i] = c.XInternAtom(d, fmt_z.ptr, c.False);
    }

    // Install module state for the service loop.
    write_pairs = pairs;
    write_atoms = atoms;
    defer {
        write_pairs = &.{};
        write_atoms = &.{};
    }

    // Claim ownership of CLIPBOARD. `clipboard_atom` is the module-level
    // atom cached in Task 11.2.
    _ = c.XSetSelectionOwner(d, clipboard_atom, our_window, c.CurrentTime);
    _ = c.XFlush(d);

    // Verify the server actually granted ownership. This can fail if another
    // client races us; treat it as a write failure so the caller knows.
    const actual = c.XGetSelectionOwner(d, clipboard_atom);
    if (actual != our_window) return ClipboardError.WriteFailed;

    // Block until timeout / grace window / SelectionClear.
    try runSelectionServiceLoop();
}
```

### Step 12.5 — Wire `mod.zig` delegation for writes

- [ ] In `native/clipboard/src/platform/linux/mod.zig`, extend the backend dispatch (still governed by the temporary `CLIPBOARD_FORCE_X11` switch from Task 11) so that `writeFormat` and `writeMultiple` route to `x11.writeFormat`/`x11.writeMultiple` when the X11 backend is active. Wayland is still unimplemented on this branch — leave its write entry points as `ClipboardError.WriteFailed` placeholders; Task 9 fills them in (task order was deliberate to unblock X11 verification against real pastes).

### Step 12.6 — Manual verification with `xclip` and `xsel`

- [ ] Rebuild the CLI for Linux and run the following end-to-end paste test on the **Xorg** VM (not XWayland — we want to hit the real X11 path):

```bash
# Terminal A — write our marker
CLIPBOARD_FORCE_X11=1 ./zig-out/bin/clipboard write --text "marker-from-our-lib"
# (this command blocks for up to 5 seconds)

# Terminal B (within the 5s window) — read via xclip
xclip -selection clipboard -o
```

Expected: terminal B prints `marker-from-our-lib`, and terminal A exits cleanly after the grace period. If terminal A exits after exactly 5 seconds with no paste attempted, that's also a passing run — the service loop should time out gracefully.

- [ ] Repeat the same test but read via `xsel` instead of `xclip` to verify we're not accidentally tied to one consumer's quirks:

```bash
xsel --clipboard --output
```

Expected: same marker string.

### Step 12.7 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/linux/x11.zig native/clipboard/src/platform/linux/mod.zig
git commit -m "feat(x11): writeFormat/writeMultiple via SelectionRequest service loop"
```

---

## Task 13: X11 `subscribe` (polling with format hash)

**Goal:** Implement `subscribe(callback)` on the X11 backend by running a background thread that polls the `CLIPBOARD` selection owner. Because X11 has no native change notification, we detect changes by hashing the `TARGETS` contents every poll tick and comparing to the previous hash.

**Files:**
- Modify: `native/clipboard/src/platform/linux/x11.zig`
- Modify: `native/clipboard/src/platform/linux/mod.zig`

**Why this is weird (again):** X11 has no equivalent of `NSPasteboardDidChangeNotification` or Wayland's `selection` event. The only reliable way to detect a clipboard change is to ask the server whose window currently owns `CLIPBOARD` and what formats it offers. Even that isn't enough — the same owner can replace its selection content multiple times without changing window ownership, so we **must rehash every tick regardless of whether the owner changed.** The spec explicitly calls this out; don't optimize it away.

**Spec reference:** "X11 subscribe" and the "X11 change detection" note in the design doc.

### Step 13.1 — Subscriber registry (mirrors Wayland design)

- [ ] In `native/clipboard/src/platform/linux/x11.zig`, add a subscriber registry and thread state. This mirrors the Wayland subscribe implementation from Task 10 intentionally, so the callsite in `mod.zig` can treat both backends uniformly. The callback type is `mod.SubscribeCallback` (nullable userdata) to match the canonical API established in Task 3.

```zig
const Subscriber = struct {
    id: u64,
    callback: mod.SubscribeCallback,
    userdata: ?*anyopaque,
};

var subs_mutex: std.Thread.Mutex = .{};
var subs: std.ArrayListUnmanaged(Subscriber) = .{};
var next_sub_id: u64 = 1; // id=0 is reserved as invalid-handle sentinel
var poll_thread: ?std.Thread = null;
var poll_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var change_count: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);
```

### Step 13.2 — `getChangeCount`

- [ ] Expose `getChangeCount` as a monotonic counter that the polling thread bumps whenever it detects a change:

```zig
pub fn getChangeCount() i64 {
    return change_count.load(.monotonic);
}
```

### Step 13.3 — The polling loop

- [ ] Write the background function. It uses `poll(2)` over `ConnectionNumber` so it wakes up promptly if an X event arrives (which we don't actually need for change detection, but lets us stop quickly on shutdown), and otherwise wakes every `poll_ms` to re-hash.

```zig
const DEFAULT_POLL_MS: i32 = 500;

fn pollThreadMain() void {
    // `display`, `clipboard_atom`, and `targets_atom` are all module-level
    // from Task 11.1/11.2.
    const d = display orelse return;

    var last_hash: u64 = 0;
    var last_owner: c.Window = 0;

    // Hidden env-var for tuning during debugging. Undocumented on purpose.
    const poll_ms: i32 = blk: {
        const raw = std.posix.getenv("LINUX_X11_POLL_MS") orelse break :blk DEFAULT_POLL_MS;
        break :blk std.fmt.parseInt(i32, raw, 10) catch DEFAULT_POLL_MS;
    };

    while (!poll_stop.load(.acquire)) {
        // Drain any stray events without blocking.
        while (c.XPending(d) > 0) {
            var ev: c.XEvent = undefined;
            _ = c.XNextEvent(d, &ev);
            // We don't care about specific events here — the hash check below
            // is the authoritative signal.
        }

        // Query current owner + targets.
        const current_owner = c.XGetSelectionOwner(d, clipboard_atom);

        // Hash TARGETS contents. If the request times out or no one owns the
        // selection, hash is 0, which is distinct from "owner with empty targets".
        const hash = hashTargets(d) catch 0;

        const changed = (hash != last_hash) or (current_owner != last_owner);
        if (changed) {
            last_hash = hash;
            last_owner = current_owner;
            _ = change_count.fetchAdd(1, .monotonic);
            fanout();
        }

        // Sleep/wait for next tick OR early wake if X events arrive OR shutdown.
        const fd = c.ConnectionNumber(d);
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, poll_ms) catch {};
    }
}
```

### Step 13.4 — `hashTargets` helper

- [ ] Write the helper that fetches TARGETS and hashes its atom list. We use FNV-1a 64-bit — it's cheap and in `std.hash`.

```zig
fn hashTargets(d: *c.Display) !u64 {
    // Dedicated destination property for subscribe-thread TARGETS reads so
    // we don't race with the foreground thread's own `our_property_atom`
    // usage in readFormat.
    const prop_atom = c.XInternAtom(d, "_CLIPBOARD_MGR_TARGETS_SUB", c.False);

    _ = c.XConvertSelection(
        d,
        clipboard_atom,
        targets_atom,
        prop_atom,
        our_window,
        c.CurrentTime,
    );
    _ = c.XFlush(d);

    // Wait briefly for SelectionNotify. We use a 200ms budget here — longer
    // than a happy-path roundtrip, short enough that a stuck request doesn't
    // stall the poll thread.
    const start = std.time.milliTimestamp();
    var got_notify = false;
    while (std.time.milliTimestamp() - start < 200) {
        var ev: c.XEvent = undefined;
        if (c.XCheckTypedWindowEvent(d, our_window, c.SelectionNotify, &ev) != 0) {
            got_notify = true;
            break;
        }
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    if (!got_notify) return 0;

    // Read the property bytes.
    var actual_type: c.Atom = 0;
    var actual_format: c_int = 0;
    var nitems: c_ulong = 0;
    var bytes_after: c_ulong = 0;
    var data_ptr: [*c]u8 = null;
    const status = c.XGetWindowProperty(
        d,
        our_window,
        prop_atom,
        0,
        1 << 20,
        c.True, // delete after read
        c.XA_ATOM,
        &actual_type,
        &actual_format,
        &nitems,
        &bytes_after,
        &data_ptr,
    );
    if (status != c.Success or data_ptr == null) return 0;
    defer _ = c.XFree(data_ptr);

    // Hash nitems * sizeof(Atom) bytes.
    const byte_len: usize = @as(usize, @intCast(nitems)) * @sizeOf(c.Atom);
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(data_ptr[0..byte_len]);
    return hasher.final();
}
```

### Step 13.5 — `fanout` and `subscribe`/`unsubscribe`

- [ ] Write the fanout helper, mirroring Wayland's snapshot-based approach to avoid holding the mutex across user callbacks:

```zig
fn fanout() void {
    var snapshot_buf: [64]Subscriber = undefined;
    var count: usize = 0;
    {
        subs_mutex.lock();
        defer subs_mutex.unlock();
        count = @min(subs.items.len, snapshot_buf.len);
        for (subs.items[0..count], 0..) |s, i| snapshot_buf[i] = s;
    }
    for (snapshot_buf[0..count]) |s| {
        s.callback(s.userdata);
    }
}
```

- [ ] Write `subscribe` and `unsubscribe`. Signatures match `mod.SubscribeCallback` and the canonical `unsubscribe(handle)` shape from Task 3. Note: the `allocator` parameter on `subscribe` is ignored — the subscriber registry uses the module-level `allocator` (set in `tryOpenDisplay` during Task 11) so the registry outlives any caller's transient allocator.

```zig
pub fn subscribe(
    _: Allocator,
    callback: mod.SubscribeCallback,
    userdata: ?*anyopaque,
) !mod.SubscribeHandle {
    const our = allocator orelse return ClipboardError.NoDisplayServer;

    subs_mutex.lock();
    defer subs_mutex.unlock();

    const id = next_sub_id;
    next_sub_id += 1;
    try subs.append(our, .{ .id = id, .callback = callback, .userdata = userdata });

    if (poll_thread == null) {
        poll_stop.store(false, .release);
        poll_thread = std.Thread.spawn(.{}, pollThreadMain, .{}) catch {
            _ = subs.pop();
            return ClipboardError.SubscribeFailed;
        };
    }

    return .{ .id = id };
}

pub fn unsubscribe(handle: mod.SubscribeHandle) void {
    subs_mutex.lock();
    defer subs_mutex.unlock();

    var i: usize = 0;
    while (i < subs.items.len) {
        if (subs.items[i].id == handle.id) {
            _ = subs.swapRemove(i);
            break;
        }
        i += 1;
    }

    // Spec: we deliberately do NOT stop the poll thread when the last
    // subscriber leaves. Process exit is the only stop signal. See the
    // design doc's "Subscribe lifetime" section.
}
```

### Step 13.6 — Wire into `mod.zig` with a dispatch split

This step reshapes the subscribe API in `mod.zig` so it can dispatch to either the Wayland registry (living inside `mod.zig`, from Task 10) OR the X11 registry (living inside `x11.zig`, from Step 13.5 above).

The asymmetry: Task 10 put the Wayland subscriber registry + `waylandThread` in `mod.zig` because they wrap the Wayland dispatch loop. Task 13 put the X11 registry + `pollThreadMain` inside `x11.zig` because the X11 poll loop needs private x11 state (atoms, owner window). We don't unify them — we dispatch between them.

- [ ] Rename Task 10's `pub fn subscribe` in `mod.zig` to `fn subscribeWayland` (drop the `pub`). Do the same for `unsubscribe` → `unsubscribeWayland` and `getChangeCount` → `getChangeCountWayland`. These are now private helpers.

- [ ] Add new public `subscribe`, `unsubscribe`, `getChangeCount` at the bottom of `mod.zig`:

```zig
pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    ensureInit();
    if (wayland_ready) return subscribeWayland(allocator, callback, userdata);
    if (x11_ready) return x11.subscribe(allocator, callback, userdata);
    return ClipboardError.NoDisplayServer;
}

pub fn unsubscribe(handle: SubscribeHandle) void {
    if (wayland_ready) {
        unsubscribeWayland(handle);
        return;
    }
    if (x11_ready) {
        x11.unsubscribe(handle);
        return;
    }
}

pub fn getChangeCount() i64 {
    if (wayland_ready) return getChangeCountWayland();
    if (x11_ready) return x11.getChangeCount();
    return -1;
}
```

- [ ] Verify nothing else in `mod.zig` still calls the old public names. Grep for `subscribeWayland` to make sure it's only referenced from the new public `subscribe`.

### Step 13.7 — Manual verification on Xorg

- [ ] On the Xorg VM, run the watch subcommand:

```bash
CLIPBOARD_FORCE_X11=1 ./zig-out/bin/clipboard watch
```

In another terminal, run:

```bash
echo "alpha" | xclip -selection clipboard
echo "beta"  | xclip -selection clipboard
echo "gamma" | xclip -selection clipboard
```

Expected: the `watch` process prints 3 change notifications. Each should arrive within roughly 500ms of the `xclip` call (the default poll interval).

- [ ] Tune check: re-run with `LINUX_X11_POLL_MS=100 CLIPBOARD_FORCE_X11=1 ./zig-out/bin/clipboard watch` and verify notifications arrive noticeably faster. This confirms the hidden env-var hook works.

### Step 13.8 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/linux/x11.zig native/clipboard/src/platform/linux/mod.zig
git commit -m "feat(x11): subscribe via background poll thread with TARGETS hash"
```

---

## Task 14: Final `platform/linux/mod.zig` wire-up and runtime backend selection

**Goal:** Replace the temporary `CLIPBOARD_FORCE_X11` env-var override with the spec-correct runtime backend selection (Wayland first, X11 fallback), wire `decodePathsForFormat` to `paths.decodeUriList` with a one-entry allowlist, and handle the new error variants in the CLI.

**Files:**
- Modify: `native/clipboard/src/platform/linux/mod.zig`
- Modify: `native/clipboard/src/main.zig`

**Why this task exists as its own step:** Until now, Tasks 7–13 have used `CLIPBOARD_FORCE_X11` so each backend could be verified in isolation. This task removes that hack and installs the real, spec-compliant initialization. The design doc calls this out in the "Runtime backend selection" section: a single `std.once.Once` that probes Wayland first, falls back to X11, and remembers the choice for the lifetime of the process.

### Step 14.1 — Write a failing test for `decodePathsForFormat` allowlist (pure Zig, no display server)

- [ ] Add a Zig unit test to `platform/linux/mod.zig` that verifies `decodePathsForFormat` returns `UnsupportedFormat` for anything except `text/uri-list`. This test should run on macOS too (it only exercises the allowlist branch, not the actual backend):

```zig
test "linux decodePathsForFormat allowlist rejects non-uri-list" {
    if (builtin.os.tag != .linux) return; // no-op on macOS
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        ClipboardError.UnsupportedFormat,
        decodePathsForFormat(allocator, "text/plain"),
    );
}
```

### Step 14.2 — Run the test to verify it fails

- [ ] Run: `cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager/native/clipboard && zig build test`

Expected on Linux: FAIL — `decodePathsForFormat` is still a stub from Task 7.
Expected on macOS: the test is a no-op (guarded by `builtin.os.tag`), passes vacuously.

### Step 14.3 — Remove the `CLIPBOARD_FORCE_X11` override from `initBackends`

All of the type declarations, dispatch functions, and backend wiring already exist in `mod.zig` from Tasks 7, 8, 10, 11, 12, 13. This task is a **targeted edit**, not a rewrite — the only behavior change is dropping the env-var override so Wayland-first / X11-fallback runs unconditionally.

- [ ] In `native/clipboard/src/platform/linux/mod.zig`, find the `initBackends` function added in Task 11.6 (which currently reads `CLIPBOARD_FORCE_X11`) and replace it with the spec-correct version:

```zig
fn initBackends() void {
    // Wayland first — the spec's "Runtime backend selection" section.
    wayland_ready = wayland.tryConnect(backend_allocator);
    if (wayland_ready) {
        wayland.on_selection_hook = &fanout;
        return;
    }

    // Fall back to X11 if Wayland wasn't available. `x11.tryOpenDisplay`
    // returns false (not an error) on missing DISPLAY or connection refusal.
    x11_ready = x11.tryOpenDisplay(backend_allocator);
}
```

- [ ] Verify no other references remain. Use the Grep tool (not the shell `grep`) to search for `CLIPBOARD_FORCE_X11` across `native/clipboard/src/`. Expected: zero matches. If any remain, fix them — the only intended use was the temporary switch inside `initBackends`.

### Step 14.3b — Wire `decodePathsForFormat` to `paths.decodeUriList`

- [ ] In `native/clipboard/src/platform/linux/mod.zig`, find the `decodePathsForFormat` stub from Task 7 (which returns `NoDisplayServer`) and replace it with:

```zig
// ---------------------------------------------------------------------------
// Path decoding for file-reference formats (Linux: text/uri-list only)
// ---------------------------------------------------------------------------

const file_ref_allowlist = [_][]const u8{"text/uri-list"};

fn isFileRefFormat(format: []const u8) bool {
    for (file_ref_allowlist) |allowed| {
        if (std.mem.eql(u8, format, allowed)) return true;
    }
    return false;
}

pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) ![]const []const u8 {
    if (!isFileRefFormat(format)) return ClipboardError.UnsupportedFormat;

    const raw = (try readFormat(allocator, format)) orelse return ClipboardError.FormatNotFound;
    defer allocator.free(raw);

    return paths.decodeUriList(allocator, raw);
}
```

- [ ] Make sure the `paths` import exists at the top of `mod.zig`. If it doesn't, add:

```zig
const paths = @import("../../paths.zig");
```

Importing `paths.zig` is NOT circular because `paths.zig` is pure Zig and doesn't depend on `clipboard.zig` or any platform file.

### Step 14.4 — Run the Zig test again to verify it passes

- [ ] Run: `cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager/native/clipboard && zig build test`

Expected: all tests pass on both macOS and Linux.

### Step 14.5 — Handle the new error variants in `main.zig`

- [ ] In `native/clipboard/src/main.zig`, find the top-level error-handling `switch` / catch that maps `ClipboardError` values to exit codes and stderr messages. Add explicit arms for the three Linux-introduced errors:

- `ClipboardError.NoDisplayServer` → stderr: `"error: no display server available (is $WAYLAND_DISPLAY or $DISPLAY set?)"`, exit code `2`
- `ClipboardError.SubscribeFailed` → stderr: `"error: clipboard subscribe unsupported on this platform or backend"`, exit code `2`
- `ClipboardError.MalformedUriList` → stderr: `"error: malformed text/uri-list payload on clipboard"`, exit code `3`

(Any transient Linux display-server failures — poll errors, socket hangups, etc. — are mapped to the existing `ClipboardError.PasteboardUnavailable` variant by the Linux backends, so that arm will already cover them.)

Match whatever exit-code convention the rest of `main.zig` already uses — if it uses `3` for "malformed clipboard data" elsewhere, reuse it; otherwise pick sensibly.

### Step 14.6 — Build for both targets and check exit codes

- [ ] macOS build:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager/native/clipboard
zig build
./zig-out/bin/clipboard read --as-path
```

Expected: works as it did before Phase B. `--as-path` still goes through the macOS allowlist and decodes pasteboard file URLs.

- [ ] Linux build on Ubuntu VM:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager/native/clipboard
zig build -Dtarget=native-linux
./zig-out/bin/clipboard read --as-path
```

Expected: on sway → hits the Wayland backend and reads `text/uri-list`. On Xorg → falls back to X11. On a TTY with no display → exits with code 2 and the `"no display server available"` message.

### Step 14.7 — Commit

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add native/clipboard/src/platform/linux/mod.zig native/clipboard/src/main.zig
git commit -m "feat(linux): runtime backend selection (Wayland first, X11 fallback)"
```

---

## Task 15: End-to-end smoke tests across four environments

**Goal:** Run the full smoke-test checklist (L1–L14 + M1–M3) from the spec across all four target environments and record the results.

**Files:**
- Create: `docs/superpowers/plans/2026-04-08-clipboard-linux-port-smoke-results.md`
- (No source changes in this task — it's a verification and documentation task.)

**Scope clarification:** This task is a pure verification pass. If any check fails, **stop** and open a bug fix task back in the appropriate earlier task's area (write the fix on top of Task 14, don't retroactively rewrite Tasks 7–14). The goal is to get an honest picture of what works before Task 16 pre-merge verification.

### Step 15.1 — Prepare the four test environments

- [ ] Confirm you have access to each of the four environments the spec calls out:

1. **sway** — Ubuntu 24.04 LTS in a UTM VM, sway compositor running, `$WAYLAND_DISPLAY` set, `$DISPLAY` unset.
2. **GNOME + XWayland** — Same VM or a second VM, GNOME Wayland session, which runs XWayland for X11 clients.
3. **Xorg (pure X11)** — Ubuntu 24.04 LTS boot option or second VM with GDM "Ubuntu on Xorg" session, so both `$DISPLAY` is set and `$WAYLAND_DISPLAY` is NOT set.
4. **macOS** — the host machine, regression target.

If you do not have all four: document which are unavailable at the top of the results file (Step 15.2), finish the remaining ones, and flag missing coverage as an open question for Task 16.

### Step 15.2 — Create the results file with the smoke-test template

- [ ] Create `docs/superpowers/plans/2026-04-08-clipboard-linux-port-smoke-results.md` with the following template. Fill in the Phase column as each test runs.

```markdown
# Clipboard Linux Port — Smoke Test Results

Date: YYYY-MM-DD
Branch: clipboard-linux-port
Commit: <output of git rev-parse HEAD>

## Environments Tested

- [ ] sway (Wayland only, `wlr-data-control`)
- [ ] GNOME + XWayland (Wayland for GNOME apps, X11 for legacy)
- [ ] Xorg (pure X11)
- [ ] macOS (regression)

If any environment was skipped, explain why here:

## Linux Test Matrix (L1–L14)

| ID | Test | sway | GNOME+XWayland | Xorg | Notes |
|----|------|------|----------------|------|-------|
| L1 | `clipboard read` returns text after `wl-copy hello` / `xclip -i` | | | | |
| L2 | `clipboard read` returns text/plain when another app copies text | | | | |
| L3 | `clipboard read` returns text/html when a browser copies styled text | | | | |
| L4 | `clipboard read` returns an image byte slice when a screenshot is copied | | | | |
| L5 | `clipboard write --text` makes the bytes readable by `wl-paste` / `xclip -o` | | | | |
| L6 | `clipboard write` with multiple formats offers all formats to consumers | | | | |
| L7 | `clipboard watch` prints a change event after each external copy | | | | |
| L8 | `clipboard watch` survives a 30-second quiet period without dropping | | | | |
| L9 | `clipboard read --as-path` decodes a single `file://` URI | | | | |
| L10 | `clipboard read --as-path` decodes a multi-path `text/uri-list` | | | | |
| L11 | `clipboard read --as-path` on `text/plain` returns `UnsupportedFormat` exit | | | | |
| L12 | `clipboard read --as-path` on a malformed uri-list returns `MalformedUriList` exit | | | | |
| L13 | `clipboard read` in a TTY session with no $DISPLAY/$WAYLAND_DISPLAY returns `NoDisplayServer` exit | | | | |
| L14 | `clipboard watch` runs for 5 minutes under a Ctrl+C interrupt and shuts down cleanly | | | | |

## macOS Regression (M1–M3)

| ID | Test | Result | Notes |
|----|------|--------|-------|
| M1 | `clipboard read --as-path` still decodes `public.file-url` | | |
| M2 | `clipboard read --as-path` still decodes `NSFilenamesPboardType` multi-file | | |
| M3 | `clipboard watch` still fires on `NSPasteboardDidChangeNotification` and/or polling fallback | | |

## Issues Found

(List any failures here with reproducer steps. Each one either becomes a fix commit before merging, or a "deferred to follow-up" note.)
```

### Step 15.3 — Run the sway matrix

- [ ] Boot the sway VM. From a terminal in the VM, run each L-test in order. Record PASS/FAIL in the sway column of the matrix. Useful companion commands:

```bash
# Copy text from outside our CLI
echo "hello sway" | wl-copy

# Copy a single file URI
printf 'file:///etc/hostname\n' | wl-copy --type text/uri-list

# Copy a multi-path uri-list
printf 'file:///etc/hostname\r\nfile:///etc/os-release\r\n' | wl-copy --type text/uri-list

# Verify what wl-paste sees
wl-paste
wl-paste --list-types
```

- [ ] For L13 (no display server), drop to a VT with Ctrl+Alt+F3, log in, and run:

```bash
unset WAYLAND_DISPLAY DISPLAY
./clipboard read
echo "exit=$?"
```

Expected: exit code 2, error about no display server.

### Step 15.4 — Run the GNOME + XWayland matrix

- [ ] Boot into a GNOME Wayland session. Run the same L-tests. Pay particular attention to L5/L6 — this environment is where backend mismatch issues are most likely to show up, because GNOME native apps speak Wayland while older apps (e.g. xterm) speak X11 via XWayland. Since our library only speaks one protocol at a time (the one selected at process start), this is an intentional limitation documented in the spec. Verify:

- When `clipboard write --text` runs under GNOME Wayland, `wl-paste` sees it.
- When `clipboard write --text` runs under GNOME Wayland, `xclip -o` does NOT see it (expected — we wrote on Wayland, not XWayland).
- Document the asymmetry in the Notes column for L5 and L6.

### Step 15.5 — Run the Xorg matrix

- [ ] Boot into the "Ubuntu on Xorg" GDM session. Run the same L-tests. The goal here is proving the X11 backend works end-to-end without the `CLIPBOARD_FORCE_X11` crutch (it should be gone after Task 14). Verify:

- `./clipboard read` prints text copied via `xclip -i`
- `./clipboard write --text foo` is pastable in `xsel -b`
- `./clipboard watch` fires once per `xclip -i` write

### Step 15.6 — Run the macOS regression matrix

- [ ] Back on the macOS host, build and run the M1–M3 checks. These should all still work — Phase B is additive, not a rewrite — but this is how we prove nothing regressed during the Linux work.

### Step 15.7 — Evaluate results and decide

- [ ] Count the failures in the matrix. One of:

  - **Zero failures:** Proceed directly to Task 16 (pre-merge verification).
  - **Failures exist but all are scope-creep (e.g. "text/html sometimes not offered in GNOME"):** Document under "Issues Found" with either a fix commit reference or a "deferred" note, then proceed to Task 16.
  - **Failures exist in L1/L2/L5/L7/L9 (core paths):** Stop. Write a fix commit on top of Task 14's branch head, re-run the affected smoke tests, and update the matrix.

### Step 15.8 — Commit the results file

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git add docs/superpowers/plans/2026-04-08-clipboard-linux-port-smoke-results.md
git commit -m "docs(smoke): record Linux port smoke test results"
```

---

## Task 16: Pre-merge verification checklist

**Goal:** Run the final pre-merge checks — full test suite on both platforms, build warnings, binary size sanity, and a clean-checkout reproducibility pass — then produce the final "ready-to-merge" commit.

**Files:**
- (No source changes expected. If any of these checks fail, the fix goes in its own commit before this task's final "all green" commit.)

### Step 16.1 — Full Zig test suite on macOS

- [ ] Run:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager/native/clipboard
zig build test 2>&1 | tee /tmp/zig-test-macos.log
```

Expected: every test passes. `paths.zig` should now have ~32 tests (16 original + 16 from Task 1's `decodeUriList`), and the stub allowlist tests from Task 14 should be covered.

Record the number of tests that ran. If anything was skipped (e.g. a Linux-only test compiled out on macOS), note it.

### Step 16.2 — Full Zig test suite on Linux

- [ ] On the Ubuntu VM:

```bash
cd ~/clipboard-manager/native/clipboard
zig build test 2>&1 | tee /tmp/zig-test-linux.log
```

Expected: every test passes. Because `paths.zig` is pure Zig, all 32 path tests should run on Linux as well, plus whatever platform-specific unit tests you added in Tasks 7–14 that aren't gated behind a display-server requirement.

### Step 16.3 — Build with warnings surfaced

- [ ] Run a clean build on macOS with a stricter flag set and check for any warnings or deprecation notices:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager/native/clipboard
rm -rf zig-out zig-cache
zig build 2>&1 | tee /tmp/zig-build-macos.log
grep -E "warning|note" /tmp/zig-build-macos.log || echo "no warnings"
```

- [ ] Same on Linux:

```bash
cd ~/clipboard-manager/native/clipboard
rm -rf zig-out zig-cache
zig build 2>&1 | tee /tmp/zig-build-linux.log
grep -E "warning|note" /tmp/zig-build-linux.log || echo "no warnings"
```

Expected: "no warnings" on both. If warnings appear, triage: silence them if spurious (unused-but-intentional vars get `_ = foo`), fix them if meaningful.

### Step 16.4 — Binary size sanity

- [ ] Check binary sizes after a clean release build on both platforms:

```bash
# macOS
zig build -Doptimize=ReleaseSafe
ls -l zig-out/bin/clipboard
```

```bash
# Linux
zig build -Doptimize=ReleaseSafe
ls -l zig-out/bin/clipboard
```

Expected: both under 2 MB. If the Linux binary is substantially larger (> 5 MB), something is statically linking that shouldn't be — investigate before merging.

### Step 16.5 — Clean-checkout reproducibility pass

- [ ] From a throwaway directory, clone the working branch and build from scratch to prove nothing depends on local state:

```bash
cd /tmp
rm -rf clipboard-manager-verify
git clone /Users/georgemandis/Projects/recurse/2026/clipboard-manager clipboard-manager-verify
cd clipboard-manager-verify
git checkout <linux-port-branch-name>
cd native/clipboard
zig build test
zig build
./zig-out/bin/clipboard read || true
```

Expected: all tests pass, build succeeds, `read` either prints the clipboard or errors with the expected `NoDisplayServer`/empty message. The point of this step is proving the repo builds for someone with no setup other than Zig 0.15.2 + the `apt install` prerequisites.

### Step 16.6 — Confirm spec compliance by reading the design doc side by side

- [ ] Open `docs/superpowers/specs/2026-04-08-clipboard-linux-port-design.md` and walk through each section. For every concrete design decision called out in the spec, confirm the final code matches. Key compliance points to double-check:

- [ ] Wayland backend uses `zwlr_data_control_unstable_v1` (not `wl_data_device`)
- [ ] Wayland `writeFormat` is fire-and-forget through `zwlr_data_control_source_v1.send`
- [ ] X11 `writeFormat` is synchronous with a 5-second service loop and 500ms grace period
- [ ] X11 `subscribe` polls at 500ms by default, hashes TARGETS every tick regardless of owner change
- [ ] Runtime backend selection: Wayland first, X11 fallback, decided once via `std.once.Once`
- [ ] Subscribe: `SubscribeHandle.id == 0` reserved as sentinel
- [ ] Subscribe: polling thread is NOT stopped when last subscriber unsubscribes (process-exit-only)
- [ ] Subscribe: fanout takes a snapshot under the mutex then releases before invoking callbacks
- [ ] `decodePathsForFormat` on Linux allowlist is exactly `{ "text/uri-list" }`
- [ ] `paths.decodeUriList` handles RFC 2483 (percent decoding, CRLF separators, `#` comment lines)
- [ ] macOS CLI allowlist check is now C-strict (no legacy `isAllowlistedFileRef` helper, no defense-in-depth catch arm)
- [ ] New errors: `NoDisplayServer`, `SubscribeFailed`, `MalformedUriList` — all mapped to sensible exit codes in `main.zig`

If any box is unchecked after the walk-through, stop and fix it on a follow-up commit before finishing this task.

### Step 16.7 — Final "all green" commit

- [ ] If you found and fixed issues in any of the steps above, each fix is its own commit — do NOT squash them. Then add a single final empty-ish commit that records the verification pass itself:

```bash
cd /Users/georgemandis/Projects/recurse/2026/clipboard-manager
git commit --allow-empty -m "chore(linux-port): Phase B verification complete

All smoke tests green across sway, GNOME+XWayland, Xorg, and macOS.
Zig test suite passes on both platforms. Spec compliance verified.
Ready to merge to main."
```

### Step 16.8 — Hand off to finishing-a-development-branch

- [ ] Invoke the `superpowers:finishing-a-development-branch` skill to choose how this work gets merged (local merge, PR, or keep-as-is). That skill handles the rest of the merge workflow.

---

## Plan Review Loop

Once the plan file above is fully written, dispatch a `plan-document-reviewer` subagent with:

- Path to the plan document: `docs/superpowers/plans/2026-04-08-clipboard-linux-port.md`
- Path to the spec document: `docs/superpowers/specs/2026-04-08-clipboard-linux-port-design.md`

Provide precisely the review context — not session history. If the reviewer flags issues, fix them in the plan file and re-dispatch until approved. Max 3 iterations; surface to human if not converged.

## Execution Handoff

After the plan review loop is approved, tell the user:

> Plan complete and saved to `docs/superpowers/plans/2026-04-08-clipboard-linux-port.md`. Two execution options:
>
> **1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
>
> **2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.
>
> Which approach?

- If **Subagent-Driven**: use `superpowers:subagent-driven-development`, one fresh subagent per task, two-stage review (spec compliance then code quality) after each.
- If **Inline Execution**: use `superpowers:executing-plans`, batch execution with checkpoints for review.







