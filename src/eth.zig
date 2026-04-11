const e1000 = @import("e1000.zig");
const net = @import("net.zig");

const MIN_ETH_FRAME_SIZE: usize = 60;

pub const TxStatus = enum {
    sent,
    no_mac,
    tx_not_ready,
    tx_frame_too_large,
    tx_descriptor_busy,
    tx_timeout,
};

pub const PollResult = enum {
    handled_arp,
    handled_ipv4,
    unhandled_arp,
    unhandled_ipv4,
    ignored,
    no_packet,
    rx_not_ready,
    rx_error,
    rx_truncated,
};

pub const Stats = struct {
    frames_received: u64,
    frames_sent: u64,
    arp_received: u64,
    ipv4_received: u64,
    unknown_received: u64,
    errors: u64,
    last_poll_result: PollResult,
    last_tx_status: TxStatus,
    last_ethertype: u16,
};

pub const Handler = *const fn (net.RxPacketMeta) void;

var stats: Stats = emptyStats();
var arp_handler: ?Handler = null;
var ipv4_handler: ?Handler = null;

pub fn init() void {
    stats = emptyStats();
    arp_handler = null;
    ipv4_handler = null;
}

pub fn registerArpHandler(handler: Handler) void {
    arp_handler = handler;
}

pub fn registerIpv4Handler(handler: Handler) void {
    ipv4_handler = handler;
}

pub fn poll() PollResult {
    const rx_status = e1000.pollReceive();
    const result = switch (rx_status) {
        .received => dispatchFrame(e1000.lastRxFrame()),
        .no_packet => PollResult.no_packet,
        .not_ready => PollResult.rx_not_ready,
        .descriptor_error => blk: {
            stats.errors += 1;
            break :blk PollResult.rx_error;
        },
        .truncated => blk: {
            stats.errors += 1;
            break :blk PollResult.rx_truncated;
        },
    };
    stats.last_poll_result = result;
    return result;
}

pub fn pollAll(max_iterations: usize) usize {
    var processed: usize = 0;
    var i: usize = 0;
    while (i < max_iterations) : (i += 1) {
        switch (poll()) {
            .handled_arp, .handled_ipv4, .unhandled_arp, .unhandled_ipv4, .ignored => processed += 1,
            .no_packet, .rx_not_ready, .rx_error, .rx_truncated => return processed,
        }
    }
    return processed;
}

pub fn send(dst_mac: net.MacAddr, ethertype: u16, payload: []const u8) TxStatus {
    const config = net.getConfig();
    if (!config.mac_valid) return rememberTx(.no_mac);
    if (payload.len > net.ETH_MTU) return rememberTx(.tx_frame_too_large);

    var frame: [net.ETH_FRAME_MAX]u8 = undefined;
    const payload_end = net.ETH_HEADER_LEN + payload.len;
    const frame_len = if (payload_end < MIN_ETH_FRAME_SIZE) MIN_ETH_FRAME_SIZE else payload_end;

    @memset(frame[0..frame_len], 0);
    @memcpy(frame[0..net.ETH_ADDR_LEN], dst_mac[0..]);
    @memcpy(frame[net.ETH_ADDR_LEN .. net.ETH_ADDR_LEN * 2], config.local_mac[0..]);
    net.writeBe16(frame[0..], 12, ethertype);
    @memcpy(frame[net.ETH_HEADER_LEN..payload_end], payload);

    const status = mapTxStatus(e1000.transmit(frame[0..frame_len]));
    if (status == .sent) {
        stats.frames_sent += 1;
    }
    return rememberTx(status);
}

pub fn getStats() Stats {
    return stats;
}

fn dispatchFrame(frame: []const u8) PollResult {
    if (frame.len < net.ETH_HEADER_LEN) {
        stats.errors += 1;
        return .ignored;
    }

    var src_mac: net.MacAddr = undefined;
    var dst_mac: net.MacAddr = undefined;
    @memcpy(dst_mac[0..], frame[0..6]);
    @memcpy(src_mac[0..], frame[6..12]);

    const ethertype = net.readBe16(frame, 12);
    stats.frames_received += 1;
    stats.last_ethertype = ethertype;

    const meta: net.RxPacketMeta = .{
        .frame = frame,
        .payload = frame[net.ETH_HEADER_LEN..],
        .src_mac = src_mac,
        .dst_mac = dst_mac,
        .ethertype = ethertype,
    };

    return switch (ethertype) {
        net.ETHERTYPE_ARP => handleArp(meta),
        net.ETHERTYPE_IPV4 => handleIpv4(meta),
        else => blk: {
            stats.unknown_received += 1;
            break :blk .ignored;
        },
    };
}

fn handleArp(meta: net.RxPacketMeta) PollResult {
    stats.arp_received += 1;
    if (arp_handler) |handler| {
        handler(meta);
        return .handled_arp;
    }
    return .unhandled_arp;
}

fn handleIpv4(meta: net.RxPacketMeta) PollResult {
    stats.ipv4_received += 1;
    if (ipv4_handler) |handler| {
        handler(meta);
        return .handled_ipv4;
    }
    return .unhandled_ipv4;
}

fn rememberTx(status: TxStatus) TxStatus {
    stats.last_tx_status = status;
    return status;
}

fn mapTxStatus(status: e1000.TxStatus) TxStatus {
    return switch (status) {
        .sent => .sent,
        .not_ready => .tx_not_ready,
        .frame_too_large => .tx_frame_too_large,
        .descriptor_busy => .tx_descriptor_busy,
        .timeout => .tx_timeout,
    };
}

fn emptyStats() Stats {
    return .{
        .frames_received = 0,
        .frames_sent = 0,
        .arp_received = 0,
        .ipv4_received = 0,
        .unknown_received = 0,
        .errors = 0,
        .last_poll_result = .rx_not_ready,
        .last_tx_status = .tx_not_ready,
        .last_ethertype = 0,
    };
}
