// Kernel logging — writes to both serial and VGA simultaneously.

const std = @import("std");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

pub fn kprint(comptime fmt: []const u8, args: anytype) void {
    serial.com1.writer().print(fmt, args) catch {};
    vga.vga_writer.writer().print(fmt, args) catch {};
}

pub fn kprintln(comptime fmt: []const u8, args: anytype) void {
    kprint(fmt ++ "\n", args);
}
