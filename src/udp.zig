const ipv4 = @import("ipv4.zig");
const net = @import("net.zig");

const UDP_HEADER_LEN: usize = 8;
const MAX_BINDINGS: usize = 8;
const MAX_UDP_PACKET_LEN: usize = net.ETH_MTU - net.IPV4_HEADER_MIN;

const OFF_SRC_PORT: usize = 0;
const OFF_DST_PORT: usize = 2;
const OFF_LENGTH: usize = 4;
const OFF_CHECKSUM: usize = 6;

pub const RxDatagram = struct {
    src_ip: net.Ipv4Addr,
    dst_ip: net.Ipv4Addr,
    src_port: u16,
    dst_port: u16,
    data: []const u8,
};

pub const DatagramHandler = *const fn (dgram: RxDatagram) void;

pub const SendStatus = enum {
    sent,
    invalid_port,
    payload_too_large,
    no_route,
    arp_pending,
    no_mac,
    tx_not_ready,
    tx_descriptor_busy,
    tx_timeout,
    tx_error,
};

pub const Stats = struct {
    datagrams_sent: u64,
    datagrams_received: u64,
    bad_checksum: u64,
    malformed: u64,
    no_binding: u64,
    send_errors: u64,
    last_src_port: u16,
    last_dst_port: u16,
    last_send_status: SendStatus,
};

const Binding = struct {
    port: u16,
    handler: ?DatagramHandler,
};

var bindings: [MAX_BINDINGS]Binding = [_]Binding{emptyBinding()} ** MAX_BINDINGS;
var stats: Stats = emptyStats();
var tx_datagram: [MAX_UDP_PACKET_LEN]u8 = [_]u8{0} ** MAX_UDP_PACKET_LEN;

pub fn init() void {
    bindings = [_]Binding{emptyBinding()} ** MAX_BINDINGS;
    stats = emptyStats();
    ipv4.registerHandler(net.IPPROTO_UDP, handleRx);
}

pub fn bind(port: u16, handler: DatagramHandler) bool {
    if (port == 0) return false;

    for (&bindings) |*binding| {
        if (binding.handler != null and binding.port == port) {
            binding.handler = handler;
            return true;
        }
    }

    for (&bindings) |*binding| {
        if (binding.handler == null) {
            binding.port = port;
            binding.handler = handler;
            return true;
        }
    }

    return false;
}

pub fn unbind(port: u16) void {
    for (&bindings) |*binding| {
        if (binding.handler != null and binding.port == port) {
            binding.* = emptyBinding();
            return;
        }
    }
}

pub fn send(src_port: u16, dst_ip: net.Ipv4Addr, dst_port: u16, data: []const u8) SendStatus {
    const udp_len = UDP_HEADER_LEN + data.len;
    stats.last_src_port = src_port;
    stats.last_dst_port = dst_port;

    if (src_port == 0 or dst_port == 0) {
        stats.send_errors += 1;
        return rememberSend(.invalid_port);
    }
    if (udp_len > tx_datagram.len) {
        stats.send_errors += 1;
        return rememberSend(.payload_too_large);
    }

    @memset(tx_datagram[0..udp_len], 0);
    net.writeBe16(tx_datagram[0..], OFF_SRC_PORT, src_port);
    net.writeBe16(tx_datagram[0..], OFF_DST_PORT, dst_port);
    net.writeBe16(tx_datagram[0..], OFF_LENGTH, @intCast(udp_len));
    net.writeBe16(tx_datagram[0..], OFF_CHECKSUM, 0);
    for (data, 0..) |byte, i| {
        tx_datagram[UDP_HEADER_LEN + i] = byte;
    }

    var checksum = net.pseudoHeaderChecksum(net.getConfig().local_ip, dst_ip, net.IPPROTO_UDP, tx_datagram[0..udp_len]);
    if (checksum == 0) checksum = 0xffff;
    net.writeBe16(tx_datagram[0..], OFF_CHECKSUM, checksum);

    const status = mapSendStatus(ipv4.send(net.IPPROTO_UDP, dst_ip, tx_datagram[0..udp_len]));
    if (status == .sent) {
        stats.datagrams_sent += 1;
    } else {
        stats.send_errors += 1;
    }
    return rememberSend(status);
}

pub fn getStats() Stats {
    return stats;
}

fn handleRx(packet: ipv4.RxIpPacket) void {
    const data = packet.payload;
    if (data.len < UDP_HEADER_LEN) {
        stats.malformed += 1;
        return;
    }

    const src_port = net.readBe16(data, OFF_SRC_PORT);
    const dst_port = net.readBe16(data, OFF_DST_PORT);
    const udp_len = @as(usize, net.readBe16(data, OFF_LENGTH));
    if (udp_len < UDP_HEADER_LEN or udp_len > data.len) {
        stats.malformed += 1;
        return;
    }

    const checksum = net.readBe16(data, OFF_CHECKSUM);
    if (checksum != 0 and net.pseudoHeaderChecksum(packet.src_ip, packet.dst_ip, net.IPPROTO_UDP, data[0..udp_len]) != 0) {
        stats.bad_checksum += 1;
        return;
    }

    stats.last_src_port = src_port;
    stats.last_dst_port = dst_port;

    if (findBinding(dst_port)) |handler| {
        const datagram: RxDatagram = .{
            .src_ip = packet.src_ip,
            .dst_ip = packet.dst_ip,
            .src_port = src_port,
            .dst_port = dst_port,
            .data = data[UDP_HEADER_LEN..udp_len],
        };
        stats.datagrams_received += 1;
        handler(datagram);
        return;
    }

    stats.no_binding += 1;
}

fn findBinding(port: u16) ?DatagramHandler {
    for (bindings) |binding| {
        if (binding.handler != null and binding.port == port) return binding.handler.?;
    }
    return null;
}

fn mapSendStatus(status: ipv4.SendStatus) SendStatus {
    return switch (status) {
        .sent => .sent,
        .frame_too_large => .payload_too_large,
        .no_route => .no_route,
        .arp_pending => .arp_pending,
        .no_mac => .no_mac,
        .tx_not_ready => .tx_not_ready,
        .tx_descriptor_busy => .tx_descriptor_busy,
        .tx_timeout => .tx_timeout,
        .tx_error => .tx_error,
    };
}

fn rememberSend(status: SendStatus) SendStatus {
    stats.last_send_status = status;
    return status;
}

fn emptyBinding() Binding {
    return .{
        .port = 0,
        .handler = null,
    };
}

fn emptyStats() Stats {
    return .{
        .datagrams_sent = 0,
        .datagrams_received = 0,
        .bad_checksum = 0,
        .malformed = 0,
        .no_binding = 0,
        .send_errors = 0,
        .last_src_port = 0,
        .last_dst_port = 0,
        .last_send_status = .tx_not_ready,
    };
}
