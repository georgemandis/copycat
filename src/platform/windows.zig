const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../paths.zig");

// ---------------------------------------------------------------------------
// Public types — must match macos.zig and linux/mod.zig exactly.
// ---------------------------------------------------------------------------

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
    MalformedHDrop,
};

pub const FormatDataPair = struct {
    format: []const u8,
    data: []const u8,
};

pub const SubscribeCallback = *const fn (userdata: ?*anyopaque) void;

pub const SubscribeHandle = struct {
    id: u64,
};

// ---------------------------------------------------------------------------
// Win32 type aliases pulled from std.os.windows where available.
// ---------------------------------------------------------------------------

const BOOL = std.os.windows.BOOL;
const DWORD = std.os.windows.DWORD;
const HANDLE = std.os.windows.HANDLE;
const HWND = ?*anyopaque; // HWND is an opaque pointer; null == clipboard accessible from any thread
const UINT = std.os.windows.UINT;
const LPVOID = ?*anyopaque;
const SIZE_T = std.os.windows.SIZE_T;
const WCHAR = u16;
const HINSTANCE = ?*anyopaque;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const LPCWSTR = ?[*:0]const WCHAR;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;

// ---------------------------------------------------------------------------
// Win32 extern declarations — NOT in std.os.windows, so we declare them here.
// ---------------------------------------------------------------------------

extern "user32" fn OpenClipboard(hWndNewOwner: HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn EnumClipboardFormats(format: UINT) callconv(.winapi) UINT;
extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?HANDLE;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) callconv(.winapi) ?HANDLE;
extern "user32" fn GetClipboardFormatNameW(format: UINT, lpszFormatName: [*]WCHAR, cchMaxCount: c_int) callconv(.winapi) c_int;
extern "user32" fn RegisterClipboardFormatW(lpszFormat: [*:0]const WCHAR) callconv(.winapi) UINT;
extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) DWORD;

extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn GlobalSize(hMem: HANDLE) callconv(.winapi) SIZE_T;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: SIZE_T) callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const WCHAR) callconv(.winapi) HINSTANCE;
extern "user32" fn GetClipboardOwner() callconv(.winapi) HWND;
extern "user32" fn GetWindowThreadProcessId(hWnd: ?*anyopaque, lpdwProcessId: *DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn K32GetModuleBaseNameW(hProcess: HANDLE, hModule: ?*anyopaque, lpBaseName: [*]WCHAR, nSize: DWORD) callconv(.winapi) DWORD;

const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;

// ---------------------------------------------------------------------------
// Win32 window/message externs for clipboard subscription.
// ---------------------------------------------------------------------------

const WNDPROC = *const fn (hwnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HINSTANCE = null,
    hIcon: HICON = null,
    hCursor: HCURSOR = null,
    hbrBackground: HBRUSH = null,
    lpszMenuName: LPCWSTR = null,
    lpszClassName: LPCWSTR = null,
    hIconSm: HICON = null,
};

const POINT = extern struct {
    x: c_long,
    y: c_long,
};

const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const WCHAR,
    lpWindowName: [*:0]const WCHAR,
    dwStyle: DWORD,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: HWND,
    hMenu: ?*anyopaque,
    hInstance: HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostMessageW(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn AddClipboardFormatListener(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn RemoveClipboardFormatListener(hwnd: HWND) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Win32 constants for subscription.
// ---------------------------------------------------------------------------

const WM_CLIPBOARDUPDATE: UINT = 0x031D;
const WM_QUIT: UINT = 0x0012;
/// HWND_MESSAGE: cast -3 to HWND (message-only window parent).
const HWND_MESSAGE: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

// ---------------------------------------------------------------------------
// GlobalAlloc flags.
// ---------------------------------------------------------------------------

const GMEM_MOVEABLE: UINT = 0x0002;

// ---------------------------------------------------------------------------
// Standard clipboard format table.
// CF_* constants as defined in winuser.h.
// ---------------------------------------------------------------------------

const StandardFormat = struct {
    id: UINT,
    name: []const u8,
};

const standard_formats = [_]StandardFormat{
    .{ .id = 1, .name = "CF_TEXT" },
    .{ .id = 2, .name = "CF_BITMAP" },
    .{ .id = 7, .name = "CF_OEMTEXT" },
    .{ .id = 8, .name = "CF_DIB" },
    .{ .id = 13, .name = "CF_UNICODETEXT" },
    .{ .id = 15, .name = "CF_HDROP" },
    .{ .id = 16, .name = "CF_LOCALE" },
    .{ .id = 17, .name = "CF_DIBV5" },
};

// ---------------------------------------------------------------------------
// Format ID <-> name helpers.
// ---------------------------------------------------------------------------

/// Map a clipboard format integer ID to an owned UTF-8 name string.
/// Checks the standard_formats table first; falls back to GetClipboardFormatNameW
/// for registered custom formats. Caller owns the returned slice.
pub fn formatIdToName(allocator: Allocator, id: UINT) ![]const u8 {
    // Check standard table first.
    for (standard_formats) |sf| {
        if (sf.id == id) return allocator.dupe(u8, sf.name);
    }

    // Fall back to Win32 API for custom registered formats.
    // MAX_PATH (260) is larger than any clipboard format name can be.
    var buf: [512]WCHAR = undefined;
    const len = GetClipboardFormatNameW(id, &buf, buf.len);
    if (len <= 0) return ClipboardError.FormatNotFound;

    const utf16_slice = buf[0..@intCast(len)];
    return std.unicode.utf16LeToUtf8Alloc(allocator, utf16_slice) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return ClipboardError.UnsupportedFormat,
    };
}

/// Map a UTF-8 format name to a Win32 clipboard format ID.
/// Checks the standard_formats table first; falls back to RegisterClipboardFormatW.
pub fn formatNameToId(allocator: Allocator, name: []const u8) !UINT {
    // Check standard table.
    for (standard_formats) |sf| {
        if (std.mem.eql(u8, sf.name, name)) return sf.id;
    }

    // Convert UTF-8 name to UTF-16LE for Win32.
    const name_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(name_w);

    const id = RegisterClipboardFormatW(name_w);
    if (id == 0) return ClipboardError.UnsupportedFormat;
    return id;
}

// ---------------------------------------------------------------------------
// getChangeCount
// ---------------------------------------------------------------------------

pub fn getChangeCount() i64 {
    const seq = GetClipboardSequenceNumber();
    if (seq == 0) return -1;
    return @as(i64, @intCast(seq));
}

// ---------------------------------------------------------------------------
// listFormats
// ---------------------------------------------------------------------------

/// Returns a slice of all format name strings currently on the clipboard.
/// Caller owns the returned outer slice and each inner string.
pub fn listFormats(allocator: Allocator) ![][]const u8 {
    if (OpenClipboard(null) == 0) return ClipboardError.PasteboardUnavailable;
    defer _ = CloseClipboard();

    var list = std.ArrayListUnmanaged([]const u8){};
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    var fmt: UINT = 0;
    while (true) {
        fmt = EnumClipboardFormats(fmt);
        if (fmt == 0) break; // no more formats (or error; treat as end)

        const name = formatIdToName(allocator, fmt) catch continue;
        errdefer allocator.free(name);
        try list.append(allocator, name);
    }

    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// readFormat
// ---------------------------------------------------------------------------

/// Read raw bytes for a named clipboard format.
/// Returns null if the format is not present on the clipboard.
/// Caller owns the returned slice.
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    const fmt_id = try formatNameToId(allocator, format);

    if (OpenClipboard(null) == 0) return ClipboardError.PasteboardUnavailable;
    defer _ = CloseClipboard();

    const hdata = GetClipboardData(fmt_id) orelse return null; // format not present

    const ptr = GlobalLock(hdata) orelse return ClipboardError.PasteboardUnavailable;
    defer _ = GlobalUnlock(hdata);

    const size = GlobalSize(hdata);
    if (size == 0) return try allocator.alloc(u8, 0);

    const bytes: [*]const u8 = @ptrCast(ptr);
    const result = try allocator.alloc(u8, size);
    @memcpy(result, bytes[0..size]);
    return result;
}

// ---------------------------------------------------------------------------
// Stub functions for write operations, clear, path decoding, and subscriptions.
// These are implemented in later tasks.
// ---------------------------------------------------------------------------

pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    const id = try formatNameToId(allocator, format);
    if (OpenClipboard(null) == 0) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    const hmem = GlobalAlloc(GMEM_MOVEABLE, data.len) orelse return error.PasteboardUnavailable;
    const dest = GlobalLock(hmem) orelse return error.PasteboardUnavailable;
    const dest_slice: [*]u8 = @ptrCast(dest);
    @memcpy(dest_slice[0..data.len], data);
    _ = GlobalUnlock(hmem);
    if (SetClipboardData(id, hmem) == null) return error.PasteboardUnavailable;
    // SetClipboardData takes ownership — do NOT free hmem
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    if (OpenClipboard(null) == 0) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    for (pairs) |pair| {
        const id = formatNameToId(allocator, pair.format) catch continue;
        const hmem = GlobalAlloc(GMEM_MOVEABLE, pair.data.len) orelse continue;
        const dest = GlobalLock(hmem) orelse continue;
        const dest_slice: [*]u8 = @ptrCast(dest);
        @memcpy(dest_slice[0..pair.data.len], pair.data);
        _ = GlobalUnlock(hmem);
        _ = SetClipboardData(id, hmem);
    }
}

pub fn clear() !void {
    if (OpenClipboard(null) == 0) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
}

const file_ref_allowlist = [_][]const u8{"CF_HDROP"};

fn isFileRefFormat(format: []const u8) bool {
    for (file_ref_allowlist) |allowed| {
        if (std.mem.eql(u8, format, allowed)) return true;
    }
    return false;
}

pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) (ClipboardError || paths.DecodePathError || Allocator.Error)![]const []const u8 {
    if (!isFileRefFormat(format)) return error.UnsupportedFormat;

    const data = (readFormat(allocator, format) catch |err| switch (err) {
        error.UnsupportedFormat => return error.UnsupportedFormat,
        error.PasteboardUnavailable => return error.PasteboardUnavailable,
        else => return error.UnsupportedFormat,
    }) orelse return error.FormatNotFound;
    defer allocator.free(data);

    return try paths.decodeHDrop(allocator, data);
}

// ---------------------------------------------------------------------------
// Subscription state — module-level, matching macOS/Linux pattern.
// ---------------------------------------------------------------------------

const Subscriber = struct {
    id: u64,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
};

var subscribe_mutex: std.Thread.Mutex = .{};
var subscribers: std.ArrayListUnmanaged(Subscriber) = .{};
var next_subscriber_id: u64 = 1;
var msg_thread: ?std.Thread = null;
var should_exit: bool = false;
var msg_hwnd: HWND = null;

// ---------------------------------------------------------------------------
// Window procedure — called on the message thread by DispatchMessageW.
// ---------------------------------------------------------------------------

fn wndProc(hwnd: HWND, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {
    if (uMsg == WM_CLIPBOARDUPDATE) {
        // Snapshot subscribers under lock, then invoke outside lock to avoid
        // deadlocks if a callback calls back into the library.
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
        return 0;
    }
    return DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// Message thread function — runs a Win32 message loop with a message-only
// window that receives WM_CLIPBOARDUPDATE via AddClipboardFormatListener.
// ---------------------------------------------------------------------------

// UTF-16LE class name: "CopycatClipSub\0"
const wnd_class_name = blk: {
    const name = "CopycatClipSub";
    var buf: [name.len + 1]WCHAR = undefined;
    for (name, 0..) |c, i| {
        buf[i] = c;
    }
    buf[name.len] = 0;
    break :blk buf;
};

fn messageThreadFn() void {
    const hInstance = GetModuleHandleW(null);

    var wc: WNDCLASSEXW = .{
        .lpfnWndProc = wndProc,
        .hInstance = hInstance,
        .lpszClassName = @ptrCast(&wnd_class_name),
    };
    wc.cbSize = @sizeOf(WNDCLASSEXW);

    _ = RegisterClassExW(&wc);

    // Empty window name (L"")
    const empty_name = [_]WCHAR{0};

    const hwnd = CreateWindowExW(
        0, // dwExStyle
        @ptrCast(&wnd_class_name), // lpClassName
        @ptrCast(&empty_name), // lpWindowName
        0, // dwStyle
        0, // x
        0, // y
        0, // nWidth
        0, // nHeight
        HWND_MESSAGE, // hWndParent — message-only window
        null, // hMenu
        hInstance, // hInstance
        null, // lpParam
    );

    if (hwnd == null) {
        // Window creation failed — nothing we can do.
        return;
    }

    if (AddClipboardFormatListener(hwnd) == 0) {
        // Failed to register listener — clean up and exit.
        _ = DestroyWindow(hwnd);
        return;
    }

    // Publish the HWND so unsubscribe() can PostMessageW to it.
    subscribe_mutex.lock();
    msg_hwnd = hwnd;
    subscribe_mutex.unlock();

    // Message loop — GetMessageW returns 0 on WM_QUIT, >0 on normal messages,
    // -1 on error (which we treat as exit).
    var msg: MSG = undefined;
    while (true) {
        const ret = GetMessageW(&msg, null, 0, 0);
        if (ret == 0 or ret == -1) break; // WM_QUIT or error
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }

    // Teardown.
    _ = RemoveClipboardFormatListener(hwnd);
    _ = DestroyWindow(hwnd);

    subscribe_mutex.lock();
    msg_hwnd = null;
    subscribe_mutex.unlock();
}

// ---------------------------------------------------------------------------
// subscribe / unsubscribe — public API.
// ---------------------------------------------------------------------------

pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    subscribe_mutex.lock();
    defer subscribe_mutex.unlock();

    // If a prior teardown left a stale thread handle, join it before reusing
    // the slot. This handles the subscribe -> unsubscribe -> subscribe
    // resurrection case.
    if (msg_thread) |old_thread| {
        if (should_exit) {
            subscribe_mutex.unlock();
            old_thread.join();
            subscribe_mutex.lock();
            msg_thread = null;
        }
    }

    const id = next_subscriber_id;
    next_subscriber_id += 1;

    try subscribers.append(allocator, .{
        .id = id,
        .callback = callback,
        .userdata = userdata,
    });

    // Spawn the message thread on first subscriber (or after a teardown).
    if (msg_thread == null) {
        should_exit = false;
        msg_thread = std.Thread.spawn(.{}, messageThreadFn, .{}) catch {
            _ = subscribers.pop();
            next_subscriber_id -= 1;
            return ClipboardError.SubscribeFailed;
        };
    }

    return SubscribeHandle{ .id = id };
}

pub fn unsubscribe(handle: SubscribeHandle) void {
    subscribe_mutex.lock();
    defer subscribe_mutex.unlock();

    // Find and remove the matching entry.
    var i: usize = 0;
    while (i < subscribers.items.len) : (i += 1) {
        if (subscribers.items[i].id == handle.id) {
            _ = subscribers.swapRemove(i);
            break;
        }
    }

    // Signal the message thread to exit if no subscribers left.
    // Shutdown is ASYNC — we do NOT join here (matches macOS/Linux pattern).
    // The next subscribe() is responsible for joining the stale handle.
    if (subscribers.items.len == 0) {
        should_exit = true;
        if (msg_hwnd) |hwnd| {
            _ = PostMessageW(hwnd, WM_QUIT, 0, 0);
        }
    }
}

pub fn getSourceInfo() @import("../clipboard.zig").ClipboardSourceInfo {
    const ClipboardSourceInfo = @import("../clipboard.zig").ClipboardSourceInfo;
    const alloc = std.heap.c_allocator;

    const owner_hwnd = GetClipboardOwner();
    if (owner_hwnd == null) {
        return ClipboardSourceInfo{
            .pid = -1,
            .name = null,
            .status = 1,
        };
    }

    var pid: DWORD = 0;
    _ = GetWindowThreadProcessId(owner_hwnd, &pid);
    if (pid == 0) {
        return ClipboardSourceInfo{
            .pid = -1,
            .name = null,
            .status = -1,
        };
    }

    const process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
    if (process == null) {
        return ClipboardSourceInfo{
            .pid = @intCast(pid),
            .name = null,
            .status = 0,
        };
    }
    defer _ = CloseHandle(process.?);

    var name_buf: [260]WCHAR = undefined;
    const name_len = K32GetModuleBaseNameW(process.?, null, &name_buf, 260);

    if (name_len == 0) {
        return ClipboardSourceInfo{
            .pid = @intCast(pid),
            .name = null,
            .status = 0,
        };
    }

    // Convert UTF-16LE to UTF-8 using the same pattern as existing codebase
    const utf16_slice = name_buf[0..name_len];
    const utf8_owned = std.unicode.utf16LeToUtf8Alloc(alloc, utf16_slice) catch {
        return ClipboardSourceInfo{
            .pid = @intCast(pid),
            .name = null,
            .status = 0,
        };
    };

    // Re-allocate as sentinel-terminated for FFI (null-terminated C string)
    const utf8_sentinel = alloc.allocSentinel(u8, utf8_owned.len, 0) catch {
        alloc.free(utf8_owned);
        return ClipboardSourceInfo{
            .pid = @intCast(pid),
            .name = null,
            .status = 0,
        };
    };
    @memcpy(utf8_sentinel[0..utf8_owned.len], utf8_owned);
    alloc.free(utf8_owned);

    return ClipboardSourceInfo{
        .pid = @intCast(pid),
        .name = utf8_sentinel.ptr,
        .status = 0,
    };
}
