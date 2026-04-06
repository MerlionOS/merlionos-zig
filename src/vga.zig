// VGA text mode driver (80x25, color, scrolling).
// Uses the standard VGA text buffer at physical address 0xB8000.

const std = @import("std");
const limine = @import("limine.zig");

pub const VGA_WIDTH = 80;
pub const VGA_HEIGHT = 25;
pub const VGA_BUFFER_ADDR = 0xB8000;

pub const Color = enum(u4) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    pink = 13,
    yellow = 14,
    white = 15,
};

fn makeColorAttr(fg: Color, bg: Color) u8 {
    return @as(u8, @intFromEnum(fg)) | (@as(u8, @intFromEnum(bg)) << 4);
}

fn makeVgaEntry(char: u8, color: u8) u16 {
    return @as(u16, char) | (@as(u16, color) << 8);
}

pub var vga_writer = VgaWriter{};

pub const VgaWriter = struct {
    col: usize = 0,
    row: usize = 0,
    color: u8 = makeColorAttr(.light_green, .black),
    buffer: ?[*]volatile u16 = null,

    pub fn init(self: *VgaWriter) void {
        // Limine typically boots QEMU in framebuffer mode; do not assume the
        // legacy VGA text buffer is mapped and writable in that configuration.
        if (limine.framebuffer_request.response) |resp| {
            if (resp.framebuffer_count > 0) {
                self.buffer = null;
                return;
            }
        }

        // Try to get HHDM offset for higher-half mapping
        const hhdm_offset: u64 = blk: {
            if (limine.hhdm_request.response) |resp| {
                break :blk resp.offset;
            }
            break :blk 0;
        };
        self.buffer = @ptrFromInt(VGA_BUFFER_ADDR + hhdm_offset);
        self.clear();
    }

    pub fn clear(self: *VgaWriter) void {
        const buf = self.buffer orelse return;
        for (0..VGA_HEIGHT) |row| {
            for (0..VGA_WIDTH) |col| {
                buf[row * VGA_WIDTH + col] = makeVgaEntry(' ', self.color);
            }
        }
        self.col = 0;
        self.row = 0;
    }

    pub fn setColor(self: *VgaWriter, fg: Color, bg: Color) void {
        self.color = makeColorAttr(fg, bg);
    }

    pub fn putChar(self: *VgaWriter, char: u8) void {
        if (self.buffer == null) return;

        switch (char) {
            '\n' => {
                self.col = 0;
                self.row += 1;
            },
            '\r' => {
                self.col = 0;
            },
            '\t' => {
                self.col = (self.col + 8) & ~@as(usize, 7);
                if (self.col >= VGA_WIDTH) {
                    self.col = 0;
                    self.row += 1;
                }
            },
            0x08 => { // backspace
                if (self.col > 0) {
                    self.col -= 1;
                    self.buffer.?[self.row * VGA_WIDTH + self.col] = makeVgaEntry(' ', self.color);
                }
            },
            else => {
                self.buffer.?[self.row * VGA_WIDTH + self.col] = makeVgaEntry(char, self.color);
                self.col += 1;
                if (self.col >= VGA_WIDTH) {
                    self.col = 0;
                    self.row += 1;
                }
            },
        }

        if (self.row >= VGA_HEIGHT) {
            self.scroll();
        }
    }

    pub fn writeBytes(self: *VgaWriter, bytes: []const u8) void {
        for (bytes) |byte| {
            self.putChar(byte);
        }
    }

    fn scroll(self: *VgaWriter) void {
        const buf = self.buffer orelse return;
        // Move all rows up by 1
        for (1..VGA_HEIGHT) |row| {
            for (0..VGA_WIDTH) |col| {
                buf[(row - 1) * VGA_WIDTH + col] = buf[row * VGA_WIDTH + col];
            }
        }
        // Clear last row
        for (0..VGA_WIDTH) |col| {
            buf[(VGA_HEIGHT - 1) * VGA_WIDTH + col] = makeVgaEntry(' ', self.color);
        }
        self.row = VGA_HEIGHT - 1;
    }

    pub fn writer(self: *VgaWriter) Writer {
        return .{ .context = self };
    }

    pub const Writer = std.io.GenericWriter(*VgaWriter, error{}, writeImpl);

    fn writeImpl(self: *VgaWriter, bytes: []const u8) error{}!usize {
        for (bytes) |byte| {
            self.putChar(byte);
        }
        return bytes.len;
    }
};
