const arp_cache = @import("arp_cache.zig");
const eth = @import("eth.zig");
const net = @import("net.zig");

const IPV4_VERSION_IHL: u8 = 0x45;
const IPV4_HEADER_LEN: usize = net.IPV4_HEADER_MIN;
const IPV4_FLAG_MF: u16 = 0x2000;
const IPV4_FRAG_OFFSET_MASK: u16 = 0x1fff;

const OFF_VERSION_IHL: usize = 0;
const OFF_TOS: usize = 1;
const OFF_TOTAL_LEN: usize = 2;
const OFF_IDENT: usize = 4;
const OFF_FLAGS_FRAG: usize = 6;
const OFF_TTL: usize = 8;
const OFF_PROTOCOL: usize = 9;
const OFF_CHECKSUM: usize = 10;
const OFF_SRC_IP: usize = 12;
const OFF_DST_IP: usize = 16;

const MAX_PROTOCOL_HANDLERS: usize = 8;
const LIMITED_BROADCAST_IP: net.Ipv4Addr = .{ 255, 255, 255, 255 };

pub const RxIpPacket = struct {
    src_ip: net.Ipv4Addr,
    dst_ip: net.Ipv4Addr,
    src_mac: net.MacAddr,
    dst_mac: net.MacAddr,
    protocol: u8,
    ttl: u8,
    payload: []const u8,
    header: []const u8,
};

pub const SendStatus = enum {
    sent,
    no_route,
    arp_pending,
    frame_too_large,
    no_mac,
    tx_not_ready,
    tx_descriptor_busy,
    tx_timeout,
    tx_error,
};

pub const ProtocolHandler = *const fn (packet: RxIpPacket) void;

pub const Stats = struct {
    packets_sent: u64,
    packets_received: u64,
    bad_checksum: u64,
    bad_version: u64,
    ttl_expired: u64,
    no_handler: u64,
    fragmented_dropped: u64,
    malformed: u64,
    not_for_us: u64,
    arp_pending: u64,
    no_route: u64,
    tx_errors: u64,
    last_protocol: u8,
    last_send_status: SendStatus,
};

const HandlerSlot = struct {
    protocol: u8,
    handler: ?ProtocolHandler,
};

var handlers: [MAX_PROTOCOL_HANDLERS]HandlerSlot = [_]HandlerSlot{emptyHandlerSlot()} ** MAX_PROTOCOL_HANDLERS;
var next_ident: u16 = 1;
var stats: Stats = emptyStats();
var tx_packet: [net.ETH_MTU]u8 = [_]u8{0} ** net.ETH_MTU;

pub fn init() void {
    handlers = [_]HandlerSlot{emptyHandlerSlot()} ** MAX_PROTOCOL_HANDLERS;
    next_ident = 1;
    stats = emptyStats();
    eth.registerIpv4Handler(handleRx);
}

pub fn registerHandler(protocol: u8, handler: ProtocolHandler) void {
    for (&handlers) |*slot| {
        if (slot.handler != null and slot.protocol == protocol) {
            slot.handler = handler;
            return;
        }
    }

    for (&handlers) |*slot| {
        if (slot.handler == null) {
            slot.protocol = protocol;
            slot.handler = handler;
            return;
        }
    }
}

pub fn handleRx(meta: net.RxPacketMeta) void {
    const data = meta.payload;
    if (data.len < IPV4_HEADER_LEN) {
        stats.malformed += 1;
        return;
    }

    const version_ihl = data[OFF_VERSION_IHL];
    if ((version_ihl >> 4) != net.IPV4_VERSION) {
        stats.bad_version += 1;
        return;
    }

    const ihl = @as(usize, version_ihl & 0x0f) * 4;
    if (ihl < IPV4_HEADER_LEN or ihl > data.len) {
        stats.malformed += 1;
        return;
    }

    const total_len = @as(usize, net.readBe16(data, OFF_TOTAL_LEN));
    if (total_len < ihl or total_len > data.len) {
        stats.malformed += 1;
        return;
    }

    if (net.internetChecksum(data[0..ihl]) != 0) {
        stats.bad_checksum += 1;
        return;
    }

    const flags_frag = net.readBe16(data, OFF_FLAGS_FRAG);
    if ((flags_frag & (IPV4_FLAG_MF | IPV4_FRAG_OFFSET_MASK)) != 0) {
        stats.fragmented_dropped += 1;
        return;
    }

    if (data[OFF_TTL] == 0) {
        stats.ttl_expired += 1;
        return;
    }

    var src_ip: net.Ipv4Addr = undefined;
    var dst_ip: net.Ipv4Addr = undefined;
    @memcpy(src_ip[0..], data[OFF_SRC_IP .. OFF_SRC_IP + 4]);
    @memcpy(dst_ip[0..], data[OFF_DST_IP .. OFF_DST_IP + 4]);

    if (!isForLocalHost(dst_ip)) {
        stats.not_for_us += 1;
        return;
    }

    const protocol = data[OFF_PROTOCOL];
    stats.last_protocol = protocol;
    const packet: RxIpPacket = .{
        .src_ip = src_ip,
        .dst_ip = dst_ip,
        .src_mac = meta.src_mac,
        .dst_mac = meta.dst_mac,
        .protocol = protocol,
        .ttl = data[OFF_TTL],
        .payload = data[ihl..total_len],
        .header = data[0..ihl],
    };

    if (findHandler(protocol)) |handler| {
        stats.packets_received += 1;
        handler(packet);
        return;
    }

    stats.no_handler += 1;
}

pub fn send(protocol: u8, dst_ip: net.Ipv4Addr, payload: []const u8) SendStatus {
    return sendFrom(protocol, net.getConfig().local_ip, dst_ip, payload);
}

pub fn sendFrom(protocol: u8, src_ip: net.Ipv4Addr, dst_ip: net.Ipv4Addr, payload: []const u8) SendStatus {
    if (payload.len > net.ETH_MTU - IPV4_HEADER_LEN) return rememberSend(.frame_too_large);

    const config = net.getConfig();
    if (!config.mac_valid) return rememberSend(.no_mac);

    var dst_mac: net.MacAddr = undefined;
    if (isBroadcastIp(dst_ip)) {
        dst_mac = net.BROADCAST_MAC;
    } else {
        const next_hop = routeNextHop(src_ip, dst_ip) orelse return rememberNoRoute();
        switch (arp_cache.lookup(next_hop, &dst_mac)) {
            .found => {},
            .pending, .not_found => {
                stats.arp_pending += 1;
                return rememberSend(.arp_pending);
            },
        }
    }

    const total_len = IPV4_HEADER_LEN + payload.len;
    @memset(tx_packet[0..total_len], 0);

    tx_packet[OFF_VERSION_IHL] = IPV4_VERSION_IHL;
    tx_packet[OFF_TOS] = 0;
    net.writeBe16(tx_packet[0..], OFF_TOTAL_LEN, @intCast(total_len));
    net.writeBe16(tx_packet[0..], OFF_IDENT, next_ident);
    next_ident +%= 1;
    net.writeBe16(tx_packet[0..], OFF_FLAGS_FRAG, 0);
    tx_packet[OFF_TTL] = net.IPV4_DEFAULT_TTL;
    tx_packet[OFF_PROTOCOL] = protocol;
    net.writeBe16(tx_packet[0..], OFF_CHECKSUM, 0);
    @memcpy(tx_packet[OFF_SRC_IP .. OFF_SRC_IP + 4], src_ip[0..]);
    @memcpy(tx_packet[OFF_DST_IP .. OFF_DST_IP + 4], dst_ip[0..]);
    for (payload, 0..) |byte, i| {
        tx_packet[IPV4_HEADER_LEN + i] = byte;
    }
    net.writeBe16(tx_packet[0..], OFF_CHECKSUM, net.internetChecksum(tx_packet[0..IPV4_HEADER_LEN]));

    const status = mapTxStatus(eth.send(dst_mac, net.ETHERTYPE_IPV4, tx_packet[0..total_len]));
    if (status == .sent) {
        stats.packets_sent += 1;
    } else {
        stats.tx_errors += 1;
    }
    return rememberSend(status);
}

pub fn getStats() Stats {
    return stats;
}

fn findHandler(protocol: u8) ?ProtocolHandler {
    for (handlers) |slot| {
        if (slot.handler != null and slot.protocol == protocol) return slot.handler.?;
    }
    return null;
}

fn routeNextHop(src_ip: net.Ipv4Addr, dst_ip: net.Ipv4Addr) ?net.Ipv4Addr {
    const config = net.getConfig();
    const next_hop = if (net.sameSubnet(src_ip, dst_ip, config.subnet_mask))
        dst_ip
    else
        config.gateway_ip;

    if (net.ipEqual(next_hop, net.ZERO_IP)) return null;
    return next_hop;
}

fn isForLocalHost(dst_ip: net.Ipv4Addr) bool {
    const config = net.getConfig();
    return net.ipEqual(dst_ip, config.local_ip) or isBroadcastIp(dst_ip);
}

fn isBroadcastIp(ip: net.Ipv4Addr) bool {
    if (net.ipEqual(ip, LIMITED_BROADCAST_IP)) return true;

    const config = net.getConfig();
    var subnet_broadcast: net.Ipv4Addr = undefined;
    for (&subnet_broadcast, config.local_ip, config.subnet_mask) |*byte, local, mask| {
        byte.* = local | ~mask;
    }
    return net.ipEqual(ip, subnet_broadcast);
}

fn rememberNoRoute() SendStatus {
    stats.no_route += 1;
    return rememberSend(.no_route);
}

fn rememberSend(status: SendStatus) SendStatus {
    stats.last_send_status = status;
    return status;
}

fn mapTxStatus(status: eth.TxStatus) SendStatus {
    return switch (status) {
        .sent => .sent,
        .no_mac => .no_mac,
        .tx_not_ready => .tx_not_ready,
        .tx_frame_too_large => .frame_too_large,
        .tx_descriptor_busy => .tx_descriptor_busy,
        .tx_timeout => .tx_timeout,
    };
}

fn emptyHandlerSlot() HandlerSlot {
    return .{
        .protocol = 0,
        .handler = null,
    };
}

fn emptyStats() Stats {
    return .{
        .packets_sent = 0,
        .packets_received = 0,
        .bad_checksum = 0,
        .bad_version = 0,
        .ttl_expired = 0,
        .no_handler = 0,
        .fragmented_dropped = 0,
        .malformed = 0,
        .not_for_us = 0,
        .arp_pending = 0,
        .no_route = 0,
        .tx_errors = 0,
        .last_protocol = 0,
        .last_send_status = .tx_not_ready,
    };
}
