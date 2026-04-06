const std = @import("std");
const objc = @import("../objc.zig");

const Allocator = std.mem.Allocator;

/// Get the NSPasteboard generalPasteboard singleton. Returns null if unavailable (e.g. daemon context).
fn getPasteboard() ?objc.id {
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return null;
    return objc.msgSend(?objc.id, NSPasteboard, objc.sel("generalPasteboard"), .{});
}

/// Returns the pasteboard change count. Returns -1 if pasteboard is unavailable.
/// Note: NSPasteboard.changeCount returns NSInteger (isize), which is i64 on 64-bit macOS.
pub fn getChangeCount() i64 {
    const pb = getPasteboard() orelse return -1;
    return objc.msgSend(objc.NSInteger, pb, objc.sel("changeCount"), .{});
}

pub const ClipboardError = error{
    PasteboardUnavailable,
    NoItems,
    WriteFailed,
};

/// List all format identifiers (UTIs) on the clipboard.
/// Caller owns the returned slice and each string within it.
pub fn listFormats(allocator: Allocator) ![][]const u8 {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;

    // Get pasteboard items
    const items: ?objc.id = objc.msgSend(?objc.id, pb, objc.sel("pasteboardItems"), .{});
    const items_array = items orelse return try allocator.alloc([]const u8, 0);

    const items_count = objc.nsArrayCount(items_array);
    if (items_count == 0) return try allocator.alloc([]const u8, 0);

    // Get first item's types
    const first_item = objc.nsArrayObjectAtIndex(items_array, 0);
    const types: ?objc.id = objc.msgSend(?objc.id, first_item, objc.sel("types"), .{});
    const types_array = types orelse return try allocator.alloc([]const u8, 0);

    const count = objc.nsArrayCount(types_array);
    if (count == 0) return try allocator.alloc([]const u8, 0);

    var result = try allocator.alloc([]const u8, count);
    errdefer allocator.free(result);
    var actual_count: usize = 0;

    for (0..count) |i| {
        const nsstr = objc.nsArrayObjectAtIndex(types_array, i);
        const cstr = objc.fromNSString(nsstr) orelse continue;
        const len = std.mem.len(cstr);
        const copy = try allocator.alloc(u8, len);
        @memcpy(copy, cstr[0..len]);
        result[actual_count] = copy;
        actual_count += 1;
    }

    // Shrink if we skipped any. realloc to a smaller size shouldn't fail in
    // practice, but if it does we propagate the error.
    if (actual_count < count) {
        result = try allocator.realloc(result, actual_count);
    }

    return result;
}

/// Read raw bytes for a given format (UTI) from the clipboard.
/// Returns null if the format is not present.
/// Caller owns the returned slice.
pub fn readFormat(allocator: Allocator, format: []const u8) !?[]const u8 {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;

    const items: ?objc.id = objc.msgSend(?objc.id, pb, objc.sel("pasteboardItems"), .{});
    const items_array = items orelse return null;

    const items_count = objc.nsArrayCount(items_array);
    if (items_count == 0) return null;

    const first_item = objc.nsArrayObjectAtIndex(items_array, 0);

    // Create NSString for the format UTI — need null-terminated copy
    const format_z = try allocator.dupeZ(u8, format);
    defer allocator.free(format_z);

    const format_nsstr = objc.nsString(format_z);

    // Call [item dataForType:]
    const nsdata: ?objc.id = objc.msgSend(?objc.id, first_item, objc.sel("dataForType:"), .{format_nsstr});
    const data = nsdata orelse return null;

    const len = objc.nsDataLength(data);
    if (len == 0) {
        // Zero-length data is valid — return empty owned slice
        return try allocator.alloc(u8, 0);
    }

    const bytes = objc.nsDataBytes(data) orelse return null;

    // Copy bytes into Zig-owned memory
    const result = try allocator.alloc(u8, len);
    @memcpy(result, bytes[0..len]);
    return result;
}

/// Clear the clipboard.
pub fn clear() !void {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;
    _ = objc.msgSend(objc.NSInteger, pb, objc.sel("clearContents"), .{});
}

/// Write a single format to the clipboard. Clears the clipboard first.
pub fn writeFormat(allocator: Allocator, format: []const u8, data: []const u8) !void {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;

    // Clear first (required by macOS — writes fail without prior clearContents)
    _ = objc.msgSend(objc.NSInteger, pb, objc.sel("clearContents"), .{});

    const format_z = try allocator.dupeZ(u8, format);
    defer allocator.free(format_z);

    const format_nsstr = objc.nsString(format_z);

    // Handle zero-length data safely (avoid sending undefined pointer through FFI)
    const nsdata = if (data.len == 0)
        objc.nsDataEmpty()
    else
        objc.nsDataFromBytes(data.ptr, data.len);

    // [pasteboard setData:forType:] returns BOOL
    const success = objc.msgSend(bool, pb, objc.sel("setData:forType:"), .{ nsdata, format_nsstr });
    if (!success) return ClipboardError.WriteFailed;
}

pub const FormatDataPair = struct {
    format: []const u8,
    data: []const u8,
};

/// Write multiple formats atomically. Clears clipboard once, then writes all.
pub fn writeMultiple(allocator: Allocator, pairs: []const FormatDataPair) !void {
    const pb = getPasteboard() orelse return ClipboardError.PasteboardUnavailable;

    // Clear once
    _ = objc.msgSend(objc.NSInteger, pb, objc.sel("clearContents"), .{});

    // Write each format
    for (pairs) |pair| {
        const format_z = try allocator.dupeZ(u8, pair.format);
        defer allocator.free(format_z);

        const format_nsstr = objc.nsString(format_z);
        const nsdata = if (pair.data.len == 0)
            objc.nsDataEmpty()
        else
            objc.nsDataFromBytes(pair.data.ptr, pair.data.len);

        const success = objc.msgSend(bool, pb, objc.sel("setData:forType:"), .{ nsdata, format_nsstr });
        if (!success) return ClipboardError.WriteFailed;
    }
}
