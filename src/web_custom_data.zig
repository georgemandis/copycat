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
