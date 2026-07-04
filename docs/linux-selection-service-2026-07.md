# Linux X11 fixes (2026-07) — NEEDS LINUX TESTING

Branch: `linux-fixes-2026-07`. Authored on a macOS host, so the X11 path
**compiles-clean at the AST/semantic level but has not been run under X11.**
Validate on a real X11 session before merging.

## What changed and why

### 1. `change_count` was dead on Linux (no history ever captured)

`getChangeCount()` returned an atomic counter that only advances when the
background poll thread runs — but that thread was only started by `subscribe()`,
which Schrödinger never calls. And `mod.zig getChangeCount` never ran
`ensureInit`, so before any other call it returned 0 unconditionally.

Fix:
- `mod.zig getChangeCount` now lazily `ensureInit(std.heap.c_allocator)`.
- `x11.zig getChangeCount` now calls `ensurePollThread()` (new helper) so the
  first poll from a caller starts the thread — matching macOS's passive
  `NSPasteboard.changeCount` semantics.

### 2. X11 writes vanished after ≤5s (the "did it even copy?" bug)

The old `writeMultiple` **borrowed** the caller's slices, claimed the selection,
then blocked in `runSelectionServiceLoop` answering requests for up to 5s (or
500ms after the first paste) and returned — still owning the selection but with
nobody serving it and the borrowed data out of scope. So a paste after that
window got nothing.

Fix:
- Write data is now a **module-owned deep copy** (`owned_pairs: []OwnedPair`),
  guarded by `write_mutex`.
- `writeMultiple` copies the data, claims the selection, ensures the poll thread
  is running, and **returns immediately** (no blocking loop).
- The **persistent poll thread** (`pollThreadMain`) now serves `SelectionRequest`
  against `owned_pairs` and frees them on `SelectionClear` (when another app
  takes the clipboard). Previously it discarded those events.
- `runSelectionServiceLoop` and its timeout/grace constants were removed.
- `deinit()` frees `owned_pairs`.

## Test plan (run on X11)

1. **History captures:** run Schrödinger, copy text in another app, confirm it
   appears in the picker/tray. (Validates fix 1.)
2. **Copy survives:** pick an entry in Schrödinger to write it to the clipboard,
   switch to another app, wait >6s, Ctrl+V — the paste must succeed. (This is
   the exact failure the old 5s window caused; validates fix 2.)
3. **Multiple formats:** copy rich text (text + html), paste into an app that
   prefers html; confirm the right target is served.
4. **Ownership handoff:** copy in Schrödinger, then copy in another app — confirm
   Schrödinger's poll thread frees its data on SelectionClear (no leak; and the
   other app's clipboard works).
5. **No busy-hang:** confirm CPU is idle when nothing is happening (the poll
   thread should block in `poll()` between ticks).
6. **Concurrency:** rapidly pick several entries in a row while another app polls
   the clipboard (e.g. a clipboard-manager or `xclip -o` in a loop) — no crash,
   no torn data.

## Known follow-ups (not addressed here)

- Wayland backend still absent (`zwlr_data_control`). Pure Wayland returns
  NoDisplayServer; XWayland is unreliable for an unmapped window.
- INCR (large-transfer) protocol still unsupported in reads.
- The poll thread and foreground FFI still share one `Display`; a second
  connection for the poll thread would remove residual event-drain contention.
