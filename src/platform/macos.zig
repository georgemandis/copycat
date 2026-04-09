const std = @import("std");
const objc = @import("../objc.zig");

const Allocator = std.mem.Allocator;

/// Callback invoked when the clipboard changes. Runs on the library's
/// background subscription thread, not the caller's thread.
pub const SubscribeCallback = *const fn (userdata: ?*anyopaque) void;

/// Opaque handle returned by subscribe. `id == 0` is the invalid-handle
/// sentinel; unsubscribe on a zero-initialized handle is a no-op.
pub const SubscribeHandle = struct {
    id: u64,
};

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
    UnsupportedFormat,
    FormatNotFound,
    MalformedPlist,
    // New for cross-platform (Linux) port; defined on every platform so
    // `clipboard.zig` can re-export a unified error set.
    NoDisplayServer,
    SubscribeFailed,
    MalformedUriList,
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

// ---------------------------------------------------------------------------
// Path decoding for file-reference formats
// ---------------------------------------------------------------------------

const paths = @import("../paths.zig");

/// The allowlist of UTIs that `decodePathsForFormat` will accept.
/// Anything else returns `ClipboardError.UnsupportedFormat`.
///
/// `NSFilenamesPboardType` is deprecated by Apple in favor of multiple
/// `public.file-url` items on the pasteboard, but real-world Finder still
/// uses it when more than one file is copied, so we support it.
const file_ref_allowlist = [_][]const u8{
    "public.file-url",
    "NSFilenamesPboardType",
    "public.url",
};

fn isFileRefFormat(format: []const u8) bool {
    for (file_ref_allowlist) |allowed| {
        if (std.mem.eql(u8, format, allowed)) return true;
    }
    return false;
}

/// Decodes a file-reference pasteboard format into one or more POSIX paths.
///
/// Returns `ClipboardError.UnsupportedFormat` for any format not in the
/// allowlist — this check happens BEFORE any pasteboard access, so the error
/// is deterministic regardless of clipboard state.
///
/// Returns `ClipboardError.FormatNotFound` if the format is in the allowlist
/// but absent from the current pasteboard.
///
/// Caller owns the returned outer slice AND each inner path string.
pub fn decodePathsForFormat(
    allocator: Allocator,
    format: []const u8,
) ![]const []const u8 {
    // Allowlist gate — before touching the pasteboard.
    if (!isFileRefFormat(format)) return ClipboardError.UnsupportedFormat;

    // Fetch raw bytes via the existing readFormat.
    const raw = try readFormat(allocator, format) orelse return ClipboardError.FormatNotFound;
    defer allocator.free(raw);

    // Dispatch by format.
    if (std.mem.eql(u8, format, "public.file-url") or std.mem.eql(u8, format, "public.url")) {
        const path = try paths.decodeFileUrl(allocator, raw);
        errdefer allocator.free(path);

        const result = try allocator.alloc([]const u8, 1);
        result[0] = path;
        return result;
    }

    if (std.mem.eql(u8, format, "NSFilenamesPboardType")) {
        return try decodeFilenamesPlist(allocator, raw);
    }

    unreachable; // allowlist check above guarantees one of the branches matches
}

/// STUB: replaced by a real NSPasteboardDidChangeNotification implementation
/// in Task 4. Returns `error.SubscribeFailed` so callers fail fast if they
/// try to use it before Task 4 lands.
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

/// STUB: no-op until Task 4 wires up real state.
pub fn unsubscribe(handle: SubscribeHandle) void {
    _ = handle;
}

/// Parse an `NSFilenamesPboardType` binary plist (bytes from the pasteboard)
/// and return an allocator-owned slice of allocator-owned POSIX path strings.
///
/// Uses `NSPropertyListSerialization propertyListWithData:options:format:error:`
/// from Foundation, which handles both binary and XML plist formats.
fn decodeFilenamesPlist(allocator: Allocator, bytes: []const u8) ![]const []const u8 {
    // Wrap the bytes in an NSData (autoreleased).
    const nsdata = if (bytes.len == 0)
        objc.nsDataEmpty()
    else
        objc.nsDataFromBytes(bytes.ptr, bytes.len);

    // Call [NSPropertyListSerialization propertyListWithData:options:format:error:]
    // Signature: + (id)propertyListWithData:(NSData *)data
    //                              options:(NSPropertyListReadOptions)opt
    //                               format:(NSPropertyListFormat *)format
    //                                error:(out NSError **)error;
    //
    // We pass 0 for options (NSPropertyListImmutable), and null for both
    // out-pointers — we don't care which plist format it was, and if it fails
    // we just need to know the call returned nil.
    const NSPropertyListSerialization = objc.getClass("NSPropertyListSerialization") orelse return ClipboardError.MalformedPlist;

    const plist: ?objc.id = objc.msgSend(
        ?objc.id,
        NSPropertyListSerialization,
        objc.sel("propertyListWithData:options:format:error:"),
        .{ nsdata, @as(objc.NSUInteger, 0), @as(?*anyopaque, null), @as(?*anyopaque, null) },
    );
    const plist_id = plist orelse return ClipboardError.MalformedPlist;

    // Must be an NSArray.
    const NSArray = objc.getClass("NSArray") orelse return ClipboardError.MalformedPlist;
    const is_array = objc.msgSend(bool, plist_id, objc.sel("isKindOfClass:"), .{NSArray});
    if (!is_array) return ClipboardError.MalformedPlist;

    const count = objc.nsArrayCount(plist_id);
    var result = try allocator.alloc([]const u8, count);
    errdefer allocator.free(result);

    // Track how many inner strings we've successfully allocated, so a later
    // allocation failure can free only the ones we own. Zig runs errdefers
    // in reverse order, so on error this fires BEFORE `allocator.free(result)`
    // above — inner strings freed first, then the outer slice.
    var filled: usize = 0;
    errdefer {
        for (result[0..filled]) |s| allocator.free(s);
    }

    const NSString = objc.getClass("NSString") orelse return ClipboardError.MalformedPlist;
    for (0..count) |i| {
        const elem = objc.nsArrayObjectAtIndex(plist_id, i);
        const is_str = objc.msgSend(bool, elem, objc.sel("isKindOfClass:"), .{NSString});
        if (!is_str) return ClipboardError.MalformedPlist;

        const cstr = objc.fromNSString(elem) orelse return ClipboardError.MalformedPlist;
        const len = std.mem.len(cstr);
        const copy = try allocator.alloc(u8, len);
        @memcpy(copy, cstr[0..len]);
        result[filled] = copy;
        filled += 1;
    }

    return result;
}
