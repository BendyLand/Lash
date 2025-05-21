const std = @import("std");
const c = @cImport({
    @cInclude("sys/stat.h");
});

pub fn main() !void {
    var allocator = std.heap.page_allocator;
    // use other allocator to test for memory leaks:
    
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // var allocator = gpa.allocator();
    // defer {
    //     if (gpa.deinit() == std.heap.Check.ok) {
    //         std.debug.print("No leaks detected!\n", .{});
    //     }
    // }
    
    try runMain(&allocator);
}

pub fn runMain(allocator: *std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator.*);
    defer std.process.argsFree(allocator.*, args);
    if (args.len < 2) {
        std.debug.print("Usage: lash <section>\n", .{});
        return;
    }
    const file = std.fs.cwd().openFile("lashfile", .{}) catch |err| {
        std.debug.print("Unable to open file: {any}\n", .{err});
        return;
    };
    defer file.close();
    const contents = file.readToEndAlloc(allocator.*, 1024*1024) catch |err| {
        std.debug.print("Unable to read file: {any}\n", .{err});
        return;
    };
    defer allocator.free(contents);
    const sections = try splitAtIndentedLines(allocator, contents);
    defer allocator.free(sections);
    var entries = try parseEntries(allocator, sections);
    defer freeMap(allocator, &entries);
    const command = entries.get(args[1]);
    if (command) |cmd| {
        const shell_file = constructShellFile(allocator, cmd) catch |err| {
            std.debug.print("Error constructing shell file: {any}\n", .{err});
            return;
        };
        var temp = try TempFile.create(allocator, shell_file);
        const mode = 0o755; // rwxr-xr-x
        const mod_res = c.chmod(temp.path.ptr, mode);
        if (mod_res != 0) {
            std.debug.print("Unable to set executable file permissions.\n", .{});
            return;
        }
        const res = try runShellFile("./.temp.sh");
        defer temp.delete() catch |err| {
            std.debug.print("Warning: Failed to delete temp file: {any}\n", .{err});
        };
        allocator.free(shell_file);
        if (res.code == 0) {
            const writer = std.io.getStdOut().writer();
            _ = try writer.write(res.output);
            //TODO maybe add flag for verbose output?
            // _ = try writer.write("\nCommands run successfully!\n");
        }
        else {
            std.debug.print("\nUnable to run commands for '{s}'.\n", .{args[1]});
            if (res.output.len > 0) {
                std.debug.print("Error: {s}\n", .{res.output});
            }
        }
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
            const segment = std.mem.trimRight(u8, input[current_start..line.ptr-input.ptr], "\n");
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
        const key_slice = key_start[0..key_start.len-1];
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
        std.debug.print(
            "Key:\n{s}\n\nValue:\n{s}\n\n~~~~~~~~~~~~~~~~~~\n\n",
            .{entry.key_ptr.*, entry.value_ptr.* }
        );
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
    const parts: [2][]const u8 = .{header, text};
    return try std.mem.join(allocator.*, "", &parts);
}

const TempFile = struct {
    allocator: *std.mem.Allocator,
    path: []const u8,
    /// Creates a new temporary file with the given contents.
    pub fn create(allocator: *std.mem.Allocator, contents: []const u8) !TempFile {
        const tmp_dir = std.fs.cwd(); 
        const path = try std.fmt.allocPrint(allocator.*, ".temp.sh", .{});
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

const CmdRes = struct {
    code: u8,
    output: []const u8,
};

pub fn runShellFile(path: []const u8) !CmdRes {
    const allocator = std.heap.page_allocator;
    var child = std.process.Child.init(&[_][]const u8{
        "/bin/sh", path,
    }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout_alloc = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 0);
    defer stdout_alloc.deinit(allocator);
    var stderr_alloc = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 0);
    defer stderr_alloc.deinit(allocator);
    try child.collectOutput(allocator, &stdout_alloc, &stderr_alloc, 1024);
    const status = try child.wait();
    var result: CmdRes = undefined;
    if (status.Exited == 0) {
        result = CmdRes{
            .code = status.Exited,
            .output = try stdout_alloc.toOwnedSlice(allocator),
        };
    }
    else {
        result = CmdRes{
            .code = status.Exited,
            .output = try stderr_alloc.toOwnedSlice(allocator),
        };
    }
    return result;
}

