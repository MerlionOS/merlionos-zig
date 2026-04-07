const arp = @import("arp.zig");
const e1000 = @import("e1000.zig");

const ETHERTYPE_IPV4: u16 = 0x0800;
const IPV4_HEADER_LEN: usize = 20;
const ICMP_HEADER_LEN: usize = 8;
const ICMP_PAYLOAD = "MerlionOS-Zig ICMP";
const ICMP_ECHO_FRAME_LEN: usize = 14 + IPV4_HEADER_LEN + ICMP_HEADER_LEN + ICMP_PAYLOAD.len;

const IPV4_VERSION_IHL: u8 = 0x45;
const IPV4_TTL: u8 = 64;
const IPV4_PROTOCOL_ICMP: u8 = 1;
const ICMP_TYPE_ECHO_REQUEST: u8 = 8;
const ICMP_CODE_ECHO: u8 = 0;

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

pub const Stats = struct {
    requests_sent: u64,
    last_status: SendStatus,
    last_source_ip: arp.Ipv4,
    last_target_ip: arp.Ipv4,
};

var stats: Stats = .{
    .requests_sent = 0,
    .last_status = .no_nic,
    .last_source_ip = arp.DEFAULT_LOCAL_IP,
    .last_target_ip = arp.DEFAULT_TARGET_IP,
};

var next_sequence: u16 = 1;

pub fn sendEchoRequest(target_ip: arp.Ipv4, source_ip: arp.Ipv4) SendStatus {
    const nic = e1000.detected() orelse return remember(.no_nic, source_ip, target_ip);
    if (!nic.mac_valid) return remember(.no_mac, source_ip, target_ip);

    const arp_info = arp.info();
    if (!ipEqual(arp_info.last_reply_ip, target_ip)) {
        return remember(.no_arp_entry, source_ip, target_ip);
    }

    var frame: [ICMP_ECHO_FRAME_LEN]u8 = undefined;
    buildEchoRequest(&frame, nic.mac, arp_info.last_reply_mac, source_ip, target_ip, next_sequence);

    const status = mapTxStatus(e1000.transmit(frame[0..]));
    if (status == .sent) {
        stats.requests_sent += 1;
        next_sequence +%= 1;
    }
    return remember(status, source_ip, target_ip);
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

    const ip_offset = 14;
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
    writeBe16(frame, icmp_offset + 4, 0x4d5a);
    writeBe16(frame, icmp_offset + 6, sequence);
    @memcpy(frame[icmp_offset + ICMP_HEADER_LEN ..], ICMP_PAYLOAD);
    writeBe16(frame, icmp_offset + 2, checksum(frame[icmp_offset..]));
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

fn ipEqual(a: arp.Ipv4, b: arp.Ipv4) bool {
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}
