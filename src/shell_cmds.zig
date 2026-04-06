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
    .{ .name = "echo", .description = "Print text", .handler = cmdEcho },
    .{ .name = "info", .description = "System information", .handler = cmdInfo },
    .{ .name = "kill", .description = "Kill a background task by pid", .handler = cmdKill },
    .{ .name = "ls", .description = "List a directory in the virtual filesystem", .handler = cmdLs },
    .{ .name = "mem", .description = "Memory statistics", .handler = cmdMem },
    .{ .name = "ps", .description = "List tasks", .handler = cmdPs },
    .{ .name = "spawn", .description = "Spawn a cooperative worker task", .handler = cmdSpawn },
    .{ .name = "uptime", .description = "Time since boot", .handler = cmdUptime },
    .{ .name = "yield", .description = "Yield the CPU cooperatively", .handler = cmdYield },
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
