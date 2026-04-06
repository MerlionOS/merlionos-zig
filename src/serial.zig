// UART 16550 serial port driver for COM1.

const std = @import("std");
const cpu = @import("cpu.zig");

pub const COM1_PORT: u16 = 0x3F8;

pub const SerialPort = struct {
    base: u16,

    pub fn init(self: SerialPort) void {
        cpu.outb(self.base + 1, 0x00); // Disable interrupts
        cpu.outb(self.base + 3, 0x80); // Enable DLAB
        cpu.outb(self.base + 0, 0x01); // Baud rate 115200 (divisor 1)
        cpu.outb(self.base + 1, 0x00);
        cpu.outb(self.base + 3, 0x03); // 8 bits, no parity, 1 stop bit (8N1)
        cpu.outb(self.base + 2, 0xC7); // Enable FIFO, clear, 14-byte threshold
        cpu.outb(self.base + 4, 0x0B); // IRQs enabled, RTS/DSR set
    }

    fn isTransmitEmpty(self: SerialPort) bool {
        return (cpu.inb(self.base + 5) & 0x20) != 0;
    }

    pub fn writeByte(self: SerialPort, byte: u8) void {
        while (!self.isTransmitEmpty()) {}
        cpu.outb(self.base, byte);
    }

    pub fn writer(self: SerialPort) Writer {
        return .{ .context = self };
    }

    pub const Writer = std.io.GenericWriter(SerialPort, error{}, writeImpl);

    fn writeImpl(self: SerialPort, bytes: []const u8) error{}!usize {
        for (bytes) |byte| {
            if (byte == '\n') {
                self.writeByte('\r');
            }
            self.writeByte(byte);
        }
        return bytes.len;
    }
};

pub var com1 = SerialPort{ .base = COM1_PORT };
