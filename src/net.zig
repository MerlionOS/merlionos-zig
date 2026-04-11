const std = @import("std");
const e1000 = @import("e1000.zig");

pub const ETH_HEADER_LEN: usize = 14;
pub const ETH_ADDR_LEN: usize = 6;
pub const ETH_MTU: usize = 1500;
pub const ETH_FRAME_MAX: usize = ETH_HEADER_LEN + ETH_MTU;

pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;

pub const IPV4_HEADER_MIN: usize = 20;
pub const IPV4_VERSION: u8 = 4;
pub const IPV4_DEFAULT_TTL: u8 = 64;

pub const IPPROTO_ICMP: u8 = 1;
pub const IPPROTO_TCP: u8 = 6;
pub const IPPROTO_UDP: u8 = 17;

pub const Ipv4Addr = [4]u8;
pub const MacAddr = [6]u8;

pub const BROADCAST_MAC: MacAddr = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
pub const ZERO_MAC: MacAddr = .{ 0, 0, 0, 0, 0, 0 };
pub const ZERO_IP: Ipv4Addr = .{ 0, 0, 0, 0 };

pub const DEFAULT_LOCAL_IP: Ipv4Addr = .{ 10, 0, 2, 15 };
pub const DEFAULT_GATEWAY_IP: Ipv4Addr = .{ 10, 0, 2, 2 };
pub const DEFAULT_SUBNET_MASK: Ipv4Addr = .{ 255, 255, 255, 0 };
pub const DEFAULT_DNS_SERVER: Ipv4Addr = .{ 10, 0, 2, 3 };

pub const NetConfig = struct {
    local_ip: Ipv4Addr,
    gateway_ip: Ipv4Addr,
    subnet_mask: Ipv4Addr,
    dns_server: Ipv4Addr,
    local_mac: MacAddr,
    mac_valid: bool,
};

pub const RxPacketMeta = struct {
    frame: []const u8,
    payload: []const u8,
    src_mac: MacAddr,
    dst_mac: MacAddr,
    ethertype: u16,
};

var config: NetConfig = defaultConfig();

pub fn init() void {
    config = defaultConfig();

    const nic = e1000.detected() orelse return;
    if (!nic.mac_valid) return;

    config.local_mac = nic.mac;
    config.mac_valid = true;
}

pub fn getConfig() *const NetConfig {
    return &config;
}

pub fn setLocalIp(ip: Ipv4Addr) void {
    config.local_ip = ip;
}

pub fn setGatewayIp(ip: Ipv4Addr) void {
    config.gateway_ip = ip;
}

pub fn setDnsServer(ip: Ipv4Addr) void {
    config.dns_server = ip;
}

pub fn readBe16(buf: []const u8, offset: usize) u16 {
    return (@as(u16, buf[offset]) << 8) | @as(u16, buf[offset + 1]);
}

pub fn readBe32(buf: []const u8, offset: usize) u32 {
    return (@as(u32, buf[offset]) << 24) |
        (@as(u32, buf[offset + 1]) << 16) |
        (@as(u32, buf[offset + 2]) << 8) |
        @as(u32, buf[offset + 3]);
}

pub fn writeBe16(buf: []u8, offset: usize, value: u16) void {
    buf[offset] = @truncate(value >> 8);
    buf[offset + 1] = @truncate(value);
}

pub fn writeBe32(buf: []u8, offset: usize, value: u32) void {
    buf[offset] = @truncate(value >> 24);
    buf[offset + 1] = @truncate(value >> 16);
    buf[offset + 2] = @truncate(value >> 8);
    buf[offset + 3] = @truncate(value);
}

pub fn internetChecksum(data: []const u8) u16 {
    return finishChecksum(sumBytes(data));
}

pub fn pseudoHeaderChecksum(src_ip: Ipv4Addr, dst_ip: Ipv4Addr, protocol: u8, data: []const u8) u16 {
    var sum: u32 = 0;
    sum += readBe16(src_ip[0..], 0);
    sum += readBe16(src_ip[0..], 2);
    sum += readBe16(dst_ip[0..], 0);
    sum += readBe16(dst_ip[0..], 2);
    sum += protocol;
    sum += @as(u16, @truncate(data.len));
    sum += sumBytes(data);
    return finishChecksum(sum);
}

pub fn ipEqual(a: Ipv4Addr, b: Ipv4Addr) bool {
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}

pub fn macEqual(a: MacAddr, b: MacAddr) bool {
    for (a, b) |left, right| {
        if (left != right) return false;
    }
    return true;
}

pub fn sameSubnet(a: Ipv4Addr, b: Ipv4Addr, mask: Ipv4Addr) bool {
    for (a, b, mask) |left, right, mask_byte| {
        if ((left & mask_byte) != (right & mask_byte)) return false;
    }
    return true;
}

pub fn formatIp(ip: Ipv4Addr, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        ip[0],
        ip[1],
        ip[2],
        ip[3],
    }) catch buf[0..0];
}

pub fn formatMac(mac: MacAddr, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        mac[0],
        mac[1],
        mac[2],
        mac[3],
        mac[4],
        mac[5],
    }) catch buf[0..0];
}

fn defaultConfig() NetConfig {
    return .{
        .local_ip = DEFAULT_LOCAL_IP,
        .gateway_ip = DEFAULT_GATEWAY_IP,
        .subnet_mask = DEFAULT_SUBNET_MASK,
        .dns_server = DEFAULT_DNS_SERVER,
        .local_mac = ZERO_MAC,
        .mac_valid = false,
    };
}

fn sumBytes(data: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | @as(u32, data[i + 1]);
    }
    if (i < data.len) {
        sum += @as(u32, data[i]) << 8;
    }
    return sum;
}

fn finishChecksum(initial_sum: u32) u16 {
    var sum = initial_sum;
    while ((sum >> 16) != 0) {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    return @truncate(~sum);
}
