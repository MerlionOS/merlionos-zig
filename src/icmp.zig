const arp = @import("arp.zig");
const arp_cache = @import("arp_cache.zig");
const e1000 = @import("e1000.zig");

const ETHERNET_HEADER_LEN: usize = 14;
const ETHERTYPE_IPV4: u16 = 0x0800;
const IPV4_HEADER_LEN: usize = 20;
const ICMP_HEADER_LEN: usize = 8;
const ICMP_PAYLOAD = "MerlionOS-Zig ICMP";
const ICMP_ECHO_FRAME_LEN: usize = 14 + IPV4_HEADER_LEN + ICMP_HEADER_LEN + ICMP_PAYLOAD.len;

const IPV4_VERSION_IHL: u8 = 0x45;
const IPV4_TTL: u8 = 64;
const IPV4_PROTOCOL_ICMP: u8 = 1;
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

pub fn sendEchoRequest(target_ip: arp.Ipv4, source_ip: arp.Ipv4) SendStatus {
    const nic = e1000.detected() orelse return remember(.no_nic, source_ip, target_ip);
    if (!nic.mac_valid) return remember(.no_mac, source_ip, target_ip);

    const target_mac = resolveTargetMac(target_ip) orelse {
        return remember(.no_arp_entry, source_ip, target_ip);
    };

    var frame: [ICMP_ECHO_FRAME_LEN]u8 = undefined;
    buildEchoRequest(&frame, nic.mac, target_mac, source_ip, target_ip, next_sequence);

    const status = mapTxStatus(e1000.transmit(frame[0..]));
    if (status == .sent) {
        stats.requests_sent += 1;
        stats.last_sequence_sent = next_sequence;
        next_sequence +%= 1;
    }
    return remember(status, source_ip, target_ip);
}

fn resolveTargetMac(target_ip: arp.Ipv4) ?[6]u8 {
    const arp_info = arp.info();
    if (ipEqual(arp_info.last_reply_ip, target_ip)) {
        return arp_info.last_reply_mac;
    }

    var mac: [6]u8 = undefined;
    if (arp_cache.resolve(target_ip, &mac)) {
        return mac;
    }
    return null;
}

pub fn pollEchoReply(local_ip: arp.Ipv4) PollStatus {
    const rx_status = e1000.pollReceive();
    const result = switch (rx_status) {
        .received => parseEchoReply(e1000.lastRxFrame(), local_ip),
        .no_packet => PollStatus.no_packet,
        .not_ready => PollStatus.rx_not_ready,
        .descriptor_error => PollStatus.rx_error,
        .truncated => PollStatus.rx_truncated,
    };
    stats.last_poll_status = result;
    return result;
}

pub fn info() *const Stats {
    return &stats;
}

fn buildEchoRequest(
    frame: *[ICMP_ECHO_FRAME_LEN]u8,
    source_mac: [6]u8,
    target_mac: [6]u8,
    source_ip: arp.Ipv4,
    target_ip: arp.Ipv4,
    sequence: u16,
) void {
    @memset(frame[0..], 0);

    @memcpy(frame[0..6], target_mac[0..]);
    @memcpy(frame[6..12], source_mac[0..]);
    writeBe16(frame, 12, ETHERTYPE_IPV4);

    const ip_offset = ETHERNET_HEADER_LEN;
    frame[ip_offset + 0] = IPV4_VERSION_IHL;
    frame[ip_offset + 1] = 0;
    writeBe16(frame, ip_offset + 2, ICMP_ECHO_FRAME_LEN - 14);
    writeBe16(frame, ip_offset + 4, sequence);
    writeBe16(frame, ip_offset + 6, 0);
    frame[ip_offset + 8] = IPV4_TTL;
    frame[ip_offset + 9] = IPV4_PROTOCOL_ICMP;
    @memcpy(frame[ip_offset + 12 .. ip_offset + 16], source_ip[0..]);
    @memcpy(frame[ip_offset + 16 .. ip_offset + 20], target_ip[0..]);
    writeBe16(frame, ip_offset + 10, checksum(frame[ip_offset .. ip_offset + IPV4_HEADER_LEN]));

    const icmp_offset = ip_offset + IPV4_HEADER_LEN;
    frame[icmp_offset + 0] = ICMP_TYPE_ECHO_REQUEST;
    frame[icmp_offset + 1] = ICMP_CODE_ECHO;
    writeBe16(frame, icmp_offset + 4, ICMP_IDENTIFIER);
    writeBe16(frame, icmp_offset + 6, sequence);
    @memcpy(frame[icmp_offset + ICMP_HEADER_LEN ..], ICMP_PAYLOAD);
    writeBe16(frame, icmp_offset + 2, checksum(frame[icmp_offset..]));
}

fn parseEchoReply(frame: []const u8, local_ip: arp.Ipv4) PollStatus {
    if (frame.len < ETHERNET_HEADER_LEN + IPV4_HEADER_LEN + ICMP_HEADER_LEN) return .ignored;
    if (readBe16(frame, 12) != ETHERTYPE_IPV4) return .ignored;

    const ip_offset = ETHERNET_HEADER_LEN;
    if ((frame[ip_offset] >> 4) != 4) return .ignored;

    const ihl = @as(usize, frame[ip_offset] & 0x0f) * 4;
    if (ihl < IPV4_HEADER_LEN) return .ignored;
    if (frame.len < ip_offset + ihl + ICMP_HEADER_LEN) return .ignored;

    const total_len = @as(usize, readBe16(frame, ip_offset + 2));
    if (total_len < ihl + ICMP_HEADER_LEN) return .ignored;
    if (frame.len < ip_offset + total_len) return .ignored;
    if (frame[ip_offset + 9] != IPV4_PROTOCOL_ICMP) return .ignored;
    if (!ipBytesEqual(frame[ip_offset + 16 .. ip_offset + 20], local_ip)) return .ignored;
    if (checksum(frame[ip_offset .. ip_offset + ihl]) != 0) return .bad_checksum;

    const icmp_offset = ip_offset + ihl;
    const icmp_len = total_len - ihl;
    const icmp_frame = frame[icmp_offset .. icmp_offset + icmp_len];
    if (checksum(icmp_frame) != 0) return .bad_checksum;
    if (icmp_frame[0] != ICMP_TYPE_ECHO_REPLY) return .ignored;
    if (icmp_frame[1] != ICMP_CODE_ECHO) return .ignored;
    if (readBe16(icmp_frame, 4) != ICMP_IDENTIFIER) return .ignored;

    @memcpy(stats.last_reply_mac[0..], frame[6..12]);
    @memcpy(stats.last_reply_ip[0..], frame[ip_offset + 12 .. ip_offset + 16]);
    stats.last_reply_sequence = readBe16(icmp_frame, 6);
    stats.replies_received += 1;
    return .echo_reply_received;
}

fn remember(status: SendStatus, source_ip: arp.Ipv4, target_ip: arp.Ipv4) SendStatus {
    stats.last_status = status;
    stats.last_source_ip = source_ip;
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

fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | @as(u32, bytes[i + 1]);
    }
    if (i < bytes.len) {
        sum += @as(u32, bytes[i]) << 8;
    }

    while ((sum >> 16) != 0) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    return @truncate(~sum);
}

fn writeBe16(buffer: []u8, offset: usize, value: anytype) void {
    const word: u16 = @intCast(value);
    buffer[offset] = @truncate(word >> 8);
    buffer[offset + 1] = @truncate(word);
}

fn readBe16(buffer: []const u8, offset: usize) u16 {
    return (@as(u16, buffer[offset]) << 8) | @as(u16, buffer[offset + 1]);
}

fn ipEqual(a: arp.Ipv4, b: arp.Ipv4) bool {
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}

fn ipBytesEqual(bytes: []const u8, ip: arp.Ipv4) bool {
    if (bytes.len != ip.len) return false;
    for (bytes, ip) |left, right| {
        if (left != right) return false;
    }
    return true;
}
