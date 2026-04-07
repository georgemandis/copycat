const std = @import("std");
const clipboard = @import("clipboard");

const allocator = std.heap.c_allocator;

/// Result of a clipboard read operation.
/// status == 0:  success — `data` points to `len` bytes; caller MUST free with clipboard_free.
/// status == 1:  format not present on the clipboard — `data` is null.
/// status == -1: error reading the clipboard — `data` is null.
pub const ClipboardData = extern struct {
    data: ?[*]const u8,
    len: usize,
    status: i32,
};

/// A (format, data) pair for clipboard_write_multiple.
/// `format` is a null-terminated UTI string. `data` and `len` describe the bytes.
/// When `len == 0`, `data` may be any value (it will not be dereferenced).
pub const ClipboardFormatPair = extern struct {
    format: [*:0]const u8,
    data: [*]const u8,
    len: usize,
};

/// Build a slice from an FFI (pointer, length) pair, treating zero-length as
/// an empty slice without dereferencing the pointer. C callers commonly pass
/// a null or undefined pointer alongside len == 0; this guards against that.
inline fn ffiSlice(ptr: [*]const u8, len: usize) []const u8 {
    return if (len == 0) &[_]u8{} else ptr[0..len];
}

/// List all clipboard format identifiers (UTIs on macOS) as a JSON array string.
///
/// Returns a null-terminated, heap-allocated string on success. The caller MUST
/// free the returned pointer with clipboard_free(). Returns null on error.
///
/// The returned JSON looks like: ["public.utf8-plain-text","public.html"]
///
/// NOTE: Format names are not JSON-escaped. Standard macOS UTIs are reverse-DNS
/// strings (e.g. `public.utf8-plain-text`, `com.example.foo`) and never contain
/// characters that require escaping. If a non-standard application registered
/// a UTI containing `"` or `\`, the returned JSON would be malformed.
export fn clipboard_list_formats() ?[*:0]u8 {
    const formats = clipboard.listFormats(allocator) catch return null;
    defer {
        for (formats) |f| allocator.free(f);
        allocator.free(formats);
    }

    var json = std.array_list.Managed(u8).init(allocator);
    defer json.deinit();

    json.append('[') catch return null;
    for (formats, 0..) |format, i| {
        if (i > 0) json.append(',') catch return null;
        json.append('"') catch return null;
        json.appendSlice(format) catch return null;
        json.append('"') catch return null;
    }
    json.append(']') catch return null;

    const result = allocator.allocSentinel(u8, json.items.len, 0) catch return null;
    @memcpy(result[0..json.items.len], json.items);
    return result;
}

/// Read raw bytes for the given format from the clipboard.
///
/// On success (status == 0), the returned `.data` points to `.len` bytes that
/// the caller MUST free with clipboard_free(). Zero-length data is valid: a
/// successful read may return `.len == 0` with `.data` non-null.
///
/// If the format is not present on the clipboard, returns status == 1 with
/// `.data == null`. On any other error, returns status == -1 with `.data == null`.
export fn clipboard_read_format(format: [*:0]const u8) ClipboardData {
    const format_slice = std.mem.sliceTo(format, 0);
    const result = clipboard.readFormat(allocator, format_slice) catch {
        return .{ .data = null, .len = 0, .status = -1 };
    };

    if (result) |bytes| {
        return .{ .data = bytes.ptr, .len = bytes.len, .status = 0 };
    } else {
        return .{ .data = null, .len = 0, .status = 1 };
    }
}

/// FFI-friendly variant of clipboard_read_format for languages (like Bun) that
/// cannot receive struct returns by value. Writes the result through the
/// provided out-pointers instead of returning a struct.
///
/// On success: out_status.* == 0, out_data.* points to out_len.* bytes that
///             the caller MUST free with clipboard_free().
/// Format absent: out_status.* == 1, out_data.* == null, out_len.* == 0.
/// Error:  out_status.* == -1, out_data.* == null, out_len.* == 0.
export fn clipboard_read_format_ex(
    format: [*:0]const u8,
    out_data: *?[*]const u8,
    out_len: *usize,
    out_status: *i32,
) void {
    const format_slice = std.mem.sliceTo(format, 0);
    const result = clipboard.readFormat(allocator, format_slice) catch {
        out_data.* = null;
        out_len.* = 0;
        out_status.* = -1;
        return;
    };

    if (result) |bytes| {
        out_data.* = bytes.ptr;
        out_len.* = bytes.len;
        out_status.* = 0;
    } else {
        out_data.* = null;
        out_len.* = 0;
        out_status.* = 1;
    }
}

/// Write a single format to the clipboard. Clears the clipboard first.
/// When `len == 0`, `data` may be any value (it will not be dereferenced).
/// Returns 0 on success, -1 on error.
export fn clipboard_write_format(format: [*:0]const u8, data: [*]const u8, len: usize) i32 {
    const format_slice = std.mem.sliceTo(format, 0);
    clipboard.writeFormat(allocator, format_slice, ffiSlice(data, len)) catch return -1;
    return 0;
}

/// Write multiple formats atomically. Clears the clipboard once, then writes
/// all formats. Useful for setting multiple representations (e.g. HTML + plain
/// text). Returns 0 on success, -1 on error.
///
/// All pointers in `pairs` must remain valid for the duration of the call.
/// The library does not retain references after return.
export fn clipboard_write_multiple(pairs: [*]const ClipboardFormatPair, count: u32) i32 {
    var zig_pairs = allocator.alloc(clipboard.FormatDataPair, count) catch return -1;
    defer allocator.free(zig_pairs);

    for (0..count) |i| {
        zig_pairs[i] = .{
            .format = std.mem.sliceTo(pairs[i].format, 0),
            .data = ffiSlice(pairs[i].data, pairs[i].len),
        };
    }

    clipboard.writeMultiple(allocator, zig_pairs) catch return -1;
    return 0;
}

/// Clear the clipboard. Returns 0 on success, -1 on error.
export fn clipboard_clear() i32 {
    clipboard.clear() catch return -1;
    return 0;
}

/// Returns the pasteboard change count, which monotonically increments on
/// every clipboard modification. Use for polling-based change detection.
/// Returns -1 if the pasteboard is unavailable.
export fn clipboard_change_count() i64 {
    return clipboard.getChangeCount();
}

/// Free a pointer previously returned by this library. Specifically:
///   - the string returned by clipboard_list_formats()
///   - the .data field of a ClipboardData with status == 0 from clipboard_read_format()
/// Safe to call with null. Do NOT call on pointers from any other source —
/// doing so is undefined behavior.
export fn clipboard_free(ptr: ?*anyopaque) void {
    // c_allocator delegates to malloc/free, so we can free by raw pointer.
    if (ptr) |p| {
        std.c.free(p);
    }
}
