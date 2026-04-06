const cpu = @import("cpu.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x11;
const ICW4_8086: u8 = 0x01;
const EOI: u8 = 0x20;

pub const PRIMARY_OFFSET: u8 = 32;
pub const SECONDARY_OFFSET: u8 = 40;

pub fn init() void {
    const mask1 = cpu.inb(PIC1_DATA);
    const mask2 = cpu.inb(PIC2_DATA);
    _ = mask1;
    _ = mask2;

    cpu.outb(PIC1_CMD, ICW1_INIT);
    cpu.ioWait();
    cpu.outb(PIC2_CMD, ICW1_INIT);
    cpu.ioWait();

    cpu.outb(PIC1_DATA, PRIMARY_OFFSET);
    cpu.ioWait();
    cpu.outb(PIC2_DATA, SECONDARY_OFFSET);
    cpu.ioWait();

    cpu.outb(PIC1_DATA, 4);
    cpu.ioWait();
    cpu.outb(PIC2_DATA, 2);
    cpu.ioWait();

    cpu.outb(PIC1_DATA, ICW4_8086);
    cpu.ioWait();
    cpu.outb(PIC2_DATA, ICW4_8086);
    cpu.ioWait();

    cpu.outb(PIC1_DATA, 0xFC);
    cpu.outb(PIC2_DATA, 0xFF);
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) cpu.outb(PIC2_CMD, EOI);
    cpu.outb(PIC1_CMD, EOI);
}

pub fn setMask(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const line = irq % 8;
    const val = cpu.inb(port) | (@as(u8, 1) << @intCast(line));
    cpu.outb(port, val);
}

pub fn clearMask(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const line = irq % 8;
    const val = cpu.inb(port) & ~(@as(u8, 1) << @intCast(line));
    cpu.outb(port, val);
}
