const ipv4 = @import("ipv4.zig");
const net = @import("net.zig");
const pit = @import("pit.zig");

const TCP_HEADER_MIN: usize = 20;
pub const MAX_CONNECTIONS: usize = 4;
const RX_BUFFER_SIZE: usize = 2048;
const TX_BUFFER_SIZE: usize = 2048;
const MAX_TCP_SEGMENT_LEN: usize = net.ETH_MTU - net.IPV4_HEADER_MIN;
const DEFAULT_WINDOW_SIZE: u16 = 2048;
const RETRANSMIT_TICKS: u64 = 300;
const MAX_RETRANSMITS: u8 = 5;
const TIME_WAIT_TICKS: u64 = 1000;
const EPHEMERAL_PORT_START: u16 = 49152;

const OFF_SRC_PORT: usize = 0;
const OFF_DST_PORT: usize = 2;
const OFF_SEQ_NUM: usize = 4;
const OFF_ACK_NUM: usize = 8;
const OFF_DATA_OFFSET: usize = 12;
const OFF_FLAGS: usize = 13;
const OFF_WINDOW: usize = 14;
const OFF_CHECKSUM: usize = 16;
const OFF_URGENT: usize = 18;

const FLAG_FIN: u8 = 0x01;
const FLAG_SYN: u8 = 0x02;
const FLAG_RST: u8 = 0x04;
const FLAG_PSH: u8 = 0x08;
const FLAG_ACK: u8 = 0x10;

pub const State = enum {
    closed,
    syn_sent,
    established,
    fin_wait_1,
    fin_wait_2,
    time_wait,
    close_wait,
    last_ack,
};

pub const ConnId = u8;

pub const Connection = struct {
    state: State,
    local_port: u16,
    remote_port: u16,
    remote_ip: net.Ipv4Addr,
    snd_una: u32,
    snd_nxt: u32,
    rcv_nxt: u32,
    iss: u32,
    rx_buf: [RX_BUFFER_SIZE]u8,
    rx_len: usize,
    tx_buf: [TX_BUFFER_SIZE]u8,
    tx_len: usize,
    retransmit_tick: u64,
    retransmit_count: u8,
    time_wait_tick: u64,
};

pub const ConnectResult = enum {
    ok,
    no_free_slot,
    invalid_port,
};

pub const SendResult = enum {
    ok,
    buffer_full,
    not_established,
    invalid_conn,
};

pub const RecvResult = struct {
    data: []const u8,
    state: State,
};

pub const Stats = struct {
    segments_sent: u64,
    segments_received: u64,
    connections_opened: u64,
    connections_closed: u64,
    retransmits: u64,
    resets_sent: u64,
    bad_checksum: u64,
    malformed: u64,
    send_errors: u64,
    last_send_status: ipv4.SendStatus,
};

var connections: [MAX_CONNECTIONS]Connection = [_]Connection{emptyConnection()} ** MAX_CONNECTIONS;
var next_local_port: u16 = EPHEMERAL_PORT_START;
var stats: Stats = emptyStats();
var tx_segment: [MAX_TCP_SEGMENT_LEN]u8 = [_]u8{0} ** MAX_TCP_SEGMENT_LEN;

pub fn init() void {
    connections = [_]Connection{emptyConnection()} ** MAX_CONNECTIONS;
    next_local_port = EPHEMERAL_PORT_START;
    stats = emptyStats();
    ipv4.registerHandler(net.IPPROTO_TCP, handleRx);
}

pub fn connect(remote_ip: net.Ipv4Addr, remote_port: u16, conn_out: *ConnId) ConnectResult {
    if (remote_port == 0) return .invalid_port;

    const idx = findFreeSlot() orelse return .no_free_slot;
    const now = pit.getTicks();
    const local_port = allocateLocalPort();
    const iss: u32 = @truncate((now *% 64000) + local_port);

    connections[idx] = emptyConnection();
    const conn = &connections[idx];
    conn.state = .syn_sent;
    conn.local_port = local_port;
    conn.remote_port = remote_port;
    conn.remote_ip = remote_ip;
    conn.iss = iss;
    conn.snd_una = iss;
    conn.snd_nxt = iss +% 1;
    conn.rcv_nxt = 0;
    conn.retransmit_tick = now;
    conn.retransmit_count = 0;

    _ = sendSegment(idx, FLAG_SYN, conn.iss, 0, &.{});
    conn_out.* = @intCast(idx);
    stats.connections_opened += 1;
    return .ok;
}

pub fn send(conn_id: ConnId, data: []const u8) SendResult {
    const conn = getMutableConnection(conn_id) orelse return .invalid_conn;
    if (conn.state != .established) return .not_established;
    if (data.len > TX_BUFFER_SIZE - conn.tx_len) return .buffer_full;

    for (data, 0..) |byte, i| {
        conn.tx_buf[conn.tx_len + i] = byte;
    }
    conn.tx_len += data.len;
    return .ok;
}

pub fn recv(conn_id: ConnId) RecvResult {
    const conn = getMutableConnection(conn_id) orelse {
        return .{ .data = &.{}, .state = .closed };
    };

    const data = conn.rx_buf[0..conn.rx_len];
    conn.rx_len = 0;
    return .{ .data = data, .state = conn.state };
}

pub fn close(conn_id: ConnId) void {
    const idx = connIndex(conn_id) orelse return;
    var conn = &connections[idx];

    switch (conn.state) {
        .established => {
            _ = sendSegment(idx, FLAG_FIN | FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
            conn.snd_nxt +%= 1;
            conn.state = .fin_wait_1;
            conn.retransmit_tick = pit.getTicks();
            conn.retransmit_count = 0;
        },
        .close_wait => {
            _ = sendSegment(idx, FLAG_FIN | FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
            conn.snd_nxt +%= 1;
            conn.state = .last_ack;
            conn.retransmit_tick = pit.getTicks();
            conn.retransmit_count = 0;
        },
        .closed => {},
        else => closeConnection(idx),
    }
}

pub fn tick() void {
    const now = pit.getTicks();

    for (&connections, 0..) |*conn, idx| {
        switch (conn.state) {
            .closed => {},
            .syn_sent => {
                if (now -% conn.retransmit_tick >= RETRANSMIT_TICKS) {
                    if (conn.retransmit_count >= MAX_RETRANSMITS) {
                        closeConnection(idx);
                    } else {
                        _ = sendSegment(idx, FLAG_SYN, conn.iss, 0, &.{});
                        conn.retransmit_count += 1;
                        conn.retransmit_tick = now;
                        stats.retransmits += 1;
                    }
                }
            },
            .established => {
                if (conn.tx_len > 0) {
                    const sent_len = conn.tx_len;
                    if (sendSegment(idx, FLAG_ACK | FLAG_PSH, conn.snd_nxt, conn.rcv_nxt, conn.tx_buf[0..sent_len]) == .sent) {
                        conn.snd_nxt +%= @intCast(sent_len);
                        conn.tx_len = 0;
                        conn.retransmit_tick = now;
                        conn.retransmit_count = 0;
                    }
                }
            },
            .fin_wait_1 => {
                if (now -% conn.retransmit_tick >= RETRANSMIT_TICKS) {
                    if (conn.retransmit_count >= MAX_RETRANSMITS) {
                        closeConnection(idx);
                    } else {
                        _ = sendSegment(idx, FLAG_FIN | FLAG_ACK, conn.snd_nxt -% 1, conn.rcv_nxt, &.{});
                        conn.retransmit_count += 1;
                        conn.retransmit_tick = now;
                        stats.retransmits += 1;
                    }
                }
            },
            .fin_wait_2 => {},
            .time_wait => {
                if (now -% conn.time_wait_tick >= TIME_WAIT_TICKS) {
                    closeConnection(idx);
                }
            },
            .close_wait => {
                _ = sendSegment(idx, FLAG_FIN | FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
                conn.snd_nxt +%= 1;
                conn.state = .last_ack;
                conn.retransmit_tick = now;
                conn.retransmit_count = 0;
            },
            .last_ack => {
                if (now -% conn.retransmit_tick >= RETRANSMIT_TICKS) {
                    if (conn.retransmit_count >= MAX_RETRANSMITS) {
                        closeConnection(idx);
                    } else {
                        _ = sendSegment(idx, FLAG_FIN | FLAG_ACK, conn.snd_nxt -% 1, conn.rcv_nxt, &.{});
                        conn.retransmit_count += 1;
                        conn.retransmit_tick = now;
                        stats.retransmits += 1;
                    }
                }
            },
        }
    }
}

pub fn getConnection(conn_id: ConnId) ?*const Connection {
    const idx = connIndex(conn_id) orelse return null;
    return &connections[idx];
}

pub fn getStats() Stats {
    return stats;
}

fn handleRx(packet: ipv4.RxIpPacket) void {
    const data = packet.payload;
    if (data.len < TCP_HEADER_MIN) {
        stats.malformed += 1;
        return;
    }

    if (net.pseudoHeaderChecksum(packet.src_ip, packet.dst_ip, net.IPPROTO_TCP, data) != 0) {
        stats.bad_checksum += 1;
        return;
    }

    const data_offset = @as(usize, data[OFF_DATA_OFFSET] >> 4) * 4;
    if (data_offset < TCP_HEADER_MIN or data_offset > data.len) {
        stats.malformed += 1;
        return;
    }

    const src_port = net.readBe16(data, OFF_SRC_PORT);
    const dst_port = net.readBe16(data, OFF_DST_PORT);
    const seq = net.readBe32(data, OFF_SEQ_NUM);
    const ack = net.readBe32(data, OFF_ACK_NUM);
    const flags = data[OFF_FLAGS];
    const payload = data[data_offset..];

    const idx = findConnection(packet.src_ip, src_port, dst_port) orelse {
        sendReset(packet, src_port, dst_port, seq, ack, flags, payload.len);
        return;
    };

    stats.segments_received += 1;
    const conn = &connections[idx];

    if ((flags & FLAG_RST) != 0) {
        closeConnection(idx);
        return;
    }

    switch (conn.state) {
        .closed => {},
        .syn_sent => handleSynSent(idx, seq, ack, flags),
        .established => handleEstablished(idx, seq, ack, flags, payload),
        .fin_wait_1 => handleFinWait1(idx, seq, ack, flags, payload),
        .fin_wait_2 => handleFinWait2(idx, seq, flags, payload),
        .time_wait => {
            _ = sendSegment(idx, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
        },
        .close_wait => {},
        .last_ack => {
            if ((flags & FLAG_ACK) != 0) closeConnection(idx);
        },
    }
}

fn handleSynSent(idx: usize, seq: u32, ack: u32, flags: u8) void {
    var conn = &connections[idx];
    if ((flags & (FLAG_SYN | FLAG_ACK)) == (FLAG_SYN | FLAG_ACK) and ack == conn.snd_nxt) {
        conn.rcv_nxt = seq +% 1;
        conn.snd_una = ack;
        conn.state = .established;
        conn.retransmit_count = 0;
        _ = sendSegment(idx, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
    }
}

fn handleEstablished(idx: usize, seq: u32, ack: u32, flags: u8, payload: []const u8) void {
    var conn = &connections[idx];
    if ((flags & FLAG_ACK) != 0 and ack > conn.snd_una) {
        conn.snd_una = ack;
    }

    if (receivePayload(idx, seq, payload)) {
        _ = sendSegment(idx, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
    }

    if ((flags & FLAG_FIN) != 0 and seq +% @as(u32, @intCast(payload.len)) == conn.rcv_nxt) {
        conn.rcv_nxt +%= 1;
        conn.state = .close_wait;
        _ = sendSegment(idx, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
    }
}

fn handleFinWait1(idx: usize, seq: u32, ack: u32, flags: u8, payload: []const u8) void {
    var conn = &connections[idx];
    if ((flags & FLAG_ACK) != 0 and ack == conn.snd_nxt) {
        conn.state = .fin_wait_2;
    }

    if (receivePayload(idx, seq, payload)) {
        _ = sendSegment(idx, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
    }

    if ((flags & FLAG_FIN) != 0 and seq +% @as(u32, @intCast(payload.len)) == conn.rcv_nxt) {
        conn.rcv_nxt +%= 1;
        conn.state = .time_wait;
        conn.time_wait_tick = pit.getTicks();
        _ = sendSegment(idx, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
    }
}

fn handleFinWait2(idx: usize, seq: u32, flags: u8, payload: []const u8) void {
    var conn = &connections[idx];
    if (receivePayload(idx, seq, payload)) {
        _ = sendSegment(idx, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
    }

    if ((flags & FLAG_FIN) != 0 and seq +% @as(u32, @intCast(payload.len)) == conn.rcv_nxt) {
        conn.rcv_nxt +%= 1;
        conn.state = .time_wait;
        conn.time_wait_tick = pit.getTicks();
        _ = sendSegment(idx, FLAG_ACK, conn.snd_nxt, conn.rcv_nxt, &.{});
    }
}

fn receivePayload(idx: usize, seq: u32, payload: []const u8) bool {
    var conn = &connections[idx];
    if (payload.len == 0 or seq != conn.rcv_nxt) return false;

    const available = RX_BUFFER_SIZE - conn.rx_len;
    const copy_len = if (payload.len < available) payload.len else available;
    for (payload[0..copy_len], 0..) |byte, i| {
        conn.rx_buf[conn.rx_len + i] = byte;
    }
    conn.rx_len += copy_len;
    conn.rcv_nxt +%= @intCast(copy_len);
    return copy_len > 0;
}

fn sendSegment(conn_idx: usize, flags: u8, seq: u32, ack: u32, payload: []const u8) ipv4.SendStatus {
    const conn = &connections[conn_idx];
    return sendSegmentTo(conn.remote_ip, conn.local_port, conn.remote_port, seq, ack, flags, payload);
}

fn sendReset(packet: ipv4.RxIpPacket, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload_len: usize) void {
    const ack_len = segmentSequenceLen(flags, payload_len);
    const reset_flags: u8 = if ((flags & FLAG_ACK) != 0) FLAG_RST else FLAG_RST | FLAG_ACK;
    const reset_seq: u32 = if ((flags & FLAG_ACK) != 0) ack else 0;
    const reset_ack: u32 = if ((flags & FLAG_ACK) != 0) 0 else seq +% ack_len;

    if (sendSegmentTo(packet.src_ip, dst_port, src_port, reset_seq, reset_ack, reset_flags, &.{}) == .sent) {
        stats.resets_sent += 1;
    }
}

fn sendSegmentTo(dst_ip: net.Ipv4Addr, src_port: u16, dst_port: u16, seq: u32, ack: u32, flags: u8, payload: []const u8) ipv4.SendStatus {
    const tcp_len = TCP_HEADER_MIN + payload.len;
    if (tcp_len > tx_segment.len) return rememberSend(.frame_too_large);

    @memset(tx_segment[0..tcp_len], 0);
    net.writeBe16(tx_segment[0..], OFF_SRC_PORT, src_port);
    net.writeBe16(tx_segment[0..], OFF_DST_PORT, dst_port);
    net.writeBe32(tx_segment[0..], OFF_SEQ_NUM, seq);
    net.writeBe32(tx_segment[0..], OFF_ACK_NUM, ack);
    tx_segment[OFF_DATA_OFFSET] = 5 << 4;
    tx_segment[OFF_FLAGS] = flags;
    net.writeBe16(tx_segment[0..], OFF_WINDOW, DEFAULT_WINDOW_SIZE);
    net.writeBe16(tx_segment[0..], OFF_CHECKSUM, 0);
    net.writeBe16(tx_segment[0..], OFF_URGENT, 0);
    for (payload, 0..) |byte, i| {
        tx_segment[TCP_HEADER_MIN + i] = byte;
    }

    net.writeBe16(
        tx_segment[0..],
        OFF_CHECKSUM,
        net.pseudoHeaderChecksum(net.getConfig().local_ip, dst_ip, net.IPPROTO_TCP, tx_segment[0..tcp_len]),
    );

    const status = ipv4.send(net.IPPROTO_TCP, dst_ip, tx_segment[0..tcp_len]);
    if (status == .sent) {
        stats.segments_sent += 1;
    } else {
        stats.send_errors += 1;
    }
    return rememberSend(status);
}

fn segmentSequenceLen(flags: u8, payload_len: usize) u32 {
    var len: u32 = @intCast(payload_len);
    if ((flags & FLAG_SYN) != 0) len +%= 1;
    if ((flags & FLAG_FIN) != 0) len +%= 1;
    return len;
}

fn findFreeSlot() ?usize {
    for (connections, 0..) |conn, i| {
        if (conn.state == .closed) return i;
    }
    return null;
}

fn findConnection(remote_ip: net.Ipv4Addr, remote_port: u16, local_port: u16) ?usize {
    for (connections, 0..) |conn, i| {
        if (conn.state == .closed) continue;
        if (conn.local_port == local_port and conn.remote_port == remote_port and net.ipEqual(conn.remote_ip, remote_ip)) return i;
    }
    return null;
}

fn getMutableConnection(conn_id: ConnId) ?*Connection {
    const idx = connIndex(conn_id) orelse return null;
    if (connections[idx].state == .closed) return null;
    return &connections[idx];
}

fn connIndex(conn_id: ConnId) ?usize {
    const idx: usize = conn_id;
    if (idx >= MAX_CONNECTIONS) return null;
    return idx;
}

fn allocateLocalPort() u16 {
    const port = next_local_port;
    next_local_port +%= 1;
    if (next_local_port < EPHEMERAL_PORT_START) next_local_port = EPHEMERAL_PORT_START;
    return port;
}

fn closeConnection(idx: usize) void {
    if (connections[idx].state != .closed) {
        stats.connections_closed += 1;
    }
    connections[idx] = emptyConnection();
}

fn rememberSend(status: ipv4.SendStatus) ipv4.SendStatus {
    stats.last_send_status = status;
    return status;
}

fn emptyConnection() Connection {
    return .{
        .state = .closed,
        .local_port = 0,
        .remote_port = 0,
        .remote_ip = net.ZERO_IP,
        .snd_una = 0,
        .snd_nxt = 0,
        .rcv_nxt = 0,
        .iss = 0,
        .rx_buf = [_]u8{0} ** RX_BUFFER_SIZE,
        .rx_len = 0,
        .tx_buf = [_]u8{0} ** TX_BUFFER_SIZE,
        .tx_len = 0,
        .retransmit_tick = 0,
        .retransmit_count = 0,
        .time_wait_tick = 0,
    };
}

fn emptyStats() Stats {
    return .{
        .segments_sent = 0,
        .segments_received = 0,
        .connections_opened = 0,
        .connections_closed = 0,
        .retransmits = 0,
        .resets_sent = 0,
        .bad_checksum = 0,
        .malformed = 0,
        .send_errors = 0,
        .last_send_status = .tx_not_ready,
    };
}
