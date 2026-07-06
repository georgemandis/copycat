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
    if (OpenClipboard(null) == .FALSE) return ClipboardError.PasteboardUnavailable;
    defer _ = CloseClipboard();

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |s| allocator.free(s);
        list.deinit(allocator);
    }

    var fmt: UINT = 0;
    while (true) {
        fmt = EnumClipboardFormats(fmt);
        if (fmt == 0) break; // no more formats (or error; treat as end)

        // Skip GDI handle formats — they can't be read as raw bytes and
        // their data is available through memory-based equivalents
        // (e.g. CF_BITMAP data is accessible via CF_DIB/CF_DIBV5).
        if (isHandleFormat(fmt)) continue;

        const name = formatIdToName(allocator, fmt) catch continue;
        errdefer allocator.free(name);
        try list.append(allocator, name);
    }

    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// readFormat
// ---------------------------------------------------------------------------

/// Clipboard format IDs that use GDI/kernel object handles instead of
/// GlobalAlloc'd memory. Calling GlobalLock/GlobalSize on these is
/// undefined behavior and will segfault.
///
/// There is no Win32 API to query whether a format uses a GDI handle or
/// HGLOBAL — the handle type is determined solely by the format ID. This
/// list is exhaustive per Microsoft's documentation:
/// https://learn.microsoft.com/en-us/windows/win32/dataxchg/standard-clipboard-formats
///
/// Data is NOT lost by skipping these: Windows automatically synthesizes
/// memory-based equivalents (e.g. CF_BITMAP ↔ CF_DIB ↔ CF_DIBV5), so
/// the same image data is readable through the CF_DIB/CF_DIBV5 formats.
const CF_BITMAP_ID: UINT = 2;
const CF_METAFILEPICT_ID: UINT = 3;
const CF_PALETTE_ID: UINT = 9;
const CF_ENHMETAFILE_ID: UINT = 14;
const CF_OWNERDISPLAY_ID: UINT = 0x0080; // hMem is always NULL
const CF_DSPBITMAP_ID: UINT = 0x0082; // display variant of CF_BITMAP
const CF_DSPMETAFILEPICT_ID: UINT = 0x0083; // display variant of CF_METAFILEPICT
const CF_DSPENHMETAFILE_ID: UINT = 0x008E; // display variant of CF_ENHMETAFILE

fn isHandleFormat(id: UINT) bool {
    return id == CF_BITMAP_ID or id == CF_METAFILEPICT_ID or
        id == CF_PALETTE_ID or id == CF_ENHMETAFILE_ID or
        id == CF_OWNERDISPLAY_ID or id == CF_DSPBITMAP_ID or
        id == CF_DSPMETAFILEPICT_ID or id == CF_DSPENHMETAFILE_ID;
}

/// Read raw bytes for a named clipboard format.
/// Returns null if the format is not present on the clipboard.
/// Caller owns the returned slice.
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    const fmt_id = try formatNameToId(allocator, format);

    // GDI handle formats can't be read as raw bytes via GlobalLock.
    if (isHandleFormat(fmt_id)) return null;

    if (OpenClipboard(null) == .FALSE) return ClipboardError.PasteboardUnavailable;
    defer _ = CloseClipboard();

    const hdata = GetClipboardData(fmt_id) orelse return null; // format not present

    const ptr = GlobalLock(hdata) orelse return null;
    defer _ = GlobalUnlock(hdata);

    const size = GlobalSize(hdata);
    if (size == 0) return try allocator.alloc(u8, 0);

    const bytes: [*]const u8 = @ptrCast(ptr);

    // Decode from the Windows on-the-wire encoding back to UTF-8 / raw HTML.
    // Note GlobalSize returns the *allocation* size, which may be rounded up
    // past the real data; the CF_UNICODETEXT decoder stops at the NUL and the
    // CF_HTML decoder uses the header's EndFragment offset, so trailing slack
    // is handled. For untransformed formats we return the raw bytes as-is.
    if (decodeForRead(allocator, fmt_id, bytes[0..size]) catch null) |decoded| {
        return decoded;
    }

    const result = try allocator.alloc(u8, size);
    @memcpy(result, bytes[0..size]);
    return result;
}

// ---------------------------------------------------------------------------
// Stub functions for write operations, clear, path decoding, and subscriptions.
// These are implemented in later tasks.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Encoding transforms at the Win32 boundary.
//
// The rest of Schrödinger/copycat speaks UTF-8 and passes HTML as a raw
// fragment, but Windows clipboard formats have their own on-the-wire encodings:
//   - CF_UNICODETEXT is UTF-16LE with a NUL terminator (NOT UTF-8).
//   - "HTML Format" is a registered format that requires the CF_HTML header
//     (Version/StartHTML/EndHTML/StartFragment/EndFragment byte offsets)
//     wrapping the fragment; apps ignore raw HTML without it.
// We transcode here on write and reverse it on read, so callers stay in UTF-8
// and never see the Windows-specific framing.
// ---------------------------------------------------------------------------

/// Transform outgoing bytes for a given format ID into the encoding Windows
/// expects. Returns owned bytes the caller must free, or null to write `data`
/// unchanged (no transform for this format).
fn encodeForWrite(allocator: Allocator, fmt_id: UINT, data: []const u8) !?[]u8 {
    if (fmt_id == 13) { // CF_UNICODETEXT
        // UTF-8 -> UTF-16LE, NUL-terminated.
        const units = try std.unicode.utf8ToUtf16LeAlloc(allocator, data);
        defer allocator.free(units);
        var out = try allocator.alloc(u8, (units.len + 1) * 2);
        for (units, 0..) |u, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], u, .little);
        std.mem.writeInt(u16, out[units.len * 2 ..][0..2], 0, .little); // NUL
        return out;
    }
    if (isHtmlFormatId(fmt_id)) {
        return try wrapCfHtml(allocator, data);
    }
    return null;
}

/// Reverse of encodeForWrite for reads. Returns owned bytes or null for "no
/// transform" (return the raw bytes as-is).
fn decodeForRead(allocator: Allocator, fmt_id: UINT, data: []const u8) !?[]u8 {
    if (fmt_id == 13) { // CF_UNICODETEXT: UTF-16LE -> UTF-8.
        // GlobalSize may over-report (allocation size, not string length), so
        // stop at the FIRST NUL rather than assuming exactly one trailing NUL —
        // otherwise trailing slack bytes would be decoded as garbage.
        const max_units = data.len / 2;
        var unit_len: usize = 0;
        while (unit_len < max_units) : (unit_len += 1) {
            const u = std.mem.readInt(u16, data[unit_len * 2 ..][0..2], .little);
            if (u == 0) break;
        }
        const units = try allocator.alloc(u16, unit_len);
        defer allocator.free(units);
        for (0..unit_len) |i| {
            units[i] = std.mem.readInt(u16, data[i * 2 ..][0..2], .little);
        }
        return try std.unicode.utf16LeToUtf8Alloc(allocator, units);
    }
    if (isHtmlFormatId(fmt_id)) {
        return try unwrapCfHtml(allocator, data);
    }
    return null;
}

/// The "HTML Format" ID is registered at runtime, so cache it per process.
var html_format_id_cache: UINT = 0;
fn htmlFormatId() UINT {
    if (html_format_id_cache != 0) return html_format_id_cache;
    // "HTML Format" as UTF-16LE, NUL-terminated.
    const name_w = std.unicode.utf8ToUtf16LeStringLiteral("HTML Format");
    html_format_id_cache = RegisterClipboardFormatW(name_w);
    return html_format_id_cache;
}
fn isHtmlFormatId(fmt_id: UINT) bool {
    return fmt_id != 0 and fmt_id == htmlFormatId();
}

/// Wrap a raw HTML fragment in the CF_HTML header. The header carries byte
/// offsets (into the final UTF-8 buffer) for the full document and the
/// fragment, which Windows apps require.
fn wrapCfHtml(allocator: Allocator, fragment: []const u8) ![]u8 {
    // The header has fixed-width zero-padded offsets so we can compute lengths
    // before filling them in. Template with 10-digit offsets.
    const prefix =
        "Version:0.9\r\n" ++
        "StartHTML:0000000000\r\n" ++
        "EndHTML:0000000000\r\n" ++
        "StartFragment:0000000000\r\n" ++
        "EndFragment:0000000000\r\n";
    const frag_open = "<html><body>\r\n<!--StartFragment-->";
    const frag_close = "<!--EndFragment-->\r\n</body></html>";

    const header_len = prefix.len;
    const start_html = header_len;
    const start_fragment = header_len + frag_open.len;
    const end_fragment = start_fragment + fragment.len;
    const end_html = end_fragment + frag_close.len;

    var buf = try allocator.alloc(u8, end_html);
    var w: usize = 0;
    @memcpy(buf[w..][0..prefix.len], prefix);
    w += prefix.len;
    @memcpy(buf[w..][0..frag_open.len], frag_open);
    w += frag_open.len;
    @memcpy(buf[w..][0..fragment.len], fragment);
    w += fragment.len;
    @memcpy(buf[w..][0..frag_close.len], frag_close);

    // Patch the offsets in place (each is a 10-digit field after its label).
    patchOffset(buf, "StartHTML:", start_html);
    patchOffset(buf, "EndHTML:", end_html);
    patchOffset(buf, "StartFragment:", start_fragment);
    patchOffset(buf, "EndFragment:", end_fragment);
    return buf;
}

/// Overwrite the 10-digit zero-padded number following `label` with `value`.
fn patchOffset(buf: []u8, comptime label: []const u8, value: usize) void {
    const idx = std.mem.indexOf(u8, buf, label) orelse return;
    const num_start = idx + label.len;
    var v = value;
    var i: usize = 10;
    while (i > 0) {
        i -= 1;
        buf[num_start + i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
}

/// Extract the fragment from a CF_HTML blob. Uses StartFragment/EndFragment if
/// present; otherwise returns everything after the header (double CRLF), or the
/// whole input as a fallback.
fn unwrapCfHtml(allocator: Allocator, data: []const u8) ![]u8 {
    const start = parseHeaderOffset(data, "StartFragment:");
    const end = parseHeaderOffset(data, "EndFragment:");
    if (start != null and end != null and end.? <= data.len and start.? <= end.?) {
        return allocator.dupe(u8, data[start.?..end.?]);
    }
    return allocator.dupe(u8, data);
}

fn parseHeaderOffset(data: []const u8, label: []const u8) ?usize {
    const idx = std.mem.indexOf(u8, data, label) orelse return null;
    var i = idx + label.len;
    var value: usize = 0;
    var seen = false;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
        value = value * 10 + (data[i] - '0');
        seen = true;
    }
    return if (seen) value else null;
}

pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    const pair = FormatDataPair{ .format = format, .data = data };
    const pairs = [_]FormatDataPair{pair};
    return writeMultiple(allocator, &pairs);
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    if (OpenClipboard(null) == .FALSE) return error.PasteboardUnavailable;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    for (pairs) |pair| {
        const id = formatNameToId(allocator, pair.format) catch continue;

        // Transcode into the encoding Windows expects for this format.
        const encoded = encodeForWrite(allocator, id, pair.data) catch null;
        defer if (encoded) |e| allocator.free(e);
        const bytes = encoded orelse pair.data;

        const hmem = GlobalAlloc(GMEM_MOVEABLE, bytes.len) orelse continue;
        const dest = GlobalLock(hmem) orelse continue;
        const dest_slice: [*]u8 = @ptrCast(dest);
        @memcpy(dest_slice[0..bytes.len], bytes);
        _ = GlobalUnlock(hmem);
        // SetClipboardData takes ownership of hmem on success.
        _ = SetClipboardData(id, hmem);
    }
}

pub fn clear() !void {
    if (OpenClipboard(null) == .FALSE) return error.PasteboardUnavailable;
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

var subscribe_mutex: SpinMutex = .{};
var subscribers: std.ArrayListUnmanaged(Subscriber) = .empty;

const SpinMutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};
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

    if (AddClipboardFormatListener(hwnd) == .FALSE) {
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
        const ret: c_int = @intFromEnum(GetMessageW(&msg, null, 0, 0));
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

    const process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid);
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
