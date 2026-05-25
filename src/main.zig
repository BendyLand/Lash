const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // register SIGINT (Ctrl+C) and SIGTERM
    const act = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    const allocator = std.heap.page_allocator;
    // use other allocator to test for memory leaks:
    //
    // var gpa = std.heap.DebugAllocator(.{}){};
    // const allocator = gpa.allocator();
    // defer {
    //     // gpa.deinit() returns .ok or .leak
    //     if (gpa.deinit() == .ok) {
    //         std.debug.print("No leaks detected!\n", .{});
    //     }
    //     // NOTE: If it returns .leak, the GPA will automatically print
    //     // a detailed stack trace of the leaked memory
    // }
    try runMain(allocator, init);
}

var global_temp_path: ?[:0]const u8 = null;

fn signalHandler(sig: std.posix.SIG) callconv(.c) void {
    if (global_temp_path) |path| {
        // unlink is async-signal-safe.
        _ = std.posix.system.unlink(path.ptr);
    }
    const sig_val = @intFromEnum(sig);
    std.process.exit(@intCast(128 + sig_val));
}

pub fn runMain(allocator: std.mem.Allocator, init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    defer init.arena.allocator().free(args);
    if (args.len < 2) {
        printHelp();
        return;
    }
    else if (std.mem.eql(u8, args[1], "help")) {
        printHelp();
        return;
    }
    else if (std.mem.eql(u8, args[1], "completions")) {
        try printCompletionScript(init);
        return;
    }
    const file = std.Io.Dir.cwd().openFile(init.io, "lashfile", .{}) catch |err| {
        std.debug.print("Unable to open file: {any}\n", .{err});
        return;
    };
    defer file.close(init.io);
    const contents = std.Io.Dir.cwd().readFileAlloc(init.io, "lashfile", allocator, std.Io.Limit.limited(1024 * 1024 * 10)) catch |err| {
        std.debug.print("Unable to read file: {any}\n", .{err});
        return;
    };
    defer allocator.free(contents);
    const sections = try splitAtIndentedLines(allocator, contents);
    defer allocator.free(sections);
    var entries = try parseEntries(allocator, sections);
    defer freeMap(allocator, &entries);
    if (std.mem.eql(u8, args[1], "sections")) {
        var it = entries.iterator();
        while (it.next()) |entry| {
            try println(init, entry.key_ptr.*);
        }
        return;
    }
    else if (std.mem.eql(u8, args[1], "print")) {
        try printSection(init, args, entries);
        return;
    }
    const command = entries.get(args[1]);
    if (command) |cmd| {
        const shell_file = constructShellFile(allocator, cmd) catch |err| {
            std.debug.print("Error constructing shell file: {any}\n", .{err});
            return;
        };
        var buf: [2]u8 = undefined;
        init.io.random(&buf);
        const rand_num = std.mem.readInt(u16, &buf, .little);
        var temp = try TempFile.create(allocator, init, shell_file, rand_num);
        global_temp_path = temp.path;
        defer {
            temp.delete(init) catch |err| {
                std.debug.print("Warning: Failed to delete temp file: {any}\n", .{err});
            };
            global_temp_path = null;
        }
        _ = try runShellFile(init.io, temp.path);
        allocator.free(shell_file);
    }
    else {
        std.debug.print("Section '{s}' not found.\n", .{args[1]});
    }
}

pub fn splitAtIndentedLines(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var parts: std.ArrayList([]const u8) = .empty;
    var current_start: usize = 0;
    var index: usize = 0;
    while (lines.next()) |line| {
        const is_start = line.len > 0 and !std.ascii.isWhitespace(line[0]);
        const is_title = std.mem.containsAtLeastScalar(u8, line, 1, ':');
        if (is_start and is_title and index != 0) {
            const segment = std.mem.trimEnd(u8, input[current_start .. line.ptr - input.ptr], "\n");
            try parts.append(allocator, segment);
            current_start = line.ptr - input.ptr;
        }
        index += 1;
    }
    // add the final segment
    if (current_start < input.len) {
        const final_segment = std.mem.trimEnd(u8, input[current_start..], "\n");
        try parts.append(allocator, final_segment);
    }
    return try parts.toOwnedSlice(allocator);
}

pub fn parseEntries(
    allocator: std.mem.Allocator,
    segments: []const []const u8,
) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator);
    for (segments) |segment| {
        var lines = std.mem.tokenizeScalar(u8, segment, '\n');
        const key_start = lines.next() orelse continue; // skip empty segments
        const key_slice = key_start[0 .. key_start.len - 1];
        const rest_start = segment[key_start.len..];
        const value_slice = std.mem.trimStart(u8, rest_start, "\n\t ");
        const stripped = try stripCommonIndent(allocator, value_slice);
        const key_copy = try allocator.dupe(u8, key_slice);
        const value_copy = try allocator.dupe(u8, stripped);
        allocator.free(stripped);
        try map.put(key_copy, value_copy);
    }
    return map;
}

pub fn printMap(map: *std.StringHashMap([]const u8)) void {
    var it = map.*.iterator();
    while (it.next()) |entry| {
        std.debug.print("Key:\n{s}\n\nValue:\n{s}\n\n~~~~~~~~~~~~~~~~~~\n\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
}

pub fn freeMap(allocator: std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn stripCommonIndent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var slices: std.ArrayList([]const u8) = .empty;
    defer slices.deinit(allocator);
    while (lines.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, "\t ");
        try slices.append(allocator, trimmed);
    }
    return std.mem.join(allocator, "\n", slices.items);
}

pub fn constructShellFile(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const header = "#!/bin/bash\n\n";
    const parts: [2][]const u8 = .{ header, text };
    return try std.mem.join(allocator, "", &parts);
}

const TempFile = struct {
    allocator: std.mem.Allocator,
    path: [:0]const u8,

    /// Creates a new temporary file with the given contents.
    pub fn create(allocator: std.mem.Allocator, init: std.process.Init, contents: []const u8, rand_num: u64) !TempFile {
        const cwd = std.Io.Dir.cwd();
        const path = try std.fmt.allocPrintSentinel(allocator, "lash_{x}.sh", .{rand_num}, 0);
        var file = try cwd.createFile(init.io, path, .{ .truncate = true });
        defer file.close(init.io);
        var w = file.writer(init.io, &.{});
        try std.Io.Writer.writeAll(&w.interface, contents);
        return TempFile{
            .allocator = allocator,
            .path = path,
        };
    }

    /// Deletes the temporary file and frees the path.
    pub fn delete(self: *TempFile, init: std.process.Init) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.deleteFile(init.io, self.path);
        self.allocator.free(self.path);
    }
};

pub fn runShellFile(io: std.Io, path: [:0]const u8) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = &[_][]const u8{ "/bin/bash", path },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const status = try child.wait(io);
    return status.exited;
}

pub fn printHelp() void {
    const helpMsg =
        \\Usage: lash <section>|<command>
        \\Available commands:
        \\ sections        : print the sections from your lashfile
        \\ completions     : prints the shell script to enable
        \\                    tab completions for your lash sections.
        \\ print <section> : prints the bash code from the specified
        \\                    section; does not execute anything.
        \\
    ;
    std.debug.print("{s}\n", .{helpMsg});
}

pub fn printCompletionScript(init: std.process.Init) !void {
    const text =
        \\# Place this script inside a file named 'lash'.
        \\# It should be located alongside your other bash completion scripts.
        \\
        \\# Completions for labeled bash
        \\_lash()
        \\{
        \\  local dynamic_sections=$(lash sections 2>/dev/null)
        \\  if [ "${COMP_CWORD}" == "2" ] && [ "${COMP_WORDS[1]}" == "print" ]; then
        \\    COMPREPLY=($(compgen -W "${dynamic_sections}" -- "${COMP_WORDS[2]}"))
        \\    return
        \\  fi
        \\  if [ "${COMP_CWORD}" != "1" ]; then
        \\    return
        \\  fi
        \\  local static_commands="sections completions print"
        \\  COMPREPLY=($(compgen -W "${dynamic_sections} ${static_commands}" -- "${COMP_WORDS[1]}"))
        \\} &&
        \\  complete -F _lash lash
    ;
    try println(init, text);
}

pub fn println(init: std.process.Init, text: []const u8) !void {
    var buf: [1024 * 10]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &writer.interface;
    try stdout.print("{s}\n", .{text});
    try stdout.flush();
}

pub fn printSection(init: std.process.Init, args: []const [:0]const u8, entries: std.StringHashMap([]const u8)) !void {
    var it = entries.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, args[2], entry.key_ptr.*)) {
            try println(init, entry.value_ptr.*);
            return;
        }
    }
    std.debug.print("Section '{s}' not found.\n", .{args[2]});
}

