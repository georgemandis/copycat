const std = @import("std");
const clipboard = @import("clipboard");
const web_custom_data = @import("web_custom_data");

const Allocator = std.mem.Allocator;

fn handleTopLevelError(err: anyerror) void {
    const stderr_file = std.fs.File.stderr();
    var errbuf: [4096]u8 = undefined;
    var ew = stderr_file.writer(&errbuf);
    switch (err) {
        error.NoDisplayServer => ew.interface.print(
            "Error: no display server available (is $WAYLAND_DISPLAY or $DISPLAY set?)\n",
            .{},
        ) catch {},
        error.SubscribeFailed => ew.interface.print(
            "Error: clipboard subscribe failed on this platform or backend\n",
            .{},
        ) catch {},
        error.PasteboardUnavailable => ew.interface.print(
            "Error: clipboard is unavailable (no pasteboard in this context)\n",
            .{},
        ) catch {},
        else => ew.interface.print(
            "Error: {s}\n",
            .{@errorName(err)},
        ) catch {},
    }
    ew.interface.flush() catch {};
    std.process.exit(2);
}

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
        return cmdList(allocator, cmd_args[1..], json_output) catch |err| return handleTopLevelError(err);
    } else if (std.mem.eql(u8, command, "read")) {
        return cmdRead(allocator, cmd_args[1..]) catch |err| return handleTopLevelError(err);
    } else if (std.mem.eql(u8, command, "write")) {
        return cmdWrite(allocator, cmd_args[1..]) catch |err| return handleTopLevelError(err);
    } else if (std.mem.eql(u8, command, "clear")) {
        return cmdClear() catch |err| return handleTopLevelError(err);
    } else if (std.mem.eql(u8, command, "watch")) {
        return cmdWatch(allocator, cmd_args[1..], json_output) catch |err| return handleTopLevelError(err);
    } else if (std.mem.eql(u8, command, "completions")) {
        return cmdCompletions(cmd_args[1..]) catch |err| return handleTopLevelError(err);
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
        \\Usage: copycat [command] [options]
        \\
        \\Commands:
        \\  (none)                          Show clipboard contents (default)
        \\  list                            List format names, one per line
        \\  list --sub-types <format>       List sub-types in a web container format
        \\  read <format> [sub-type]        Read format data (or sub-type) to stdout
        \\       [--out <file>]             Write output to a file instead
        \\       [--as-path [-0]]           Decode file-reference formats to POSIX paths
        \\  write <format> [--data <text>]  Write inline data, or read from stdin
        \\  clear                           Clear the clipboard
        \\  watch                           Watch for clipboard changes (event-driven)
        \\  completions <shell>             Print shell completions (fish, bash, zsh)
        \\  help                            Show this help message
        \\
        \\Global flags:
        \\  --json                          Output as JSON (introspect, list)
        \\  --help, -h                      Show this help message
        \\
        \\Created by George Mandis <george@mand.is>
        \\https://github.com/georgemandis/copycat
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
            try printFormatPreview(allocator, &w.interface, format, bytes);
        } else {
            try w.interface.print("  {s}    (not readable)\n\n", .{format});
        }
    }
    try w.interface.flush();
}

fn printFormatPreview(allocator: Allocator, writer: *std.io.Writer, format: []const u8, bytes: []const u8) !void {
    try writer.print("  {s}    {d} bytes\n", .{ format, bytes.len });

    // Try to parse web custom data container formats
    if (isWebCustomDataFormat(format)) {
        if (web_custom_data.parse(allocator, bytes)) |result| {
            defer result.deinit(allocator);
            const format_name: []const u8 = switch (result.format) {
                .chromium => "Chromium",
                .firefox => "Firefox",
                .webkit => "WebKit/Safari",
            };
            try writer.print("  [{s} container", .{format_name});
            if (result.origin) |origin| {
                try writer.print(", origin: {s}", .{origin});
            }
            try writer.print("]\n", .{});
            for (result.sub_types) |st| {
                if (st.value) |val| {
                    const preview_len = @min(val.len, 60);
                    var preview_buf: [60]u8 = undefined;
                    for (val[0..preview_len], 0..) |c, i| {
                        preview_buf[i] = if (c == '\n' or c == '\r') ' ' else c;
                    }
                    try writer.print("    {s}    {d} bytes\n", .{ st.name, val.len });
                    try writer.print("    \"{s}", .{preview_buf[0..preview_len]});
                    if (val.len > 60) try writer.print("...", .{});
                    try writer.print("\"\n", .{});
                } else {
                    try writer.print("    {s}    (null)\n", .{st.name});
                }
            }
            try writer.print("\n", .{});
            return;
        } else |_| {}
    }

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

fn isWebCustomDataFormat(format: []const u8) bool {
    const web_formats = [_][]const u8{
        "com.apple.WebKit.custom-pasteboard-data",
        "org.chromium.web-custom-data",
        "application/x-moz-custom-clipdata",
    };
    for (web_formats) |wf| {
        if (std.mem.eql(u8, format, wf)) return true;
    }
    return false;
}

/// Check if a format string is "container/sub-type" and extract the sub-type value.
/// Returns owned slice with the sub-type value, or null if not a web sub-type reference.
fn resolveWebSubType(allocator: Allocator, format: []const u8) ?[]u8 {
    const prefixes = [_][]const u8{
        "com.apple.WebKit.custom-pasteboard-data/",
        "org.chromium.web-custom-data/",
        "application/x-moz-custom-clipdata/",
    };
    const container_names = [_][]const u8{
        "com.apple.WebKit.custom-pasteboard-data",
        "org.chromium.web-custom-data",
        "application/x-moz-custom-clipdata",
    };

    for (prefixes, 0..) |prefix, idx| {
        if (std.mem.startsWith(u8, format, prefix)) {
            const sub_type_name = format[prefix.len..];
            if (sub_type_name.len == 0) return null;

            const container = container_names[idx];
            const data = clipboard.readFormat(allocator, container) catch return null;
            if (data) |bytes| {
                defer allocator.free(bytes);
                if (web_custom_data.parse(allocator, bytes)) |result| {
                    defer result.deinit(allocator);
                    for (result.sub_types) |st| {
                        if (std.mem.eql(u8, st.name, sub_type_name)) {
                            if (st.value) |val| {
                                const owned = allocator.alloc(u8, val.len) catch return null;
                                @memcpy(owned, val);
                                return owned;
                            }
                            return null;
                        }
                    }
                } else |_| {}
            }
            return null;
        }
    }
    return null;
}

/// Resolve a sub-type from two separate args: container format + sub-type name.
fn resolveWebSubTypeFromArgs(allocator: Allocator, container: []const u8, sub_type_name: []const u8) ?[]u8 {
    if (!isWebCustomDataFormat(container)) return null;
    const data = clipboard.readFormat(allocator, container) catch return null;
    if (data) |bytes| {
        defer allocator.free(bytes);
        if (web_custom_data.parse(allocator, bytes)) |result| {
            defer result.deinit(allocator);
            for (result.sub_types) |st| {
                if (std.mem.eql(u8, st.name, sub_type_name)) {
                    if (st.value) |val| {
                        const owned = allocator.alloc(u8, val.len) catch return null;
                        @memcpy(owned, val);
                        return owned;
                    }
                    return null;
                }
            }
        } else |_| {}
    }
    return null;
}

/// List sub-type names for a given web custom data container format.
fn listSubTypes(allocator: Allocator, writer: *std.io.Writer, container: []const u8) !void {
    if (!isWebCustomDataFormat(container)) return;
    const data = try clipboard.readFormat(allocator, container);
    if (data) |bytes| {
        defer allocator.free(bytes);
        if (web_custom_data.parse(allocator, bytes)) |result| {
            defer result.deinit(allocator);
            for (result.sub_types) |st| {
                try writer.print("{s}\n", .{st.name});
            }
        } else |_| {}
    }
}

fn isLikelyText(format: []const u8) bool {
    const text_formats = [_][]const u8{
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.html",
        "public.rtf",
        "public.file-url",
        // Linux
        "UTF8_STRING",
        "text/plain",
        "text/html",
        "text/uri-list",
        // Windows
        "CF_TEXT",
        "CF_UNICODETEXT",
        "CF_OEMTEXT",
        "HTML Format",
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

fn cmdList(allocator: Allocator, args: []const []const u8, json_output: bool) !void {
    const stdout_file = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout_file.writer(&buf);

    // --sub-types <format>: list only sub-type names for a container format
    var sub_types_for: ?[]const u8 = null;
    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--sub-types") and i + 1 < args.len) {
                sub_types_for = args[i + 1];
                i += 1;
            }
        }
    }

    if (sub_types_for) |container| {
        try listSubTypes(allocator, &w.interface, container);
        try w.interface.flush();
        return;
    }

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
        // Expand web custom data sub-types inline
        if (isWebCustomDataFormat(format)) {
            const data = try clipboard.readFormat(allocator, format);
            if (data) |bytes| {
                defer allocator.free(bytes);
                if (web_custom_data.parse(allocator, bytes)) |result| {
                    defer result.deinit(allocator);
                    for (result.sub_types) |st| {
                        try w.interface.print("  {s}/{s}\n", .{ format, st.name });
                    }
                } else |_| {}
            }
        }
    }
    try w.interface.flush();
}

fn cmdRead(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Usage: copycat read <format> [sub-type] [--out <file>] [--as-path [-0]]\n", .{});
        try ew.interface.flush();
        std.process.exit(1);
    }

    const format = args[0];
    var sub_type_arg: ?[]const u8 = null;
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
        } else if (!std.mem.startsWith(u8, args[i], "-") and sub_type_arg == null) {
            // Second positional arg = sub-type name
            sub_type_arg = args[i];
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
        // Resolve sub-type: either from second positional arg or "container/sub-type" slash syntax
        const sub_type_result = if (sub_type_arg) |st|
            resolveWebSubTypeFromArgs(allocator, format, st)
        else
            resolveWebSubType(allocator, format);

        if (sub_type_result) |sub_val| {
            defer allocator.free(sub_val);
            if (out_file) |path| {
                const file = try std.fs.cwd().createFile(path, .{});
                defer file.close();
                try file.writeAll(sub_val);
                const stderr_file = std.fs.File.stderr();
                var errbuf: [4096]u8 = undefined;
                var ew = stderr_file.writer(&errbuf);
                try ew.interface.print("Wrote {d} bytes to {s}\n", .{ sub_val.len, path });
                try ew.interface.flush();
            } else {
                const stdout_file = std.fs.File.stdout();
                try stdout_file.writeAll(sub_val);
            }
            return;
        }

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
            error.PasteboardUnavailable, error.NoDisplayServer => try ew.interface.print(
                "Error: clipboard is unavailable (no display server or pasteboard in this context)\n",
                .{},
            ),
            error.MalformedUriList => try ew.interface.print(
                "Error: malformed text/uri-list payload on clipboard\n",
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
        try ew.interface.print("Usage: copycat write <format> [--data \"text\"]\n", .{});
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
    _ = args; // --interval is no longer accepted; unknown args are ignored.

    const stderr_file = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = stderr_file.writer(&stderr_buf);
    try stderr_w.interface.print("Watching clipboard (Ctrl+C to stop)...\n\n", .{});
    try stderr_w.interface.flush();

    var context = WatchContext{
        .allocator = allocator,
        .json_output = json_output,
        .mutex = .{},
        .condition = .{},
        .pending = false,
    };

    const handle = try clipboard.subscribe(allocator, WatchContext.onChange, &context);
    defer clipboard.unsubscribe(handle);

    // Main loop: wait for the callback to signal, introspect, loop until SIGINT.
    // SIGINT handling relies on process termination — see spec's cmdWatch section.
    while (true) {
        context.mutex.lock();
        while (!context.pending) {
            context.condition.wait(&context.mutex);
        }
        context.pending = false;
        context.mutex.unlock();

        try introspect(allocator, json_output);

        const stdout_file = std.fs.File.stdout();
        var stdout_buf: [4096]u8 = undefined;
        var stdout_w = stdout_file.writer(&stdout_buf);
        try stdout_w.interface.print("---\n\n", .{});
        try stdout_w.interface.flush();
    }
}

fn cmdCompletions(args: []const []const u8) !void {
    const stdout_file = std.fs.File.stdout();

    const shell = if (args.len > 0) args[0] else {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Usage: copycat completions <fish|bash|zsh>\n", .{});
        try ew.interface.flush();
        std.process.exit(1);
    };

    if (std.mem.eql(u8, shell, "fish")) {
        try stdout_file.writeAll(fish_completions);
    } else if (std.mem.eql(u8, shell, "bash")) {
        try stdout_file.writeAll(bash_completions);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try stdout_file.writeAll(zsh_completions);
    } else {
        const stderr_file = std.fs.File.stderr();
        var errbuf: [4096]u8 = undefined;
        var ew = stderr_file.writer(&errbuf);
        try ew.interface.print("Unknown shell: {s}. Supported: fish, bash, zsh\n", .{shell});
        try ew.interface.flush();
        std.process.exit(1);
    }
}

const fish_completions =
    \\# copycat completions for fish
    \\# Install: copycat completions fish | source
    \\# Persist: copycat completions fish > ~/.config/fish/completions/copycat.fish
    \\
    \\# Clear any previously loaded copycat completions
    \\complete -e -c copycat
    \\complete -c copycat -f
    \\complete -c copycat -n "__fish_use_subcommand" -a "list" -d "List clipboard formats"
    \\complete -c copycat -n "__fish_use_subcommand" -a "read" -d "Read clipboard format"
    \\complete -c copycat -n "__fish_use_subcommand" -a "write" -d "Write clipboard format"
    \\complete -c copycat -n "__fish_use_subcommand" -a "clear" -d "Clear clipboard"
    \\complete -c copycat -n "__fish_use_subcommand" -a "watch" -d "Watch for changes"
    \\complete -c copycat -n "__fish_use_subcommand" -a "completions" -d "Print shell completions"
    \\complete -c copycat -n "__fish_use_subcommand" -a "help" -d "Show help"
    \\complete -c copycat -l json -d "Output as JSON"
    \\complete -c copycat -l help -s h -d "Show help"
    \\
    \\# read: first arg = format from clipboard
    \\# Only show when exactly "copycat read" is typed (2 tokens before cursor)
    \\complete -c copycat -n "__fish_seen_subcommand_from read; and test (count (commandline -oc)) -le 2" -f -a "(copycat list 2>/dev/null | grep -v '^  ')" -d "Clipboard format"
    \\
    \\# read: second arg = sub-type
    \\# Show when "copycat read <format>" is typed (3 tokens before cursor)
    \\# Uses -k to keep order and -f to suppress file completions on the "/" in MIME types
    \\complete -c copycat -n "__fish_seen_subcommand_from read; and test (count (commandline -oc)) -ge 3" -f -k -a "(copycat list --sub-types (commandline -oc)[3] 2>/dev/null)" -d "Sub-type"
    \\
    \\# read flags
    \\complete -c copycat -n "__fish_seen_subcommand_from read" -l out -r -d "Write to file"
    \\complete -c copycat -n "__fish_seen_subcommand_from read" -l as-path -d "Decode as file paths"
    \\complete -c copycat -n "__fish_seen_subcommand_from read" -s 0 -l null -d "Null-separate paths"
    \\
    \\# write: first arg = format
    \\complete -c copycat -n "__fish_seen_subcommand_from write; and test (count (commandline -opc)) -eq 2" -a "(copycat list 2>/dev/null | grep -v '^  ')" -d "Clipboard format"
    \\complete -c copycat -n "__fish_seen_subcommand_from write" -l data -r -d "Inline data"
    \\
    \\# list flags
    \\complete -c copycat -n "__fish_seen_subcommand_from list" -l sub-types -r -a "(copycat list 2>/dev/null | grep -v '^  ')" -d "List sub-types for format"
    \\
    \\# completions: shell name
    \\complete -c copycat -n "__fish_seen_subcommand_from completions" -a "fish bash zsh"
    \\
;

const bash_completions =
    \\# copycat completions for bash
    \\# Install: eval "$(copycat completions bash)"
    \\# Persist: copycat completions bash > /etc/bash_completion.d/copycat
    \\
    \\_copycat() {
    \\    local cur prev words cword
    \\    _init_completion || return
    \\
    \\    local commands="list read write clear watch completions help"
    \\
    \\    if [[ $cword -eq 1 ]]; then
    \\        COMPREPLY=($(compgen -W "$commands --json --help -h" -- "$cur"))
    \\        return
    \\    fi
    \\
    \\    local cmd="${words[1]}"
    \\
    \\    case "$cmd" in
    \\        read)
    \\            if [[ $cword -eq 2 ]]; then
    \\                local formats
    \\                formats=$(copycat list 2>/dev/null | grep -v '^  ')
    \\                COMPREPLY=($(compgen -W "$formats --out --as-path" -- "$cur"))
    \\            elif [[ $cword -eq 3 && "${words[2]}" != --* ]]; then
    \\                local subtypes
    \\                subtypes=$(copycat list --sub-types "${words[2]}" 2>/dev/null)
    \\                COMPREPLY=($(compgen -W "$subtypes --out --as-path" -- "$cur"))
    \\            fi
    \\            ;;
    \\        write)
    \\            if [[ $cword -eq 2 ]]; then
    \\                local formats
    \\                formats=$(copycat list 2>/dev/null | grep -v '^  ')
    \\                COMPREPLY=($(compgen -W "$formats --data" -- "$cur"))
    \\            fi
    \\            ;;
    \\        list)
    \\            COMPREPLY=($(compgen -W "--sub-types --json" -- "$cur"))
    \\            ;;
    \\        completions)
    \\            COMPREPLY=($(compgen -W "fish bash zsh" -- "$cur"))
    \\            ;;
    \\    esac
    \\}
    \\complete -F _copycat copycat
    \\
;

const zsh_completions =
    \\#compdef copycat
    \\# copycat completions for zsh
    \\# Install: copycat completions zsh | source /dev/stdin
    \\# Persist: copycat completions zsh > ~/.zfunc/_copycat && fpath+=(~/.zfunc)
    \\
    \\_copycat() {
    \\    local -a commands
    \\    commands=(
    \\        'list:List clipboard formats'
    \\        'read:Read clipboard format'
    \\        'write:Write clipboard format'
    \\        'clear:Clear clipboard'
    \\        'watch:Watch for changes'
    \\        'completions:Print shell completions'
    \\        'help:Show help'
    \\    )
    \\
    \\    _arguments -C \
    \\        '--json[Output as JSON]' \
    \\        '(--help -h)'{--help,-h}'[Show help]' \
    \\        '1:command:->cmd' \
    \\        '*::arg:->args'
    \\
    \\    case "$state" in
    \\        cmd)
    \\            _describe 'command' commands
    \\            ;;
    \\        args)
    \\            case "${words[1]}" in
    \\                read)
    \\                    if (( CURRENT == 2 )); then
    \\                        local -a formats
    \\                        formats=(${(f)"$(copycat list 2>/dev/null | grep -v '^  ')"})
    \\                        _describe 'format' formats
    \\                    elif (( CURRENT == 3 )); then
    \\                        local -a subtypes
    \\                        subtypes=(${(f)"$(copycat list --sub-types "${words[2]}" 2>/dev/null)"})
    \\                        if [[ -n "$subtypes" ]]; then
    \\                            _describe 'sub-type' subtypes
    \\                        fi
    \\                    fi
    \\                    ;;
    \\                write)
    \\                    if (( CURRENT == 2 )); then
    \\                        local -a formats
    \\                        formats=(${(f)"$(copycat list 2>/dev/null | grep -v '^  ')"})
    \\                        _describe 'format' formats
    \\                    fi
    \\                    ;;
    \\                list)
    \\                    _arguments '--sub-types[List sub-types]:format:($(copycat list 2>/dev/null | grep -v "^  "))'
    \\                    ;;
    \\                completions)
    \\                    _values 'shell' fish bash zsh
    \\                    ;;
    \\            esac
    \\            ;;
    \\    esac
    \\}
    \\
    \\_copycat "$@"
    \\
;

const WatchContext = struct {
    allocator: Allocator,
    json_output: bool,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    pending: bool,

    fn onChange(userdata: ?*anyopaque) void {
        const ctx: *WatchContext = @ptrCast(@alignCast(userdata.?));
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        ctx.pending = true;
        ctx.condition.signal();
    }
};
