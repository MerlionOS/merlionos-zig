const e1000 = @import("e1000.zig");

pub const Ipv4 = [4]u8;

pub const DEFAULT_LOCAL_IP: Ipv4 = .{ 10, 0, 2, 15 };
pub const DEFAULT_TARGET_IP: Ipv4 = .{ 10, 0, 2, 2 };

const BROADCAST_MAC = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
const ZERO_MAC = [_]u8{ 0, 0, 0, 0, 0, 0 };

const ETHERTYPE_ARP: u16 = 0x0806;
const ARP_HTYPE_ETHERNET: u16 = 0x0001;
const ARP_PTYPE_IPV4: u16 = 0x0800;
const ARP_HLEN_ETHERNET: u8 = 6;
const ARP_PLEN_IPV4: u8 = 4;
const ARP_OPER_REQUEST: u16 = 0x0001;
const ARP_OPER_REPLY: u16 = 0x0002;

const ARP_REQUEST_LEN: usize = 42;
const ETHERNET_HEADER_LEN: usize = 14;
const ARP_PACKET_LEN: usize = 28;

pub const SendStatus = enum {
    sent,
    no_nic,
    no_mac,
    tx_not_ready,
    tx_frame_too_large,
    tx_descriptor_busy,
    tx_timeout,
};

pub const PollStatus = enum {
    reply_received,
    no_packet,
    ignored,
    rx_not_ready,
    rx_error,
    rx_truncated,
};

pub const Stats = struct {
    requests_sent: u64,
    replies_received: u64,
    last_status: SendStatus,
    last_poll_status: PollStatus,
    last_sender_ip: Ipv4,
    last_target_ip: Ipv4,
    last_reply_ip: Ipv4,
    last_reply_mac: [6]u8,
};

var stats: Stats = .{
    .requests_sent = 0,
    .replies_received = 0,
    .last_status = .no_nic,
    .last_poll_status = .rx_not_ready,
    .last_sender_ip = DEFAULT_LOCAL_IP,
    .last_target_ip = DEFAULT_TARGET_IP,
    .last_reply_ip = .{ 0, 0, 0, 0 },
    .last_reply_mac = .{ 0, 0, 0, 0, 0, 0 },
};

pub fn sendRequest(target_ip: Ipv4, sender_ip: Ipv4) SendStatus {
    const nic = e1000.detected() orelse return remember(.no_nic, sender_ip, target_ip);
    if (!nic.mac_valid) return remember(.no_mac, sender_ip, target_ip);

    var frame: [ARP_REQUEST_LEN]u8 = undefined;
    buildRequest(&frame, nic.mac, sender_ip, target_ip);

    const status = mapTxStatus(e1000.transmit(frame[0..]));
    if (status == .sent) {
        stats.requests_sent += 1;
    }
    return remember(status, sender_ip, target_ip);
}

pub fn info() *const Stats {
    return &stats;
}

pub fn pollReply() PollStatus {
    const rx_status = e1000.pollReceive();
    const result = switch (rx_status) {
        .received => parseReply(e1000.lastRxFrame()),
        .no_packet => PollStatus.no_packet,
        .not_ready => PollStatus.rx_not_ready,
        .descriptor_error => PollStatus.rx_error,
        .truncated => PollStatus.rx_truncated,
    };
    stats.last_poll_status = result;
    return result;
}

fn buildRequest(frame: *[ARP_REQUEST_LEN]u8, sender_mac: [6]u8, sender_ip: Ipv4, target_ip: Ipv4) void {
    @memcpy(frame[0..6], BROADCAST_MAC[0..]);
    @memcpy(frame[6..12], sender_mac[0..]);
    writeBe16(frame, 12, ETHERTYPE_ARP);

    writeBe16(frame, 14, ARP_HTYPE_ETHERNET);
    writeBe16(frame, 16, ARP_PTYPE_IPV4);
    frame[18] = ARP_HLEN_ETHERNET;
    frame[19] = ARP_PLEN_IPV4;
    writeBe16(frame, 20, ARP_OPER_REQUEST);
    @memcpy(frame[22..28], sender_mac[0..]);
    @memcpy(frame[28..32], sender_ip[0..]);
    @memcpy(frame[32..38], ZERO_MAC[0..]);
    @memcpy(frame[38..42], target_ip[0..]);
}

fn parseReply(frame: []const u8) PollStatus {
    if (frame.len < ETHERNET_HEADER_LEN + ARP_PACKET_LEN) return .ignored;
    if (readBe16(frame, 12) != ETHERTYPE_ARP) return .ignored;

    const arp_offset = ETHERNET_HEADER_LEN;
    if (readBe16(frame, arp_offset + 0) != ARP_HTYPE_ETHERNET) return .ignored;
    if (readBe16(frame, arp_offset + 2) != ARP_PTYPE_IPV4) return .ignored;
    if (frame[arp_offset + 4] != ARP_HLEN_ETHERNET) return .ignored;
    if (frame[arp_offset + 5] != ARP_PLEN_IPV4) return .ignored;
    if (readBe16(frame, arp_offset + 6) != ARP_OPER_REPLY) return .ignored;

    @memcpy(stats.last_reply_mac[0..], frame[arp_offset + 8 .. arp_offset + 14]);
    @memcpy(stats.last_reply_ip[0..], frame[arp_offset + 14 .. arp_offset + 18]);
    stats.replies_received += 1;
    return .reply_received;
}

fn remember(status: SendStatus, sender_ip: Ipv4, target_ip: Ipv4) SendStatus {
    stats.last_status = status;
    stats.last_sender_ip = sender_ip;
    stats.last_target_ip = target_ip;
    return status;
}

fn mapTxStatus(status: e1000.TxStatus) SendStatus {
    return switch (status) {
        .sent => .sent,
        .not_ready => .tx_not_ready,
        .frame_too_large => .tx_frame_too_large,
        .descriptor_busy => .tx_descriptor_busy,
        .timeout => .tx_timeout,
    };
}

fn writeBe16(buffer: []u8, offset: usize, value: u16) void {
    buffer[offset] = @truncate(value >> 8);
    buffer[offset + 1] = @truncate(value);
}

fn readBe16(buffer: []const u8, offset: usize) u16 {
    return (@as(u16, buffer[offset]) << 8) | @as(u16, buffer[offset + 1]);
}
