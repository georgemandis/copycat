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
