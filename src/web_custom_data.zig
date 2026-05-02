const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SubType = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub const ContainerFormat = enum {
    chromium,
    firefox,
    webkit,
};

pub const ParseResult = struct {
    format: ContainerFormat,
    origin: ?[]const u8,
    sub_types: []SubType,

    pub fn deinit(self: ParseResult, allocator: Allocator) void {
        if (self.origin) |o| allocator.free(o);
        for (self.sub_types) |st| {
            allocator.free(st.name);
            if (st.value) |v| allocator.free(v);
        }
        allocator.free(self.sub_types);
    }
};

fn utf16LeToUtf8(allocator: Allocator, utf16_bytes: []const u8) ![]u8 {
    if (utf16_bytes.len % 2 != 0) return error.InvalidData;
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i + 1 < utf16_bytes.len) : (i += 2) {
        const lo: u16 = utf16_bytes[i];
        const hi: u16 = utf16_bytes[i + 1];
        const cu = lo | (hi << 8);
        if (cu >= 0xD800 and cu <= 0xDBFF) {
            if (i + 3 >= utf16_bytes.len) return error.InvalidData;
            i += 2;
            const lo2: u16 = utf16_bytes[i];
            const hi2: u16 = utf16_bytes[i + 1];
            const cu2 = lo2 | (hi2 << 8);
            if (cu2 < 0xDC00 or cu2 > 0xDFFF) return error.InvalidData;
            const cp: u21 = 0x10000 + (@as(u21, cu - 0xD800) << 10) + @as(u21, cu2 - 0xDC00);
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidData;
            try out.appendSlice(buf[0..len]);
        } else if (cu >= 0xDC00 and cu <= 0xDFFF) {
            return error.InvalidData;
        } else {
            var buf: [3]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cu), &buf) catch return error.InvalidData;
            try out.appendSlice(buf[0..len]);
        }
    }
    return out.toOwnedSlice();
}

fn parseChromium(allocator: Allocator, data: []const u8) !ParseResult {
    if (data.len < 8) return error.InvalidData;

    const total_size = std.mem.readInt(u32, data[0..4], .little);
    const count = std.mem.readInt(u32, data[4..8], .little);

    if (count == 0 or count > 10000) return error.InvalidData;
    if (@as(usize, total_size) + 4 > data.len + 16) return error.InvalidData;

    var sub_types = try std.array_list.Managed(SubType).initCapacity(allocator, count);
    errdefer {
        for (sub_types.items) |st| {
            allocator.free(st.name);
            if (st.value) |v| allocator.free(v);
        }
        sub_types.deinit();
    }

    var offset: usize = 8;
    var entry_idx: usize = 0;
    while (entry_idx < count) : (entry_idx += 1) {
        const is_last = (entry_idx == count - 1);

        // Type
        if (offset + 4 > data.len) return error.InvalidData;
        const type_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        const type_byte_len = @as(usize, type_len) * 2;
        if (offset + type_byte_len > data.len) return error.InvalidData;
        const name = try utf16LeToUtf8(allocator, data[offset..][0..type_byte_len]);
        errdefer allocator.free(name);
        offset += type_byte_len;
        if (!is_last) offset += 2; // null terminator

        // Value
        if (offset + 4 > data.len) return error.InvalidData;
        const val_len = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;
        const val_byte_len = @as(usize, val_len) * 2;
        if (offset + val_byte_len > data.len) return error.InvalidData;
        const value = try utf16LeToUtf8(allocator, data[offset..][0..val_byte_len]);
        errdefer allocator.free(value);
        offset += val_byte_len;
        if (!is_last) offset += 2; // null terminator

        try sub_types.append(.{ .name = name, .value = value });
    }

    return .{
        .format = .chromium,
        .origin = null,
        .sub_types = try sub_types.toOwnedSlice(),
    };
}

fn parseFirefox(allocator: Allocator, data: []const u8) !ParseResult {
    var sub_types = std.array_list.Managed(SubType).init(allocator);
    errdefer {
        for (sub_types.items) |st| {
            allocator.free(st.name);
            if (st.value) |v| allocator.free(v);
        }
        sub_types.deinit();
    }

    var offset: usize = 0;
    while (offset + 4 <= data.len) {
        const marker = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (marker == 0) break; // sentinel
        if (marker != 1) return error.InvalidData;

        // Type
        if (offset + 4 > data.len) return error.InvalidData;
        const type_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (offset + type_len > data.len) return error.InvalidData;
        const name = try utf16LeToUtf8(allocator, data[offset..][0..type_len]);
        errdefer allocator.free(name);
        offset += type_len;

        // Value
        if (offset + 4 > data.len) return error.InvalidData;
        const val_len = std.mem.readInt(u32, data[offset..][0..4], .big);
        offset += 4;
        if (offset + val_len > data.len) return error.InvalidData;
        const value = try utf16LeToUtf8(allocator, data[offset..][0..val_len]);
        errdefer allocator.free(value);
        offset += val_len;

        try sub_types.append(.{ .name = name, .value = value });
    }

    if (sub_types.items.len == 0) return error.InvalidData;

    return .{
        .format = .firefox,
        .origin = null,
        .sub_types = try sub_types.toOwnedSlice(),
    };
}

fn parseWebKit(allocator: Allocator, data: []const u8) !ParseResult {
    var sub_types = std.array_list.Managed(SubType).init(allocator);
    errdefer {
        for (sub_types.items) |st| {
            allocator.free(st.name);
            if (st.value) |v| allocator.free(v);
        }
        sub_types.deinit();
    }
    var origin_alloc: ?[]u8 = null;
    errdefer if (origin_alloc) |o| allocator.free(o);

    var offset: usize = 0;

    // Version (u32 LE) — must be 1
    if (offset + 4 > data.len) return error.InvalidData;
    const version = std.mem.readInt(u32, data[offset..][0..4], .little);
    offset += 4;
    if (version != 1) return error.InvalidData;

    // Origin string
    const origin_str = try readWkString(allocator, data, &offset);
    origin_alloc = origin_str;

    // HashMap<String, String>: sameOriginCustomStringData
    if (offset + 8 > data.len) return error.InvalidData;
    const map_count = std.mem.readInt(u64, data[offset..][0..8], .little);
    offset += 8;
    if (map_count > 10000) return error.InvalidData;

    var map_idx: u64 = 0;
    while (map_idx < map_count) : (map_idx += 1) {
        const key = try readWkString(allocator, data, &offset) orelse return error.InvalidData;
        errdefer allocator.free(key);
        const val = try readWkString(allocator, data, &offset);
        try sub_types.append(.{ .name = key, .value = val });
    }

    // Vector<String>: orderedTypes — we parse but don't use (types already in map)
    if (offset + 8 <= data.len) {
        const vec_count = std.mem.readInt(u64, data[offset..][0..8], .little);
        offset += 8;
        var vec_idx: u64 = 0;
        while (vec_idx < vec_count) : (vec_idx += 1) {
            const s = try readWkString(allocator, data, &offset);
            if (s) |owned| allocator.free(owned);
        }
    }
    // Remaining bytes are SHA1 checksum — we ignore them.

    if (sub_types.items.len == 0 and origin_alloc == null) return error.InvalidData;

    return .{
        .format = .webkit,
        .origin = origin_alloc,
        .sub_types = try sub_types.toOwnedSlice(),
    };
}

/// Read a WTF::Persistence encoded String.
/// Returns null for null-strings (length == 0xFFFFFFFF) and an owned slice otherwise.
fn readWkString(allocator: Allocator, data: []const u8, offset: *usize) !?[]u8 {
    if (offset.* + 4 > data.len) return error.InvalidData;
    const length = std.mem.readInt(u32, data[offset.*..][0..4], .little);
    offset.* += 4;
    if (length == 0xFFFFFFFF) return null; // null string

    if (offset.* + 1 > data.len) return error.InvalidData;
    const is_8bit = data[offset.*];
    offset.* += 1;

    if (is_8bit == 1) {
        // Latin-1: one byte per character
        if (offset.* + length > data.len) return error.InvalidData;
        const slice = data[offset.*..][0..length];
        offset.* += length;
        const out = try allocator.alloc(u8, length);
        @memcpy(out, slice);
        return out;
    } else {
        // UTF-16LE: two bytes per character
        const byte_len = @as(usize, length) * 2;
        if (offset.* + byte_len > data.len) return error.InvalidData;
        const result = try utf16LeToUtf8(allocator, data[offset.*..][0..byte_len]);
        offset.* += byte_len;
        return result;
    }
}

/// Try each parser in order. Chromium and Firefox have distinctive headers
/// that make false-positive detection unlikely.
pub fn parse(allocator: Allocator, data: []const u8) !ParseResult {
    if (data.len < 4) return error.InvalidData;

    // WebKit: starts with version u32 LE == 1 (0x01 0x00 0x00 0x00)
    // Chromium: starts with total_size u32 LE, then count u32 LE
    // Firefox: starts with marker u32 BE == 1 (0x00 0x00 0x00 0x01)

    // Firefox: check for big-endian marker == 1
    const first_be = std.mem.readInt(u32, data[0..4], .big);
    if (first_be == 1 or first_be == 0) {
        if (parseFirefox(allocator, data)) |result| return result else |_| {}
    }

    // Chromium: total_size should roughly match data.len, count should be small
    if (data.len >= 8) {
        const total_size = std.mem.readInt(u32, data[0..4], .little);
        const count = std.mem.readInt(u32, data[4..8], .little);
        if (count >= 1 and count <= 100 and total_size > 8) {
            if (parseChromium(allocator, data)) |result| return result else |_| {}
        }
    }

    // WebKit: version == 1
    const first_le = std.mem.readInt(u32, data[0..4], .little);
    if (first_le == 1) {
        if (parseWebKit(allocator, data)) |result| return result else |_| {}
    }

    return error.InvalidData;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

// Chromium blob: 2 entries — "text/x-test":"hello", "text/plain":"world"
// Built from spec: [u32 LE total_size][u32 LE count]
// Entry 0 (non-last): type + null_term + value + null_term
// Entry 1 (last): type + value (no null terminators)
const chromium_blob = [_]u8{
    // total_size=86 (LE), count=2 (LE)
    0x56, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
    // Entry 0: type_len=11, "text/x-test" UTF-16LE, null term
    0x0b, 0x00, 0x00, 0x00,
    0x74, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00, 0x2f, 0x00,
    0x78, 0x00, 0x2d, 0x00, 0x74, 0x00, 0x65, 0x00, 0x73, 0x00, 0x74, 0x00,
    0x00, 0x00, // null terminator
    // val_len=5, "hello" UTF-16LE, null term
    0x05, 0x00, 0x00, 0x00,
    0x68, 0x00, 0x65, 0x00, 0x6c, 0x00, 0x6c, 0x00, 0x6f, 0x00,
    0x00, 0x00, // null terminator
    // Entry 1 (last): type_len=10, "text/plain" UTF-16LE (no null term)
    0x0a, 0x00, 0x00, 0x00,
    0x74, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00, 0x2f, 0x00,
    0x70, 0x00, 0x6c, 0x00, 0x61, 0x00, 0x69, 0x00, 0x6e, 0x00,
    // val_len=5, "world" UTF-16LE (no null term)
    0x05, 0x00, 0x00, 0x00,
    0x77, 0x00, 0x6f, 0x00, 0x72, 0x00, 0x6c, 0x00, 0x64, 0x00,
};

test "parseChromium: two entries with correct names and values" {
    const result = try parseChromium(testing.allocator, &chromium_blob);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(ContainerFormat.chromium, result.format);
    try testing.expectEqual(@as(?[]const u8, null), result.origin);
    try testing.expectEqual(@as(usize, 2), result.sub_types.len);

    try testing.expectEqualStrings("text/x-test", result.sub_types[0].name);
    try testing.expectEqualStrings("hello", result.sub_types[0].value.?);

    try testing.expectEqualStrings("text/plain", result.sub_types[1].name);
    try testing.expectEqualStrings("world", result.sub_types[1].value.?);
}

test "parseChromium: truncated blob returns error" {
    const result = parseChromium(testing.allocator, chromium_blob[0..4]);
    try testing.expectError(error.InvalidData, result);
}

test "parseChromium: empty blob returns error" {
    const result = parseChromium(testing.allocator, &[_]u8{});
    try testing.expectError(error.InvalidData, result);
}

// Firefox blob: 2 entries — "text/x-test":"hello", "text/plain":"world"
// Per entry: [u32 BE marker=1][u32 BE type_len_bytes][UTF-16LE type][u32 BE val_len_bytes][UTF-16LE value]
// Ends with [u32 BE sentinel=0]
const firefox_blob = [_]u8{
    // Entry 0: marker=1, type_len=22 bytes (11 UTF-16LE chars)
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x16,
    0x74, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00,
    0x2f, 0x00, 0x78, 0x00, 0x2d, 0x00, 0x74, 0x00,
    0x65, 0x00, 0x73, 0x00, 0x74, 0x00,
    // val_len=10 bytes (5 UTF-16LE chars)
    0x00, 0x00, 0x00, 0x0a,
    0x68, 0x00, 0x65, 0x00, 0x6c, 0x00, 0x6c, 0x00, 0x6f, 0x00,
    // Entry 1: marker=1, type_len=20 bytes (10 UTF-16LE chars)
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x14,
    0x74, 0x00, 0x65, 0x00, 0x78, 0x00, 0x74, 0x00,
    0x2f, 0x00, 0x70, 0x00, 0x6c, 0x00, 0x61, 0x00,
    0x69, 0x00, 0x6e, 0x00,
    // val_len=10 bytes
    0x00, 0x00, 0x00, 0x0a,
    0x77, 0x00, 0x6f, 0x00, 0x72, 0x00, 0x6c, 0x00, 0x64, 0x00,
    // Sentinel
    0x00, 0x00, 0x00, 0x00,
};

test "parseFirefox: two entries with correct names and values" {
    const result = try parseFirefox(testing.allocator, &firefox_blob);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(ContainerFormat.firefox, result.format);
    try testing.expectEqual(@as(?[]const u8, null), result.origin);
    try testing.expectEqual(@as(usize, 2), result.sub_types.len);

    try testing.expectEqualStrings("text/x-test", result.sub_types[0].name);
    try testing.expectEqualStrings("hello", result.sub_types[0].value.?);

    try testing.expectEqualStrings("text/plain", result.sub_types[1].name);
    try testing.expectEqualStrings("world", result.sub_types[1].value.?);
}

test "parseFirefox: truncated blob returns error" {
    const result = parseFirefox(testing.allocator, firefox_blob[0..6]);
    try testing.expectError(error.InvalidData, result);
}

// WebKit blob: origin="https://example.com", 1 entry — "text/plain":"hi"
// Format: [u32 LE version=1][String origin][HashMap count=1][String key][String val][Vector count=1][String type]
// String: [u32 LE length][u8 is8Bit][data...]
const webkit_blob = [_]u8{
    // version = 1 (u32 LE)
    0x01, 0x00, 0x00, 0x00,
    // origin string: length=19, is8Bit=1, "https://example.com"
    0x13, 0x00, 0x00, 0x00, 0x01,
    'h', 't', 't', 'p', 's', ':', '/', '/', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm',
    // HashMap count = 1 (u64 LE)
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // key: length=10, is8Bit=1, "text/plain"
    0x0a, 0x00, 0x00, 0x00, 0x01,
    't', 'e', 'x', 't', '/', 'p', 'l', 'a', 'i', 'n',
    // value: length=2, is8Bit=1, "hi"
    0x02, 0x00, 0x00, 0x00, 0x01,
    'h', 'i',
    // Vector count = 1 (u64 LE)
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    // element: length=10, is8Bit=1, "text/plain"
    0x0a, 0x00, 0x00, 0x00, 0x01,
    't', 'e', 'x', 't', '/', 'p', 'l', 'a', 'i', 'n',
};

test "parseWebKit: one entry with origin" {
    const result = try parseWebKit(testing.allocator, &webkit_blob);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(ContainerFormat.webkit, result.format);
    try testing.expectEqualStrings("https://example.com", result.origin.?);
    try testing.expectEqual(@as(usize, 1), result.sub_types.len);

    try testing.expectEqualStrings("text/plain", result.sub_types[0].name);
    try testing.expectEqualStrings("hi", result.sub_types[0].value.?);
}

test "parseWebKit: wrong version returns error" {
    var bad = webkit_blob;
    bad[0] = 0x02; // version 2
    const result = parseWebKit(testing.allocator, &bad);
    try testing.expectError(error.InvalidData, result);
}

test "parseWebKit: truncated blob returns error" {
    const result = parseWebKit(testing.allocator, webkit_blob[0..3]);
    try testing.expectError(error.InvalidData, result);
}

// Auto-detect tests
test "parse: auto-detects Chromium" {
    const result = try parse(testing.allocator, &chromium_blob);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(ContainerFormat.chromium, result.format);
    try testing.expectEqual(@as(usize, 2), result.sub_types.len);
}

test "parse: auto-detects Firefox" {
    const result = try parse(testing.allocator, &firefox_blob);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(ContainerFormat.firefox, result.format);
    try testing.expectEqual(@as(usize, 2), result.sub_types.len);
}

test "parse: auto-detects WebKit" {
    const result = try parse(testing.allocator, &webkit_blob);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(ContainerFormat.webkit, result.format);
    try testing.expectEqual(@as(usize, 1), result.sub_types.len);
}

test "parse: empty data returns error" {
    const result = parse(testing.allocator, &[_]u8{});
    try testing.expectError(error.InvalidData, result);
}
