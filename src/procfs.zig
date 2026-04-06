const std = @import("std");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const vfs = @import("vfs.zig");

const VERSION_TEXT = "MerlionOS-Zig v0.1.0\n";

var task_snapshot: [vfs.MAX_DATA]u8 = undefined;
var task_snapshot_len: usize = 0;

pub fn init() void {
    const proc_dir = vfs.resolve("/proc") orelse return;

    if (vfs.createProcNode(proc_dir, "version")) |idx| {
        _ = vfs.writeFile(idx, VERSION_TEXT);
    }
    _ = vfs.createProcNode(proc_dir, "uptime");
    _ = vfs.createProcNode(proc_dir, "meminfo");
    _ = vfs.createProcNode(proc_dir, "tasks");
}

pub fn prepareRead(path: []const u8) void {
    if (strEql(path, "/proc/uptime")) {
        updateUptime();
        return;
    }
    if (strEql(path, "/proc/meminfo")) {
        updateMeminfo();
        return;
    }
    if (strEql(path, "/proc/tasks")) {
        updateTasks();
    }
}

fn updateUptime() void {
    const idx = vfs.resolve("/proc/uptime") orelse return;

    var buf: [64]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, "{d}\n", .{pit.uptimeSeconds()}) catch return;
    _ = vfs.writeFile(idx, rendered);
}

fn updateMeminfo() void {
    const idx = vfs.resolve("/proc/meminfo") orelse return;

    var buf: [160]u8 = undefined;
    const rendered = std.fmt.bufPrint(
        &buf,
        "MemTotal: {d} kB\nMemFree:  {d} kB\nMemUsed:  {d} kB\n",
        .{
            pmm.totalMemory() / 1024,
            pmm.freeMemory() / 1024,
            pmm.usedMemory() / 1024,
        },
    ) catch return;
    _ = vfs.writeFile(idx, rendered);
}

fn updateTasks() void {
    const idx = vfs.resolve("/proc/tasks") orelse return;

    task_snapshot_len = 0;
    appendTaskText("PID  STATE    TICKS  RUNS   YIELDS PRIO  NAME\n", .{});
    task.forEach(appendTaskLine);
    appendTaskText("Summary: {d} total ({d} runnable)\n", .{
        task.taskCount(),
        task.runnableCount(),
    });
    appendTaskText("Scheduler: tick={d} quantum={d} switches={d} preempt={d}\n", .{
        scheduler.getTickCount(),
        scheduler.getQuantum(),
        scheduler.getContextSwitches(),
        scheduler.getPreemptRequests(),
    });
    _ = vfs.writeFile(idx, task_snapshot[0..task_snapshot_len]);
}

fn appendTaskLine(task_entry: *const task.Task, is_current: bool) void {
    appendTaskText("{d: <4} {s: <8} {d: <6} {d: <6} {d: <6} {d: <5} {s}{s}\n", .{
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

fn appendTaskText(comptime fmt: []const u8, args: anytype) void {
    if (task_snapshot_len >= task_snapshot.len) return;

    const rendered = std.fmt.bufPrint(task_snapshot[task_snapshot_len..], fmt, args) catch return;
    task_snapshot_len += rendered.len;
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
