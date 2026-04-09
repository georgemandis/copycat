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
    _ = format;
    _ = data;
    // X11 write lands in Task 12.
    return ClipboardError.NoDisplayServer;
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    ensureInit(allocator);
    _ = pairs;
    // X11 write lands in Task 12.
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
    return 0; // X11 getChangeCount lands in Task 13.
}

pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) (ClipboardError || paths.DecodePathError || Allocator.Error)![]const []const u8 {
    ensureInit(allocator);
    _ = format;
    // Wired in Task 14.
    return ClipboardError.NoDisplayServer;
}

pub fn subscribe(
    allocator: Allocator,
    callback: SubscribeCallback,
    userdata: ?*anyopaque,
) !SubscribeHandle {
    ensureInit(allocator);
    _ = callback;
    _ = userdata;
    // X11 subscribe lands in Task 13.
    return ClipboardError.SubscribeFailed;
}

pub fn unsubscribe(handle: SubscribeHandle) void {
    _ = handle;
}
