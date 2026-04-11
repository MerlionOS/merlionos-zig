const arp = @import("arp.zig");
const eth = @import("eth.zig");
const net = @import("net.zig");
const pit = @import("pit.zig");

const MAX_ENTRIES: usize = 16;
const ENTRY_TIMEOUT_TICKS: u64 = 6000;
const ARP_RETRY_TICKS: u64 = 100;
const MAX_RETRIES: u8 = 5;

const ARP_HTYPE_ETHERNET: u16 = 0x0001;
const ARP_PTYPE_IPV4: u16 = 0x0800;
const ARP_HLEN: u8 = 6;
const ARP_PLEN: u8 = 4;
const ARP_OPER_REQUEST: u16 = 1;
const ARP_OPER_REPLY: u16 = 2;
const ARP_PACKET_LEN: usize = 28;

pub const EntryState = enum {
    free,
    pending,
    resolved,
};

pub const Entry = struct {
    state: EntryState,
    ip: net.Ipv4Addr,
    mac: net.MacAddr,
    timestamp: u64,
    retries: u8,
};

pub const LookupResult = enum {
    found,
    pending,
    not_found,
};

pub const Stats = struct {
    requests_sent: u64,
    requests_received: u64,
    replies_sent: u64,
    replies_received: u64,
    lookups: u64,
    misses: u64,
    retries: u64,
    expired: u64,
};

var table: [MAX_ENTRIES]Entry = [_]Entry{emptyEntry()} ** MAX_ENTRIES;
var stats: Stats = emptyStats();

pub fn init() void {
    flush();
    eth.registerArpHandler(handleRx);
}

pub fn lookup(ip: net.Ipv4Addr, mac_out: *net.MacAddr) LookupResult {
    stats.lookups += 1;

    if (findIndex(ip)) |idx| {
        const entry = &table[idx];
        return switch (entry.state) {
            .resolved => blk: {
                mac_out.* = entry.mac;
                break :blk .found;
            },
            .pending => .pending,
            .free => .not_found,
        };
    }

    stats.misses += 1;
    if (sendRequest(ip) == .sent) {
        insertPending(ip, pit.getTicks(), 0);
    }
    return .not_found;
}

pub fn resolve(ip: net.Ipv4Addr, mac_out: *net.MacAddr) bool {
    for (table) |entry| {
        if (entry.state == .resolved and ipMatches(entry.ip, ip)) {
            mac_out.* = entry.mac;
            return true;
        }
    }
    return false;
}

pub fn handleRx(meta: net.RxPacketMeta) void {
    const payload = meta.payload;
    if (payload.len < ARP_PACKET_LEN) return;
    if (net.readBe16(payload, 0) != ARP_HTYPE_ETHERNET) return;
    if (net.readBe16(payload, 2) != ARP_PTYPE_IPV4) return;
    if (payload[4] != ARP_HLEN or payload[5] != ARP_PLEN) return;

    const operation = net.readBe16(payload, 6);
    var sender_mac: net.MacAddr = undefined;
    var sender_ip: net.Ipv4Addr = undefined;
    var target_ip: net.Ipv4Addr = undefined;
    @memcpy(sender_mac[0..], payload[8..14]);
    @memcpy(sender_ip[0..], payload[14..18]);
    @memcpy(target_ip[0..], payload[24..28]);

    switch (operation) {
        ARP_OPER_REPLY => {
            addStatic(sender_ip, sender_mac);
            arp.learnReply(sender_ip, sender_mac);
            stats.replies_received += 1;
        },
        ARP_OPER_REQUEST => {
            stats.requests_received += 1;
            addStatic(sender_ip, sender_mac);
            replyIfForUs(sender_mac, sender_ip, target_ip);
        },
        else => {},
    }
}

pub fn tick() void {
    const now = pit.getTicks();
    for (&table) |*entry| {
        switch (entry.state) {
            .free => {},
            .resolved => {
                if (now -% entry.timestamp > ENTRY_TIMEOUT_TICKS) {
                    entry.* = emptyEntry();
                    stats.expired += 1;
                }
            },
            .pending => {
                if (entry.retries >= MAX_RETRIES) {
                    entry.* = emptyEntry();
                    stats.expired += 1;
                } else if (now -% entry.timestamp >= ARP_RETRY_TICKS) {
                    if (sendRequest(entry.ip) == .sent) {
                        entry.timestamp = now;
                        entry.retries += 1;
                        stats.retries += 1;
                    }
                }
            },
        }
    }
}

pub fn getTable() []const Entry {
    return table[0..];
}

pub fn getStats() Stats {
    return stats;
}

pub fn addStatic(ip: net.Ipv4Addr, mac: net.MacAddr) void {
    const idx = findIndex(ip) orelse chooseSlot();
    table[idx] = .{
        .state = .resolved,
        .ip = ip,
        .mac = mac,
        .timestamp = pit.getTicks(),
        .retries = 0,
    };
    removeDuplicateEntries(ip, idx);
}

pub fn markPending(ip: net.Ipv4Addr) void {
    if (findIndex(ip)) |idx| {
        if (table[idx].state == .resolved) return;
        table[idx].state = .pending;
        table[idx].timestamp = pit.getTicks();
        return;
    }
    insertPending(ip, pit.getTicks(), 0);
}

pub fn flush() void {
    table = [_]Entry{emptyEntry()} ** MAX_ENTRIES;
    stats = emptyStats();
}

fn sendRequest(target_ip: net.Ipv4Addr) eth.TxStatus {
    const config = net.getConfig();
    if (!config.mac_valid) return .no_mac;

    var payload: [ARP_PACKET_LEN]u8 = undefined;
    buildPacket(
        &payload,
        ARP_OPER_REQUEST,
        config.local_mac,
        config.local_ip,
        net.ZERO_MAC,
        target_ip,
    );

    const status = eth.send(net.BROADCAST_MAC, net.ETHERTYPE_ARP, payload[0..]);
    if (status == .sent) {
        stats.requests_sent += 1;
    }
    return status;
}

fn replyIfForUs(target_mac: net.MacAddr, target_ip: net.Ipv4Addr, requested_ip: net.Ipv4Addr) void {
    const config = net.getConfig();
    if (!config.mac_valid) return;
    if (!net.ipEqual(requested_ip, config.local_ip)) return;

    var payload: [ARP_PACKET_LEN]u8 = undefined;
    buildPacket(
        &payload,
        ARP_OPER_REPLY,
        config.local_mac,
        config.local_ip,
        target_mac,
        target_ip,
    );

    if (eth.send(target_mac, net.ETHERTYPE_ARP, payload[0..]) == .sent) {
        stats.replies_sent += 1;
    }
}

fn buildPacket(
    payload: *[ARP_PACKET_LEN]u8,
    operation: u16,
    sender_mac: net.MacAddr,
    sender_ip: net.Ipv4Addr,
    target_mac: net.MacAddr,
    target_ip: net.Ipv4Addr,
) void {
    net.writeBe16(payload[0..], 0, ARP_HTYPE_ETHERNET);
    net.writeBe16(payload[0..], 2, ARP_PTYPE_IPV4);
    payload[4] = ARP_HLEN;
    payload[5] = ARP_PLEN;
    net.writeBe16(payload[0..], 6, operation);
    @memcpy(payload[8..14], sender_mac[0..]);
    @memcpy(payload[14..18], sender_ip[0..]);
    @memcpy(payload[18..24], target_mac[0..]);
    @memcpy(payload[24..28], target_ip[0..]);
}

fn insertPending(ip: net.Ipv4Addr, timestamp: u64, retries: u8) void {
    table[chooseSlot()] = .{
        .state = .pending,
        .ip = ip,
        .mac = net.ZERO_MAC,
        .timestamp = timestamp,
        .retries = retries,
    };
}

fn findIndex(ip: net.Ipv4Addr) ?usize {
    for (table, 0..) |entry, i| {
        if (entry.state != .free and ipMatches(entry.ip, ip)) return i;
    }
    return null;
}

fn removeDuplicateEntries(ip: net.Ipv4Addr, keep_index: usize) void {
    for (&table, 0..) |*entry, i| {
        if (i == keep_index) continue;
        if (entry.state != .free and ipMatches(entry.ip, ip)) {
            entry.* = emptyEntry();
        }
    }
}

fn ipMatches(a: net.Ipv4Addr, b: net.Ipv4Addr) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn chooseSlot() usize {
    var oldest_index: usize = 0;
    var oldest_tick: u64 = table[0].timestamp;
    for (table, 0..) |entry, i| {
        if (entry.state == .free) return i;
        if (entry.timestamp < oldest_tick) {
            oldest_tick = entry.timestamp;
            oldest_index = i;
        }
    }
    return oldest_index;
}

fn emptyEntry() Entry {
    return .{
        .state = .free,
        .ip = net.ZERO_IP,
        .mac = net.ZERO_MAC,
        .timestamp = 0,
        .retries = 0,
    };
}

fn emptyStats() Stats {
    return .{
        .requests_sent = 0,
        .requests_received = 0,
        .replies_sent = 0,
        .replies_received = 0,
        .lookups = 0,
        .misses = 0,
        .retries = 0,
        .expired = 0,
    };
}
