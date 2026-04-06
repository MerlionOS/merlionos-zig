const cpu = @import("cpu.zig");

const KB_DATA_PORT: u16 = 0x60;

pub const KeyEvent = union(enum) {
    char: u8,
    enter,
    backspace,
    tab,
    escape,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    home,
    end,
    delete,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

const BUFFER_SIZE = 128;

var key_buffer: [BUFFER_SIZE]KeyEvent = undefined;
var buf_read: usize = 0;
var buf_write: usize = 0;

var shift_pressed = false;
var ctrl_pressed = false;
var extended = false;

pub fn handleInterrupt() void {
    const scancode = cpu.inb(KB_DATA_PORT);

    if (scancode == 0xE0) {
        extended = true;
        return;
    }

    const is_release = (scancode & 0x80) != 0;
    const code = scancode & 0x7F;

    if (extended) {
        extended = false;
        if (!is_release) {
            const event: ?KeyEvent = switch (code) {
                0x48 => .arrow_up,
                0x50 => .arrow_down,
                0x4B => .arrow_left,
                0x4D => .arrow_right,
                0x47 => .home,
                0x4F => .end,
                0x53 => .delete,
                0x49 => .page_up,
                0x51 => .page_down,
                else => null,
            };
            if (event) |e| {
                pushEvent(e);
            }
        }
        return;
    }

    if (code == 0x2A or code == 0x36) {
        shift_pressed = !is_release;
        return;
    }

    if (code == 0x1D) {
        ctrl_pressed = !is_release;
        return;
    }

    if (is_release) return;

    switch (code) {
        0x1C => pushEvent(.enter),
        0x0E => pushEvent(.backspace),
        0x0F => pushEvent(.tab),
        0x01 => pushEvent(.escape),
        0x3B => pushEvent(.f1),
        0x3C => pushEvent(.f2),
        0x3D => pushEvent(.f3),
        0x3E => pushEvent(.f4),
        0x3F => pushEvent(.f5),
        0x40 => pushEvent(.f6),
        0x41 => pushEvent(.f7),
        0x42 => pushEvent(.f8),
        0x43 => pushEvent(.f9),
        0x44 => pushEvent(.f10),
        0x57 => pushEvent(.f11),
        0x58 => pushEvent(.f12),
        else => {
            const char = scancodeToChar(code);
            if (char != 0) {
                var c = char;
                if (shift_pressed) c = shiftChar(c);
                if (ctrl_pressed and c >= 'a' and c <= 'z') {
                    c = c - 'a' + 1;
                }
                pushEvent(.{ .char = c });
            }
        },
    }
}

pub fn readEvent() ?KeyEvent {
    if (buf_read == buf_write) return null;
    const event = key_buffer[buf_read];
    buf_read = (buf_read + 1) % BUFFER_SIZE;
    return event;
}

fn pushEvent(event: KeyEvent) void {
    const next = (buf_write + 1) % BUFFER_SIZE;
    if (next == buf_read) return;
    key_buffer[buf_write] = event;
    buf_write = next;
}

fn scancodeToChar(code: u8) u8 {
    const table = comptime blk: {
        var t: [128]u8 = [_]u8{0} ** 128;
        t[0x02] = '1';
        t[0x03] = '2';
        t[0x04] = '3';
        t[0x05] = '4';
        t[0x06] = '5';
        t[0x07] = '6';
        t[0x08] = '7';
        t[0x09] = '8';
        t[0x0A] = '9';
        t[0x0B] = '0';
        t[0x0C] = '-';
        t[0x0D] = '=';
        t[0x29] = '`';
        t[0x10] = 'q';
        t[0x11] = 'w';
        t[0x12] = 'e';
        t[0x13] = 'r';
        t[0x14] = 't';
        t[0x15] = 'y';
        t[0x16] = 'u';
        t[0x17] = 'i';
        t[0x18] = 'o';
        t[0x19] = 'p';
        t[0x1A] = '[';
        t[0x1B] = ']';
        t[0x2B] = '\\';
        t[0x1E] = 'a';
        t[0x1F] = 's';
        t[0x20] = 'd';
        t[0x21] = 'f';
        t[0x22] = 'g';
        t[0x23] = 'h';
        t[0x24] = 'j';
        t[0x25] = 'k';
        t[0x26] = 'l';
        t[0x27] = ';';
        t[0x28] = '\'';
        t[0x2C] = 'z';
        t[0x2D] = 'x';
        t[0x2E] = 'c';
        t[0x2F] = 'v';
        t[0x30] = 'b';
        t[0x31] = 'n';
        t[0x32] = 'm';
        t[0x33] = ',';
        t[0x34] = '.';
        t[0x35] = '/';
        t[0x39] = ' ';
        break :blk t;
    };

    if (code < table.len) return table[code];
    return 0;
}

fn shiftChar(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return switch (c) {
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        '`' => '~',
        else => c,
    };
}
