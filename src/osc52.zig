const std = @import("std");

/// Writes an OSC 52 clipboard-set escape sequence to the provided writer.
/// Format: \x1b]52;c;<base64-encoded data>\x07
/// This is a pure formatting function with no side effects.
pub fn formatOsc52(writer: *std.Io.Writer, data: []const u8) !void {
    try writer.writeAll("\x1b]52;c;");
    try std.base64.standard.Encoder.encodeWriter(writer, data);
    try writer.writeAll("\x07");
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "formatOsc52: basic encoding" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatOsc52(&writer, "hello");
    const output = writer.buffered();
    try testing.expectEqualSlices(u8, "\x1b]52;c;aGVsbG8=\x07", output);
}

test "formatOsc52: empty string" {
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatOsc52(&writer, "");
    const output = writer.buffered();
    try testing.expectEqualSlices(u8, "\x1b]52;c;\x07", output);
}

test "formatOsc52: binary data round-trip" {
    const input = [_]u8{ 0x00, 0xFF, 0x80, 0x7F, 0xDE, 0xAD };
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatOsc52(&writer, &input);
    const output = writer.buffered();

    // Verify framing
    try testing.expect(std.mem.startsWith(u8, output, "\x1b]52;c;"));
    try testing.expect(output[output.len - 1] == 0x07);

    // Extract base64 payload and decode
    const b64_payload = output[7 .. output.len - 1]; // skip "\x1b]52;c;" and "\x07"
    var decoded: [256]u8 = undefined;
    const decoded_len = try std.base64.standard.Decoder.calcSizeForSlice(b64_payload);
    try std.base64.standard.Decoder.decode(decoded[0..decoded_len], b64_payload);
    try testing.expectEqualSlices(u8, &input, decoded[0..decoded_len]);
}

test "formatOsc52: no newlines in output" {
    // Use data that would produce multi-line base64 in other implementations
    const input = "The quick brown fox jumps over the lazy dog. " ++
        "This is a longer string to ensure base64 output stays on one line.";
    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try formatOsc52(&writer, input);
    const output = writer.buffered();

    for (output) |c| {
        try testing.expect(c != '\n');
        try testing.expect(c != '\r');
    }
}
