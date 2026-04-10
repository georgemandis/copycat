//! Pure Zig helpers for decoding file-reference pasteboard bytes into POSIX paths.
//!
//! This module has NO dependencies on Foundation, Obj-C, or any OS APIs —
//! it operates purely on byte slices. That makes it trivially unit-testable
//! and portable if the clipboard library ever targets non-macOS platforms
//! (percent decoding and file:// parsing are platform-agnostic).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DecodePathError = error{
    /// Input did not begin with `file://`.
    NotFileScheme,
    /// URL was malformed in a way we can't recover from (e.g. empty after prefix).
    MalformedUrl,
    /// A `%` escape was truncated or contained non-hex characters.
    InvalidPercentEncoding,
    /// A DROPFILES (CF_HDROP) blob was too short or structurally invalid.
    MalformedHDrop,
    /// Allocator ran out of memory.
    OutOfMemory,
};

/// Percent-decodes a byte slice: `%20` → ` `, `%E2%98%83` → `☃` (UTF-8 passthrough).
/// A lone `%` or a `%` followed by fewer than two hex characters is an error.
/// Caller owns the returned slice.
pub fn percentDecode(allocator: Allocator, input: []const u8) DecodePathError![]u8 {
    var out = try std.array_list.Managed(u8).initCapacity(allocator, input.len);
    errdefer out.deinit();

    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '%') {
            try out.append(input[i]);
            continue;
        }
        if (i + 2 >= input.len) return DecodePathError.InvalidPercentEncoding;
        const hi = std.fmt.charToDigit(input[i + 1], 16) catch return DecodePathError.InvalidPercentEncoding;
        const lo = std.fmt.charToDigit(input[i + 2], 16) catch return DecodePathError.InvalidPercentEncoding;
        try out.append((hi << 4) | lo);
        i += 2;
    }

    return try out.toOwnedSlice();
}

/// Decodes a `file://...` URL byte slice into a POSIX path.
///
/// Steps:
///   1. Strip a single trailing NUL byte if present (macOS pasteboards sometimes NUL-terminate).
///   2. Verify the input begins with `file://`. Otherwise → `NotFileScheme`.
///   3. Strip the `file://` prefix.
///   4. Reject empty-after-prefix inputs → `MalformedUrl`.
///   5. Percent-decode the remainder and return it.
///
/// Note: does NOT canonicalize, resolve symlinks, or check existence.
/// Caller owns the returned slice.
pub fn decodeFileUrl(allocator: Allocator, url_bytes: []const u8) DecodePathError![]u8 {
    // 1. Strip a single trailing NUL if present.
    var trimmed: []const u8 = url_bytes;
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == 0) {
        trimmed = trimmed[0 .. trimmed.len - 1];
    }

    // 2. Verify `file://` prefix.
    const prefix = "file://";
    if (trimmed.len < prefix.len or !std.mem.eql(u8, trimmed[0..prefix.len], prefix)) {
        return DecodePathError.NotFileScheme;
    }

    // 3 + 4. Strip prefix, reject empty remainder.
    const after_prefix = trimmed[prefix.len..];
    if (after_prefix.len == 0) return DecodePathError.MalformedUrl;

    // 5. Percent-decode.
    return try percentDecode(allocator, after_prefix);
}

/// Parses a text/uri-list blob (RFC 2483) into POSIX paths.
///
/// Steps:
///   1. Split the input on CRLF or LF (tolerant of both).
///   2. Skip blank lines and comment lines (lines starting with '#').
///   3. For each remaining line, delegate to decodeFileUrl.
///   4. If decodeFileUrl returns NotFileScheme, propagate the error —
///      non-file URIs are not supported by this library.
///
/// Caller owns the outer slice AND each inner path string.
pub fn decodeUriList(
    allocator: Allocator,
    bytes: []const u8,
) DecodePathError![]const []const u8 {
    var out = try std.array_list.Managed([]const u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit();
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= bytes.len) : (i += 1) {
        const at_eol = i == bytes.len or bytes[i] == '\n';
        if (!at_eol) continue;

        // Extract the line, stripping a trailing \r if present (CRLF tolerance).
        var line_end = i;
        if (line_end > start and bytes[line_end - 1] == '\r') line_end -= 1;
        const line = bytes[start..line_end];
        start = i + 1;

        // Skip blanks and comments.
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const decoded = try decodeFileUrl(allocator, line);
        errdefer allocator.free(decoded);
        try out.append(decoded);
    }

    return try out.toOwnedSlice();
}

/// Decodes a Windows `CF_HDROP` clipboard blob (a serialised `DROPFILES` struct)
/// into a slice of UTF-8 path strings.
///
/// The `DROPFILES` layout (all fields little-endian):
///   offset  0, u32: pFiles  — byte offset from the start of the struct to the file list
///   offset  4, u32: pt.x    — (ignored)
///   offset  8, u32: pt.y    — (ignored)
///   offset 12, u32: fNC     — (ignored)
///   offset 16, u32: fWide   — 0 = ANSI, non-zero = UTF-16LE
///
/// The file list starts at `data[pFiles..]` and consists of null-terminated
/// strings (each path followed by a NUL character/code-unit), terminated by an
/// extra NUL (i.e. a double-NUL marks the end).
///
/// Returns `error.MalformedHDrop` if `data` is shorter than 20 bytes (the
/// minimum header size) or if `pFiles` points past the end of `data`.
///
/// Caller owns the returned outer slice AND each inner path string.
pub fn decodeHDrop(allocator: Allocator, data: []const u8) DecodePathError![][]u8 {
    // The DROPFILES header is exactly 20 bytes.
    if (data.len < 20) return DecodePathError.MalformedHDrop;

    const p_files = std.mem.readInt(u32, data[0..4], .little);
    const f_wide = std.mem.readInt(u32, data[16..20], .little);

    if (p_files > data.len) return DecodePathError.MalformedHDrop;

    const file_list = data[p_files..];

    var out = try std.array_list.Managed([]u8).initCapacity(allocator, 4);
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit();
    }

    if (f_wide != 0) {
        // UTF-16LE: iterate over 2-byte code units.
        // We work on raw bytes (unaligned) and use readInt to build u16 values,
        // then batch them into a []u16 buffer for std.unicode.utf16LeToUtf8Alloc.
        var pos: usize = 0;
        while (pos + 1 < file_list.len) {
            // Collect one null-terminated UTF-16LE string into a u16 buffer.
            var units = try std.array_list.Managed(u16).initCapacity(allocator, 64);
            defer units.deinit();

            while (pos + 1 < file_list.len) {
                const unit = std.mem.readInt(u16, file_list[pos..][0..2], .little);
                pos += 2;
                if (unit == 0) break; // null terminator for this path
                try units.append(unit);
            }

            // An empty unit list means we hit the double-null terminator.
            if (units.items.len == 0) break;

            const utf8 = std.unicode.utf16LeToUtf8Alloc(allocator, units.items) catch |err| switch (err) {
                error.OutOfMemory => return DecodePathError.OutOfMemory,
                else => return DecodePathError.MalformedHDrop,
            };
            errdefer allocator.free(utf8);
            try out.append(utf8);
        }
    } else {
        // ANSI: single-byte null-terminated strings.
        var pos: usize = 0;
        while (pos < file_list.len) {
            if (file_list[pos] == 0) break; // double-null terminator

            // Find the null terminator for this path.
            const start = pos;
            while (pos < file_list.len and file_list[pos] != 0) : (pos += 1) {}
            const path_bytes = file_list[start..pos];
            pos += 1; // skip the null terminator

            const copy = try allocator.dupe(u8, path_bytes);
            errdefer allocator.free(copy);
            try out.append(copy);
        }
    }

    return try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "percentDecode passes through plain ASCII unchanged" {
    const result = try percentDecode(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "percentDecode handles empty input" {
    const result = try percentDecode(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "percentDecode decodes %20 to space" {
    const result = try percentDecode(std.testing.allocator, "a%20b");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("a b", result);
}

test "percentDecode decodes multi-byte UTF-8 sequence" {
    // %E2%98%83 is U+2603 SNOWMAN (☃) in UTF-8
    const result = try percentDecode(std.testing.allocator, "%E2%98%83");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("\xE2\x98\x83", result);
}

test "percentDecode handles uppercase and lowercase hex" {
    const upper = try percentDecode(std.testing.allocator, "%2F");
    defer std.testing.allocator.free(upper);
    try std.testing.expectEqualStrings("/", upper);

    const lower = try percentDecode(std.testing.allocator, "%2f");
    defer std.testing.allocator.free(lower);
    try std.testing.expectEqualStrings("/", lower);
}

test "percentDecode rejects truncated escape at end" {
    try std.testing.expectError(
        DecodePathError.InvalidPercentEncoding,
        percentDecode(std.testing.allocator, "abc%2"),
    );
}

test "percentDecode rejects lone percent sign" {
    try std.testing.expectError(
        DecodePathError.InvalidPercentEncoding,
        percentDecode(std.testing.allocator, "%"),
    );
}

test "percentDecode rejects non-hex characters in escape" {
    try std.testing.expectError(
        DecodePathError.InvalidPercentEncoding,
        percentDecode(std.testing.allocator, "%ZZ"),
    );
}

test "decodeFileUrl strips file:// prefix and percent-decodes" {
    const result = try decodeFileUrl(std.testing.allocator, "file:///Users/george/Downloads/thing.pdf");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/Users/george/Downloads/thing.pdf", result);
}

test "decodeFileUrl handles percent-encoded spaces" {
    const result = try decodeFileUrl(std.testing.allocator, "file:///Users/george/My%20Files/thing.pdf");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/Users/george/My Files/thing.pdf", result);
}

test "decodeFileUrl strips trailing NUL byte" {
    const input = "file:///tmp/foo\x00";
    const result = try decodeFileUrl(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/foo", result);
}

test "decodeFileUrl handles UTF-8 in path" {
    // %E2%98%83 is ☃
    const result = try decodeFileUrl(std.testing.allocator, "file:///tmp/%E2%98%83.txt");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("/tmp/\xE2\x98\x83.txt", result);
}

test "decodeFileUrl rejects http scheme" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeFileUrl(std.testing.allocator, "http://example.com/"),
    );
}

test "decodeFileUrl rejects missing scheme" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeFileUrl(std.testing.allocator, "/plain/path"),
    );
}

test "decodeFileUrl rejects empty input" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeFileUrl(std.testing.allocator, ""),
    );
}

test "decodeFileUrl rejects file:// with empty path" {
    try std.testing.expectError(
        DecodePathError.MalformedUrl,
        decodeFileUrl(std.testing.allocator, "file://"),
    );
}

test "decodeUriList single file LF" {
    const input = "file:///tmp/foo\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/foo", result[0]);
}

test "decodeUriList single file CRLF" {
    const input = "file:///tmp/foo\r\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/foo", result[0]);
}

test "decodeUriList single file no trailing newline" {
    const input = "file:///tmp/foo";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/foo", result[0]);
}

test "decodeUriList multiple files LF" {
    const input = "file:///tmp/a\nfile:///tmp/b\nfile:///tmp/c\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
    try std.testing.expectEqualStrings("/tmp/c", result[2]);
}

test "decodeUriList multiple files CRLF" {
    const input = "file:///tmp/a\r\nfile:///tmp/b\r\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
}

test "decodeUriList mixed LF and CRLF" {
    const input = "file:///tmp/a\nfile:///tmp/b\r\nfile:///tmp/c\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
    try std.testing.expectEqualStrings("/tmp/c", result[2]);
}

test "decodeUriList skips comment lines" {
    const input = "# this is a comment\nfile:///tmp/a\n# another comment\nfile:///tmp/b\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
}

test "decodeUriList skips blank lines" {
    const input = "\nfile:///tmp/a\n\n\nfile:///tmp/b\n\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("/tmp/a", result[0]);
    try std.testing.expectEqualStrings("/tmp/b", result[1]);
}

test "decodeUriList percent-encoded spaces" {
    const input = "file:///tmp/My%20Docs/foo.txt\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/My Docs/foo.txt", result[0]);
}

test "decodeUriList UTF-8 percent-encoded" {
    // %E2%98%83 is a snowman
    const input = "file:///tmp/%E2%98%83.txt\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer {
        for (result) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(result);
    }
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqualStrings("/tmp/\xE2\x98\x83.txt", result[0]);
}

test "decodeUriList empty input" {
    const result = try decodeUriList(std.testing.allocator, "");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decodeUriList only comments and blanks" {
    const input = "# hello\n\n# world\n\n";
    const result = try decodeUriList(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "decodeUriList rejects http scheme" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeUriList(std.testing.allocator, "http://example.com/\n"),
    );
}

test "decodeUriList rejects mixed file and non-file" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeUriList(std.testing.allocator, "file:///tmp/a\nhttps://b/\n"),
    );
}

test "decodeUriList rejects missing scheme" {
    try std.testing.expectError(
        DecodePathError.NotFileScheme,
        decodeUriList(std.testing.allocator, "/plain/path\n"),
    );
}

test "decodeUriList rejects invalid percent encoding" {
    try std.testing.expectError(
        DecodePathError.InvalidPercentEncoding,
        decodeUriList(std.testing.allocator, "file:///tmp/bad%ZZ\n"),
    );
}

test "decodeHDrop: single wide-char path" {
    // DROPFILES header: pFiles=20, pt=(0,0), fNC=0, fWide=1
    // Followed by "C:\test.txt\0\0" in UTF-16LE
    const header = [_]u8{
        0x14, 0x00, 0x00, 0x00, // pFiles = 20
        0x00, 0x00, 0x00, 0x00, // pt.x = 0
        0x00, 0x00, 0x00, 0x00, // pt.y = 0
        0x00, 0x00, 0x00, 0x00, // fNC = 0
        0x01, 0x00, 0x00, 0x00, // fWide = 1 (Unicode)
    };
    // "C:\test.txt" in UTF-16LE + null + null (double-null terminator)
    const path_data = [_]u8{
        'C', 0, ':', 0, '\\', 0, 't', 0, 'e', 0, 's', 0, 't', 0, '.', 0, 't', 0, 'x', 0, 't', 0,
        0, 0, // null terminator
        0, 0, // double-null terminator
    };
    const data = header ++ path_data;

    const paths = try decodeHDrop(std.testing.allocator, &data);
    defer {
        for (paths) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("C:\\test.txt", paths[0]);
}

test "decodeHDrop: multiple wide-char paths" {
    const header = [_]u8{
        0x14, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x01, 0x00, 0x00, 0x00,
    };
    // "A\0" + null + "B\0" + null + double-null
    const path_data = [_]u8{
        'A', 0, 0, 0, // "A" + null
        'B', 0, 0, 0, // "B" + null
        0, 0,         // double-null terminator
    };
    const data = header ++ path_data;

    const paths = try decodeHDrop(std.testing.allocator, &data);
    defer {
        for (paths) |p| std.testing.allocator.free(p);
        std.testing.allocator.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("A", paths[0]);
    try std.testing.expectEqualStrings("B", paths[1]);
}

test "decodeHDrop: data too short for header" {
    const short = [_]u8{ 0x14, 0x00 };
    try std.testing.expectError(error.MalformedHDrop, decodeHDrop(std.testing.allocator, &short));
}
