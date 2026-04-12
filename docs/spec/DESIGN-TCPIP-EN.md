# MerlionOS-Zig TCP/IP Protocol Stack Design Document

> This document is intended for direct implementation by AI code generation tools (Codex, etc.).
> Interfaces, data structures, function signatures, and constant values are provided for every file — implement them file by file.
> Implementation order must strictly follow Phase numbering; within each Phase, implement files in the listed order.

## Table of Contents

1. [Design Principles and Constraints](#1-design-principles-and-constraints)
2. [Phase 7a: Network Infrastructure](#2-phase-7a-network-infrastructure)
3. [Phase 7b: Ethernet Frame Dispatch](#3-phase-7b-ethernet-frame-dispatch)
4. [Phase 7c: ARP Cache Table](#4-phase-7c-arp-cache-table)
5. [Phase 7d: IPv4 Layer](#5-phase-7d-ipv4-layer)
6. [Phase 7e: UDP](#6-phase-7e-udp)
7. [Phase 7f: TCP](#7-phase-7f-tcp)
8. [Phase 7g: DNS Client](#8-phase-7g-dns-client)
9. [Phase 7h: Shell Command Integration](#9-phase-7h-shell-command-integration)
10. [Integration and Initialization Order](#10-integration-and-initialization-order)
11. [QEMU Testing Methods](#11-qemu-testing-methods)

---

## 1. Design Principles and Constraints

### 1.1 Design Goals

- Build a complete IPv4/UDP/TCP protocol stack on top of the existing e1000 poll-based driver
- Maintain MerlionOS-Zig's style: no external dependencies, explicit allocators, freestanding Zig 0.15
- All network processing remains poll-based (not interrupt-driven), triggered by shell commands or timers
- Provide a clean socket-like API for shell commands and future userspace programs

### 1.2 Architecture Overview

```
┌──────────────────────────────────────────────┐
│  Shell Commands (udpsend, tcpconnect, dns...) │
├──────────────────────────────────────────────┤
│  socket.zig — Socket API                      │
├──────────────┬───────────────────────────────┤
│  udp.zig     │  tcp.zig                      │
├──────────────┴───────────────────────────────┤
│  ipv4.zig — IPv4 send/receive/routing         │
├──────────────┬───────────────────────────────┤
│  arp_cache.zig │  icmp.zig (existing, minor changes) │
├──────────────┴───────────────────────────────┤
│  eth.zig — Ethernet frame dispatch            │
├──────────────────────────────────────────────┤
│  net.zig — Common types & utility functions    │
├──────────────────────────────────────────────┤
│  e1000.zig — NIC driver (existing, no changes) │
└──────────────────────────────────────────────┘
```

### 1.3 New File List

```
src/
├── net.zig          # Common network types, big-endian utilities, PacketBuffer
├── eth.zig          # Ethernet frame send/receive and EtherType dispatch
├── arp_cache.zig    # ARP cache table (replaces arp.zig's single-entry storage)
├── ipv4.zig         # IPv4 send/receive, routing, fragmentation (reassembly on receive only)
├── udp.zig          # UDP protocol
├── tcp.zig          # TCP state machine
├── socket.zig       # Unified Socket API
└── dns.zig          # DNS client (UDP-based)
```

### 1.4 Modifications to Existing Files

| File | Modifications |
|------|--------------|
| `src/arp.zig` | Internally switch to `arp_cache.zig`; public interface unchanged; `sendRequest` writes to cache upon receiving a reply |
| `src/icmp.zig` | Internally switch to `ipv4.zig` for building/parsing IP headers; public interface unchanged |
| `src/main.zig` | After `e1000.init()`, call `net.init()`, `eth.init()`, `arp_cache.init()`, `ipv4.init()`, `udp.init()`, `tcp.init()`, `dns.init()` |
| `src/shell_cmds.zig` | Add `udpsend`, `udplisten`, `tcpconnect`, `tcpclose`, `dns`, `netpoll`, `ifconfig` commands |

### 1.5 Zig 0.15 Notes

All new code must comply with the syntax requirements in `docs/DESIGN.md` §1.4. Additional notes:

```zig
// packed struct for network protocol header parsing
const IpHeader = packed struct {
    // Note: x86 is little-endian, network is big-endian — manual conversion is required
    // packed struct arranges bits in declaration order
};

// Do NOT use packed struct to parse protocol headers. Use offset + manual big-endian field reads.
// Reason: Zig packed struct bit layout is compiler-implementation-dependent and unreliable across platforms.
// Existing code (arp.zig, icmp.zig) all uses offset + readBe16 approach — stay consistent.
```

---

## 2. Phase 7a: Network Infrastructure

### 2.1 src/net.zig — Common Network Types and Utilities

This file provides type definitions and utility functions shared by all network modules.

#### Constants

```zig
// Ethernet
pub const ETH_HEADER_LEN: usize = 14;
pub const ETH_ADDR_LEN: usize = 6;
pub const ETH_MTU: usize = 1500;
pub const ETH_FRAME_MAX: usize = ETH_HEADER_LEN + ETH_MTU; // 1514

// EtherType
pub const ETHERTYPE_IPV4: u16 = 0x0800;
pub const ETHERTYPE_ARP: u16 = 0x0806;

// IPv4
pub const IPV4_HEADER_MIN: usize = 20;
pub const IPV4_VERSION: u8 = 4;
pub const IPV4_DEFAULT_TTL: u8 = 64;

// Protocol numbers
pub const IPPROTO_ICMP: u8 = 1;
pub const IPPROTO_TCP: u8 = 6;
pub const IPPROTO_UDP: u8 = 17;

// Broadcast/zero addresses
pub const BROADCAST_MAC: [6]u8 = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
pub const ZERO_MAC: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
pub const ZERO_IP: Ipv4Addr = .{ 0, 0, 0, 0 };

// QEMU default network configuration
pub const DEFAULT_LOCAL_IP: Ipv4Addr = .{ 10, 0, 2, 15 };
pub const DEFAULT_GATEWAY_IP: Ipv4Addr = .{ 10, 0, 2, 2 };
pub const DEFAULT_SUBNET_MASK: Ipv4Addr = .{ 255, 255, 255, 0 };
pub const DEFAULT_DNS_SERVER: Ipv4Addr = .{ 10, 0, 2, 3 };
```

#### Types

```zig
pub const Ipv4Addr = [4]u8;
pub const MacAddr = [6]u8;

/// Network configuration (global singleton)
pub const NetConfig = struct {
    local_ip: Ipv4Addr,
    gateway_ip: Ipv4Addr,
    subnet_mask: Ipv4Addr,
    dns_server: Ipv4Addr,
    local_mac: MacAddr,
    mac_valid: bool,
};

/// Metadata for a received packet, passed from eth.zig to upper layers
pub const RxPacketMeta = struct {
    frame: []const u8,       // Complete Ethernet frame
    payload: []const u8,     // Payload after stripping the Ethernet header
    src_mac: MacAddr,
    dst_mac: MacAddr,
    ethertype: u16,
};
```

#### Global State

```zig
var config: NetConfig = .{
    .local_ip = DEFAULT_LOCAL_IP,
    .gateway_ip = DEFAULT_GATEWAY_IP,
    .subnet_mask = DEFAULT_SUBNET_MASK,
    .dns_server = DEFAULT_DNS_SERVER,
    .local_mac = ZERO_MAC,
    .mac_valid = false,
};
```

#### Public Functions

```zig
/// Initialize: read MAC address from e1000
pub fn init() void;

/// Get current network configuration (read-only)
pub fn getConfig() *const NetConfig;

/// Set local IP (used by the ifconfig command)
pub fn setLocalIp(ip: Ipv4Addr) void;

/// Set gateway IP
pub fn setGatewayIp(ip: Ipv4Addr) void;

/// Set DNS server
pub fn setDnsServer(ip: Ipv4Addr) void;
```

#### Utility Functions

```zig
/// Big-endian read/write (unified replacement for readBe16/writeBe16 in individual modules)
pub fn readBe16(buf: []const u8, offset: usize) u16;
pub fn readBe32(buf: []const u8, offset: usize) u32;
pub fn writeBe16(buf: []u8, offset: usize, value: u16) void;
pub fn writeBe32(buf: []u8, offset: usize, value: u32) void;

/// Internet checksum (RFC 1071)
/// Usable for IPv4 header, ICMP, UDP, and TCP checksums
/// data: byte slice to checksum
/// Return value: checksum in network byte order; when verifying existing data, result should be 0
pub fn internetChecksum(data: []const u8) u16;

/// Checksum with pseudo-header (used for UDP/TCP)
/// Pseudo-header fields: src_ip, dst_ip, zero, protocol, length
/// Accumulates pseudo-header first, then accumulates data
pub fn pseudoHeaderChecksum(
    src_ip: Ipv4Addr,
    dst_ip: Ipv4Addr,
    protocol: u8,
    data: []const u8,
) u16;

/// IPv4 address comparison
pub fn ipEqual(a: Ipv4Addr, b: Ipv4Addr) bool;

/// MAC address comparison
pub fn macEqual(a: MacAddr, b: MacAddr) bool;

/// Check if two IPs are on the same subnet
pub fn sameSubnet(a: Ipv4Addr, b: Ipv4Addr, mask: Ipv4Addr) bool;

/// Format IPv4 address as "a.b.c.d" into buffer, return the written slice
pub fn formatIp(ip: Ipv4Addr, buf: []u8) []const u8;

/// Format MAC address as "aa:bb:cc:dd:ee:ff"
pub fn formatMac(mac: MacAddr, buf: []u8) []const u8;
```

#### init() Implementation Logic

```
1. Call e1000.detected()
2. If NIC is detected and mac_valid, copy MAC to config
3. Set config.mac_valid = true
```

---

## 3. Phase 7b: Ethernet Frame Dispatch

### 3.1 src/eth.zig — Ethernet Frame Send/Receive

eth.zig is the core dispatch layer of the network stack. It polls packets from the e1000 driver and dispatches them to ARP / IPv4 handlers by EtherType; on the send path, it prepends the Ethernet header and calls e1000.transmit.

#### Types

```zig
/// Frame transmit status, maps to e1000.TxStatus
pub const TxStatus = enum {
    sent,
    no_nic,
    no_mac,
    tx_not_ready,
    tx_frame_too_large,
    tx_descriptor_busy,
    tx_timeout,
};

/// Result of a single poll
pub const PollResult = enum {
    handled_arp,
    handled_ipv4,
    ignored,
    no_packet,
    rx_not_ready,
    rx_error,
};

/// Receive statistics
pub const Stats = struct {
    frames_received: u64,
    frames_sent: u64,
    arp_received: u64,
    ipv4_received: u64,
    unknown_received: u64,
    errors: u64,
};
```

#### Global State

```zig
var stats: Stats = zeroed Stats;
```

#### Public Functions

```zig
/// Initialize (reset statistics counters)
pub fn init() void;

/// Poll one received Ethernet frame and dispatch it
/// Calls e1000.pollReceive(), parses EtherType:
///   - 0x0806 (ARP)  → arp_cache.handleRx(meta)
///   - 0x0800 (IPv4) → ipv4.handleRx(meta)
///   - Other          → ignore
/// Returns PollResult indicating what happened
pub fn poll() PollResult;

/// Poll repeatedly until no more packets (up to max_iterations times)
/// Returns the number of frames actually processed
pub fn pollAll(max_iterations: usize) usize;

/// Send an Ethernet frame
/// Automatically fills in src MAC (from net.getConfig()); caller provides dst_mac, ethertype, and payload
/// Payload length must not exceed ETH_MTU (1500)
/// Internally builds the complete frame [dst_mac(6) | src_mac(6) | ethertype(2) | payload]
/// Then calls e1000.transmit()
pub fn send(dst_mac: net.MacAddr, ethertype: u16, payload: []const u8) TxStatus;

/// Get statistics
pub fn getStats() Stats;
```

#### poll() Internal Logic

```
1. rx_status = e1000.pollReceive()
2. If rx_status != .received → return the corresponding PollResult
3. frame = e1000.lastRxFrame()
4. If frame.len < ETH_HEADER_LEN → stats.errors += 1, return .ignored
5. Parse src_mac = frame[6..12], dst_mac = frame[0..6], ethertype = readBe16(frame, 12)
6. Build RxPacketMeta { .frame = frame, .payload = frame[14..], .src_mac, .dst_mac, .ethertype }
7. switch (ethertype):
     ETHERTYPE_ARP  → arp_cache.handleRx(meta), stats.arp_received += 1, return .handled_arp
     ETHERTYPE_IPV4 → ipv4.handleRx(meta), stats.ipv4_received += 1, return .handled_ipv4
     else           → stats.unknown_received += 1, return .ignored
8. stats.frames_received += 1
```

#### send() Internal Logic

```
1. Check net.getConfig().mac_valid; if unavailable, return .no_mac
2. Build frame buffer var frame: [net.ETH_FRAME_MAX]u8
3. @memcpy(frame[0..6], dst_mac)
4. @memcpy(frame[6..12], config.local_mac)
5. writeBe16(frame, 12, ethertype)
6. @memcpy(frame[14..14+payload.len], payload)
7. total_len = 14 + payload.len; if < 60, pad with zeros to 60 (minimum frame length)
8. e1000.transmit(frame[0..total_len]) → map to TxStatus
9. stats.frames_sent += 1
```

---

## 4. Phase 7c: ARP Cache Table

### 4.1 src/arp_cache.zig — ARP Cache

Replaces the single-entry storage in arp.zig. Maintains a fixed-size ARP table with timeout and proactive queries.

#### Constants

```zig
const MAX_ENTRIES: usize = 16;
const ENTRY_TIMEOUT_TICKS: u64 = 6000; // 60 seconds @ 100Hz PIT
const ARP_RETRY_TICKS: u64 = 100;      // 1-second retry interval

// ARP protocol constants
const ARP_HTYPE_ETHERNET: u16 = 0x0001;
const ARP_PTYPE_IPV4: u16 = 0x0800;
const ARP_HLEN: u8 = 6;
const ARP_PLEN: u8 = 4;
const ARP_OPER_REQUEST: u16 = 1;
const ARP_OPER_REPLY: u16 = 2;
const ARP_PACKET_LEN: usize = 28;  // Excluding Ethernet header
```

#### Types

```zig
pub const EntryState = enum {
    free,
    pending,    // Request sent, awaiting reply
    resolved,   // Reply received, MAC is known
};

pub const Entry = struct {
    state: EntryState,
    ip: net.Ipv4Addr,
    mac: net.MacAddr,
    timestamp: u64,     // PIT tick at last update
    retries: u8,
};

pub const LookupResult = enum {
    found,
    pending,
    not_found,
};
```

#### Global State

```zig
var table: [MAX_ENTRIES]Entry = [_]Entry{emptyEntry()} ** MAX_ENTRIES;
var stats: struct {
    requests_sent: u64,
    replies_received: u64,
    lookups: u64,
    misses: u64,
} = .{ .requests_sent = 0, .replies_received = 0, .lookups = 0, .misses = 0 };
```

#### Public Functions

```zig
/// Initialize the cache table
pub fn init() void;

/// Look up the MAC address for a given IP
/// Return value: LookupResult
/// If found, mac_out is populated
/// If not_found, automatically sends an ARP request and creates a pending entry in the table
pub fn lookup(ip: net.Ipv4Addr, mac_out: *net.MacAddr) LookupResult;

/// Handle a received ARP frame (called by eth.zig)
/// Parse ARP reply → update/insert cache entry
/// Parse ARP request (targeting our IP) → send ARP reply
pub fn handleRx(meta: net.RxPacketMeta) void;

/// Periodic maintenance (called by netpoll or PIT tick)
/// - Purge expired entries
/// - Resend ARP requests for pending entries
pub fn tick() void;

/// Get a snapshot of the cache table (for the shell arp command display)
pub fn getTable() []const Entry;

/// Get statistics
pub fn getStats() @TypeOf(stats);

/// Manually add a static entry (for testing)
pub fn addStatic(ip: net.Ipv4Addr, mac: net.MacAddr) void;

/// Flush the cache
pub fn flush() void;
```

#### handleRx() Internal Logic

```
1. payload = meta.payload
2. Verify length >= ARP_PACKET_LEN
3. Verify htype == ETHERNET, ptype == IPV4, hlen == 6, plen == 4
4. Read oper, sender_mac(payload[8..14]), sender_ip(payload[14..18]),
   target_mac(payload[18..24]), target_ip(payload[24..28])
5. If oper == REPLY:
   a. Look up sender_ip entry in the table
   b. If found → update mac, state = .resolved, timestamp = pit.ticks()
   c. If not found → insert new entry (replace the oldest free or oldest resolved)
   d. stats.replies_received += 1
6. If oper == REQUEST and target_ip == our IP:
   a. Build ARP reply (swap sender/target, fill in our MAC)
   b. Call eth.send(sender_mac, ETHERTYPE_ARP, reply_payload)
   c. Also update/insert sender_ip → sender_mac into the cache
```

#### lookup() Internal Logic

```
1. stats.lookups += 1
2. Iterate table, find entry with matching ip and state == .resolved
3. If found → copy mac to mac_out, return .found
4. Iterate table, find entry with matching ip and state == .pending
5. If found → return .pending
6. stats.misses += 1
7. Send ARP request: build ARP request payload, call eth.send(BROADCAST_MAC, ETHERTYPE_ARP, ...)
8. Insert pending entry into the table
9. stats.requests_sent += 1
10. Return .not_found
```

#### ARP Request Frame Construction

```
payload is 28 bytes:
  [0..2]   htype = 0x0001
  [2..4]   ptype = 0x0800
  [4]      hlen  = 6
  [5]      plen  = 4
  [6..8]   oper  = 0x0001 (request)
  [8..14]  sender_mac = our MAC
  [14..18] sender_ip  = our IP
  [18..24] target_mac = 00:00:00:00:00:00
  [24..28] target_ip  = target IP
```

### 4.2 Modifications to src/arp.zig

Keep all public function signatures in `arp.zig` unchanged; internally switch to calling `arp_cache`:

```zig
// arp.zig after modification
const arp_cache = @import("arp_cache.zig");

pub fn sendRequest(target_ip: Ipv4, sender_ip: Ipv4) SendStatus {
    // Keep original logic, but also create a pending entry in arp_cache
    // ... original frame construction and send logic unchanged ...
    // Added:
    var mac_out: [6]u8 = undefined;
    _ = arp_cache.lookup(target_ip, &mac_out); // Trigger cache entry creation
}

pub fn pollReply() PollStatus {
    // Keep original logic, but write parsed reply into arp_cache
    // ... original logic ...
    // Added: when parseReply succeeds
    // arp_cache.addStatic(reply_ip, reply_mac);
}
```

> Note: This is an incremental migration. Old shell commands (arpreq/arppoll) continue to work.
> The new network stack (ipv4/udp/tcp) only uses arp_cache.lookup().

---

## 5. Phase 7d: IPv4 Layer

### 5.1 src/ipv4.zig — IPv4 Send/Receive and Routing

#### Constants

```zig
const IPV4_VERSION_IHL: u8 = 0x45;   // version=4, IHL=5 (20 bytes)
const IPV4_HEADER_LEN: usize = 20;
const IPV4_FLAG_DF: u16 = 0x4000;    // Don't Fragment
const IPV4_FLAG_MF: u16 = 0x2000;    // More Fragments
const IPV4_FRAG_OFFSET_MASK: u16 = 0x1FFF;

// IPv4 header field offsets
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
```

#### Types

```zig
/// Parsed result of a received IPv4 packet
pub const RxIpPacket = struct {
    src_ip: net.Ipv4Addr,
    dst_ip: net.Ipv4Addr,
    protocol: u8,
    ttl: u8,
    payload: []const u8,    // IP payload (excluding IP header)
    header: []const u8,     // IP header (including options)
};

/// Send status
pub const SendStatus = enum {
    sent,
    no_route,          // Cannot determine next hop
    arp_pending,       // ARP not yet resolved; packet dropped (caller should retry later)
    frame_too_large,   // Exceeds MTU
    tx_error,          // e1000 transmit failure
};

/// Protocol handler callback type
/// Upper-layer protocols (UDP/TCP/ICMP) register their handler functions
pub const ProtocolHandler = *const fn (packet: RxIpPacket) void;

/// Route entry
pub const Route = struct {
    dest: net.Ipv4Addr,     // Destination network
    mask: net.Ipv4Addr,     // Subnet mask
    gateway: net.Ipv4Addr,  // Next hop (ZERO_IP means directly connected)
};

/// Statistics
pub const Stats = struct {
    packets_sent: u64,
    packets_received: u64,
    bad_checksum: u64,
    bad_version: u64,
    ttl_expired: u64,
    no_handler: u64,
    fragmented_dropped: u64,
};
```

#### Global State

```zig
const MAX_PROTOCOL_HANDLERS: usize = 8;

var handlers: [MAX_PROTOCOL_HANDLERS]struct {
    protocol: u8,
    handler: ?ProtocolHandler,
} = [_]@TypeOf(handlers[0]){.{ .protocol = 0, .handler = null }} ** MAX_PROTOCOL_HANDLERS;

var next_ident: u16 = 1;  // IP identification, auto-incrementing
var stats: Stats = zeroed Stats;
```

#### Public Functions

```zig
/// Initialize
pub fn init() void;

/// Register a protocol handler (ICMP=1, TCP=6, UDP=17)
pub fn registerHandler(protocol: u8, handler: ProtocolHandler) void;

/// Handle a received IPv4 frame (called by eth.zig)
pub fn handleRx(meta: net.RxPacketMeta) void;

/// Send an IPv4 packet
/// protocol: IPPROTO_ICMP / IPPROTO_UDP / IPPROTO_TCP
/// dst_ip: destination IP
/// payload: IP payload (excluding IP header)
/// Automatically handles: IP header construction, checksum calculation, route lookup, ARP resolution, eth.send()
pub fn send(protocol: u8, dst_ip: net.Ipv4Addr, payload: []const u8) SendStatus;

/// Send with explicit src_ip (for special cases like DHCP)
pub fn sendFrom(protocol: u8, src_ip: net.Ipv4Addr, dst_ip: net.Ipv4Addr, payload: []const u8) SendStatus;

/// Get statistics
pub fn getStats() Stats;
```

#### handleRx() Internal Logic

```
1. data = meta.payload
2. If data.len < IPV4_HEADER_LEN → return
3. version_ihl = data[OFF_VERSION_IHL]
4. version = version_ihl >> 4; if != 4 → stats.bad_version += 1, return
5. ihl = (version_ihl & 0x0f) * 4; if ihl < 20 → return
6. total_len = readBe16(data, OFF_TOTAL_LEN)
7. If data.len < total_len → return (truncated packet)
8. Verify IP header checksum: internetChecksum(data[0..ihl]) != 0 → stats.bad_checksum += 1, return
9. flags_frag = readBe16(data, OFF_FLAGS_FRAG)
10. If fragmented (offset != 0 or MF bit set) → stats.fragmented_dropped += 1, return
    (MVP does not support fragment reassembly; drop immediately)
11. protocol = data[OFF_PROTOCOL]
12. src_ip = data[OFF_SRC_IP..][0..4].*
13. dst_ip = data[OFF_DST_IP..][0..4].*
14. If dst_ip != our IP and dst_ip != 255.255.255.255 → return (not addressed to us)
15. Build RxIpPacket { src_ip, dst_ip, protocol, ttl, payload = data[ihl..total_len], header = data[0..ihl] }
16. Look up matching protocol handler in handlers
17. If found → handler(packet), stats.packets_received += 1
18. Otherwise → stats.no_handler += 1
```

#### send() Internal Logic

```
1. src_ip = net.getConfig().local_ip
2. Call sendFrom(protocol, src_ip, dst_ip, payload)
```

#### sendFrom() Internal Logic

```
1. If payload.len > ETH_MTU - IPV4_HEADER_LEN → return .frame_too_large
2. Determine next-hop IP:
   If sameSubnet(dst_ip, src_ip, config.subnet_mask) → next_hop = dst_ip
   Otherwise → next_hop = config.gateway_ip
   If next_hop == ZERO_IP → return .no_route
3. ARP lookup: arp_cache.lookup(next_hop, &dst_mac)
   If .pending or .not_found → return .arp_pending
4. Build IP header (20 bytes):
   [0]      = 0x45 (v4, IHL=5)
   [1]      = 0x00 (TOS)
   [2..4]   = total_len = 20 + payload.len (big-endian)
   [4..6]   = next_ident (big-endian), next_ident += 1
   [6..8]   = IPV4_FLAG_DF (Don't Fragment)
   [8]      = DEFAULT_TTL (64)
   [9]      = protocol
   [10..12] = 0x0000 (checksum initially zero)
   [12..16] = src_ip
   [16..20] = dst_ip
   Compute checksum → write into [10..12]
5. Build complete IP packet: var packet: [ETH_MTU]u8
   @memcpy(packet[0..20], ip_header)
   @memcpy(packet[20..20+payload.len], payload)
6. eth.send(dst_mac, ETHERTYPE_IPV4, packet[0..20+payload.len])
7. Map eth.TxStatus → SendStatus, stats.packets_sent += 1
```

---

## 6. Phase 7e: UDP

### 6.1 src/udp.zig — UDP Protocol

#### Constants

```zig
const UDP_HEADER_LEN: usize = 8;
const MAX_BINDINGS: usize = 8;

// UDP header field offsets
const OFF_SRC_PORT: usize = 0;
const OFF_DST_PORT: usize = 2;
const OFF_LENGTH: usize = 4;
const OFF_CHECKSUM: usize = 6;
```

#### Types

```zig
/// Received UDP datagram
pub const RxDatagram = struct {
    src_ip: net.Ipv4Addr,
    dst_ip: net.Ipv4Addr,
    src_port: u16,
    dst_port: u16,
    data: []const u8,
};

/// Port binding callback type
pub const DatagramHandler = *const fn (dgram: RxDatagram) void;

/// Send status
pub const SendStatus = enum {
    sent,
    payload_too_large,
    ip_error,
};

/// Statistics
pub const Stats = struct {
    datagrams_sent: u64,
    datagrams_received: u64,
    bad_checksum: u64,
    no_binding: u64,
};
```

#### Global State

```zig
var bindings: [MAX_BINDINGS]struct {
    port: u16,
    handler: ?DatagramHandler,
} = [_]@TypeOf(bindings[0]){.{ .port = 0, .handler = null }} ** MAX_BINDINGS;

var stats: Stats = zeroed Stats;
```

#### Public Functions

```zig
/// Initialize; register with ipv4 as the handler for protocol=17
pub fn init() void;

/// Bind a port and register a callback
/// Returns true on success, false if bindings are full
pub fn bind(port: u16, handler: DatagramHandler) bool;

/// Unbind a port
pub fn unbind(port: u16) void;

/// Send a UDP datagram
/// src_port: source port
/// dst_ip: destination IP
/// dst_port: destination port
/// data: payload data
pub fn send(src_port: u16, dst_ip: net.Ipv4Addr, dst_port: u16, data: []const u8) SendStatus;

/// Handle a received IPv4 packet (callback registered with ipv4)
/// Does not need to be public, but is registered as ipv4.registerHandler(IPPROTO_UDP, handleRx) during implementation
fn handleRx(packet: ipv4.RxIpPacket) void;

/// Get statistics
pub fn getStats() Stats;
```

#### handleRx() Internal Logic

```
1. data = packet.payload
2. If data.len < UDP_HEADER_LEN → return
3. src_port = readBe16(data, OFF_SRC_PORT)
4. dst_port = readBe16(data, OFF_DST_PORT)
5. udp_len = readBe16(data, OFF_LENGTH)
6. If udp_len < 8 or udp_len > data.len → return
7. checksum = readBe16(data, OFF_CHECKSUM)
8. If checksum != 0:
   Verify pseudoHeaderChecksum(packet.src_ip, packet.dst_ip, IPPROTO_UDP, data[0..udp_len])
   If != 0 → stats.bad_checksum += 1, return
9. payload = data[UDP_HEADER_LEN..udp_len]
10. Look up matching handler for dst_port in bindings
11. If found → handler(RxDatagram{ src_ip, dst_ip, src_port, dst_port, data = payload })
    stats.datagrams_received += 1
12. Otherwise → stats.no_binding += 1
```

#### send() Internal Logic

```
1. udp_len = UDP_HEADER_LEN + data.len
2. If udp_len > net.ETH_MTU - net.IPV4_HEADER_MIN → return .payload_too_large
3. Build UDP packet: var packet: [net.ETH_MTU - net.IPV4_HEADER_MIN]u8
   writeBe16(packet, 0, src_port)
   writeBe16(packet, 2, dst_port)
   writeBe16(packet, 4, udp_len)
   writeBe16(packet, 6, 0)  // checksum initially zero
   @memcpy(packet[8..8+data.len], data)
4. Compute UDP checksum (with pseudo-header):
   cs = pseudoHeaderChecksum(local_ip, dst_ip, IPPROTO_UDP, packet[0..udp_len])
   If cs == 0 → cs = 0xFFFF (UDP checksum of 0 means "not used")
   writeBe16(packet, 6, cs)
5. ipv4.send(IPPROTO_UDP, dst_ip, packet[0..udp_len])
6. Map result → SendStatus, stats.datagrams_sent += 1
```

---

## 7. Phase 7f: TCP

### 7.1 src/tcp.zig — TCP State Machine

The TCP implementation uses a simplified design:
- Maximum 4 concurrent connections
- Only active connections (connect) are supported; listen/accept is not supported (no server for the MVP)
- Fixed receive window of 2048 bytes
- No congestion control (kernel environment, low-speed scenario)
- Timeout retransmission uses a simple fixed timer

#### Constants

```zig
const TCP_HEADER_MIN: usize = 20;
const MAX_CONNECTIONS: usize = 4;
const RX_BUFFER_SIZE: usize = 2048;
const TX_BUFFER_SIZE: usize = 2048;
const DEFAULT_WINDOW_SIZE: u16 = 2048;
const RETRANSMIT_TICKS: u64 = 300;    // 3 seconds @ 100Hz
const MAX_RETRANSMITS: u8 = 5;
const TIME_WAIT_TICKS: u64 = 1000;    // 10 seconds
const CONNECT_TIMEOUT_TICKS: u64 = 500; // 5 seconds

// TCP header field offsets
const OFF_SRC_PORT: usize = 0;
const OFF_DST_PORT: usize = 2;
const OFF_SEQ_NUM: usize = 4;
const OFF_ACK_NUM: usize = 8;
const OFF_DATA_OFF_FLAGS: usize = 12;
const OFF_WINDOW: usize = 14;
const OFF_CHECKSUM: usize = 16;
const OFF_URGENT: usize = 18;

// TCP flags
const FLAG_FIN: u8 = 0x01;
const FLAG_SYN: u8 = 0x02;
const FLAG_RST: u8 = 0x04;
const FLAG_PSH: u8 = 0x08;
const FLAG_ACK: u8 = 0x10;
```

#### Types

```zig
pub const State = enum {
    closed,
    syn_sent,
    established,
    fin_wait_1,
    fin_wait_2,
    time_wait,
    close_wait,
    last_ack,
};

pub const ConnId = u8;  // Connection index 0..MAX_CONNECTIONS-1

pub const Connection = struct {
    state: State,
    local_port: u16,
    remote_port: u16,
    remote_ip: net.Ipv4Addr,

    // Sequence number management
    snd_una: u32,    // Oldest unacknowledged sequence number
    snd_nxt: u32,    // Next sequence number to send
    rcv_nxt: u32,    // Next expected receive sequence number
    iss: u32,        // Initial send sequence number

    // Buffers
    rx_buf: [RX_BUFFER_SIZE]u8,
    rx_len: usize,   // Amount of readable data in the receive buffer
    tx_buf: [TX_BUFFER_SIZE]u8,
    tx_len: usize,   // Amount of data pending in the send buffer

    // Timers
    retransmit_tick: u64,
    retransmit_count: u8,
    time_wait_tick: u64,
};

pub const ConnectResult = enum {
    ok,
    no_free_slot,
    invalid_port,
};

pub const SendResult = enum {
    ok,
    buffer_full,
    not_established,
    invalid_conn,
};

pub const RecvResult = struct {
    data: []const u8,
    state: State,
};

pub const Stats = struct {
    segments_sent: u64,
    segments_received: u64,
    connections_opened: u64,
    connections_closed: u64,
    retransmits: u64,
    resets_sent: u64,
    bad_checksum: u64,
};
```

#### Global State

```zig
var connections: [MAX_CONNECTIONS]Connection = [_]Connection{emptyConnection()} ** MAX_CONNECTIONS;
var next_local_port: u16 = 49152;  // Ephemeral port start
var stats: Stats = zeroed Stats;
```

#### Public Functions

```zig
/// Initialize; register with ipv4 as the handler for protocol=6
pub fn init() void;

/// Actively connect to remote_ip:remote_port
/// Returns ConnId (connection handle) and result
/// Internally: allocate connection slot, generate ISS, send SYN, transition state → syn_sent
pub fn connect(remote_ip: net.Ipv4Addr, remote_port: u16, conn_out: *ConnId) ConnectResult;

/// Send data (places data into the TX buffer; tick() handles actual transmission)
pub fn send(conn: ConnId, data: []const u8) SendResult;

/// Read data from the receive buffer
/// Returns a slice of readable data and the current connection state
/// Clears the receive buffer after reading
pub fn recv(conn: ConnId) RecvResult;

/// Actively close the connection (sends FIN)
pub fn close(conn: ConnId) void;

/// Timer tick (called by netpoll)
/// - Handle retransmissions
/// - Handle TIME_WAIT timeout
/// - Transmit data from TX buffer
pub fn tick() void;

/// Get connection state
pub fn getConnection(conn: ConnId) ?*const Connection;

/// Get statistics
pub fn getStats() Stats;

/// Handle a received IPv4 packet (registered as ipv4 handler)
fn handleRx(packet: ipv4.RxIpPacket) void;
```

#### connect() Internal Logic

```
1. Find a free slot with state == .closed
2. If none → return .no_free_slot; conn_out is not written
3. Allocate ephemeral port: local_port = next_local_port, next_local_port += 1
4. Generate initial sequence number: iss = simple pit.ticks() * 64000 + local_port
   (No complex ISN generation — no security concerns in a kernel environment)
5. Initialize connection:
   state = .syn_sent
   Fill in local_port, remote_port, remote_ip
   snd_una = iss, snd_nxt = iss + 1, rcv_nxt = 0, iss = iss
   Clear buffers
   retransmit_tick = pit.ticks(), retransmit_count = 0
6. Send SYN segment: sendSegment(conn, FLAG_SYN, iss, 0, &.{})
7. conn_out.* = slot_index
8. stats.connections_opened += 1
9. return .ok
```

#### handleRx() Internal Logic

```
1. data = packet.payload
2. If data.len < TCP_HEADER_MIN → return
3. src_port = readBe16(data, OFF_SRC_PORT)
4. dst_port = readBe16(data, OFF_DST_PORT)
5. Find matching connection: remote_ip == packet.src_ip, remote_port == src_port, local_port == dst_port
6. If not found → send RST, return
7. Verify checksum: pseudoHeaderChecksum(src_ip, dst_ip, IPPROTO_TCP, data)
   If != 0 → stats.bad_checksum += 1, return
8. Parse fields:
   seq = readBe32(data, OFF_SEQ_NUM)
   ack = readBe32(data, OFF_ACK_NUM)
   data_offset = (data[OFF_DATA_OFF_FLAGS] >> 4) * 4
   flags = data[OFF_DATA_OFF_FLAGS + 1] (low byte)
   payload = data[data_offset..]

9. Process based on connection state:

   .syn_sent:
     If flags have SYN + ACK:
       If ack == snd_nxt:
         rcv_nxt = seq + 1
         snd_una = ack
         state = .established
         Send ACK segment
     If flags have RST:
       state = .closed

   .established:
     If flags have RST → state = .closed, return
     If flags have ACK → snd_una = max(snd_una, ack)
     If seq == rcv_nxt and payload.len > 0:
       Copy payload to rx_buf[rx_len..] (not exceeding RX_BUFFER_SIZE)
       rx_len += copied_len
       rcv_nxt += copied_len
       Send ACK segment
     If flags have FIN:
       rcv_nxt = seq + 1 (if there is payload, then +payload.len+1)
       state = .close_wait
       Send ACK segment

   .fin_wait_1:
     If flags have ACK and ack == snd_nxt:
       state = .fin_wait_2
     If flags have FIN:
       rcv_nxt = seq + 1
       If state == .fin_wait_2:
         state = .time_wait, time_wait_tick = pit.ticks()
       Otherwise:
         state = .time_wait, time_wait_tick = pit.ticks()
       Send ACK segment

   .fin_wait_2:
     If flags have FIN:
       rcv_nxt = seq + 1
       state = .time_wait, time_wait_tick = pit.ticks()
       Send ACK segment

   .last_ack:
     If flags have ACK:
       state = .closed

   .time_wait:
     // Ignore or resend ACK

10. stats.segments_received += 1
```

#### sendSegment() Internal Function

```zig
/// Build and send a TCP segment
fn sendSegment(
    conn_idx: usize,
    flags: u8,
    seq: u32,
    ack: u32,
    payload: []const u8,
) void;
```

```
1. conn = &connections[conn_idx]
2. tcp_len = TCP_HEADER_MIN + payload.len
3. var segment: [net.ETH_MTU - net.IPV4_HEADER_MIN]u8
4. Build TCP header:
   writeBe16(segment, 0, conn.local_port)
   writeBe16(segment, 2, conn.remote_port)
   writeBe32(segment, 4, seq)
   writeBe32(segment, 8, ack)
   segment[12] = (5 << 4)  // data offset = 5 (20 bytes), no options
   segment[13] = flags
   writeBe16(segment, 14, DEFAULT_WINDOW_SIZE)
   writeBe16(segment, 16, 0)  // checksum initially zero
   writeBe16(segment, 18, 0)  // urgent pointer
5. If there is payload → @memcpy(segment[20..20+payload.len], payload)
6. Compute checksum:
   cs = pseudoHeaderChecksum(local_ip, conn.remote_ip, IPPROTO_TCP, segment[0..tcp_len])
   writeBe16(segment, 16, cs)
7. ipv4.send(IPPROTO_TCP, conn.remote_ip, segment[0..tcp_len])
8. stats.segments_sent += 1
```

#### tick() Internal Logic

```
1. now = pit.ticks()
2. Iterate all connections:
   .syn_sent:
     If now - retransmit_tick > RETRANSMIT_TICKS:
       If retransmit_count >= MAX_RETRANSMITS → state = .closed
       Otherwise → resend SYN, retransmit_count += 1, retransmit_tick = now
       stats.retransmits += 1

   .established:
     If tx_len > 0:
       Send tx_buf[0..tx_len] as a data segment
       (Simplified: send the entire buffer at once, no segmentation)
       tx_len = 0

   .time_wait:
     If now - time_wait_tick > TIME_WAIT_TICKS:
       state = .closed
       stats.connections_closed += 1

   .close_wait:
     // Automatically send FIN (simplified: don't wait for explicit user close)
     sendSegment(i, FLAG_FIN | FLAG_ACK, snd_nxt, rcv_nxt, &.{})
     snd_nxt += 1
     state = .last_ack

   .last_ack:
     If now - retransmit_tick > RETRANSMIT_TICKS:
       If retransmit_count >= MAX_RETRANSMITS → state = .closed
       Otherwise → resend FIN+ACK, retransmit_count += 1
```

#### close() Internal Logic

```
1. conn = &connections[conn]
2. If state == .established:
   Send FIN+ACK: sendSegment(conn, FLAG_FIN | FLAG_ACK, snd_nxt, rcv_nxt, &.{})
   snd_nxt += 1
   state = .fin_wait_1
   retransmit_tick = pit.ticks(), retransmit_count = 0
3. If state == .close_wait:
   Send FIN+ACK
   state = .last_ack
4. Other states → state = .closed
```

---

## 8. Phase 7g: DNS Client

### 8.1 src/dns.zig — DNS Client

A simple UDP-based DNS resolver. Supports only A record queries (IPv4 addresses).

#### Constants

```zig
const DNS_PORT: u16 = 53;
const DNS_LOCAL_PORT: u16 = 10053;
const DNS_HEADER_LEN: usize = 12;
const DNS_MAX_RESPONSE: usize = 512;
const DNS_QUERY_TIMEOUT_TICKS: u64 = 300;  // 3 seconds
const MAX_CACHED_ENTRIES: usize = 8;

// DNS header fields
const DNS_FLAG_QR: u16 = 0x8000;       // Response
const DNS_FLAG_RD: u16 = 0x0100;       // Recursion Desired
const DNS_FLAG_RA: u16 = 0x0080;       // Recursion Available
const DNS_RCODE_MASK: u16 = 0x000F;
const DNS_TYPE_A: u16 = 1;
const DNS_CLASS_IN: u16 = 1;
```

#### Types

```zig
pub const ResolveStatus = enum {
    resolved,
    pending,        // Query sent, awaiting response
    not_found,      // NXDOMAIN
    timeout,
    server_error,
    name_too_long,
    no_dns_server,
};

pub const CacheEntry = struct {
    name: [64]u8,
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
};
```

#### Global State

```zig
var cache: [MAX_CACHED_ENTRIES]CacheEntry = [_]CacheEntry{emptyCacheEntry()} ** MAX_CACHED_ENTRIES;
var next_query_id: u16 = 1;

// State of the most recent query (simplified: only one pending query at a time)
var pending_query: struct {
    active: bool,
    query_id: u16,
    name: [64]u8,
    name_len: u8,
    start_tick: u64,
    result_ip: net.Ipv4Addr,
    status: ResolveStatus,
} = .{
    .active = false,
    .query_id = 0,
    .name = [_]u8{0} ** 64,
    .name_len = 0,
    .start_tick = 0,
    .result_ip = net.ZERO_IP,
    .status = .pending,
};

var stats: Stats = zeroed Stats;
```

#### Public Functions

```zig
/// Initialize; bind UDP port 10053
pub fn init() void;

/// Resolve a domain name
/// name: e.g. "example.com"
/// ip_out: populated on successful resolution
/// Return value:
///   .resolved → ip_out is valid (from cache or a completed query)
///   .pending  → query sent; caller needs to wait via netpoll and call again
///   .timeout / .not_found / .server_error → failure
pub fn resolve(name: []const u8, ip_out: *net.Ipv4Addr) ResolveStatus;

/// Check if the pending query has timed out (called by tick)
pub fn tick() void;

/// Get cache contents
pub fn getCache() []const CacheEntry;

/// Flush the cache
pub fn flushCache() void;

/// Get statistics
pub fn getStats() Stats;
```

#### resolve() Internal Logic

```
1. If name.len > 63 → return .name_too_long
2. Check cache first: iterate cache, find entry with matching name and valid == true
   If found → ip_out.* = entry.ip, stats.cache_hits += 1, return .resolved
3. stats.cache_misses += 1
4. If pending_query.active:
   If name matches the current pending query:
     If status != .pending → ip_out.* = result_ip, return status
     Otherwise → return .pending (still waiting)
   Otherwise → cancel the current query (simplified handling)
5. Build DNS query packet:
   a. DNS header (12 bytes):
      query_id (2), flags=RD (2), qdcount=1 (2), ancount=0, nscount=0, arcount=0
   b. Question section:
      Encode domain name: "example.com" → [7]"example"[3]"com"[0]
      qtype = A (2), qclass = IN (2)
6. Send via udp.send(DNS_LOCAL_PORT, dns_server, DNS_PORT, query_packet)
7. Set pending_query: active=true, query_id, name, start_tick=pit.ticks(), status=.pending
8. stats.queries_sent += 1
9. return .pending
```

#### UDP Callback handleDnsResponse() (registered on UDP port 10053)

```
1. dgram: udp.RxDatagram
2. data = dgram.data
3. If data.len < DNS_HEADER_LEN → return
4. response_id = readBe16(data, 0)
5. If response_id != pending_query.query_id → return
6. flags = readBe16(data, 2)
7. If (flags & DNS_FLAG_QR) == 0 → return (not a response)
8. rcode = flags & DNS_RCODE_MASK
9. If rcode == 3 → pending_query.status = .not_found, return
10. If rcode != 0 → pending_query.status = .server_error, return
11. ancount = readBe16(data, 6)
12. If ancount == 0 → pending_query.status = .not_found, return
13. Skip Question section (starting from offset=12, skip the domain name and 4 bytes of qtype/qclass)
14. Parse the first Answer RR:
    Skip name (may be a compression pointer 0xC0xx)
    type = readBe16, class = readBe16, ttl = readBe32, rdlength = readBe16
    If type == A and class == IN and rdlength == 4:
      @memcpy(pending_query.result_ip[0..], rdata[0..4])
      pending_query.status = .resolved
      Write to cache
      stats.responses_received += 1
```

#### DNS Name Encoding Function

```zig
/// Encode "example.com" into DNS format [7]example[3]com[0]
/// Writes into buf, returns the number of bytes written
fn encodeDnsName(name: []const u8, buf: []u8) usize;
```

```
1. Process segment by segment, delimited by '.'
2. Write a length byte before each segment, then write the segment contents
3. Write 0x00 terminator at the end
```

#### DNS Name Skip Function

```zig
/// Skip a domain name in a DNS response (supports compression pointers)
/// Returns the offset after the name
fn skipDnsName(data: []const u8, offset: usize) usize;
```

```
1. If the top two bits of data[offset] == 0xC0 → compression pointer, return offset + 2
2. Otherwise skip segment by segment until 0x00 is encountered
```

---

## 9. Phase 7h: Shell Command Integration

### 9.1 New Commands in src/shell_cmds.zig

Add the following commands to the `commands` array:

```zig
// Add to the commands array
.{ .name = "ifconfig", .description = "Show/set network interface config", .handler = cmdIfconfig },
.{ .name = "netpoll", .description = "Poll network stack (ARP, IPv4, timers)", .handler = cmdNetpoll },
.{ .name = "arp", .description = "Show ARP cache table", .handler = cmdArp },
.{ .name = "udpsend", .description = "Send a UDP datagram", .handler = cmdUdpsend },
.{ .name = "tcpconnect", .description = "Open a TCP connection", .handler = cmdTcpconnect },
.{ .name = "tcpsend", .description = "Send data on a TCP connection", .handler = cmdTcpsend },
.{ .name = "tcprecv", .description = "Read data from a TCP connection", .handler = cmdTcprecv },
.{ .name = "tcpclose", .description = "Close a TCP connection", .handler = cmdTcpclose },
.{ .name = "tcpstat", .description = "Show TCP connection states", .handler = cmdTcpstat },
.{ .name = "dns", .description = "Resolve a domain name to IPv4", .handler = cmdDns },
.{ .name = "httpget", .description = "Simple HTTP GET request", .handler = cmdHttpget },
```

#### New Imports

```zig
const net = @import("net.zig");
const eth = @import("eth.zig");
const arp_cache = @import("arp_cache.zig");
const ipv4 = @import("ipv4.zig");
const udp = @import("udp.zig");
const tcp = @import("tcp.zig");
const dns = @import("dns.zig");
```

#### cmdIfconfig

```
Usage: ifconfig
       ifconfig ip 10.0.2.15
       ifconfig gw 10.0.2.2
       ifconfig dns 10.0.2.3

Without arguments, displays:
  eth0: MAC xx:xx:xx:xx:xx:xx
        IP  10.0.2.15
        GW  10.0.2.2
        DNS 10.0.2.3
        Mask 255.255.255.0
  ETH stats: rx=N tx=N
  IPv4 stats: rx=N tx=N bad_csum=N
  UDP stats: rx=N tx=N
  TCP stats: rx=N tx=N retrans=N

With arguments, calls net.setLocalIp / net.setGatewayIp / net.setDnsServer
```

#### cmdNetpoll

```
Usage: netpoll [count]

Default count=10
Calls eth.poll() in a loop count times
Also calls arp_cache.tick(), tcp.tick(), dns.tick()
Displays: "netpoll: processed N frames"
```

> This is the core command for the MVP. Since there is no interrupt-driven packet reception, all network interactions require the user to manually run netpoll.
> Typical workflow: `arpreq` → `netpoll` → `dns example.com` → `netpoll` → `tcpconnect ...`

#### cmdArp

```
Usage: arp

Displays ARP cache table:
  IP              MAC                State
  10.0.2.2        52:54:00:12:34:56  resolved
  10.0.2.3        52:54:00:12:34:57  pending

Displays statistics: requests=N replies=N lookups=N misses=N
```

#### cmdUdpsend

```
Usage: udpsend <ip> <port> <message>
Example: udpsend 10.0.2.2 9999 "Hello from MerlionOS"

1. Parse IP and port
2. udp.send(12345, dst_ip, dst_port, message_bytes)
3. Display result
```

#### cmdTcpconnect

```
Usage: tcpconnect <ip> <port>
Example: tcpconnect 10.0.2.2 80

1. Parse IP and port
2. tcp.connect(ip, port, &conn_id)
3. Display: "TCP connecting to x.x.x.x:port (conn=N)..."
4. Loop netpoll until connection is established or timeout (up to 50 iterations, polling 10 frames each)
5. Display: "TCP connected" or "TCP connection failed"
```

#### cmdTcpsend

```
Usage: tcpsend <conn_id> <data>
Example: tcpsend 0 "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n"

Supports \r\n escape sequences
```

#### cmdTcprecv

```
Usage: tcprecv <conn_id>

1. Run netpoll for a few rounds to receive data
2. tcp.recv(conn_id)
3. Display received data (hex dump + ASCII)
```

#### cmdTcpclose

```
Usage: tcpclose <conn_id>

1. tcp.close(conn_id)
2. Run netpoll for a few rounds to wait for close completion
3. Display final state
```

#### cmdTcpstat

```
Usage: tcpstat

Displays all connections:
  Conn  State        Local      Remote           SndUna    SndNxt    RcvNxt
  0     established  :49152     10.0.2.2:80      1000      1050      5000
  1     closed       -          -                -         -         -
```

#### cmdDns

```
Usage: dns <domain>
Example: dns example.com

1. dns.resolve(name, &ip)
2. If .pending → loop netpoll + dns.resolve until resolution completes or timeout
3. Display: "example.com → 93.184.216.34" or error message
```

#### cmdHttpget

```
Usage: httpget <ip> <port> <path>
Example: httpget 10.0.2.2 80 /index.html

This is a composite command demonstrating the complete TCP workflow:
1. tcp.connect(ip, port)
2. netpoll to wait for connection
3. tcp.send(conn, "GET <path> HTTP/1.0\r\nHost: <ip>\r\nConnection: close\r\n\r\n")
4. netpoll loop to receive
5. tcp.recv(conn) to display response
6. tcp.close(conn)
```

---

## 10. Integration and Initialization Order

### 10.1 Modifications to src/main.zig

Insert network stack initialization between the existing `e1000.init()` and `ai.init()`:

```zig
// Existing
e1000.init();
// ... e1000 logging ...

// New: Network stack initialization
const net_mod = @import("net.zig");
const eth_mod = @import("eth.zig");
const arp_cache_mod = @import("arp_cache.zig");
const ipv4_mod = @import("ipv4.zig");
const udp_mod = @import("udp.zig");
const tcp_mod = @import("tcp.zig");
const dns_mod = @import("dns.zig");

net_mod.init();
eth_mod.init();
arp_cache_mod.init();
ipv4_mod.init();
udp_mod.init();
tcp_mod.init();
dns_mod.init();

const cfg = net_mod.getConfig();
if (cfg.mac_valid) {
    log.kprintln("[net] Stack initialized: {d}.{d}.{d}.{d} gw {d}.{d}.{d}.{d}", .{
        cfg.local_ip[0], cfg.local_ip[1], cfg.local_ip[2], cfg.local_ip[3],
        cfg.gateway_ip[0], cfg.gateway_ip[1], cfg.gateway_ip[2], cfg.gateway_ip[3],
    });
} else {
    log.kprintln("[net] Stack initialized (no NIC)", .{});
}

// Existing
ai.init();
```

### 10.2 Initialization Dependency Chain

```
e1000.init()           ← NIC driver
  ↓
net.init()             ← Read MAC, set default IP
  ↓
eth.init()             ← Reset statistics
  ↓
arp_cache.init()       ← Clear ARP table
  ↓
ipv4.init()            ← Register protocol handlers (reserve slots)
  ↓
udp.init()             ← Register with ipv4 (protocol=17), bind DNS port
  ↓
tcp.init()             ← Register with ipv4 (protocol=6)
  ↓
dns.init()             ← Bind UDP port 10053
```

---

## 11. QEMU Testing Methods

### 11.1 Basic Network Connectivity

QEMU uses user-mode networking (SLIRP) by default:
- Virtual gateway: 10.0.2.2
- Virtual DNS: 10.0.2.3
- Guest IP: 10.0.2.15

```bash
# Start (the existing zig build run works; QEMU enables networking by default)
zig build run
```

### 11.2 Testing ARP + New Cache

```
MerlionOS> arpreq 10.0.2.2
MerlionOS> netpoll
MerlionOS> arp
```

### 11.3 Testing UDP

Start a UDP echo server on the host machine:

```bash
# Terminal 1: Start a simple UDP echo
nc -u -l 9999
```

QEMU requires port forwarding for the guest to access the host:

```bash
# Start QEMU with hostfwd (requires modifying build.zig or QEMU parameters)
# -netdev user,id=n0,hostfwd=udp::9999-:9999
```

A simpler approach is to send to the gateway 10.0.2.2 (SLIRP will handle it).

### 11.4 Testing TCP

SLIRP supports TCP connections to the host (via port forwarding) or to the external network.

```bash
# Start a simple HTTP server on the host
python3 -m http.server 8080
```

```bash
# Add port forwarding to QEMU parameters (modify build.zig)
# -netdev user,id=n0,hostfwd=tcp::8080-:8080 is incorrect
# Correct approach: guest connects directly to 10.0.2.2:8080 (SLIRP's host gateway)
```

In the shell:

```
MerlionOS> arpreq 10.0.2.2
MerlionOS> netpoll
MerlionOS> httpget 10.0.2.2 8080 /
```

### 11.5 Testing DNS

SLIRP has a built-in DNS forwarder (10.0.2.3):

```
MerlionOS> dns example.com
MerlionOS> netpoll
MerlionOS> dns example.com    # Second call should return from cache
```

### 11.6 build.zig QEMU Parameter Recommendations

If the current QEMU configuration does not explicitly configure networking, verify that the `-nic` or `-netdev` parameters are correct. The e1000 is already working (ARP/ICMP are functional based on the git log), so the existing QEMU configuration should be sufficient.

If host port forwarding is needed, add to the QEMU parameters in build.zig:

```
-netdev user,id=net0,hostfwd=tcp::8080-:8080 -device e1000,netdev=net0
```

---

## Appendix: Implementation Order Checklist

Implement in this order; each file can be compiled and tested as soon as it is complete:

- [x] `src/net.zig` — Compilation alone is sufficient to verify; no runtime dependencies
- [x] `src/eth.zig` — After compilation, test frame dispatch in the shell with `netpoll`
- [x] `src/arp_cache.zig` — Verify cache with `arpreq` + `netpoll` + `arp`
- [x] Modify `src/arp.zig` — Ensure old commands still work
- [x] `src/ipv4.zig` — Verify with `pingtest` + `netpoll` (ICMP goes through the new IPv4 layer)
- [x] Modify `src/icmp.zig` — Switch to ipv4.zig; verify ping still works
- [x] `src/udp.zig` — Test with `udpsend`
- [x] `src/tcp.zig` — Test the three-way handshake, send, receive, and close with `tcpconnect` + `netpoll`
- [x] `src/dns.zig` — Test with `dns example.com` + `netpoll`, and verify a cache hit on the second query
- [ ] Shell command integration — Add and verify commands one by one (`netpoll`, `arp`, `udpsend`, `tcpconnect`, `tcpsend`, `tcprecv`, `tcpclose`, `tcpstat`, `dns`, `httpget` done)
- [x] `src/main.zig` — Add initialization calls (net/eth/arp_cache/ipv4/icmp/udp/tcp/dns wired)
