const serial = @import("serial.zig");

const MAX_PROMPT_LEN: usize = 240;
const MAX_RESPONSE_LEN: usize = 512;

pub const SendStatus = enum {
    sent,
    unavailable,
    prompt_empty,
    prompt_too_long,
};

pub const PollStatus = enum {
    response_received,
    partial,
    no_data,
    unavailable,
    response_truncated,
};

pub const Info = struct {
    initialized: bool,
    available: bool,
    prompts_sent: u64,
    responses_received: u64,
    last_send_status: SendStatus,
    last_poll_status: PollStatus,
    response_len: usize,
};

var info_state: Info = .{
    .initialized = false,
    .available = false,
    .prompts_sent = 0,
    .responses_received = 0,
    .last_send_status = .unavailable,
    .last_poll_status = .unavailable,
    .response_len = 0,
};

var response_buf: [MAX_RESPONSE_LEN]u8 = [_]u8{0} ** MAX_RESPONSE_LEN;
var response_len: usize = 0;

pub fn init() void {
    serial.com2.init();
    info_state.initialized = true;
    info_state.available = serial.com2.isPresent();
    if (info_state.available) {
        info_state.last_send_status = .prompt_empty;
        info_state.last_poll_status = .no_data;
    }
}

pub fn info() *const Info {
    return &info_state;
}

pub fn lastResponse() []const u8 {
    return response_buf[0..response_len];
}

pub fn sendPrompt(prompt: []const u8) SendStatus {
    if (!info_state.available) return rememberSend(.unavailable);
    if (prompt.len == 0) return rememberSend(.prompt_empty);
    if (prompt.len > MAX_PROMPT_LEN) return rememberSend(.prompt_too_long);

    response_len = 0;
    info_state.response_len = 0;
    const writer = serial.com2.writer();
    writer.print("ASK {s}\n", .{prompt}) catch {};

    info_state.prompts_sent += 1;
    return rememberSend(.sent);
}

pub fn pollResponse() PollStatus {
    if (!info_state.available) return rememberPoll(.unavailable);

    var read_any = false;
    while (serial.com2.tryReadByte()) |byte| {
        read_any = true;
        if (byte == '\r') continue;
        if (byte == '\n') {
            info_state.responses_received += 1;
            info_state.response_len = response_len;
            return rememberPoll(.response_received);
        }
        if (response_len >= response_buf.len) {
            info_state.response_len = response_len;
            return rememberPoll(.response_truncated);
        }
        response_buf[response_len] = byte;
        response_len += 1;
    }

    info_state.response_len = response_len;
    if (read_any or response_len > 0) return rememberPoll(.partial);
    return rememberPoll(.no_data);
}

fn rememberSend(status: SendStatus) SendStatus {
    info_state.last_send_status = status;
    return status;
}

fn rememberPoll(status: PollStatus) PollStatus {
    info_state.last_poll_status = status;
    return status;
}
