const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos.zig"),
    .linux => @import("platform/linux/mod.zig"),
    .windows => @import("platform/windows.zig"),
    else => @compileError("Unsupported platform. Supported: macOS, Linux, Windows."),
};

pub const FormatDataPair = platform.FormatDataPair;
pub const ClipboardError = platform.ClipboardError;
pub const SubscribeCallback = platform.SubscribeCallback;
pub const SubscribeHandle = platform.SubscribeHandle;

pub fn listFormats(allocator: Allocator) ![][]const u8 {
    return platform.listFormats(allocator);
}

pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    return platform.readFormat(allocator, format);
}

pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    return platform.writeFormat(allocator, format, data);
}

pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    return platform.writeMultiple(allocator, pairs);
}

pub fn clear() !void {
    return platform.clear();
}

pub fn getChangeCount() i64 {
    return platform.getChangeCount();
}

/// Decodes a file-reference pasteboard format (e.g. `public.file-url`,
/// `NSFilenamesPboardType`, `public.url` with file:// scheme) into one or
/// more POSIX paths. Caller owns the outer slice AND each inner path string.
pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) ![]const []const u8 {
    return platform.decodePathsForFormat(allocator, format);
}

/// Register a callback that fires on every clipboard change. Spawns a
/// background thread on first subscription; reuses it for subsequent
/// subscribers. The callback runs on the background thread, not the
/// caller's thread — callers must ensure their callback is thread-safe
/// with respect to any state it touches.
///
/// Platform notes:
///   - macOS: 250ms polling on NSPasteboard.changeCount (event-driven variant TBD).
///   - Linux/Wayland: event-driven via zwlr_data_control selection events.
///   - Linux/X11: polling-based (500ms default, tunable via LINUX_X11_POLL_MS).
///
/// Implementation note: the current macOS and Linux backends support up to 64
/// concurrent subscribers; additional subscribers beyond that are silently
/// dropped during fanout. Lift the cap in the respective backends if you hit
/// this limit.
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
