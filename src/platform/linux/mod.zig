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
