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
