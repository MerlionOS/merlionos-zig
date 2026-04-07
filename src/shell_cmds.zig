const log = @import("log.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const procfs = @import("procfs.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const vfs = @import("vfs.zig");
const vga = @import("vga.zig");

const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn ([]const u8) void,
};

const commands = [_]Command{
    .{ .name = "cat", .description = "Print a file from the virtual filesystem", .handler = cmdCat },
    .{ .name = "help", .description = "Show available commands", .handler = cmdHelp },
    .{ .name = "clear", .description = "Clear the screen", .handler = cmdClear },
    .{ .name = "echo", .description = "Print text or write with > redirection", .handler = cmdEcho },
    .{ .name = "info", .description = "System information", .handler = cmdInfo },
    .{ .name = "kill", .description = "Kill a background task by pid", .handler = cmdKill },
    .{ .name = "ls", .description = "List a directory in the virtual filesystem", .handler = cmdLs },
    .{ .name = "mem", .description = "Memory statistics", .handler = cmdMem },
    .{ .name = "mkdir", .description = "Create a directory in the virtual filesystem", .handler = cmdMkdir },
    .{ .name = "ps", .description = "List tasks", .handler = cmdPs },
    .{ .name = "spawn", .description = "Spawn a cooperative worker task", .handler = cmdSpawn },
    .{ .name = "uptime", .description = "Time since boot", .handler = cmdUptime },
    .{ .name = "yield", .description = "Yield the CPU cooperatively", .handler = cmdYield },
    .{ .name = "write", .description = "Write text to a virtual file", .handler = cmdWrite },
    .{ .name = "version", .description = "Kernel version", .handler = cmdVersion },
};

pub fn dispatch(cmd: []const u8, args: []const u8) void {
    for (commands) |command| {
        if (strEql(cmd, command.name)) {
            command.handler(args);
            return;
        }
    }

    log.kprintln("Unknown command: {s}. Type 'help' for commands.", .{cmd});
}

fn cmdHelp(_: []const u8) void {
    log.kprintln("Available commands:", .{});
    for (commands) |command| {
        log.kprintln("  {s: <12} {s}", .{ command.name, command.description });
    }
}

fn cmdClear(_: []const u8) void {
    vga.vga_writer.clear();
}

fn cmdCat(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePath(args, false, &path_buf) orelse {
        log.kprintln("Usage: cat <path>", .{});
        return;
    };

    procfs.prepareRead(path);

    const idx = vfs.resolve(path) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    const inode = vfs.getInode(idx) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    if (inode.node_type == .directory) {
        log.kprintln("{s}: is a directory", .{path});
        return;
    }

    const data = vfs.readFile(idx) orelse {
        log.kprintln("{s}: cannot read", .{path});
        return;
    };
    if (data.len == 0) return;

    log.kprint("{s}", .{data});
    if (data[data.len - 1] != '\n') {
        log.kprint("\n", .{});
    }
}

fn cmdEcho(args: []const u8) void {
    if (parseEchoRedirect(args)) |redirect| {
        switch (writePath(redirect.path, redirect.text)) {
            .ok => log.kprintln("Wrote {d} bytes to {s}.", .{ redirect.text.len, redirect.path }),
            .invalid_path => log.kprintln("echo: invalid path", .{}),
            .parent_missing => log.kprintln("echo: parent directory missing", .{}),
            .parent_not_dir => log.kprintln("echo: parent is not a directory", .{}),
            .name_invalid => log.kprintln("echo: invalid file name", .{}),
            .write_failed => log.kprintln("echo: failed to write file", .{}),
        }
        return;
    }

    log.kprintln("{s}", .{args});
}

fn cmdInfo(_: []const u8) void {
    log.kprintln("MerlionOS-Zig v0.1.0", .{});
    log.kprintln("Architecture: x86_64", .{});
    log.kprintln("Boot: Limine", .{});
    log.kprintln("Uptime: {d}s", .{pit.uptimeSeconds()});
    log.kprintln("Memory: {d}/{d} MB free", .{
        pmm.freeMemory() / 1048576,
        pmm.totalMemory() / 1048576,
    });
    log.kprintln("Tasks: {d} total ({d} runnable)", .{
        task.taskCount(),
        task.runnableCount(),
    });
    log.kprintln("Scheduler: cooperative, quantum={d}, switches={d}", .{
        scheduler.getQuantum(),
        scheduler.getContextSwitches(),
    });
    log.kprintln("Preemption: pending={s} requests={d}", .{
        if (scheduler.hasPreemptPending()) "yes" else "no",
        scheduler.getPreemptRequests(),
    });
}

fn cmdKill(args: []const u8) void {
    const trimmed = trimSpaces(args);
    const pid = parsePid(trimmed) orelse {
        log.kprintln("Usage: kill <pid>", .{});
        return;
    };

    switch (task.kill(pid)) {
        .killed => log.kprintln("Killed task {d}.", .{pid}),
        .not_found => log.kprintln("Task {d} not found.", .{pid}),
        .busy_current => log.kprintln("Cannot kill the currently running task {d}.", .{pid}),
    }
}

fn cmdMem(_: []const u8) void {
    log.kprintln("Physical memory:", .{});
    log.kprintln("  Total: {d} MB", .{pmm.totalMemory() / 1048576});
    log.kprintln("  Used:  {d} MB", .{pmm.usedMemory() / 1048576});
    log.kprintln("  Free:  {d} MB", .{pmm.freeMemory() / 1048576});
}

fn cmdMkdir(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePath(args, false, &path_buf) orelse {
        log.kprintln("Usage: mkdir <path>", .{});
        return;
    };

    switch (createDirectory(path)) {
        .ok => log.kprintln("Created directory {s}.", .{path}),
        .already_exists => log.kprintln("{s}: already exists", .{path}),
        .invalid_path => log.kprintln("mkdir: invalid path", .{}),
        .parent_missing => log.kprintln("mkdir: parent directory missing", .{}),
        .parent_not_dir => log.kprintln("mkdir: parent is not a directory", .{}),
        .name_invalid => log.kprintln("mkdir: invalid directory name", .{}),
        .create_failed => log.kprintln("mkdir: failed to create directory", .{}),
    }
}

fn cmdLs(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePathOrRoot(args, &path_buf);
    const idx = vfs.resolve(path) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    const inode = vfs.getInode(idx) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    if (inode.node_type != .directory) {
        log.kprintln("{s}: not a directory", .{path});
        return;
    }

    vfs.listDir(idx, printDirEntry);
}

fn cmdPs(_: []const u8) void {
    if (task.taskCount() == 0) {
        log.kprintln("No tasks registered.", .{});
        return;
    }

    log.kprintln("PID  STATE    TICKS  RUNS   YIELDS PRIO  NAME", .{});
    task.forEach(printTaskRow);
    log.kprintln("Scheduler: tick={d} quantum={d} yields={d} slices={d} switches={d}", .{
        scheduler.getTickCount(),
        scheduler.getQuantum(),
        scheduler.getYieldRequests(),
        scheduler.getTimeSliceExpirations(),
        scheduler.getContextSwitches(),
    });
    log.kprintln("Preemption: pending={s} requests={d}", .{
        if (scheduler.hasPreemptPending()) "yes" else "no",
        scheduler.getPreemptRequests(),
    });
}

fn cmdSpawn(args: []const u8) void {
    const trimmed = trimSpaces(args);
    const task_name = if (trimmed.len == 0) "worker" else trimmed;
    if (scheduler.spawnWorker(task_name)) |pid| {
        log.kprintln("Spawned task {d}: {s}", .{ pid, task_name });
        return;
    }

    log.kprintln("Failed to spawn task. Task table or stack pool is full.", .{});
}

fn cmdUptime(_: []const u8) void {
    const secs = pit.uptimeSeconds();
    const mins = secs / 60;
    const hours = mins / 60;
    log.kprintln("Uptime: {d}h {d}m {d}s ({d} ticks)", .{
        hours,
        mins % 60,
        secs % 60,
        pit.getTicks(),
    });
}

fn cmdYield(_: []const u8) void {
    if (scheduler.yield()) {
        log.kprintln("Yielded to another runnable task and returned.", .{});
        return;
    }

    if (task.currentPid()) |pid| {
        log.kprintln("No alternate runnable task; still on PID {d}.", .{pid});
    } else {
        log.kprintln("Tasking is not initialized.", .{});
    }
}

fn cmdWrite(args: []const u8) void {
    const trimmed = trimSpaces(args);
    if (trimmed.len == 0) {
        log.kprintln("Usage: write <path> <text>", .{});
        return;
    }

    var split: usize = 0;
    while (split < trimmed.len and trimmed[split] != ' ') : (split += 1) {}
    if (split == trimmed.len) {
        log.kprintln("Usage: write <path> <text>", .{});
        return;
    }

    const path = trimSpaces(trimmed[0..split]);
    const text = trimSpaces(trimmed[split + 1 ..]);
    if (path.len == 0) {
        log.kprintln("write: invalid path", .{});
        return;
    }

    switch (writePath(path, text)) {
        .ok => log.kprintln("Wrote {d} bytes to {s}.", .{ text.len, path }),
        .invalid_path => log.kprintln("write: invalid path", .{}),
        .parent_missing => log.kprintln("write: parent directory missing", .{}),
        .parent_not_dir => log.kprintln("write: parent is not a directory", .{}),
        .name_invalid => log.kprintln("write: invalid file name", .{}),
        .write_failed => log.kprintln("write: failed to write file", .{}),
    }
}

fn cmdVersion(_: []const u8) void {
    log.kprintln("MerlionOS-Zig v0.1.0", .{});
    log.kprintln("Built with Zig 0.15", .{});
}

fn printTaskRow(task_entry: *const task.Task, is_current: bool) void {
    log.kprintln("{d: <4} {s: <8} {d: <6} {d: <6} {d: <6} {d: <5} {s}{s}", .{
        task_entry.pid,
        @tagName(task_entry.state),
        task_entry.ticks,
        task_entry.run_count,
        task_entry.yield_count,
        task_entry.priority,
        task.nameSlice(task_entry),
        if (is_current) " *" else "",
    });
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn trimSpaces(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;

    while (start < end and value[start] == ' ') : (start += 1) {}
    while (end > start and value[end - 1] == ' ') : (end -= 1) {}

    return value[start..end];
}

const MAX_PATH = 256;

fn normalizePathOrRoot(input: []const u8, buffer: *[MAX_PATH]u8) []const u8 {
    return normalizePath(input, true, buffer) orelse "/";
}

fn normalizePath(input: []const u8, allow_root_default: bool, buffer: *[MAX_PATH]u8) ?[]const u8 {
    const trimmed = trimSpaces(input);
    if (trimmed.len == 0) {
        return if (allow_root_default) "/" else null;
    }
    if (trimmed[0] == '/') return trimmed;
    if (trimmed.len + 1 > buffer.len) return null;

    buffer[0] = '/';
    @memcpy(buffer[1 .. trimmed.len + 1], trimmed);
    return buffer[0 .. trimmed.len + 1];
}

fn parsePid(value: []const u8) ?u32 {
    if (value.len == 0) return null;

    var pid: u32 = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        pid = pid * 10 + (ch - '0');
    }
    return pid;
}

fn printDirEntry(_: u16, inode: *const vfs.Inode) void {
    log.kprintln("{s}{s}", .{
        vfs.getName(inode),
        if (inode.node_type == .directory) "/" else "",
    });
}

const CreateStatus = enum {
    ok,
    already_exists,
    invalid_path,
    parent_missing,
    parent_not_dir,
    name_invalid,
    create_failed,
};

const WriteStatus = enum {
    ok,
    invalid_path,
    parent_missing,
    parent_not_dir,
    name_invalid,
    write_failed,
};

const EchoRedirect = struct {
    text: []const u8,
    path: []const u8,
};

fn createDirectory(path: []const u8) CreateStatus {
    if (path.len <= 1) return .invalid_path;
    if (vfs.resolve(path) != null) return .already_exists;

    var parent_buf: [MAX_PATH]u8 = undefined;
    const target = splitParent(path, &parent_buf) orelse return .invalid_path;
    if (target.name.len == 0) return .name_invalid;

    const parent_idx = vfs.resolve(target.parent) orelse return .parent_missing;
    const parent_inode = vfs.getInode(parent_idx) orelse return .parent_missing;
    if (parent_inode.node_type != .directory) return .parent_not_dir;

    if (vfs.createDir(parent_idx, target.name) == null) return .create_failed;
    return .ok;
}

fn writePath(path: []const u8, text: []const u8) WriteStatus {
    if (path.len <= 1) return .invalid_path;

    if (vfs.resolve(path)) |idx| {
        if (!vfs.writeFile(idx, text)) return .write_failed;
        return .ok;
    }

    var parent_buf: [MAX_PATH]u8 = undefined;
    const target = splitParent(path, &parent_buf) orelse return .invalid_path;
    if (target.name.len == 0) return .name_invalid;

    const parent_idx = vfs.resolve(target.parent) orelse return .parent_missing;
    const parent_inode = vfs.getInode(parent_idx) orelse return .parent_missing;
    if (parent_inode.node_type != .directory) return .parent_not_dir;

    const file_idx = vfs.createFile(parent_idx, target.name) orelse return .write_failed;
    if (!vfs.writeFile(file_idx, text)) return .write_failed;
    return .ok;
}

const ParentSplit = struct {
    parent: []const u8,
    name: []const u8,
};

fn splitParent(path: []const u8, buffer: *[MAX_PATH]u8) ?ParentSplit {
    if (path.len == 0 or path[0] != '/') return null;

    var last_slash = path.len;
    while (last_slash > 0) : (last_slash -= 1) {
        if (path[last_slash - 1] == '/') break;
    }

    if (last_slash == 0 or last_slash > path.len) return null;
    const name = trimSpaces(path[last_slash..]);
    if (name.len == 0) return null;

    const parent = if (last_slash == 1) "/" else blk: {
        const parent_len = last_slash - 1;
        if (parent_len >= buffer.len) return null;
        @memcpy(buffer[0..parent_len], path[0..parent_len]);
        break :blk buffer[0..parent_len];
    };

    return .{ .parent = parent, .name = name };
}

fn parseEchoRedirect(args: []const u8) ?EchoRedirect {
    const trimmed = trimSpaces(args);
    var i: usize = 0;
    while (i + 1 < trimmed.len) : (i += 1) {
        if (trimmed[i] == '>' and trimmed[i + 1] != '>') {
            const left = trimSpaces(trimmed[0..i]);
            const right = trimSpaces(trimmed[i + 1 ..]);
            if (right.len == 0) return null;
            return .{ .text = left, .path = right };
        }
    }
    return null;
}
