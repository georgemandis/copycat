const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const platform = switch (builtin.os.tag) {
    .macos => @import("platform/macos.zig"),
    else => @compileError("Unsupported platform. Currently only macOS is implemented."),
};

pub const FormatDataPair = platform.FormatDataPair;
pub const ClipboardError = platform.ClipboardError;

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
