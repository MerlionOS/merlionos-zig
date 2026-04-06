// Kernel panic handler — writes to serial and halts.

const serial = @import("serial.zig");

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    const w = serial.com1.writer();
    w.print("\r\n!!! KERNEL PANIC !!!\r\n{s}\r\n", .{msg}) catch {};
    while (true) {
        asm volatile ("cli; hlt");
    }
}
