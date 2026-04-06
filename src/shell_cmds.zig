const log = @import("log.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
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
    .{ .name = "uptime", .description = "Time since boot", .handler = cmdUptime },
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
}

fn cmdMem(_: []const u8) void {
    log.kprintln("Physical memory:", .{});
    log.kprintln("  Total: {d} MB", .{pmm.totalMemory() / 1048576});
    log.kprintln("  Used:  {d} MB", .{pmm.usedMemory() / 1048576});
    log.kprintln("  Free:  {d} MB", .{pmm.freeMemory() / 1048576});
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

fn cmdVersion(_: []const u8) void {
    log.kprintln("MerlionOS-Zig v0.1.0", .{});
    log.kprintln("Built with Zig 0.15", .{});
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
