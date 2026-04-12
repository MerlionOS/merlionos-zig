const net = @import("net.zig");
const pit = @import("pit.zig");
const udp = @import("udp.zig");

const DNS_PORT: u16 = 53;
const DNS_LOCAL_PORT: u16 = 10053;
const DNS_HEADER_LEN: usize = 12;
const DNS_MAX_PACKET_LEN: usize = 512;
const DNS_QUERY_TIMEOUT_TICKS: u64 = 300;
const MAX_CACHED_ENTRIES: usize = 8;
const MAX_NAME_LEN: usize = 63;

const OFF_ID: usize = 0;
const OFF_FLAGS: usize = 2;
const OFF_QDCOUNT: usize = 4;
const OFF_ANCOUNT: usize = 6;
const OFF_NSCOUNT: usize = 8;
const OFF_ARCOUNT: usize = 10;

const DNS_FLAG_QR: u16 = 0x8000;
const DNS_FLAG_RD: u16 = 0x0100;
const DNS_RCODE_MASK: u16 = 0x000f;
const DNS_RCODE_NXDOMAIN: u16 = 3;
const DNS_TYPE_A: u16 = 1;
const DNS_CLASS_IN: u16 = 1;

pub const ResolveStatus = enum {
    resolved,
    pending,
    not_found,
    timeout,
    server_error,
    name_too_long,
    invalid_name,
    no_dns_server,
    send_error,
};

pub const CacheEntry = struct {
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    ip: net.Ipv4Addr,
    timestamp: u64,
    valid: bool,
};

pub const Stats = struct {
    queries_sent: u64,
    responses_received: u64,
    cache_hits: u64,
    cache_misses: u64,
    timeouts: u64,
    malformed: u64,
    send_errors: u64,
    last_send_status: udp.SendStatus,
};

const PendingQuery = struct {
    active: bool,
    sent: bool,
    query_id: u16,
    name: [MAX_NAME_LEN]u8,
    name_len: u8,
    start_tick: u64,
    result_ip: net.Ipv4Addr,
    status: ResolveStatus,
};

var cache: [MAX_CACHED_ENTRIES]CacheEntry = [_]CacheEntry{emptyCacheEntry()} ** MAX_CACHED_ENTRIES;
var next_query_id: u16 = 1;
var pending_query: PendingQuery = emptyPendingQuery();
var stats: Stats = emptyStats();

pub fn init() void {
    flushCache();
    next_query_id = 1;
    pending_query = emptyPendingQuery();
    stats = emptyStats();
    _ = udp.bind(DNS_LOCAL_PORT, handleDnsResponse);
}

pub fn resolve(name: []const u8, ip_out: *net.Ipv4Addr) ResolveStatus {
    const normalized = trimTrailingDot(name);
    if (normalized.len == 0) return .invalid_name;
    if (normalized.len > MAX_NAME_LEN) return .name_too_long;

    if (pending_query.active) {
        if (nameMatches(pending_query.name[0..@as(usize, pending_query.name_len)], normalized)) {
            if (pending_query.status != .pending) {
                const status = pending_query.status;
                if (status == .resolved) ip_out.* = pending_query.result_ip;
                pending_query = emptyPendingQuery();
                return status;
            }

            if (!pending_query.sent) {
                return sendPendingQuery();
            }
            return .pending;
        }

        pending_query = emptyPendingQuery();
    }

    if (findCache(normalized)) |entry| {
        ip_out.* = entry.ip;
        stats.cache_hits += 1;
        return .resolved;
    }

    stats.cache_misses += 1;
    return startQuery(normalized);
}

pub fn tick() void {
    if (!pending_query.active or pending_query.status != .pending) return;

    const now = pit.getTicks();
    if (now -% pending_query.start_tick >= DNS_QUERY_TIMEOUT_TICKS) {
        pending_query.status = .timeout;
        stats.timeouts += 1;
        return;
    }

    if (!pending_query.sent) {
        _ = sendPendingQuery();
    }
}

pub fn getCache() []const CacheEntry {
    return cache[0..];
}

pub fn flushCache() void {
    cache = [_]CacheEntry{emptyCacheEntry()} ** MAX_CACHED_ENTRIES;
}

pub fn getStats() Stats {
    return stats;
}

fn startQuery(name: []const u8) ResolveStatus {
    const config = net.getConfig();
    if (net.ipEqual(config.dns_server, net.ZERO_IP)) return .no_dns_server;

    pending_query = emptyPendingQuery();
    pending_query.active = true;
    pending_query.sent = false;
    pending_query.query_id = allocateQueryId();
    pending_query.name_len = @intCast(name.len);
    @memcpy(pending_query.name[0..name.len], name);
    pending_query.start_tick = pit.getTicks();
    pending_query.status = .pending;

    return sendPendingQuery();
}

fn sendPendingQuery() ResolveStatus {
    var packet: [DNS_MAX_PACKET_LEN]u8 = undefined;
    const packet_len = buildQuery(&packet, pending_query.query_id, pending_query.name[0..@as(usize, pending_query.name_len)]) orelse {
        pending_query = emptyPendingQuery();
        return .invalid_name;
    };

    const status = udp.send(DNS_LOCAL_PORT, net.getConfig().dns_server, DNS_PORT, packet[0..packet_len]);
    stats.last_send_status = status;
    switch (status) {
        .sent => {
            if (!pending_query.sent) stats.queries_sent += 1;
            pending_query.sent = true;
            return .pending;
        },
        .arp_pending, .tx_not_ready, .tx_descriptor_busy => return .pending,
        else => {
            stats.send_errors += 1;
            pending_query = emptyPendingQuery();
            return .send_error;
        },
    }
}

fn handleDnsResponse(dgram: udp.RxDatagram) void {
    if (!pending_query.active) return;
    if (dgram.src_port != DNS_PORT) return;
    if (!net.ipEqual(dgram.src_ip, net.getConfig().dns_server)) return;

    const data = dgram.data;
    if (data.len < DNS_HEADER_LEN) {
        stats.malformed += 1;
        return;
    }

    if (net.readBe16(data, OFF_ID) != pending_query.query_id) return;

    const flags = net.readBe16(data, OFF_FLAGS);
    if ((flags & DNS_FLAG_QR) == 0) return;

    stats.responses_received += 1;
    const rcode = flags & DNS_RCODE_MASK;
    if (rcode == DNS_RCODE_NXDOMAIN) {
        pending_query.status = .not_found;
        return;
    }
    if (rcode != 0) {
        pending_query.status = .server_error;
        return;
    }

    const qdcount = net.readBe16(data, OFF_QDCOUNT);
    const ancount = net.readBe16(data, OFF_ANCOUNT);
    if (ancount == 0) {
        pending_query.status = .not_found;
        return;
    }

    var offset: usize = DNS_HEADER_LEN;
    var question_index: u16 = 0;
    while (question_index < qdcount) : (question_index += 1) {
        offset = skipDnsName(data, offset) orelse {
            markMalformedResponse();
            return;
        };
        if (offset + 4 > data.len) {
            markMalformedResponse();
            return;
        }
        offset += 4;
    }

    var answer_index: u16 = 0;
    while (answer_index < ancount) : (answer_index += 1) {
        offset = skipDnsName(data, offset) orelse {
            markMalformedResponse();
            return;
        };
        if (offset + 10 > data.len) {
            markMalformedResponse();
            return;
        }

        const rr_type = net.readBe16(data, offset);
        const rr_class = net.readBe16(data, offset + 2);
        const rdlength = @as(usize, net.readBe16(data, offset + 8));
        offset += 10;
        if (offset + rdlength > data.len) {
            markMalformedResponse();
            return;
        }

        if (rr_type == DNS_TYPE_A and rr_class == DNS_CLASS_IN and rdlength == 4) {
            @memcpy(pending_query.result_ip[0..], data[offset .. offset + 4]);
            pending_query.status = .resolved;
            addCache(pending_query.name[0..@as(usize, pending_query.name_len)], pending_query.result_ip);
            return;
        }

        offset += rdlength;
    }

    pending_query.status = .not_found;
}

fn buildQuery(packet: *[DNS_MAX_PACKET_LEN]u8, query_id: u16, name: []const u8) ?usize {
    @memset(packet[0..], 0);
    net.writeBe16(packet[0..], OFF_ID, query_id);
    net.writeBe16(packet[0..], OFF_FLAGS, DNS_FLAG_RD);
    net.writeBe16(packet[0..], OFF_QDCOUNT, 1);
    net.writeBe16(packet[0..], OFF_ANCOUNT, 0);
    net.writeBe16(packet[0..], OFF_NSCOUNT, 0);
    net.writeBe16(packet[0..], OFF_ARCOUNT, 0);

    var offset: usize = DNS_HEADER_LEN;
    const encoded_len = encodeDnsName(name, packet[offset..]) orelse return null;
    offset += encoded_len;
    if (offset + 4 > packet.len) return null;
    net.writeBe16(packet[0..], offset, DNS_TYPE_A);
    net.writeBe16(packet[0..], offset + 2, DNS_CLASS_IN);
    offset += 4;
    return offset;
}

fn encodeDnsName(name: []const u8, out: []u8) ?usize {
    var out_index: usize = 0;
    var label_start: usize = 0;
    var i: usize = 0;

    while (i <= name.len) : (i += 1) {
        if (i < name.len and name[i] != '.') continue;

        const label_len = i - label_start;
        if (label_len == 0 or label_len > 63) return null;
        if (out_index + 1 + label_len > out.len) return null;

        out[out_index] = @intCast(label_len);
        out_index += 1;
        @memcpy(out[out_index .. out_index + label_len], name[label_start..i]);
        out_index += label_len;
        label_start = i + 1;
    }

    if (out_index + 1 > out.len) return null;
    out[out_index] = 0;
    return out_index + 1;
}

fn skipDnsName(data: []const u8, offset: usize) ?usize {
    var current = offset;
    while (current < data.len) {
        const length = data[current];
        if ((length & 0xc0) == 0xc0) {
            if (current + 1 >= data.len) return null;
            return current + 2;
        }
        if ((length & 0xc0) != 0) return null;

        current += 1;
        if (length == 0) return current;
        if (current + length > data.len) return null;
        current += length;
    }

    return null;
}

fn addCache(name: []const u8, ip: net.Ipv4Addr) void {
    const idx = findCacheIndex(name) orelse chooseCacheSlot();
    cache[idx] = emptyCacheEntry();
    cache[idx].valid = true;
    cache[idx].name_len = @intCast(name.len);
    @memcpy(cache[idx].name[0..name.len], name);
    cache[idx].ip = ip;
    cache[idx].timestamp = pit.getTicks();
}

fn findCache(name: []const u8) ?CacheEntry {
    for (cache) |entry| {
        if (!entry.valid) continue;
        if (nameMatches(entry.name[0..@as(usize, entry.name_len)], name)) return entry;
    }
    return null;
}

fn findCacheIndex(name: []const u8) ?usize {
    for (cache, 0..) |entry, i| {
        if (!entry.valid) continue;
        if (nameMatches(entry.name[0..@as(usize, entry.name_len)], name)) return i;
    }
    return null;
}

fn chooseCacheSlot() usize {
    var oldest_index: usize = 0;
    var oldest_tick: u64 = cache[0].timestamp;
    for (cache, 0..) |entry, i| {
        if (!entry.valid) return i;
        if (entry.timestamp < oldest_tick) {
            oldest_tick = entry.timestamp;
            oldest_index = i;
        }
    }
    return oldest_index;
}

fn markMalformedResponse() void {
    stats.malformed += 1;
    pending_query.status = .server_error;
}

fn allocateQueryId() u16 {
    const id = next_query_id;
    next_query_id +%= 1;
    if (next_query_id == 0) next_query_id = 1;
    return id;
}

fn trimTrailingDot(name: []const u8) []const u8 {
    if (name.len > 1 and name[name.len - 1] == '.') return name[0 .. name.len - 1];
    return name;
}

fn nameMatches(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_ch, right_ch| {
        if (left_ch != right_ch) return false;
    }
    return true;
}

fn emptyCacheEntry() CacheEntry {
    return .{
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .ip = net.ZERO_IP,
        .timestamp = 0,
        .valid = false,
    };
}

fn emptyPendingQuery() PendingQuery {
    return .{
        .active = false,
        .sent = false,
        .query_id = 0,
        .name = [_]u8{0} ** MAX_NAME_LEN,
        .name_len = 0,
        .start_tick = 0,
        .result_ip = net.ZERO_IP,
        .status = .pending,
    };
}

fn emptyStats() Stats {
    return .{
        .queries_sent = 0,
        .responses_received = 0,
        .cache_hits = 0,
        .cache_misses = 0,
        .timeouts = 0,
        .malformed = 0,
        .send_errors = 0,
        .last_send_status = .tx_not_ready,
    };
}
