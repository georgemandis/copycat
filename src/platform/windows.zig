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

pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) (ClipboardError || paths.DecodePathError || Allocator.Error)![]const []const u8 {
    _ = allocator;
    _ = format;
    return ClipboardError.PasteboardUnavailable;
}

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

pub fn unsubscribe(handle: SubscribeHandle) void {
    _ = handle;
}
