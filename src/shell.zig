const cpu = @import("cpu.zig");
const keyboard = @import("keyboard.zig");
const log = @import("log.zig");
const shell_cmds = @import("shell_cmds.zig");
const vga = @import("vga.zig");

const MAX_INPUT = 256;
const HISTORY_SIZE = 16;

var input_buf: [MAX_INPUT]u8 = undefined;
var input_len: usize = 0;
var cursor_pos: usize = 0;

var history: [HISTORY_SIZE][MAX_INPUT]u8 = undefined;
var history_lens: [HISTORY_SIZE]usize = [_]usize{0} ** HISTORY_SIZE;
var history_count: usize = 0;
var history_index: usize = 0;

pub fn run() noreturn {
    printPrompt();
    while (true) {
        if (keyboard.readEvent()) |event| {
            switch (event) {
                .enter => {
                    log.kprint("\n", .{});
                    if (input_len > 0) {
                        addHistory();
                        executeCommand(input_buf[0..input_len]);
                    }
                    input_len = 0;
                    cursor_pos = 0;
                    printPrompt();
                },
                .backspace => {
                    if (cursor_pos > 0) {
                        cursor_pos -= 1;
                        input_len -= 1;
                        var i = cursor_pos;
                        while (i < input_len) : (i += 1) {
                            input_buf[i] = input_buf[i + 1];
                        }
                        redrawLine();
                    }
                },
                .arrow_up => {
                    if (history_count > 0) {
                        if (history_index > 0) history_index -= 1;
                        loadHistory(history_index);
                        redrawLine();
                    }
                },
                .arrow_down => {
                    if (history_index < history_count) {
                        history_index += 1;
                        if (history_index == history_count) {
                            input_len = 0;
                            cursor_pos = 0;
                        } else {
                            loadHistory(history_index);
                        }
                        redrawLine();
                    }
                },
                .char => |c| {
                    if (input_len < MAX_INPUT - 1) {
                        input_buf[input_len] = c;
                        input_len += 1;
                        cursor_pos += 1;
                        log.kprint("{c}", .{c});
                    }
                },
                else => {},
            }
        } else {
            asm volatile ("hlt");
        }
    }
}

fn executeCommand(line: []const u8) void {
    var cmd_end: usize = 0;
    while (cmd_end < line.len and line[cmd_end] != ' ') : (cmd_end += 1) {}
    const cmd = line[0..cmd_end];
    const args = if (cmd_end < line.len) line[cmd_end + 1 ..] else "";
    shell_cmds.dispatch(cmd, args);
}

fn printPrompt() void {
    vga.vga_writer.setColor(.light_cyan, .black);
    log.kprint("merlion", .{});
    vga.vga_writer.setColor(.white, .black);
    log.kprint("> ", .{});
    vga.vga_writer.setColor(.light_green, .black);
}

fn redrawLine() void {
    log.kprint("\r", .{});
    printPrompt();
    for (input_buf[0..input_len]) |c| {
        log.kprint("{c}", .{c});
    }
    log.kprint("  ", .{});
    log.kprint("\r", .{});
    printPrompt();
    for (input_buf[0..input_len]) |c| {
        log.kprint("{c}", .{c});
    }
}

fn addHistory() void {
    const idx = history_count % HISTORY_SIZE;
    @memcpy(history[idx][0..input_len], input_buf[0..input_len]);
    history_lens[idx] = input_len;
    if (history_count < HISTORY_SIZE) history_count += 1;
    history_index = history_count;
}

fn loadHistory(idx: usize) void {
    const real_idx = idx % HISTORY_SIZE;
    input_len = history_lens[real_idx];
    @memcpy(input_buf[0..input_len], history[real_idx][0..input_len]);
    cursor_pos = input_len;
}
