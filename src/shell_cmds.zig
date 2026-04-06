const log = @import("log.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const vga = @import("vga.zig");

const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn ([]const u8) void,
};

const commands = [_]Command{
    .{ .name = "help", .description = "Show available commands", .handler = cmdHelp },
    .{ .name = "clear", .description = "Clear the screen", .handler = cmdClear },
    .{ .name = "echo", .description = "Print text", .handler = cmdEcho },
    .{ .name = "info", .description = "System information", .handler = cmdInfo },
    .{ .name = "mem", .description = "Memory statistics", .handler = cmdMem },
    .{ .name = "ps", .description = "List tasks", .handler = cmdPs },
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
}

fn cmdMem(_: []const u8) void {
    log.kprintln("Physical memory:", .{});
    log.kprintln("  Total: {d} MB", .{pmm.totalMemory() / 1048576});
    log.kprintln("  Used:  {d} MB", .{pmm.usedMemory() / 1048576});
    log.kprintln("  Free:  {d} MB", .{pmm.freeMemory() / 1048576});
}

fn cmdPs(_: []const u8) void {
    if (task.taskCount() == 0) {
        log.kprintln("No tasks registered.", .{});
        return;
    }

    log.kprintln("PID  STATE    TICKS  PRIO  NAME", .{});
    task.forEach(printTaskRow);
    log.kprintln("Scheduler: tick={d} quantum={d} yields={d} slices={d} switches={d}", .{
        scheduler.getTickCount(),
        scheduler.getQuantum(),
        scheduler.getYieldRequests(),
        scheduler.getTimeSliceExpirations(),
        scheduler.getContextSwitches(),
    });
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
        log.kprintln("Yielded to another runnable task.", .{});
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
    log.kprintln("{d: <4} {s: <8} {d: <6} {d: <5} {s}{s}", .{
        task_entry.pid,
        @tagName(task_entry.state),
        task_entry.ticks,
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
