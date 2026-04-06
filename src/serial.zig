// UART 16550 serial port driver for COM1.

const std = @import("std");

pub const COM1_PORT: u16 = 0x3F8;

pub const SerialPort = struct {
    base: u16,

    pub fn init(self: SerialPort) void {
        outb(self.base + 1, 0x00); // Disable interrupts
        outb(self.base + 3, 0x80); // Enable DLAB
        outb(self.base + 0, 0x01); // Baud rate 115200 (divisor 1)
        outb(self.base + 1, 0x00);
        outb(self.base + 3, 0x03); // 8 bits, no parity, 1 stop bit (8N1)
        outb(self.base + 2, 0xC7); // Enable FIFO, clear, 14-byte threshold
        outb(self.base + 4, 0x0B); // IRQs enabled, RTS/DSR set
    }

    fn isTransmitEmpty(self: SerialPort) bool {
        return (inb(self.base + 5) & 0x20) != 0;
    }

    pub fn writeByte(self: SerialPort, byte: u8) void {
        while (!self.isTransmitEmpty()) {}
        outb(self.base, byte);
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

// --- Port I/O ---

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}
