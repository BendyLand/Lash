const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
});

pub fn main() !void {
    // Register SIGINT (Ctrl+C) and SIGTERM
    const act = std.posix.Sigaction{
        .handler = .{ .handler = signalHandler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    var allocator = std.heap.page_allocator;
    // use other allocator to test for memory leaks:
    // 
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // var allocator = gpa.allocator();
    // defer {
    //     if (gpa.deinit() == std.heap.Check.ok) {
    //         std.debug.print("No leaks detected!\n", .{});
    //     }
    // }
    try runMain(&allocator);
}

var global_temp_path: ?[:0]const u8 = null;

fn signalHandler(sig: i32) callconv(.C) void {
    if (global_temp_path) |path| {
        // unlink is async-signal-safe.
        _ = std.posix.system.unlink(path.ptr);
    }
    // 128 + signal is the standard exit code convention for signals
    std.process.exit(@intCast(128 + sig));
}


pub fn runMain(allocator: *std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator.*);
    defer std.process.argsFree(allocator.*, args);
    if (args.len < 2) {
        printHelp();
        return;
    }
    const file = std.fs.cwd().openFile("lashfile", .{}) catch |err| {
        std.debug.print("Unable to open file: {any}\n", .{err});
        return;
    };
    defer file.close();
    const contents = file.readToEndAlloc(allocator.*, 1024 * 1024 * 10) catch |err| {
        std.debug.print("Unable to read file: {any}\n", .{err});
        return;
    };
    defer allocator.free(contents);
    const sections = try splitAtIndentedLines(allocator, contents);
    defer allocator.free(sections);
    var entries = try parseEntries(allocator, sections);
    defer freeMap(allocator, &entries);
    if (std.mem.eql(u8, args[1], "sections")) {
        const writer = std.io.getStdOut().writer();
        var it = entries.iterator();
        while (it.next()) |entry| {
            try writer.print("{s}\n", .{entry.key_ptr.*});
        }
        return;
    }
    else if (std.mem.eql(u8, args[1], "help")) {
        printHelp();
        return;
    }
    else if (std.mem.eql(u8, args[1], "completions")) {
        try printCompletionScript();
        return;
    }
    const command = entries.get(args[1]);
    if (command) |cmd| {
        const shell_file = constructShellFile(allocator, cmd) catch |err| {
            std.debug.print("Error constructing shell file: {any}\n", .{err});
            return;
        };
        var temp = try TempFile.create(allocator, shell_file);
        global_temp_path = temp.path;
        defer {
            temp.delete() catch |err| {
                std.debug.print("Warning: Failed to delete temp file: {any}\n", .{err});
            };
            global_temp_path = null;
        }
        const mode = 0o755; // rwxr-xr-x
        const mod_res = c.chmod(temp.path.ptr, mode);
        if (mod_res != 0) {
            std.debug.print("Unable to set executable file permissions.\n", .{});
            return;
        }
        _ = try runShellFile(temp.path);
        allocator.free(shell_file);
    }
    else {
        std.debug.print("Section '{s}' not found.\n", .{args[1]});
    }
}

pub fn splitAtIndentedLines(allocator: *std.mem.Allocator, input: []const u8) ![]const []const u8 {
    var lines = std.mem.splitScalar(u8, input, '\n');
    var parts = std.ArrayList([]const u8).init(allocator.*);
    var current_start: usize = 0;
    var index: usize = 0;
    while (lines.next()) |line| {
        const is_start = line.len > 0 and !std.ascii.isWhitespace(line[0]);
        const is_title = std.mem.containsAtLeastScalar(u8, line, 1, ':');
        if (is_start and is_title and index != 0) {
            const segment = std.mem.trimRight(u8, input[current_start .. line.ptr - input.ptr], "\n");
            try parts.append(segment);
            current_start = line.ptr - input.ptr;
        }
        index += 1;
    }
    // Add the final segment
    if (current_start < input.len) {
        const final_segment = std.mem.trimRight(u8, input[current_start..], "\n");
        try parts.append(final_segment);
    }
    return try parts.toOwnedSlice();
}

pub fn parseEntries(
    allocator: *std.mem.Allocator,
    segments: []const []const u8,
) !std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(allocator.*);
    for (segments) |segment| {
        var lines = std.mem.tokenizeScalar(u8, segment, '\n');
        const key_start = lines.next() orelse continue; // skip empty segments
        const key_slice = key_start[0 .. key_start.len - 1];
        const rest_start = segment[key_start.len..];
        const value_slice = std.mem.trimLeft(u8, rest_start, "\n\t ");
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

pub fn freeMap(allocator: *std.mem.Allocator, map: *std.StringHashMap([]const u8)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    map.deinit();
}

fn stripCommonIndent(allocator: *std.mem.Allocator, text: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var slices = std.ArrayList([]const u8).init(allocator.*);
    defer slices.deinit();
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, "\t ");
        try slices.append(trimmed);
    }
    return std.mem.join(allocator.*, "\n", slices.items);
}

pub fn constructShellFile(allocator: *std.mem.Allocator, text: []const u8) ![]const u8 {
    const header = "#!/bin/bash\n\n";
    const parts: [2][]const u8 = .{ header, text };
    return try std.mem.join(allocator.*, "", &parts);
}

const TempFile = struct {
    allocator: *std.mem.Allocator,
    path: [:0]const u8,
    /// Creates a new temporary file with the given contents.
    pub fn create(allocator: *std.mem.Allocator, contents: []const u8) !TempFile {
        const tmp_dir = std.fs.cwd();
        const rand_num = std.crypto.random.int(u16);
        const path = try std.fmt.allocPrintZ(allocator.*, ".{d}.sh", .{rand_num});
        var file = try tmp_dir.createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writer().writeAll(contents);
        return TempFile{
            .allocator = allocator,
            .path = path,
        };
    }
    
    /// Deletes the temporary file and frees the path.
    pub fn delete(self: *TempFile) !void {
        const tmp_dir = std.fs.cwd();
        try tmp_dir.deleteFile(self.path);
        self.allocator.free(self.path);
    }
};

pub fn runShellFile(path: []const u8) !u8 {
    const allocator = std.heap.page_allocator;
    var child = std.process.Child.init(&[_][]const u8{
        "/bin/bash", path,
    }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const status = try child.wait();
    return status.Exited;
}

pub fn printHelp() void {
    const helpMsg =
        \\Usage: lash <section>|<command>
        \\Available commands:
        \\ sections    : print the sections from your lashfile
        \\ completions : prints the shell script to enable
        \\                 tab completions for your lash sections.
        \\
    ;
    std.debug.print("{s}\n", .{helpMsg});
}

pub fn printCompletionScript() !void {
    const writer = std.io.getStdOut().writer();
    const text =
        \\# Place this script inside a file named 'lash'.
        \\# It should be located alongside your other bash completion scripts.
        \\
        \\# Completions for labeled bash
        \\_lash()
        \\{
        \\  # Only complete the first argument (the section name)
        \\  if [ "${COMP_CWORD}" != "1" ]; then
        \\    return
        \\  fi
        \\  local dynamic_sections=$(lash sections 2>/dev/null)
        \\  # hardcoded commands
        \\  local static_commands="sections completions"
        \\  COMPREPLY=($(compgen -W "${dynamic_sections} ${static_commands}" -- "${COMP_WORDS[1]}"))
        \\} &&
        \\  complete -F _lash lash
        \\
        ;
    _ = try writer.write(text);
}

