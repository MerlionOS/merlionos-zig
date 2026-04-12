// Kernel logging — writes to both serial and VGA simultaneously.

const std = @import("std");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

pub fn kprint(comptime fmt: []const u8, args: anytype) void {
    serial.com1.writer().print(fmt, args) catch {};

    var buf: [512]u8 = undefined;
    const rendered = std.fmt.bufPrint(&buf, fmt, args) catch return;
    vga.vga_writer.writeBytes(rendered);
}

pub fn kprintln(comptime fmt: []const u8, args: anytype) void {
    kprint(fmt ++ "\n", args);
}

pub fn writeBytes(bytes: []const u8) void {
    serial.com1.writer().writeAll(bytes) catch {};
    vga.vga_writer.writeBytes(bytes);
}
