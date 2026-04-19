const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("../../paths.zig");

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
// Backend state. Currently X11-only; Wayland backend will be added in
// Tasks 8-10.
// ---------------------------------------------------------------------------
const x11 = @import("x11.zig");

var backend_allocator: ?Allocator = null;
var x11_ready: bool = false;
var init_done: bool = false;

fn ensureInit(alloc: Allocator) void {
    if (init_done) return;
    init_done = true;
    backend_allocator = alloc;
    x11_ready = x11.tryOpenDisplay(alloc);
}

pub fn listFormats(allocator: Allocator) ![][]const u8 {
    ensureInit(allocator);
    if (x11_ready) return x11.listFormats(allocator);
    return ClipboardError.NoDisplayServer;
}

pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    ensureInit(allocator);
    if (x11_ready) return x11.readFormat(allocator, format);
    return ClipboardError.NoDisplayServer;
}

pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    ensureInit(allocator);
    if (x11_ready) return x11.writeFormat(allocator, format, data);
    return ClipboardError.NoDisplayServer;
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    ensureInit(allocator);
    if (x11_ready) return x11.writeMultiple(allocator, pairs);
    return ClipboardError.NoDisplayServer;
}

pub fn clear() !void {
    // ensureInit requires an allocator; if we haven't initialized yet,
    // there's nothing to clear.
    if (!init_done) return ClipboardError.NoDisplayServer;
    if (x11_ready) return x11.clear();
    return ClipboardError.NoDisplayServer;
}

pub fn getChangeCount() i64 {
    if (x11_ready) return x11.getChangeCount();
    return 0;
}

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
) (ClipboardError || paths.DecodePathError || Allocator.Error)![]const []const u8 {
    if (!isFileRefFormat(format)) return ClipboardError.UnsupportedFormat;

    ensureInit(allocator);
    const raw = (try readFormat(allocator, format)) orelse return ClipboardError.FormatNotFound;
    defer allocator.free(raw);

    return paths.decodeUriList(allocator, raw);
}

pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    ensureInit(allocator);
    if (x11_ready) return x11.subscribe(allocator, callback, userdata);
    return ClipboardError.SubscribeFailed;
}

pub fn unsubscribe(handle: SubscribeHandle) void {
    if (x11_ready) {
        x11.unsubscribe(handle);
        return;
    }
}

pub fn getSourceInfo() @import("../../clipboard.zig").ClipboardSourceInfo {
    const ClipboardSourceInfo = @import("../../clipboard.zig").ClipboardSourceInfo;
    if (x11_ready) return x11.getSourceInfo();
    return ClipboardSourceInfo{
        .pid = -1,
        .name = null,
        .status = -1,
    };
}
