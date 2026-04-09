const std = @import("std");
const clipboard = @import("clipboard");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for global flags: --json and --help/-h
    var json_output = false;
    var help_requested = false;
    var filtered_args = std.array_list.Managed([]const u8).init(allocator);
    defer filtered_args.deinit();

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json_output = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help_requested = true;
        } else {
            try filtered_args.append(arg);
        }
    }

    if (help_requested) {
        const stdout_file = std.fs.File.stdout();
        var helpbuf: [4096]u8 = undefined;
        var hw = stdout_file.writer(&helpbuf);
        try printUsage(&hw.interface);
        try hw.interface.flush();
        return;
    }

    const cmd_args = filtered_args.items;

    if (cmd_args.len == 0) {
        return introspect(allocator, json_output);
    }

    const command = cmd_args[0];

    if (std.mem.eql(u8, command, "help")) {
        const stdout_file = std.fs.File.stdout();
        var helpbuf: [4096]u8 = undefined;
        var hw = stdout_file.writer(&helpbuf);
        try printUsage(&hw.interface);
        try hw.interface.flush();
        return;
    } else if (std.mem.eql(u8, command, "list")) {
        return cmdList(allocator, json_output);
    } else if (std.mem.eql(u8, command, "read")) {
        return cmdRead(allocator, cmd_args[1..]);
    } else if (std.mem.eql(u8, command, "write")) {
        return cmdWrite(allocator, cmd_args[1..]);
    } else if (std.mem.eql(u8, command, "clear")) {
        return cmdClear();
    } else if (std.mem.eql(u8, command, "watch")) {
        return cmdWatch(allocator, cmd_args[1..], json_output);
    } else {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Unknown command: {s}\n", .{command});
        try printUsage(&ew.interface);
        try ew.interface.flush();
        std.process.exit(1);
    }
}

fn printUsage(writer: *std.io.Writer) !void {
    try writer.print(
        \\Usage: clipboard [command] [options]
        \\
        \\Commands:
        \\  (none)                          Show clipboard contents (default)
        \\  list                            List format names, one per line
        \\  read <format> [--out <file>]    Read format data to stdout, or to a file
        \\                [--as-path [-0]]  Decode file-reference formats to POSIX paths
        \\  write <format> [--data <text>]  Write inline data, or read from stdin
        \\  clear                           Clear the clipboard
        \\  watch [--interval <ms>]         Watch for clipboard changes (default 500ms)
        \\  help                            Show this help message
        \\
        \\Global flags:
        \\  --json                          Output as JSON (introspect, list)
        \\  --help, -h                      Show this help message
        \\
    , .{});
}

fn introspect(allocator: Allocator, json_output: bool) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);

    const change_count = clipboard.getChangeCount();
    const formats = try clipboard.listFormats(allocator);
    defer {
        for (formats) |f| allocator.free(f);
        allocator.free(formats);
    }

    if (json_output) {
        try jsonIntrospect(allocator, &w.interface, formats, change_count);
        try w.interface.flush();
        return;
    }

    try w.interface.print("Clipboard contents ({d} format{s}, changeCount: {d}):\n\n", .{
        formats.len,
        if (formats.len != 1) "s" else "",
        change_count,
    });

    for (formats) |format| {
        const data = try clipboard.readFormat(allocator, format);
        if (data) |bytes| {
            defer allocator.free(bytes);
            try printFormatPreview(&w.interface, format, bytes);
        } else {
            try w.interface.print("  {s}    (not readable)\n\n", .{format});
        }
    }
    try w.interface.flush();
}

fn printFormatPreview(writer: *std.io.Writer, format: []const u8, bytes: []const u8) !void {
    try writer.print("  {s}    {d} bytes\n", .{ format, bytes.len });

    if (isLikelyText(format)) {
        const preview_len = @min(bytes.len, 80);
        // Replace newlines with spaces for preview
        var preview_buf: [80]u8 = undefined;
        const preview = bytes[0..preview_len];
        for (preview, 0..) |c, i| {
            preview_buf[i] = if (c == '\n' or c == '\r') ' ' else c;
        }
        try writer.print("  \"{s}", .{preview_buf[0..preview_len]});
        if (bytes.len > 80) try writer.print("...", .{});
        try writer.print("\"\n\n", .{});
    } else {
        const hex_len = @min(bytes.len, 8);
        try writer.print("  [", .{});
        for (bytes[0..hex_len], 0..) |byte, i| {
            if (i > 0) try writer.print(" ", .{});
            try writer.print("{X:0>2}", .{byte});
        }
        try writer.print("]", .{});
        if (bytes.len > 8) try writer.print(" ...", .{});
        try writer.print(" ({s})\n\n", .{detectType(bytes)});
    }
}

fn isLikelyText(format: []const u8) bool {
    const text_formats = [_][]const u8{
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.html",
        "public.rtf",
        "public.file-url",
    };
    for (text_formats) |tf| {
        if (std.mem.eql(u8, format, tf)) return true;
    }
    return false;
}

fn detectType(bytes: []const u8) []const u8 {
    if (bytes.len >= 4) {
        if (bytes[0] == 0x89 and bytes[1] == 0x50 and bytes[2] == 0x4E and bytes[3] == 0x47) return "PNG image";
        if ((bytes[0] == 0x49 and bytes[1] == 0x49 and bytes[2] == 0x2A and bytes[3] == 0x00) or
            (bytes[0] == 0x4D and bytes[1] == 0x4D and bytes[2] == 0x00 and bytes[3] == 0x2A)) return "TIFF image";
        if (bytes[0] == 0x25 and bytes[1] == 0x50 and bytes[2] == 0x44 and bytes[3] == 0x46) return "PDF";
    }
    return "binary";
}

fn jsonIntrospect(allocator: Allocator, writer: *std.io.Writer, formats: [][]const u8, change_count: i64) !void {
    try writer.print("{{\"changeCount\":{d},\"formats\":[", .{change_count});
    for (formats, 0..) |format, i| {
        if (i > 0) try writer.print(",", .{});
        const data = try clipboard.readFormat(allocator, format);
        const size: usize = if (data) |d| blk: {
            defer allocator.free(d);
            break :blk d.len;
        } else 0;
        try writer.print("{{\"name\":\"{s}\",\"size\":{d}}}", .{ format, size });
    }
    try writer.print("]}}\n", .{});
}

fn cmdList(allocator: Allocator, json_output: bool) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);

    const formats = try clipboard.listFormats(allocator);
    defer {
        for (formats) |f| allocator.free(f);
        allocator.free(formats);
    }

    if (json_output) {
        try w.interface.print("[", .{});
        for (formats, 0..) |format, i| {
            if (i > 0) try w.interface.print(",", .{});
            try w.interface.print("\"{s}\"", .{format});
        }
        try w.interface.print("]\n", .{});
        try w.interface.flush();
        return;
    }

    for (formats) |format| {
        try w.interface.print("{s}\n", .{format});
    }
    try w.interface.flush();
}

fn cmdRead(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Usage: clipboard read <format> [--out <file>] [--as-path [-0]]\n", .{});
        try ew.interface.flush();
        std.process.exit(1);
    }

    const format = args[0];
    var out_file: ?[]const u8 = null;
    var as_path = false;
    var null_sep = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_file = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--as-path")) {
            as_path = true;
        } else if (std.mem.eql(u8, args[i], "-0") or std.mem.eql(u8, args[i], "--null")) {
            null_sep = true;
        }
        // Unknown flags are ignored, matching the existing (lax) behavior.
    }

    // --- Validation (runs BEFORE any pasteboard access) ---

    if (null_sep and !as_path) {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Error: -0 requires --as-path\n", .{});
        try ew.interface.flush();
        std.process.exit(1);
    }

    // --- Dispatch ---

    if (!as_path) {
        // Existing raw-bytes path — unchanged.
        const data = try clipboard.readFormat(allocator, format);
        if (data) |bytes| {
            defer allocator.free(bytes);

            if (out_file) |path| {
                const file = try std.fs.cwd().createFile(path, .{});
                defer file.close();
                try file.writeAll(bytes);
                const stderr_file = std.fs.File.stderr();
                var errbuf: [4096]u8 = undefined;
                var ew = stderr_file.writer(&errbuf);
                try ew.interface.print("Wrote {d} bytes to {s}\n", .{ bytes.len, path });
                try ew.interface.flush();
            } else {
                const stdout_file = std.fs.File.stdout();
                try stdout_file.writeAll(bytes);
            }
        } else {
            const stderr_file = std.fs.File.stderr();
            var errbuf: [4096]u8 = undefined;
            var ew = stderr_file.writer(&errbuf);
            try ew.interface.print("Format not found: {s}\n", .{format});
            try ew.interface.flush();
            std.process.exit(1);
        }
        return;
    }

    // --- --as-path path ---

    const paths_result = clipboard.decodePathsForFormat(allocator, format) catch |err| {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        switch (err) {
            error.FormatNotFound => try ew.interface.print("Format not found: {s}\n", .{format}),
            error.NotFileScheme => try ew.interface.print("Error: {s} is not a file:// URL\n", .{format}),
            error.MalformedUrl => try ew.interface.print("Error: failed to decode {s}: malformed URL\n", .{format}),
            error.InvalidPercentEncoding => try ew.interface.print("Error: failed to decode {s}: invalid percent-encoding\n", .{format}),
            error.MalformedPlist => try ew.interface.print("Error: failed to decode {s}: malformed plist\n", .{format}),
            error.UnsupportedFormat => try ew.interface.print(
                "Error: --as-path does not support this format on this platform\n",
                .{},
            ),
            error.PasteboardUnavailable => try ew.interface.print(
                "Error: clipboard is unavailable (no pasteboard in this context)\n",
                .{},
            ),
            else => try ew.interface.print("Error: failed to decode {s}: {s}\n", .{ format, @errorName(err) }),
        }
        try ew.interface.flush();
        std.process.exit(1);
    };
    defer {
        for (paths_result) |p| allocator.free(p);
        allocator.free(paths_result);
    }

    const terminator: u8 = if (null_sep) 0 else '\n';

    if (out_file) |path| {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        for (paths_result) |p| {
            try file.writeAll(p);
            try file.writeAll(&[_]u8{terminator});
        }
    } else {
        const stdout_file = std.fs.File.stdout();
        for (paths_result) |p| {
            try stdout_file.writeAll(p);
            try stdout_file.writeAll(&[_]u8{terminator});
        }
    }
}

fn cmdWrite(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Usage: clipboard write <format> [--data \"text\"]\n", .{});
        try ew.interface.flush();
        std.process.exit(1);
    }

    const format = args[0];
    var inline_data: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--data") and i + 1 < args.len) {
            inline_data = args[i + 1];
            i += 1;
        }
    }

    if (inline_data) |data| {
        try clipboard.writeFormat(allocator, format, data);
    } else {
        // Read from stdin
        const stdin_file = std.fs.File.stdin();
        const data = try stdin_file.readToEndAlloc(allocator, 1024 * 1024 * 100); // 100MB max
        defer allocator.free(data);
        try clipboard.writeFormat(allocator, format, data);
    }
}

fn cmdClear() !void {
    try clipboard.clear();
}

fn cmdWatch(allocator: Allocator, args: []const []const u8, json_output: bool) !void {
    var interval_ms: u64 = 500;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--interval") and i + 1 < args.len) {
            interval_ms = std.fmt.parseInt(u64, args[i + 1], 10) catch 500;
            i += 1;
        }
    }

    const stderr_file = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = stderr_file.writer(&stderr_buf);
    try stderr_w.interface.print("Watching clipboard (interval: {d}ms, Ctrl+C to stop)...\n\n", .{interval_ms});
    try stderr_w.interface.flush();

    var last_count = clipboard.getChangeCount();

    while (true) {
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
        const current_count = clipboard.getChangeCount();
        if (current_count != last_count) {
            last_count = current_count;
            try introspect(allocator, json_output);
            const stdout_file = std.fs.File.stdout();
            var stdout_buf: [4096]u8 = undefined;
            var stdout_w = stdout_file.writer(&stdout_buf);
            try stdout_w.interface.print("---\n\n", .{});
            try stdout_w.interface.flush();
        }
    }
}
