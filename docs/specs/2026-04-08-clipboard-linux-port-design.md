# Clipboard Library Linux Port Design Spec

**Date:** 2026-04-08
**Status:** Proposed
**Related:** `2026-04-06-zig-clipboard-library-design.md`, `2026-04-07-clipboard-read-as-path-design.md`

## Goal

Add Linux as a first-class platform to the native clipboard library and CLI, alongside the existing macOS implementation. The library currently guards non-macOS builds with `@compileError` in `src/clipboard.zig`; this spec removes that guard for Linux and ships two native display-server backends (Wayland via `wlr-data-control-unstable-v1` and X11 via `libX11`) selected at runtime. As a side effect, the spec introduces a new event-driven `subscribe` / `unsubscribe` primitive to the Zig library and CLI — necessary because Linux's change-detection models are fundamentally different from macOS's polling-based `changeCount`, and forcing polling everywhere would waste Wayland's real event model.

Windows remains out of scope. This spec deliberately lays groundwork for a future Windows port without committing to any Windows-specific design decisions.

## Non-Goals

Explicitly out of scope for this spec:

- **Windows support.** A separate spec will tackle `platform/windows.zig` after the Linux port and FFI v2 land. This spec should not introduce abstractions that constrain the Windows design, but also should not speculate about what Windows will need.
- **FFI changes.** `src/lib.zig` (the C ABI layer that Bun FFI calls into for the Schrodinger app) is not modified. Schrodinger continues polling `clipboard_change_count` via the existing FFI exactly as it does today. Exposing `subscribe` across the C ABI is a follow-up spec ("FFI v2"), which is the highest-priority next step after this port ships.
- **Automated integration tests on Linux.** Standing up a headless compositor (sway or Xvfb) in CI is a separate engineering project. This spec specifies manual smoke-test environments and a pre-merge checklist; automated end-to-end tests are deferred.
- **GitHub Actions or other CI.** Native builds on developer machines are the mechanism for verifying both platforms during this port. CI is a follow-up that can land once the Linux port has stabilized.
- **Cross-compilation from macOS to Linux.** Zig supports it in principle, but cross-compiling against `libX11` and `libwayland-client` headers requires a Linux sysroot setup that is distracting and not useful when a Linux VM is available for real verification.
- **Format identifier translation.** The library takes and returns platform-native format strings as-is. On macOS, `public.utf8-plain-text`; on Linux, `text/plain;charset=utf-8`. No portable abstraction, no translation layer. Translation, if needed, belongs in the product layer (Schrodinger), not the library.
- **X11 daemonization for `clipboard write`.** Unlike `xclip`, this library does not fork a background process to keep X11 selection ownership alive after the CLI exits. `clipboard write` on X11 is synchronous: it waits for a reader (typically a clipboard manager) to grab the data, then exits. If no clipboard manager is running, the write evaporates with the process. This is documented as an X11 caveat; it is not a bug to fix.
- **X11 `PRIMARY` or `SECONDARY` selections.** Only the `CLIPBOARD` selection (the Ctrl+C/Ctrl+V one) is supported. Middle-click paste (`PRIMARY`) and the obsolete `SECONDARY` are out of scope.
- **GNOME-specific Wayland clipboard integration.** GNOME/Mutter deliberately does not implement `wlr-data-control` (they consider unprivileged clipboard reads a security issue). This spec does not work around that gap — GNOME users transparently fall through to the X11 backend via XWayland, which handles their use case. A GNOME-native Wayland backend via the GNOME Shell D-Bus API or similar is not part of this work.
- **Clipboard manager semantics (history, re-ownership, serving stashed data).** The library's job is "list/read/write the current clipboard." Clipboard-manager behavior — remembering past contents, serving them after the original writer has exited, claiming selection ownership on behalf of dead writers — is a product concern for Schrodinger, not a library concern. Schrodinger will eventually need its own X11 selection-ownership management to function as a Linux clipboard manager; that may or may not motivate a future library primitive.
- **Auto-reconnection on display-server death.** If the Wayland compositor restarts or the X server dies while the library is in use, subsequent calls return `error.PasteboardUnavailable`. The library does not attempt to reconnect, reselect backends, or recover subscription state. The caller (CLI or Schrodinger) is responsible for restarting if needed.

## Background

The native clipboard library at `native/clipboard/` is a Zig library + CLI + C ABI shared library (`libclipboard.dylib`) used by the Schrodinger clipboard manager via Bun FFI. The current state:

- **`src/clipboard.zig`** — thin public-API dispatch layer. One `switch (builtin.os.tag)` over platform implementations. Currently only `.macos` is implemented; everything else hits `@compileError`.
- **`src/platform/macos.zig`** — the only platform implementation today. Built on `objc.zig` + AppKit/Foundation. Exports `listFormats`, `readFormat`, `writeFormat`, `writeMultiple`, `clear`, `getChangeCount`, `decodePathsForFormat`.
- **`src/objc.zig`** — Obj-C bridge. macOS-only by design.
- **`src/paths.zig`** — pure Zig helpers for percent-decoding and parsing `file://` URLs. No OS dependencies. Covered by 16 hand-written unit tests that run on any host via `zig build test`.
- **`src/main.zig`** — the CLI. Imports `clipboard.zig` only; does not touch `platform/*` or `objc.zig` directly.
- **`src/lib.zig`** — the C ABI shared library. Imports `clipboard.zig` only. Exports functions like `clipboard_read_format_ex`, `clipboard_change_count`, etc. Consumed by Schrodinger via Bun's FFI.
- **`build.zig`** — single-target build. Unconditionally links `objc` (system library) and `AppKit` (framework). No conditional logic for other platforms yet.

The layering discipline in place — `clipboard.zig` is a one-liner dispatch layer, `platform/macos.zig` holds all macOS-specific code, `paths.zig` is OS-free, `main.zig`/`lib.zig` never reach below `clipboard.zig` — is exactly the structure needed to add a second platform without rewrites. This spec exercises that design.

### Why Linux now, and not Windows

The long-term goal is all three platforms. Linux is first because:

1. The hardest abstraction question in the whole port ("what does change detection look like when the OS doesn't give you a polling counter?") is answered more cleanly by Linux than by Windows. Wayland has real events (`wlr-data-control` selection notifications); X11 has explicit polling. Getting `subscribe` right on these two forces the API design to be honest about event vs polling — Windows has both a polling counter (`GetClipboardSequenceNumber`) *and* an event-driven notifier (`AddClipboardFormatListener`), so it could paper over a bad abstraction.
2. George is at Recurse Center specifically to work on systems-level tools. Wayland protocol handling and Xlib selection ownership are the interesting, learnable systems material. Windows clipboard internals are also interesting but are a single-platform sidequest; better to do them as a focused follow-up.
3. Schrodinger's target users overlap heavily with Linux-on-desktop users (developers, tinkerers, people who live in terminals). Linux support unlocks a real user base.

## Design

### Architecture

Add Linux as a new branch in the existing dispatch layer. Linux internally contains two backends (Wayland and X11) hidden behind a single `platform/linux/mod.zig` facade that satisfies the same interface as `platform/macos.zig`. Backend selection happens once at init time and is stored in module-level state.

```
                              main.zig / lib.zig
                                     │
                          (imports only clipboard.zig)
                                     │
                                     ▼
                              src/clipboard.zig
                          switch (builtin.os.tag) {
                              .macos => platform/macos.zig
                              .linux => platform/linux/mod.zig
                          }
                                     │
                  ┌──────────────────┴──────────────────┐
                  │                                     │
                  ▼                                     ▼
          platform/macos.zig                 platform/linux/mod.zig
           (unchanged except          (backend selection + shared
            for subscribe add)         subscribe thread + dispatch)
                                              │
                                              │  (at runtime, either or)
                                              │
                            ┌─────────────────┴─────────────────┐
                            │                                   │
                            ▼                                   ▼
                  platform/linux/wayland.zig      platform/linux/x11.zig
                   (wlr-data-control proto)        (Xlib selections)
                            │                                   │
                            └─────────────────┬─────────────────┘
                                              │
                                              ▼
                                       src/paths.zig
                                  (pure Zig, no OS deps;
                                   decodeFileUrl, percentDecode,
                                   NEW: decodeUriList)
```

**Invariants enforced by the architecture:**

- `clipboard.zig` is exactly one `switch` plus one-line forwarders. No conditional logic. Adding Linux adds exactly one `case` and (for the new `subscribe` API) two new forwarders.
- `main.zig` and `lib.zig` only see `clipboard.zig`. They never import any `platform/*` file directly. They never know which Linux backend is active at runtime.
- `platform/linux/mod.zig` is the only file that knows two backends exist. It owns backend selection at init time, the active-backend state, and (crucially) the subscription registry + background thread shared across backends.
- `platform/linux/wayland.zig` and `platform/linux/x11.zig` are peer implementations. Neither imports the other. Neither is aware of the other. Both present the same public interface to `mod.zig`.
- `paths.zig` stays OS-free. The new `decodeUriList` helper is added there, not in `platform/linux/*`, because parsing a URI list is a platform-agnostic operation that just happens to be needed by Linux first.
- `objc.zig` is untouched. It is imported only by `platform/macos.zig`.

**One new structural divergence:** `platform/linux/` is the first subdirectory under `platform/`. macOS stays as a single file because macOS has one backend. This asymmetry is deliberate — the structure reflects reality (Linux has two display-server backends; macOS has one).

### Format identifiers: native MIME, zero translation

On Linux, all clipboard format identifiers are MIME types, matching what both Wayland and X11 natively use:

- `text/plain;charset=utf-8` — UTF-8 plain text (the Linux equivalent of macOS's `public.utf8-plain-text`)
- `text/html` — HTML
- `text/uri-list` — RFC 2483 URI list (the file-reference format; Linux equivalent of `public.file-url`)
- `image/png`, `image/jpeg`, `image/tiff` — image formats
- `application/x-whatever` — vendor-specific formats

The library does **not** translate between macOS UTIs and Linux MIME types. Callers passing a format string to `clipboard read` or `clipboard write` are expected to know which platform they're on and use the appropriate identifier. This is the design contract.

Rationale: the library's purpose is to be a thin bridge to the native clipboard, not a format engine. Translation is a compatibility layer that grows complexity fast — every mapping is a judgment call, byte-level reformatting is sometimes required (e.g. `CF_HTML`'s header prefix on Windows), and edge cases proliferate. Once translation is in, the library owns every format's cross-platform semantics forever. Keeping the library native-only means each platform file is small, focused, and correct for that platform, and the hard cross-platform decisions can be made at the product layer (Schrodinger) where the context is clearer.

Documentation of the platform format differences — a reference table mapping UTIs ↔ MIME ↔ CF codes, with the wrinkles (CRLF in `CF_HTML`, `NSFilenamesPboardType` having no Linux equivalent, etc.) — is planned as a follow-up documentation task after the Windows port lands. It is not part of this spec.

### Backend selection on Linux

At the first call to any library function that needs the display server (`listFormats`, `readFormat`, `writeFormat`, `clear`, `decodePathsForFormat`, `subscribe`, or `getChangeCount` once the subscription thread is running), `platform/linux/mod.zig` runs `ensureInit()`, which performs backend selection exactly once using a `std.once.Once` guard:

1. **Try Wayland first.** Call `wayland.tryConnect()`. Internally this:
   - Checks the `WAYLAND_DISPLAY` environment variable. If unset → return `false`.
   - Calls `wl_display_connect(null)`. If it returns null → return `false`.
   - Binds to the registry and does one `wl_display_roundtrip` to populate it.
   - Checks that `zwlr_data_control_manager_v1` is advertised. If not → disconnect, return `false`.
   - If all pass → store the `wl_display` + `zwlr_data_control_manager_v1` handles in `wayland.zig`'s module state, return `true`.
2. **If Wayland failed, try X11.** Call `x11.tryOpenDisplay()`. Internally:
   - Calls `XOpenDisplay(null)`. If it returns null → return `false`.
   - Calls `XInternAtom(display, "CLIPBOARD", False)` to precache the CLIPBOARD atom and verify the display is responsive.
   - Creates a dedicated invisible window (`XCreateSimpleWindow`) for selection requests/conversions.
   - Stores the `Display*` + window ID in `x11.zig`'s module state. Returns `true`.
3. **If both failed:** set `init_error = error.NoDisplayServer`. Every subsequent call returns that error.

Once a backend is selected, it is never re-evaluated. There is no runtime backend switching.

**Why runtime selection and not compile-time:**

Compile-time selection (e.g. `-Dbackend=wayland` flag) would force the user to know their environment at build time, which doesn't work for distribution: a single binary shipped to Linux users needs to run on GNOME sessions (X11 via XWayland), on sway (native Wayland), and on anyone's machine regardless of their display stack. Runtime selection is the only option that produces a single portable binary.

### The `subscribe` / `unsubscribe` primitive

The library gains a new public API:

```zig
pub const SubscribeCallback = *const fn (userdata: ?*anyopaque) void;

pub const SubscribeHandle = struct {
    id: u64,
};

// `id == 0` is reserved as the "invalid handle" sentinel. `next_subscriber_id`
// starts at 1 (see registry below). This is what makes `unsubscribe` safe to
// call on a zero-initialized `SubscribeHandle{}` — it matches no live entry
// in the registry and silently no-ops.

/// Register a callback that fires on every clipboard change. Spawns a
/// background thread on first subscription; reuses it for subsequent
/// subscribers.
///
/// The callback is invoked from the background thread, NOT from the
/// thread that called subscribe. Callers must ensure their callback is
/// thread-safe with respect to any shared state they touch.
///
/// On Wayland (Linux), change detection is event-driven via
/// zwlr_data_control_device_v1::selection events.
///
/// On X11 (Linux), change detection is polling-based (500ms default);
/// the callback fires when a change is detected.
///
/// On macOS, change detection uses NSPasteboardDidChangeNotification
/// (also event-driven).
pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle;

/// Remove a subscription. Idempotent: passing a handle that was never
/// subscribed, or was already unsubscribed, is a no-op.
///
/// When the last subscription is removed, the background thread is
/// signaled to shut down and joined. This call does NOT block waiting
/// for the thread to exit; the shutdown happens asynchronously.
pub fn unsubscribe(handle: SubscribeHandle) void;
```

**Allocator lifetime.** The `allocator` passed to `subscribe` is used only
during registration (to grow the subscriber list if needed) and is not
retained past the call. Different subscribers may pass different allocators;
the library does not assume a single allocator across the lifetime of the
subscription thread. The subscriber registry itself lives in a module-level
`std.ArrayListUnmanaged` whose backing memory is owned by whichever allocator
is active at the time of the `append` call. Implementers should use the
caller's allocator for that append and release on `unsubscribe`. Do **not**
stash the allocator in module state.

#### Why subscribe is needed at all

On macOS, `NSPasteboard.changeCount` is an O(1) system-wide counter maintained by the `pboard` daemon. The current `cmdWatch` in `main.zig` polls it every 500ms, compares to the previous value, and introspects the clipboard when it changes. This works because macOS provides the counter.

On Linux there is no equivalent. Two reasons the naive "poll a counter" approach doesn't work:

1. **Wayland has no counter, but does have events.** The `wlr-data-control-unstable-v1` protocol emits a `selection` event on `zwlr_data_control_device_v1` every time the clipboard changes. This is a real, event-driven signal. If we polled some fake counter wrapping these events, we would be throwing away the only efficient change-detection mechanism Wayland offers.
2. **X11 has neither a counter nor a non-polling event.** X11's clipboard model is selection-ownership based: whoever owns the CLIPBOARD selection serves it on request. There is no broadcast notification when ownership changes, unless you are yourself the selection owner (in which case you get `SelectionClear`, but we're not the owner when we're watching). The only way to detect a change as a non-owner is to poll `XGetSelectionOwner` and fetch/hash the contents on every change.

This creates a tension: Wayland wants events, X11 wants polling, macOS has both a counter and a notification center. The cleanest API that fits all three is an event-subscription primitive (`subscribe(callback)`) that the library implements with whatever mechanism is best for the platform. Callers write one code path; the library handles the details.

#### Background thread semantics

On all three platforms, `subscribe` spawns a background thread on first subscription and joins it when the last subscription is removed. The thread body differs per platform:

**Wayland:** Blocks on `poll(2)` over the Wayland FD. When the FD becomes readable, calls `wl_display_dispatch`, which invokes Wayland's own event handlers. Those handlers call into `wayland.zig`'s "selection changed" hook, which calls `mod.zig`'s fanout function, which iterates the subscriber list and invokes each callback. Zero polling; the thread sleeps indefinitely between events.

**X11:** Blocks on `poll(2)` over the X11 FD (obtained via `ConnectionNumber(display)`) with a 500ms timeout. When the timeout expires or an X event arrives, runs one iteration of:

1. Drain pending X events via `XPending` + `XNextEvent`.
2. Get the current CLIPBOARD owner via `XGetSelectionOwner`.
3. Compute a hash of the current clipboard contents (concatenated bytes of every format advertised in TARGETS) and compare to the previous hash, regardless of whether the owner changed. Hashing every tick — not just on owner change — is deliberate: some apps (editors, REPLs) re-copy with the same selection owner window, so gating on owner change alone would miss those updates. Hashing is cheap relative to the 500ms tick rate and the round-trip cost of actually reading the clipboard contents.
4. If the hash differs → call `mod.zig`'s fanout function.

The 500ms default is configurable via a hidden `LINUX_X11_POLL_MS` env var for development/testing; it's not exposed in the public API. Production users don't need to tune it.

**macOS:** Registers an observer for `NSPasteboardDidChangeNotification` on `NSNotificationCenter.defaultCenter`. Runs a `CFRunLoop` in the background thread; when the notification fires, the observer callback calls `mod.zig`'s fanout function. Zero polling. This improves macOS behavior as a side effect of the port: today's `cmdWatch` polls `changeCount` every 500ms; after this spec, it's event-driven.

#### Fanout and thread safety

`platform/linux/mod.zig` (and the equivalent state in `platform/macos.zig`) owns a `std.Thread.Mutex`-protected subscriber registry:

```zig
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

`subscribe` locks the mutex, appends a new subscriber with a fresh `id`, spawns the thread if this is the first subscriber, unlocks, returns the handle. `unsubscribe` locks the mutex, removes the matching entry, and if the list is empty, signals `should_exit` and schedules the thread for join (but does not block). `fanout` (called from the background thread) locks the mutex, copies the callback list into a local buffer, unlocks, then invokes each callback from the buffer — this avoids holding the lock across user code, which could deadlock if a callback calls back into the library.

**Caller contract:** callbacks are invoked from the background thread, not from the thread that called `subscribe`. Callers are responsible for their own thread safety. This is the same contract as every other subscription-based API in systems programming (epoll callbacks, libuv handlers, GCD blocks on a background queue, etc.).

#### `getChangeCount` on Linux

`getChangeCount` on Linux returns a module-level monotonic counter maintained by `mod.zig`:

- Initialized to 0 at process start.
- Incremented by the fanout function every time the background thread detects a clipboard change.
- **Not maintained if no subscription is active.** If `subscribe` has never been called, the counter is always 0. If all subscriptions have been `unsubscribe`d, the counter stops incrementing but retains its last value.
- Reset to 0 on process exit. Not persistent across process lifetimes.

This differs from macOS, where `getChangeCount` returns `NSPasteboard.changeCount` — a system-wide counter maintained by the `pboard` daemon, meaningful even without any subscription. Cross-platform code that wants `getChangeCount` to track changes on Linux must call `subscribe(noop_callback, null)` at startup to keep the background thread running.

**This asymmetry is documented in the public API doc comment for `getChangeCount`, not hidden.** The alternative — auto-starting the background thread on first `getChangeCount` call — was considered and rejected: it creates a surprise side effect where a read-only-looking function starts a thread that cannot be shut down. Explicit is better.

### `decodePathsForFormat` on Linux

On Linux, the file-reference allowlist for `decodePathsForFormat` is exactly one entry: **`text/uri-list`**. This is the RFC 2483 URI list format, used by both Wayland and X11 for file copy-paste. Unlike macOS, Linux has no separate single-file vs multi-file format — `text/uri-list` handles both.

Dispatch in `platform/linux/mod.zig`:

1. Check the allowlist. If `format != "text/uri-list"` → return `error.UnsupportedFormat`. This check happens before any display-server access, same as on macOS.
2. Call the active backend's `readFormat(allocator, "text/uri-list")`. If it returns null → return `error.FormatNotFound`.
3. Call `paths.decodeUriList(allocator, bytes)` to parse the URI list into POSIX paths.
4. Free the raw bytes.
5. Return the decoded path slice (caller owns both the outer slice and each inner string).

The new `decodeUriList` helper lives in `paths.zig` (pure Zig, no OS dependency) and has this signature:

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
) DecodePathError![]const []const u8;
```

The function reuses the existing `decodeFileUrl` (which already handles `file://` prefix verification + percent decoding) and `percentDecode` helpers. It is trivially unit-testable with plain byte slices — no display server involved. Unit tests cover single-file, multi-file, CRLF vs LF, comments, blank lines, percent-encoding, non-file rejection, and malformed input.

### `decodePathsForFormat` allowlist cleanup (C-strict)

The post-implementation review of the `--as-path` spec flagged that the allowlist existed in two places: `file_ref_allowlist` in `platform/macos.zig` and `isAllowlistedFileRef` in `main.zig`. A defense-in-depth catch arm for `error.UnsupportedFormat` was added post-review (commit `4a134d5`) to cover the "if the two lists drift, at least the user sees a clear message" case.

This spec eliminates the duplication as part of the Linux port:

1. **Delete `isAllowlistedFileRef` from `main.zig`.** The function is no longer needed.
2. **Delete the explicit `error.UnsupportedFormat` catch arm** added in commit `4a134d5`. Its purpose (covering allowlist drift) is gone because the allowlist is now single-sourced.
3. **Generalize the `UnsupportedFormat` message.** The catch-switch in `cmdRead` still needs to handle `error.UnsupportedFormat`, but its message changes from a macOS-specific list of UTIs to a generic one:
   ```
   Error: --as-path does not support this format on this platform
   ```
   This is slightly less specific than the old message, but single-sourcing the allowlist is worth more than the specific error text. Users who want to know what *is* supported can run `clipboard help` or `clipboard list`.
4. **Each `platform/*` file owns its own allowlist exclusively.** `platform/macos.zig` keeps its three entries (`public.file-url`, `NSFilenamesPboardType`, `public.url`). `platform/linux/mod.zig` defines its own one-entry allowlist (`text/uri-list`). Neither platform file exports the allowlist; it's internal.

This cleanup is in scope for this spec because it is *enabled* by the Linux port (the new Linux platform file would otherwise have to duplicate its own entry into `main.zig`'s `isAllowlistedFileRef`), and because it resolves a duplication the post-review flagged as "real but low-current-risk."

### Data flow per operation

#### `readFormat(allocator, format) → ?[]const u8`

**Wayland:**

1. Check that the cached "current selection offer" (maintained by `wayland.zig`'s `data_offer` event handler) advertises the requested MIME type. If not → return `null`.
2. Call `zwlr_data_control_offer_v1::receive(mime_type, write_fd)`, passing the write end of a freshly created pipe.
3. `wl_display_flush` to send the request.
4. Read from the read end of the pipe until EOF, accumulating into an `std.ArrayList(u8)`.
5. Close the pipe, return the collected bytes as an allocator-owned slice.

Blocking read is inherent to the protocol — there is no async alternative. A buggy or slow writer can block us; this is the same behavior as `wl-paste` and every other Wayland clipboard reader. If it becomes a problem in practice, a timeout can be added in a follow-up.

**X11:**

1. Look up the format atom (MIME type → X11 atom) in a per-session atom cache. If absent, `XInternAtom`.
2. `XGetSelectionOwner(CLIPBOARD)`. If `None` → return `null`.
3. `XConvertSelection(CLIPBOARD, target_atom, our_property_atom, our_window, CurrentTime)`.
4. `XFlush`.
5. Wait for a `SelectionNotify` event on our window for up to 2 seconds (via `poll(2)` + `XCheckTypedWindowEvent`). If it doesn't arrive → return `null`.
6. If the event's `property` field is `None` → owner refused the conversion → return `null`.
7. `XGetWindowProperty` on our window to retrieve the bytes.
8. `XDeleteProperty` to clean up.
9. Copy the bytes into an allocator-owned slice and return it.

The 2-second timeout is a defense against misbehaving clipboard owners; it is not tunable and not part of the public API.

#### `writeFormat(allocator, format, data) → void`

**Wayland:**

1. Create a new `zwlr_data_control_source_v1` via `zwlr_data_control_manager_v1::create_data_source`.
2. `zwlr_data_control_source_v1::offer(mime_type)` — announce the MIME type we serve.
3. Register a `send` event handler on the source. When the compositor fires the `send` event (another client is asking for the data), the handler writes `data` to the provided FD and closes it.
4. `zwlr_data_control_device_v1::set_selection(source, serial)` — claim selection ownership.
5. Store the source + data bytes in `wayland.zig`'s module state so the `send` handler has access.
6. `wl_display_roundtrip` — wait up to ~500ms for the compositor to acknowledge the ownership change.
7. Return.

Wayland's `wlr-data-control` is *not* daemonization-requiring like X11. Once the compositor has the selection, it serves the data to future clients on the data source's behalf — our process can exit and the clipboard contents persist. This is the clean side of Wayland's clipboard model.

Caveat: if the compositor queries our `send` handler *after* our process has exited (e.g., because no client ever pasted, and then one does 10 seconds later), it will get nothing. In practice this is rare because compositors typically forward the data to a clipboard manager daemon, which caches it.

**X11 (see X11 write caveat):**

1. Store `data` + format atom in `x11.zig`'s module state.
2. `XSetSelectionOwner(CLIPBOARD, our_window, CurrentTime)`.
3. `XSync` to flush.
4. Verify ownership was actually granted: call `XGetSelectionOwner` immediately after and confirm it returns our window. If it doesn't → `error.WriteFailed`.
5. **Enter the `SelectionRequest` service loop:**
   ```
   loop {
       wait for X event with 5-second timeout
       if timeout expired with no events → error.WriteFailed ("no reader")
       if SelectionClear arrived → someone else took ownership; success, return
       if SelectionRequest arrived → respond via XChangeProperty + SendEvent(SelectionNotify)
           → after responding, continue the loop for a short grace period
             (in case a clipboard manager takes ownership shortly after)
       if we've serviced at least one successful request AND 500ms has passed → return success
   }
   ```
6. Return.

This is the state machine that implements "synchronous CLI write without daemonization." The exit conditions:

- **Success A:** We serviced at least one `SelectionRequest` and then either (a) someone else took ownership (a clipboard manager grabbed it) or (b) 500ms of idle time elapsed. Normal flow on any desktop environment with a clipboard manager.
- **Success B:** Someone took ownership before we even got a request (rare — typically only happens if a clipboard manager is extremely aggressive).
- **Failure:** Five seconds passed with no requests at all. Typically means no clipboard manager and no interactive paste. Return `error.WriteFailed` with the message "clipboard write timed out; no reader (install a clipboard manager?)"

This is intentionally less robust than `xclip`'s fork-and-daemonize behavior. We accept that as the cost of keeping the library process-clean.

#### `writeMultiple(allocator, pairs) → void`

On Wayland, creates a single `zwlr_data_control_source_v1` and calls `offer` once per pair before `set_selection`. Same synchronous acknowledge-and-return flow as `writeFormat`, including the same post-exit caveat: if the compositor queries the `send` handler after our process has exited and no clipboard manager daemon cached the data, the paste will fail silently.

On X11, stores the entire pair set in module state, claims selection ownership once, and the `SelectionRequest` handler checks which target atom is being requested and responds with the matching pair. Same service loop as `writeFormat`, including the same 5-second timeout and "no clipboard manager → write evaporates on exit" caveat.

#### `listFormats(allocator) → [][]const u8`

**Wayland:** Copy the cached format list from `wayland.zig`'s module state (updated automatically by the `data_offer` event handler on every clipboard change). O(1) + allocation cost. No I/O.

**X11:**

1. `XGetSelectionOwner(CLIPBOARD)`. If `None` → return empty slice.
2. `XConvertSelection(CLIPBOARD, TARGETS_atom, our_property_atom, our_window, CurrentTime)`.
3. Wait for `SelectionNotify` (2-second timeout).
4. `XGetWindowProperty` to retrieve the atom list.
5. For each atom, `XGetAtomName` to resolve it to a string.
6. Filter out X11-internal atoms (`TARGETS`, `MULTIPLE`, `TIMESTAMP`, `SAVE_TARGETS`).
7. Return the remaining atom names as allocator-owned strings.

`listFormats` on X11 is a full round-trip per call. This is acceptable — it's not called in a tight loop by any real consumer.

#### `clear() → void`

**Wayland:** Call `zwlr_data_control_device_v1::set_selection(null, serial)` to clear ownership. `wl_display_roundtrip`.

**X11:** `XSetSelectionOwner(CLIPBOARD, None, CurrentTime)`. `XSync`.

Both are synchronous and fast.

### Error handling

The existing `ClipboardError` set in `platform/macos.zig` is extended with new variants for Linux. The unified set lives in `platform/linux/mod.zig`:

```zig
pub const ClipboardError = error{
    // Shared across platforms:
    PasteboardUnavailable,   // display server was reachable at init, now isn't
    NoItems,                 // macOS-only; kept for compat
    WriteFailed,             // write did not complete
    UnsupportedFormat,       // format outside the platform's decodePathsForFormat allowlist
    FormatNotFound,          // format not present on clipboard
    MalformedPlist,          // macOS-only; unused on Linux

    // New for Linux:
    NoDisplayServer,         // no display server could be reached at init
    SubscribeFailed,         // subscribe() failed to start the background thread
    MalformedUriList,        // decodeUriList couldn't parse the bytes
};
```

`clipboard.zig` re-exports the set via `pub const ClipboardError = platform.ClipboardError`.

**Mapping policy:** each backend (`wayland.zig`, `x11.zig`, `macos.zig`) maps its low-level failures to `ClipboardError` variants. Consumers (`clipboard.zig`, `main.zig`, `lib.zig`) only ever see the abstract set. Backends never leak raw `libX11`/`libwayland` error codes.

**New CLI catch arms in `main.zig`:**

```zig
error.NoDisplayServer => try ew.interface.print(
    "Error: no display server available (tried Wayland and X11)\n",
    .{},
),
error.SubscribeFailed => try ew.interface.print(
    "Error: failed to start clipboard subscription\n",
    .{},
),
error.MalformedUriList => try ew.interface.print(
    "Error: failed to decode {s}: malformed URI list\n",
    .{format},
),
```

The existing `error.UnsupportedFormat` arm is kept but its message is generalized (per the C-strict cleanup above). The defense-in-depth arm for `UnsupportedFormat` added in commit `4a134d5` is deleted.

**`PasteboardUnavailable` on Linux:** Returned on any subsequent call after the initial display server connection dies (compositor restart, X server crash, session teardown). The library does not attempt to reconnect. This is a deliberate non-feature — auto-reconnection would require reselecting backends, replaying subscription state, and handling "did the clipboard change during the outage?" ambiguity, none of which is worth the complexity for a rare case. The caller (CLI, or Schrodinger) decides whether to restart or propagate.

**`OutOfMemory`:** Propagates unchanged. Caught by the `else` arm in `main.zig`'s catch-switches and printed as a generic "Error: failed to ...: OutOfMemory".

### `cmdWatch` rewrite

`cmdWatch` in `main.zig` currently polls `getChangeCount` in a loop every 500ms, calling `introspect` when the counter changes. This spec rewrites it to use `subscribe`:

```zig
fn cmdWatch(allocator: Allocator, args: []const []const u8, json_output: bool) !void {
    // interval-ms arg parsing is removed; the library decides how to detect changes

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
    while (true) {
        context.mutex.lock();
        while (!context.pending) {
            context.condition.wait(&context.mutex);
        }
        context.pending = false;
        context.mutex.unlock();

        try introspect(allocator, json_output);
        // Print separator
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

This works identically on every platform. On Wayland and macOS it's truly event-driven (reacts within a few ms of a clipboard change). On X11 it's driven by the library's 500ms polling loop (same effective latency as today, but the polling logic moves out of `main.zig` and into the library).

**SIGINT handling.** The `condition.wait` call inside the main loop is not reliably interruptible by signals on all libcs (glibc may spuriously wake; musl is stricter). The CLI intentionally relies on process termination to tear down the loop — SIGINT kills the process, the kernel reclaims the background thread, and no explicit shutdown sequence runs. This is simpler than trying to plumb a signal handler into the condvar and is acceptable because `cmdWatch` has no state that needs graceful teardown. Implementers should not waste time trying to make Ctrl-C produce a clean exit path here; the current behavior is the intended behavior.

The `--interval` flag is removed. Change-detection cadence is not tunable from the CLI — the library decides. If someone later has a real need for a tunable X11 poll interval, it can come back as a hidden env var.

**Ctrl+C handling:** Zig's default SIGINT handler will still terminate the process, and the process exit will tear down the background thread along with everything else. No explicit signal handler is needed — this matches today's behavior and is the simplest path.

### Build system changes

`build.zig` becomes target-aware:

```zig
const target_os = target.result.os.tag;

switch (target_os) {
    .macos => {
        clipboard_mod.linkSystemLibrary("objc", .{});
        clipboard_mod.linkFramework("AppKit", .{});
    },
    .linux => {
        clipboard_mod.linkSystemLibrary("X11", .{});
        clipboard_mod.linkSystemLibrary("wayland-client", .{});

        // wayland-scanner generates a C header from the wlr-data-control XML;
        // we @cImport the header in wayland.zig. The XML file ships under
        // vendor/wayland-protocols/ (committed to the repo so builds don't
        // depend on system wayland-protocols install paths).
        const wl_scanner = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        wl_scanner.addFileArg(b.path("vendor/wayland-protocols/wlr-data-control-unstable-v1.xml"));
        const wl_header = wl_scanner.addOutputFileArg("wlr-data-control-unstable-v1-client-protocol.h");

        const wl_scanner_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        wl_scanner_code.addFileArg(b.path("vendor/wayland-protocols/wlr-data-control-unstable-v1.xml"));
        const wl_code = wl_scanner_code.addOutputFileArg("wlr-data-control-unstable-v1-protocol.c");

        // The generated .c file is compiled and linked into clipboard_mod.
        clipboard_mod.addCSourceFile(.{ .file = wl_code });
        clipboard_mod.addIncludePath(wl_header.dirname());
    },
    else => {},
}
```

**Vendoring the protocol XML:** the `wlr-data-control-unstable-v1.xml` file is committed to the repo at `vendor/wayland-protocols/`. This avoids depending on the user having `wayland-protocols` installed at a known path (which varies between distros and between native/crossbuild). The XML is small (~8KB) and under the MIT license, so vendoring it is cheap and removes a class of build failures.

**`wayland-scanner` is a required system tool on Linux builds.** Ubuntu ships it in the `libwayland-bin` package. If it's missing, the build fails with a clear error; the spec's implementation plan will include a "install these packages" checklist.

**The `test` step remains pure Zig with no OS dependencies.** `zig build test` runs the `paths.zig` unit tests (including the new `decodeUriList` tests) and does not link or import anything from `platform/*`. This is enforced by the existing split in `build.zig`: `paths_tests` uses only `src/paths.zig` as its root source file.

### Testing

#### Pure unit tests (automated)

Run on every `zig build test` invocation on any host. No OS dependency. New tests in `src/paths.zig` for `decodeUriList`:

1. Single file, LF-terminated → 1 path
2. Single file, CRLF-terminated → 1 path
3. Single file, no trailing newline → 1 path
4. Multiple files, LF-separated → N paths in order
5. Multiple files, CRLF-separated → N paths in order
6. Mixed LF/CRLF → N paths (tolerant)
7. Comment lines (`# ...`) skipped
8. Blank lines skipped
9. Percent-encoded path (spaces) → decoded
10. UTF-8 percent-encoded path → decoded
11. Empty input → empty slice
12. Only comments and blank lines → empty slice
13. Non-file scheme (`http://...`) → `error.NotFileScheme`
14. Mixed file + non-file → `error.NotFileScheme` on the non-file line
15. Malformed URL (no scheme) → `error.NotFileScheme`
16. Invalid percent encoding → `error.InvalidPercentEncoding`

Plus the existing 16 tests for `percentDecode` and `decodeFileUrl`. Target: all `zig build test` invocations on any host pass 32+ tests.

**No unit tests for `platform/linux/*`.** Those files `@cImport` libX11 and libwayland-client, which cannot compile without the libraries present. The pure helpers they depend on are covered by the `paths.zig` tests.

#### Manual platform-specific smoke tests

Documented as a test matrix in the spec and run manually by George after implementation lands.

**Environment 1: Ubuntu 24.04 on sway (native Wayland).**

Tests the Wayland backend path end-to-end.

- **L1.** `clipboard list` on empty clipboard → empty list, exit 0.
- **L2.** `wl-copy "hello"` then `clipboard read text/plain;charset=utf-8` → `hello`, exit 0.
- **L3.** `clipboard write text/plain --data "from cli"` then `wl-paste` → `from cli`.
- **L4.** `clipboard clear` then `wl-paste` → empty.
- **L5.** `clipboard watch` in one terminal; `wl-copy "a"` and `wl-copy "b"` in another → two change events. Verify reaction time < 100ms (confirms event-driven, not polling).
- **L6.** `wl-copy --type text/uri-list "file:///tmp/foo"` then `clipboard read text/uri-list --as-path` → `/tmp/foo`, exit 0.
- **L7.** Multi-file: `wl-copy --type text/uri-list "$(printf 'file:///tmp/a\nfile:///tmp/b\n')"` then `clipboard read text/uri-list --as-path` → two lines. With `-0` → NUL-separated. Both exit 0.
- **L8.** `wl-copy --type text/uri-list "https://example.com/"` then `clipboard read text/uri-list --as-path` → `error.MalformedUriList` message, exit 1.
- **L9.** `clipboard read text/plain --as-path` → "does not support this format on this platform", exit 1.

**Environment 2: Ubuntu 24.04 on GNOME Wayland (X11 via XWayland fallback).**

Tests backend selection's fallback path. GNOME does not advertise `wlr-data-control`, so the library should select X11.

- **L10.** `clipboard list` → works via XWayland/X11. Confirm via log line or debug print that the X11 backend was chosen, not Wayland.
- **L11.** Copy from Firefox, `clipboard read text/plain` → correct content.
- **L12.** `clipboard write text/plain --data "test"` → paste into Firefox succeeds *if* a clipboard manager is running. Document actual result.
- **L13.** `clipboard watch` → detects changes from both XWayland apps (Firefox) and native Wayland apps (GTK4 apps, if any are installed).

**Environment 3: Ubuntu 24.04 on Xorg (pure X11).**

Tests the X11 backend without any Wayland involvement. Log into "Ubuntu on Xorg" at the login screen.

- **L14.** All of `clipboard list`, `read`, `write`, `clear`, `watch` work. `--as-path` works on a `text/uri-list` copied from a file manager.

**Environment 4: macOS regression.**

Tests that nothing in the existing macOS path broke, including the new macOS `subscribe` implementation.

- **M1.** All existing macOS smoke tests pass unchanged: `clipboard list`, `clipboard read public.utf8-plain-text`, `clipboard read public.file-url --as-path` with a Finder copy, `clipboard watch`.
- **M2.** `clipboard watch` on macOS reacts within ~100ms of a clipboard change (confirms the new `NSPasteboardDidChangeNotification`-based implementation is event-driven, not polling).
- **M3.** Rebuild Schrodinger against the new `libclipboard.dylib` (no Bun FFI code changes) and verify clipboard history updates exactly as before. This is the key regression check for the unmodified `lib.zig`.

#### Pre-merge verification checklist

Before declaring the Linux port shipped, all of the following must pass:

- [ ] `zig build test` passes on macOS (32+ tests).
- [ ] `zig build test` passes on Linux (32+ tests).
- [ ] `zig build` on macOS produces a working dylib + CLI, Environment 4 smoke tests pass.
- [ ] `zig build` on Linux produces a working `.so` + CLI, Environment 1 (sway) smoke tests pass.
- [ ] Environment 2 (GNOME Wayland + XWayland) smoke tests pass.
- [ ] Environment 3 (Xorg) smoke tests pass.
- [ ] `lib.zig` is binary-compatible (Schrodinger rebuilds and works without FFI changes).
- [ ] `grep -r 'TODO\|FIXME\|XXX' src/` is clean in changed files.
- [ ] Git history is one commit per logical task with no fix-up commits amending prior tasks.

### Future work (ordered)

Explicitly deferred from this spec. Ordering reflects priority:

1. **FFI v2 — expose `subscribe` across the C ABI.** Design a C-friendly subscription mechanism (function pointer + userdata + opaque handle), update `lib.zig`, update Schrodinger's Bun FFI shim to use it instead of polling. Highest priority because it immediately improves Schrodinger (George's daily driver) by making clipboard change detection event-driven on macOS today, and will automatically pick up Linux event-driven detection once Schrodinger ships on Linux.
2. **Platform differences documentation.** Short reference doc at `docs/` covering UTI vs MIME vs CF format naming, the `wlr-data-control` GNOME gap, `CF_HTML` prefix quirks, X11 CLIPBOARD vs PRIMARY selections, `NSFilenamesPboardType` having no Linux equivalent, and other platform-specific wrinkles. With links to reference material. Cheap to write after all three platforms have been touched.
3. **Windows port.** `platform/windows.zig` using `OpenClipboard`/`GetClipboardData`/`SetClipboardData` and `AddClipboardFormatListener` for `subscribe`. Inherits the `subscribe` API shape already shaken out by the Linux work + FFI v2.
4. **GNOME Wayland gap documentation.** One paragraph added to the platform-differences doc (item 2) explaining that GNOME users transparently fall through to X11 via XWayland, and recommending sway/KDE/hyprland for users who want the native Wayland code path. Documentation only; no engineering work.

Additional deferred items without priority ordering:

- Automated integration tests on Linux (requires headless compositor in CI).
- GitHub Actions CI matrix (macOS + Linux).
- Fuzzing of `decodeUriList` via `zig build test --fuzz` (optional; current hand-written edge-case tests are likely sufficient).
- A `clipboard.takeOwnership` primitive for clipboard-manager use cases (only if Schrodinger's Linux clipboard-manager implementation demonstrates a concrete need).

## Summary of Files Touched

**New:**
- `native/clipboard/src/platform/linux/mod.zig` — backend selection, dispatch, subscribe registry + thread.
- `native/clipboard/src/platform/linux/wayland.zig` — `wlr-data-control-unstable-v1` backend.
- `native/clipboard/src/platform/linux/x11.zig` — `libX11` backend.
- `native/clipboard/vendor/wayland-protocols/wlr-data-control-unstable-v1.xml` — vendored protocol definition.

**Modified:**
- `native/clipboard/src/clipboard.zig` — add `.linux` case to the `switch`, add `subscribe`/`unsubscribe` forwarders, export `SubscribeHandle` and `SubscribeCallback` types.
- `native/clipboard/src/platform/macos.zig` — add `subscribe`/`unsubscribe` using `NSPasteboardDidChangeNotification`. No other changes.
- `native/clipboard/src/paths.zig` — add `decodeUriList` helper and its unit tests.
- `native/clipboard/src/main.zig` — rewrite `cmdWatch` to use `subscribe`; delete `isAllowlistedFileRef` helper; delete the defense-in-depth `UnsupportedFormat` catch arm; generalize the `UnsupportedFormat` message; add catch arms for `NoDisplayServer`, `SubscribeFailed`, `MalformedUriList`.
- `native/clipboard/build.zig` — add target-aware linking for Linux (X11, wayland-client, wayland-scanner code generation).

**Unchanged:**
- `native/clipboard/src/lib.zig` — explicitly not touched. FFI v2 is a separate spec.
- `native/clipboard/src/objc.zig` — macOS-only, still imported only by `platform/macos.zig`.
