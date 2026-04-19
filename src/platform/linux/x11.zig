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

// The pairs currently being served. Borrowed from the caller for the
// duration of the writeFormat/writeMultiple call.
var write_pairs: []const mod.FormatDataPair = &.{};
// Parallel array of pre-interned atoms for each pair's format string, so the
// SelectionRequest handler doesn't need to re-intern on every paste. Owned
// by the module-level allocator for the duration of the write call.
var write_atoms: []c.Atom = &.{};

// MIME-type -> atom cache. Populated lazily.
const AtomEntry = struct {
    mime: []u8,
    atom: c.Atom,
};
var atom_cache_mutex: std.Thread.Mutex = .{};
var atom_cache: std.ArrayListUnmanaged(AtomEntry) = .{};
// Module-level allocator for backend-private state: atom cache, subscriber
// registry, module-owned format buffers. Set once by `tryOpenDisplay`.
// Long-lived -- not freed until process exit (backend state lives forever).
var mod_allocator: ?Allocator = null;

// ---------------------------------------------------------------------------
// tryOpenDisplay + atomFor
// ---------------------------------------------------------------------------

/// Opens the X display, creates an invisible window to use for selection
/// requests, and precaches the core atoms. Returns true on success, false
/// if XOpenDisplay fails. `alloc` is stored in the module-level `mod_allocator`
/// and used for every backend-private allocation for the life of the process.
pub fn tryOpenDisplay(alloc: Allocator) bool {
    const d = c.XOpenDisplay(null) orelse return false;
    display = d;
    mod_allocator = alloc;

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
    const alloc = mod_allocator orelse return null;

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

// ---------------------------------------------------------------------------
// readFormat via XConvertSelection
// ---------------------------------------------------------------------------

pub fn readFormat(alloc: Allocator, format: []const u8) !?[]const u8 {
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
    // INCR transfers are out of scope for this task; if encountered, return
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
        @ptrCast(&prop_data),
    );

    if (actual_type == incr_atom) {
        if (prop_data != null) _ = c.XFree(@ptrCast(prop_data));
        return null; // INCR transfers not supported.
    }

    if (prop_data == null or nitems == 0) {
        if (prop_data != null) _ = c.XFree(@ptrCast(prop_data));
        return try alloc.alloc(u8, 0);
    }

    // `nitems` is in units of `actual_format / 8` bytes (8, 16, or 32).
    const elem_bytes: usize = @intCast(@divExact(actual_format, 8));
    const total_bytes = nitems * elem_bytes;

    const out = try alloc.alloc(u8, total_bytes);
    @memcpy(out, prop_data[0..total_bytes]);
    _ = c.XFree(@ptrCast(prop_data));

    return out;
}

// ---------------------------------------------------------------------------
// listFormats via TARGETS
// ---------------------------------------------------------------------------

pub fn listFormats(alloc: Allocator) ![][]const u8 {
    const d = display orelse return ClipboardError.PasteboardUnavailable;

    const owner = c.XGetSelectionOwner(d, clipboard_atom);
    if (owner == c.None) return try alloc.alloc([]const u8, 0);

    _ = c.XConvertSelection(d, clipboard_atom, targets_atom, our_property_atom, our_window, c.CurrentTime);
    _ = c.XFlush(d);

    // Wait for SelectionNotify (same 2s poll as readFormat).
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
        return try alloc.alloc([]const u8, 0);
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
        @ptrCast(&prop_data),
    );

    if (prop_data == null or nitems == 0) {
        if (prop_data != null) _ = c.XFree(@ptrCast(prop_data));
        return try alloc.alloc([]const u8, 0);
    }

    const atoms_ptr: [*]const c.Atom = @ptrCast(@alignCast(prop_data));
    const atoms = atoms_ptr[0..@intCast(nitems)];

    var out = try std.array_list.Managed([]const u8).initCapacity(alloc, nitems);
    errdefer {
        for (out.items) |s| alloc.free(s);
        out.deinit();
    }

    for (atoms) |atom| {
        const name_c = c.XGetAtomName(d, atom) orelse continue;
        const name = std.mem.span(name_c);

        // Filter X11-internal atoms.
        const skip = std.mem.eql(u8, name, "TARGETS") or
            std.mem.eql(u8, name, "MULTIPLE") or
            std.mem.eql(u8, name, "TIMESTAMP") or
            std.mem.eql(u8, name, "SAVE_TARGETS");

        if (skip) {
            _ = c.XFree(@ptrCast(name_c));
            continue;
        }

        const copy = alloc.dupe(u8, name) catch |err| {
            _ = c.XFree(@ptrCast(name_c));
            return err;
        };
        _ = c.XFree(@ptrCast(name_c));
        try out.append(copy);
    }

    _ = c.XFree(@ptrCast(prop_data));
    return try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// clear
// ---------------------------------------------------------------------------

pub fn clear() !void {
    const d = display orelse return ClipboardError.PasteboardUnavailable;
    _ = c.XSetSelectionOwner(d, clipboard_atom, c.None, c.CurrentTime);
    _ = c.XSync(d, c.False);
}

// ---------------------------------------------------------------------------
// writeFormat / writeMultiple via SelectionRequest service loop
// ---------------------------------------------------------------------------

const SELECTION_WRITE_TIMEOUT_MS: i64 = 5_000;
const SELECTION_WRITE_GRACE_MS: i64 = 500;

fn respondToSelectionRequest(ev: *c.XSelectionRequestEvent) bool {
    const alloc = mod_allocator orelse return false;

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
    if (ev.target == targets_atom) {
        const buf = alloc.alloc(c.Atom, write_atoms.len + 1) catch return false;
        defer alloc.free(buf);
        buf[0] = targets_atom;
        @memcpy(buf[1..], write_atoms);

        _ = c.XChangeProperty(
            ev.display,
            ev.requestor,
            ev.property,
            c.XA_ATOM,
            32,
            c.PropModeReplace,
            @ptrCast(buf.ptr),
            @intCast(buf.len),
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

fn runSelectionServiceLoop() !void {
    const d = display orelse return ClipboardError.NoDisplayServer;
    const start = std.time.milliTimestamp();
    var first_service_time: ?i64 = null;

    while (true) {
        const now = std.time.milliTimestamp();
        if (first_service_time) |t| {
            if (now - t >= SELECTION_WRITE_GRACE_MS) return; // grace exhausted -> success
        }
        if (now - start >= SELECTION_WRITE_TIMEOUT_MS) {
            return; // No one pasted -- still a successful write (clipboard is owned).
        }

        const fd = c.ConnectionNumber(d);
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        _ = std.posix.poll(&pfd, 100) catch return ClipboardError.PasteboardUnavailable;

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
                    return; // Another client took ownership. Successful exit.
                },
                else => {},
            }
        }
    }
}

pub fn writeFormat(alloc: Allocator, format: []const u8, data: []const u8) !void {
    const pair = mod.FormatDataPair{ .format = format, .data = data };
    const pairs = [_]mod.FormatDataPair{pair};
    return writeMultiple(alloc, &pairs);
}

pub fn writeMultiple(alloc: Allocator, pairs: []const mod.FormatDataPair) !void {
    _ = alloc; // unused: we use the module-level allocator for scratch state
    const d = display orelse return ClipboardError.NoDisplayServer;
    const our = mod_allocator orelse return ClipboardError.NoDisplayServer;

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

    // Claim ownership of CLIPBOARD.
    _ = c.XSetSelectionOwner(d, clipboard_atom, our_window, c.CurrentTime);
    _ = c.XFlush(d);

    // Verify the server actually granted ownership.
    const actual = c.XGetSelectionOwner(d, clipboard_atom);
    if (actual != our_window) return ClipboardError.WriteFailed;

    // Block until timeout / grace window / SelectionClear.
    try runSelectionServiceLoop();
}

// ---------------------------------------------------------------------------
// subscribe / unsubscribe via background TARGETS hash poll
// ---------------------------------------------------------------------------

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

pub fn getChangeCount() i64 {
    return change_count.load(.monotonic);
}

const DEFAULT_POLL_MS: i32 = 500;

fn pollThreadMain() void {
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
        std.Thread.sleep(5 * std.time.ns_per_ms);
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

pub fn subscribe(
    _: Allocator,
    callback: mod.SubscribeCallback,
    userdata: ?*anyopaque,
) !mod.SubscribeHandle {
    const our = mod_allocator orelse return ClipboardError.NoDisplayServer;

    subs_mutex.lock();
    defer subs_mutex.unlock();

    const id = next_sub_id;
    next_sub_id += 1;
    subs.append(our, .{ .id = id, .callback = callback, .userdata = userdata }) catch {
        return ClipboardError.SubscribeFailed;
    };

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

// ---------------------------------------------------------------------------
// getSourceInfo — query clipboard owner PID and process name
// ---------------------------------------------------------------------------

pub fn getSourceInfo() @import("../../clipboard.zig").ClipboardSourceInfo {
    const ClipboardSourceInfo = @import("../../clipboard.zig").ClipboardSourceInfo;
    const alloc = std.heap.c_allocator;

    const d = display orelse return ClipboardSourceInfo{
        .pid = -1,
        .name = null,
        .status = -1,
    };

    const owner = c.XGetSelectionOwner(d, clipboard_atom);
    if (owner == c.None) {
        return ClipboardSourceInfo{
            .pid = -1,
            .name = null,
            .status = 1,
        };
    }

    // Query _NET_WM_PID property on the owner window
    const net_wm_pid_atom = c.XInternAtom(d, "_NET_WM_PID", c.True);
    if (net_wm_pid_atom == c.None) {
        return ClipboardSourceInfo{
            .pid = -1,
            .name = null,
            .status = -1,
        };
    }

    var actual_type: c.Atom = undefined;
    var actual_format: c_int = undefined;
    var n_items: c_ulong = undefined;
    var bytes_after: c_ulong = undefined;
    var prop_data: ?[*]u8 = null;

    const result = c.XGetWindowProperty(
        d,
        owner,
        net_wm_pid_atom,
        0,       // offset
        1,       // length (1 x 32-bit word)
        c.False, // delete
        c.XA_CARDINAL,
        &actual_type,
        &actual_format,
        &n_items,
        &bytes_after,
        @ptrCast(&prop_data),
    );

    if (result != c.Success or prop_data == null or n_items == 0) {
        if (prop_data) |p| _ = c.XFree(p);
        return ClipboardSourceInfo{
            .pid = -1,
            .name = null,
            .status = -1,
        };
    }

    const pid_ptr: *const u32 = @ptrCast(@alignCast(prop_data.?));
    const pid: i64 = @intCast(pid_ptr.*);
    _ = c.XFree(prop_data.?);

    // Read /proc/{pid}/comm for process name
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch {
        return ClipboardSourceInfo{ .pid = pid, .name = null, .status = 0 };
    };

    const file = std.fs.openFileAbsolute(path, .{}) catch {
        return ClipboardSourceInfo{ .pid = pid, .name = null, .status = 0 };
    };
    defer file.close();

    var name_buf: [256]u8 = undefined;
    const bytes_read = file.read(&name_buf) catch {
        return ClipboardSourceInfo{ .pid = pid, .name = null, .status = 0 };
    };

    if (bytes_read == 0) {
        return ClipboardSourceInfo{ .pid = pid, .name = null, .status = 0 };
    }

    // Trim trailing newline
    var name_len = bytes_read;
    if (name_len > 0 and name_buf[name_len - 1] == '\n') {
        name_len -= 1;
    }

    // Heap-allocate null-terminated copy for FFI
    const name_copy = alloc.allocSentinel(u8, name_len, 0) catch {
        return ClipboardSourceInfo{ .pid = pid, .name = null, .status = 0 };
    };
    @memcpy(name_copy[0..name_len], name_buf[0..name_len]);

    return ClipboardSourceInfo{
        .pid = pid,
        .name = name_copy.ptr,
        .status = 0,
    };
}
