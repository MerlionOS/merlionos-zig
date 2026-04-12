const dns = @import("dns.zig");
const net = @import("net.zig");
const tcp = @import("tcp.zig");
const udp = @import("udp.zig");

pub const Endpoint = struct {
    ip: net.Ipv4Addr,
    port: u16,
};

pub const TcpConnId = tcp.ConnId;
pub const TcpConnection = tcp.Connection;
pub const TcpConnectResult = tcp.ConnectResult;
pub const TcpRecvResult = tcp.RecvResult;
pub const TcpSendResult = tcp.SendResult;
pub const TcpState = tcp.State;
pub const TcpStats = tcp.Stats;
pub const UdpSendStatus = udp.SendStatus;
pub const UdpStats = udp.Stats;
pub const DnsResolveStatus = dns.ResolveStatus;
pub const DnsStats = dns.Stats;

pub const MAX_TCP_CONNECTIONS = tcp.MAX_CONNECTIONS;

pub fn init() void {
    udp.init();
    tcp.init();
    dns.init();
}

pub fn tick() void {
    tcp.tick();
    dns.tick();
}

pub fn udpSend(local_port: u16, remote: Endpoint, data: []const u8) UdpSendStatus {
    return udp.send(local_port, remote.ip, remote.port, data);
}

pub fn tcpConnect(remote: Endpoint, conn_out: *TcpConnId) TcpConnectResult {
    return tcp.connect(remote.ip, remote.port, conn_out);
}

pub fn tcpSend(conn_id: TcpConnId, data: []const u8) TcpSendResult {
    return tcp.send(conn_id, data);
}

pub fn tcpRecv(conn_id: TcpConnId) TcpRecvResult {
    return tcp.recv(conn_id);
}

pub fn tcpClose(conn_id: TcpConnId) void {
    tcp.close(conn_id);
}

pub fn tcpGetConnection(conn_id: TcpConnId) ?*const TcpConnection {
    return tcp.getConnection(conn_id);
}

pub fn resolveA(name: []const u8, ip_out: *net.Ipv4Addr) DnsResolveStatus {
    return dns.resolve(name, ip_out);
}

pub fn flushDnsCache() void {
    dns.flushCache();
}

pub fn getUdpStats() UdpStats {
    return udp.getStats();
}

pub fn getTcpStats() TcpStats {
    return tcp.getStats();
}

pub fn getDnsStats() DnsStats {
    return dns.getStats();
}
