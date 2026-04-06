const cpu = @import("cpu.zig");

const PIT_CHANNEL0: u16 = 0x40;
const PIT_CMD: u16 = 0x43;
const PIT_BASE_FREQ: u32 = 1193182;

var ticks: u64 = 0;
var frequency: u32 = 100;

pub fn init(hz: u32) void {
    frequency = hz;
    const divisor: u16 = @intCast(PIT_BASE_FREQ / hz);

    cpu.outb(PIT_CMD, 0x36);
    cpu.outb(PIT_CHANNEL0, @intCast(divisor & 0xFF));
    cpu.outb(PIT_CHANNEL0, @intCast((divisor >> 8) & 0xFF));
}

pub fn tick() void {
    ticks += 1;
}

pub fn getTicks() u64 {
    return ticks;
}

pub fn uptimeSeconds() u64 {
    return ticks / frequency;
}

pub fn uptimeMs() u64 {
    return (ticks * 1000) / frequency;
}
