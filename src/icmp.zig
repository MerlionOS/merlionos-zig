const arp = @import("arp.zig");
const ipv4 = @import("ipv4.zig");
const net = @import("net.zig");

const ICMP_HEADER_LEN: usize = 8;
const ICMP_PAYLOAD = [_]u8{
    'M', 'e', 'r', 'l', 'i', 'o', 'n', 'O', 'S',
    '-', 'Z', 'i', 'g', ' ', 'I', 'C', 'M', 'P',
};
const ICMP_ECHO_PACKET_LEN: usize = ICMP_HEADER_LEN + ICMP_PAYLOAD.len;

const ICMP_TYPE_ECHO_REQUEST: u8 = 8;
const ICMP_TYPE_ECHO_REPLY: u8 = 0;
const ICMP_CODE_ECHO: u8 = 0;
const ICMP_IDENTIFIER: u16 = 0x4d5a;

pub const SendStatus = enum {
    sent,
    no_nic,
    no_mac,
    no_arp_entry,
    tx_not_ready,
    tx_frame_too_large,
    tx_descriptor_busy,
    tx_timeout,
};

pub const PollStatus = enum {
    echo_reply_received,
    no_packet,
    ignored,
    bad_checksum,
    rx_not_ready,
    rx_error,
    rx_truncated,
};

pub const Stats = struct {
    requests_sent: u64,
    replies_received: u64,
    last_status: SendStatus,
    last_poll_status: PollStatus,
    last_source_ip: arp.Ipv4,
    last_target_ip: arp.Ipv4,
    last_reply_ip: arp.Ipv4,
    last_reply_mac: [6]u8,
    last_sequence_sent: u16,
    last_reply_sequence: u16,
};

var stats: Stats = .{
    .requests_sent = 0,
    .replies_received = 0,
    .last_status = .no_nic,
    .last_poll_status = .rx_not_ready,
    .last_source_ip = arp.DEFAULT_LOCAL_IP,
    .last_target_ip = arp.DEFAULT_TARGET_IP,
    .last_reply_ip = .{ 0, 0, 0, 0 },
    .last_reply_mac = .{ 0, 0, 0, 0, 0, 0 },
    .last_sequence_sent = 0,
    .last_reply_sequence = 0,
};

var next_sequence: u16 = 1;
var pending_poll_status: ?PollStatus = null;
var echo_packet: [ICMP_ECHO_PACKET_LEN]u8 = [_]u8{0} ** ICMP_ECHO_PACKET_LEN;

pub fn init() void {
    stats = emptyStats();
    next_sequence = 1;
    pending_poll_status = null;
    ipv4.registerHandler(net.IPPROTO_ICMP, handleRx);
}

pub fn sendEchoRequest(target_ip: arp.Ipv4, source_ip: arp.Ipv4) SendStatus {
    buildEchoRequest(echo_packet[0..], next_sequence);

    const status = mapSendStatus(ipv4.sendFrom(net.IPPROTO_ICMP, source_ip, target_ip, echo_packet[0..]));
    if (status == .sent) {
        stats.requests_sent += 1;
        stats.last_sequence_sent = next_sequence;
        next_sequence +%= 1;
    }
    return remember(status, source_ip, target_ip);
}

pub fn pollEchoReply(local_ip: arp.Ipv4) PollStatus {
    _ = local_ip;

    if (pending_poll_status) |status| {
        pending_poll_status = null;
        return rememberPoll(status);
    }
    return rememberPoll(.no_packet);
}

pub fn info() *const Stats {
    return &stats;
}

fn buildEchoRequest(packet: []u8, sequence: u16) void {
    @memset(packet, 0);

    packet[0] = ICMP_TYPE_ECHO_REQUEST;
    packet[1] = ICMP_CODE_ECHO;
    writeBe16(packet, 4, ICMP_IDENTIFIER);
    writeBe16(packet, 6, sequence);
    for (ICMP_PAYLOAD, 0..) |byte, i| {
        packet[ICMP_HEADER_LEN + i] = byte;
    }
    writeBe16(packet, 2, net.internetChecksum(packet));
}

fn handleRx(packet: ipv4.RxIpPacket) void {
    const data = packet.payload;
    if (data.len < ICMP_HEADER_LEN) return;
    if (net.internetChecksum(data) != 0) return recordPoll(.bad_checksum);
    if (data[0] != ICMP_TYPE_ECHO_REPLY) return;
    if (data[1] != ICMP_CODE_ECHO) return;
    if (net.readBe16(data, 4) != ICMP_IDENTIFIER) return;

    stats.last_reply_mac = packet.src_mac;
    stats.last_reply_ip = packet.src_ip;
    stats.last_reply_sequence = net.readBe16(data, 6);
    stats.replies_received += 1;
    recordPoll(.echo_reply_received);
}

fn remember(status: SendStatus, source_ip: arp.Ipv4, target_ip: arp.Ipv4) SendStatus {
    stats.last_status = status;
    stats.last_source_ip = source_ip;
    stats.last_target_ip = target_ip;
    return status;
}

fn rememberPoll(status: PollStatus) PollStatus {
    stats.last_poll_status = status;
    return status;
}

fn recordPoll(status: PollStatus) void {
    stats.last_poll_status = status;
    pending_poll_status = status;
}

fn mapSendStatus(status: ipv4.SendStatus) SendStatus {
    return switch (status) {
        .sent => .sent,
        .no_mac => .no_mac,
        .no_route, .arp_pending => .no_arp_entry,
        .frame_too_large => .tx_frame_too_large,
        .tx_not_ready, .tx_error => .tx_not_ready,
        .tx_descriptor_busy => .tx_descriptor_busy,
        .tx_timeout => .tx_timeout,
    };
}

fn writeBe16(packet: []u8, offset: usize, value: u16) void {
    packet[offset] = @as(u8, @truncate(value >> 8));
    packet[offset + 1] = @as(u8, @truncate(value & 0x00ff));
}

fn emptyStats() Stats {
    return .{
        .requests_sent = 0,
        .replies_received = 0,
        .last_status = .no_nic,
        .last_poll_status = .rx_not_ready,
        .last_source_ip = arp.DEFAULT_LOCAL_IP,
        .last_target_ip = arp.DEFAULT_TARGET_IP,
        .last_reply_ip = .{ 0, 0, 0, 0 },
        .last_reply_mac = .{ 0, 0, 0, 0, 0, 0 },
        .last_sequence_sent = 0,
        .last_reply_sequence = 0,
    };
}
