# MerlionOS-Zig TCP/IP 协议栈设计文档

> 本文档供 AI 代码生成工具（Codex 等）直接实现使用。
> 每个文件的接口、数据结构、函数签名、常量值均已给出，按文件逐一实现即可。
> 实现顺序严格按 Phase 编号进行，每个 Phase 内按文件顺序实现。

## 目录

1. [设计原则与约束](#1-设计原则与约束)
2. [Phase 7a: 网络基础设施](#2-phase-7a-网络基础设施)
3. [Phase 7b: 以太网帧分发](#3-phase-7b-以太网帧分发)
4. [Phase 7c: ARP 缓存表](#4-phase-7c-arp-缓存表)
5. [Phase 7d: IPv4 层](#5-phase-7d-ipv4-层)
6. [Phase 7e: UDP](#6-phase-7e-udp)
7. [Phase 7f: TCP](#7-phase-7f-tcp)
8. [Phase 7g: DNS 客户端](#8-phase-7g-dns-客户端)
9. [Phase 7h: Shell 命令集成](#9-phase-7h-shell-命令集成)
10. [集成与初始化顺序](#10-集成与初始化顺序)
11. [QEMU 测试方法](#11-qemu-测试方法)

---

## 1. 设计原则与约束

### 1.1 设计目标

- 在现有 e1000 poll-based 驱动之上构建完整的 IPv4/UDP/TCP 协议栈
- 保持 MerlionOS-Zig 的风格：无外部依赖、显式分配器、freestanding Zig 0.15
- 所有网络处理仍基于 polling（非中断驱动），由 shell 命令或定时器触发
- 提供类 socket 的简洁 API，供 shell 命令和未来用户态程序使用

### 1.2 架构总览

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
│  arp_cache.zig │  icmp.zig (已有,小改)        │
├──────────────┴───────────────────────────────┤
│  eth.zig — Ethernet frame dispatch            │
├──────────────────────────────────────────────┤
│  net.zig — 公共类型 & 工具函数                 │
├──────────────────────────────────────────────┤
│  e1000.zig — NIC 驱动 (已有,不改)             │
└──────────────────────────────────────────────┘
```

### 1.3 新增文件列表

```
src/
├── net.zig          # 公共网络类型、大端序工具、PacketBuffer
├── eth.zig          # Ethernet 帧收发与 EtherType 分发
├── arp_cache.zig    # ARP 缓存表（替代 arp.zig 的单条记录）
├── ipv4.zig         # IPv4 收发、路由、分片（仅收端重组）
├── udp.zig          # UDP 协议
├── tcp.zig          # TCP 状态机
├── socket.zig       # 统一 Socket API
└── dns.zig          # DNS 客户端（UDP-based）
```

### 1.4 对已有文件的修改

| 文件 | 修改内容 |
|------|---------|
| `src/arp.zig` | 内部改用 `arp_cache.zig`，公共接口不变，`sendRequest` 收到 reply 后写入缓存 |
| `src/icmp.zig` | 内部改用 `ipv4.zig` 构建/解析 IP 头，公共接口不变 |
| `src/main.zig` | 在 `e1000.init()` 之后调用 `net.init()`, `eth.init()`, `arp_cache.init()`, `ipv4.init()`, `udp.init()`, `tcp.init()`, `dns.init()` |
| `src/shell_cmds.zig` | 新增 `udpsend`, `udplisten`, `tcpconnect`, `tcpclose`, `dns`, `netpoll`, `ifconfig` 命令 |

### 1.5 Zig 0.15 注意事项

所有新代码必须遵守 `docs/DESIGN.md` §1.4 的语法要求。额外注意：

```zig
// packed struct 用于网络协议头解析
const IpHeader = packed struct {
    // 注意：x86 是小端，网络是大端，必须手动转换
    // packed struct 按声明顺序排列比特位
};

// 不用 packed struct 解析协议头。用 offset + 手动读取大端字段。
// 原因：Zig packed struct 的位布局依赖编译器实现，跨平台不可靠。
// 已有代码（arp.zig, icmp.zig）均使用 offset + readBe16 方式，保持一致。
```

---

## 2. Phase 7a: 网络基础设施

### 2.1 src/net.zig — 公共网络类型与工具

本文件提供所有网络模块共享的类型定义和工具函数。

#### 常量

```zig
// 以太网
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

// 协议号
pub const IPPROTO_ICMP: u8 = 1;
pub const IPPROTO_TCP: u8 = 6;
pub const IPPROTO_UDP: u8 = 17;

// 广播/零地址
pub const BROADCAST_MAC: [6]u8 = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
pub const ZERO_MAC: [6]u8 = .{ 0, 0, 0, 0, 0, 0 };
pub const ZERO_IP: Ipv4Addr = .{ 0, 0, 0, 0 };

// QEMU 默认网络配置
pub const DEFAULT_LOCAL_IP: Ipv4Addr = .{ 10, 0, 2, 15 };
pub const DEFAULT_GATEWAY_IP: Ipv4Addr = .{ 10, 0, 2, 2 };
pub const DEFAULT_SUBNET_MASK: Ipv4Addr = .{ 255, 255, 255, 0 };
pub const DEFAULT_DNS_SERVER: Ipv4Addr = .{ 10, 0, 2, 3 };
```

#### 类型

```zig
pub const Ipv4Addr = [4]u8;
pub const MacAddr = [6]u8;

/// 网络配置（全局单例）
pub const NetConfig = struct {
    local_ip: Ipv4Addr,
    gateway_ip: Ipv4Addr,
    subnet_mask: Ipv4Addr,
    dns_server: Ipv4Addr,
    local_mac: MacAddr,
    mac_valid: bool,
};

/// 收到的包的元信息，从 eth.zig 传递给上层
pub const RxPacketMeta = struct {
    frame: []const u8,       // 完整以太网帧
    payload: []const u8,     // 去掉以太网头后的载荷
    src_mac: MacAddr,
    dst_mac: MacAddr,
    ethertype: u16,
};
```

#### 全局状态

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

#### 公共函数

```zig
/// 初始化：从 e1000 读取 MAC 地址
pub fn init() void;

/// 获取当前网络配置（只读）
pub fn getConfig() *const NetConfig;

/// 设置本机 IP（供 ifconfig 命令使用）
pub fn setLocalIp(ip: Ipv4Addr) void;

/// 设置网关 IP
pub fn setGatewayIp(ip: Ipv4Addr) void;

/// 设置 DNS 服务器
pub fn setDnsServer(ip: Ipv4Addr) void;
```

#### 工具函数

```zig
/// 大端序读写（统一替代各模块的 readBe16/writeBe16）
pub fn readBe16(buf: []const u8, offset: usize) u16;
pub fn readBe32(buf: []const u8, offset: usize) u32;
pub fn writeBe16(buf: []u8, offset: usize, value: u16) void;
pub fn writeBe32(buf: []u8, offset: usize, value: u32) void;

/// Internet checksum（RFC 1071）
/// 可用于 IPv4 头、ICMP、UDP、TCP 校验和
/// data: 待校验的字节切片
/// 返回值：校验和（网络字节序），对已有数据验证时结果应为 0
pub fn internetChecksum(data: []const u8) u16;

/// 带伪头的 checksum（用于 UDP/TCP）
/// pseudo_header 字段：src_ip, dst_ip, zero, protocol, length
/// 先累加伪头，再累加 data
pub fn pseudoHeaderChecksum(
    src_ip: Ipv4Addr,
    dst_ip: Ipv4Addr,
    protocol: u8,
    data: []const u8,
) u16;

/// IPv4 地址比较
pub fn ipEqual(a: Ipv4Addr, b: Ipv4Addr) bool;

/// MAC 地址比较
pub fn macEqual(a: MacAddr, b: MacAddr) bool;

/// 检查 IP 是否在同一子网
pub fn sameSubnet(a: Ipv4Addr, b: Ipv4Addr, mask: Ipv4Addr) bool;

/// IPv4 地址格式化为 "a.b.c.d" 写入 buffer，返回写入的切片
pub fn formatIp(ip: Ipv4Addr, buf: []u8) []const u8;

/// MAC 地址格式化为 "aa:bb:cc:dd:ee:ff"
pub fn formatMac(mac: MacAddr, buf: []u8) []const u8;
```

#### init() 实现逻辑

```
1. 调用 e1000.detected()
2. 如果检测到 NIC 且 mac_valid，复制 MAC 到 config
3. 设置 config.mac_valid = true
```

---

## 3. Phase 7b: 以太网帧分发

### 3.1 src/eth.zig — Ethernet 帧收发

eth.zig 是网络栈的核心分发层。它从 e1000 poll 收包，按 EtherType 分发给 ARP / IPv4 处理器；发包时负责添加以太网头并调用 e1000.transmit。

#### 类型

```zig
/// 帧发送状态，映射 e1000.TxStatus
pub const TxStatus = enum {
    sent,
    no_nic,
    no_mac,
    tx_not_ready,
    tx_frame_too_large,
    tx_descriptor_busy,
    tx_timeout,
};

/// 一次 poll 的结果
pub const PollResult = enum {
    handled_arp,
    handled_ipv4,
    ignored,
    no_packet,
    rx_not_ready,
    rx_error,
};

/// 收包统计
pub const Stats = struct {
    frames_received: u64,
    frames_sent: u64,
    arp_received: u64,
    ipv4_received: u64,
    unknown_received: u64,
    errors: u64,
};
```

#### 全局状态

```zig
var stats: Stats = zeroed Stats;
```

#### 公共函数

```zig
/// 初始化（重置统计计数器）
pub fn init() void;

/// Poll 一个收到的以太网帧并分发
/// 调用 e1000.pollReceive()，解析 EtherType：
///   - 0x0806 (ARP)  → arp_cache.handleRx(meta)
///   - 0x0800 (IPv4) → ipv4.handleRx(meta)
///   - 其他          → 忽略
/// 返回 PollResult 告知调用者发生了什么
pub fn poll() PollResult;

/// 多次 poll 直到无包可收（最多 max_iterations 次）
/// 返回实际处理的帧数
pub fn pollAll(max_iterations: usize) usize;

/// 发送以太网帧
/// 自动填充 src MAC（从 net.getConfig()），调用者提供 dst_mac、ethertype 和 payload
/// payload 长度不得超过 ETH_MTU (1500)
/// 内部构建完整帧 [dst_mac(6) | src_mac(6) | ethertype(2) | payload]
/// 然后调用 e1000.transmit()
pub fn send(dst_mac: net.MacAddr, ethertype: u16, payload: []const u8) TxStatus;

/// 获取统计信息
pub fn getStats() Stats;
```

#### poll() 内部逻辑

```
1. rx_status = e1000.pollReceive()
2. 如果 rx_status != .received → 返回对应的 PollResult
3. frame = e1000.lastRxFrame()
4. 如果 frame.len < ETH_HEADER_LEN → stats.errors += 1, 返回 .ignored
5. 解析 src_mac = frame[6..12], dst_mac = frame[0..6], ethertype = readBe16(frame, 12)
6. 构建 RxPacketMeta { .frame = frame, .payload = frame[14..], .src_mac, .dst_mac, .ethertype }
7. switch (ethertype):
     ETHERTYPE_ARP  → arp_cache.handleRx(meta), stats.arp_received += 1, return .handled_arp
     ETHERTYPE_IPV4 → ipv4.handleRx(meta), stats.ipv4_received += 1, return .handled_ipv4
     else           → stats.unknown_received += 1, return .ignored
8. stats.frames_received += 1
```

#### send() 内部逻辑

```
1. 检查 net.getConfig().mac_valid，不可用则返回 .no_mac
2. 构建帧缓冲区 var frame: [net.ETH_FRAME_MAX]u8
3. @memcpy(frame[0..6], dst_mac)
4. @memcpy(frame[6..12], config.local_mac)
5. writeBe16(frame, 12, ethertype)
6. @memcpy(frame[14..14+payload.len], payload)
7. total_len = 14 + payload.len，如果 < 60 则补零到 60（最小帧长）
8. e1000.transmit(frame[0..total_len]) → 映射为 TxStatus
9. stats.frames_sent += 1
```

---

## 4. Phase 7c: ARP 缓存表

### 4.1 src/arp_cache.zig — ARP 缓存

替代 arp.zig 中的单条记录存储。维护一个固定大小的 ARP 表，支持超时和主动查询。

#### 常量

```zig
const MAX_ENTRIES: usize = 16;
const ENTRY_TIMEOUT_TICKS: u64 = 6000; // 60秒 @ 100Hz PIT
const ARP_RETRY_TICKS: u64 = 100;      // 1秒重试间隔

// ARP 协议常量
const ARP_HTYPE_ETHERNET: u16 = 0x0001;
const ARP_PTYPE_IPV4: u16 = 0x0800;
const ARP_HLEN: u8 = 6;
const ARP_PLEN: u8 = 4;
const ARP_OPER_REQUEST: u16 = 1;
const ARP_OPER_REPLY: u16 = 2;
const ARP_PACKET_LEN: usize = 28;  // 不含以太网头
```

#### 类型

```zig
pub const EntryState = enum {
    free,
    pending,    // 已发送 request，等待 reply
    resolved,   // 已收到 reply，MAC 已知
};

pub const Entry = struct {
    state: EntryState,
    ip: net.Ipv4Addr,
    mac: net.MacAddr,
    timestamp: u64,     // 最后更新时的 PIT tick
    retries: u8,
};

pub const LookupResult = enum {
    found,
    pending,
    not_found,
};
```

#### 全局状态

```zig
var table: [MAX_ENTRIES]Entry = [_]Entry{emptyEntry()} ** MAX_ENTRIES;
var stats: struct {
    requests_sent: u64,
    replies_received: u64,
    lookups: u64,
    misses: u64,
} = .{ .requests_sent = 0, .replies_received = 0, .lookups = 0, .misses = 0 };
```

#### 公共函数

```zig
/// 初始化缓存表
pub fn init() void;

/// 查找 IP 对应的 MAC 地址
/// 返回值：LookupResult
/// 如果 found，mac_out 被填充
/// 如果 not_found，自动发送一个 ARP request 并在表中创建 pending 条目
pub fn lookup(ip: net.Ipv4Addr, mac_out: *net.MacAddr) LookupResult;

/// 处理收到的 ARP 帧（由 eth.zig 调用）
/// 解析 ARP reply → 更新/插入缓存条目
/// 解析 ARP request（目标是本机 IP）→ 发送 ARP reply
pub fn handleRx(meta: net.RxPacketMeta) void;

/// 定时维护（由 netpoll 或 PIT tick 调用）
/// - 清除超时条目
/// - 重发 pending 条目的 ARP request
pub fn tick() void;

/// 获取缓存表快照（供 shell arp 命令显示）
pub fn getTable() []const Entry;

/// 获取统计
pub fn getStats() @TypeOf(stats);

/// 手动添加静态条目（供测试）
pub fn addStatic(ip: net.Ipv4Addr, mac: net.MacAddr) void;

/// 清空缓存
pub fn flush() void;
```

#### handleRx() 内部逻辑

```
1. payload = meta.payload
2. 验证长度 >= ARP_PACKET_LEN
3. 验证 htype == ETHERNET, ptype == IPV4, hlen == 6, plen == 4
4. 读取 oper, sender_mac(payload[8..14]), sender_ip(payload[14..18]),
   target_mac(payload[18..24]), target_ip(payload[24..28])
5. 如果 oper == REPLY:
   a. 在表中查找 sender_ip 的条目
   b. 如果找到 → 更新 mac, state = .resolved, timestamp = pit.ticks()
   c. 如果未找到 → 插入新条目（替换最老的 free 或最老的 resolved）
   d. stats.replies_received += 1
6. 如果 oper == REQUEST 且 target_ip == 本机 IP:
   a. 构建 ARP reply（swap sender/target, 填入本机 MAC）
   b. 调用 eth.send(sender_mac, ETHERTYPE_ARP, reply_payload)
   c. 同时更新/插入 sender_ip → sender_mac 到缓存
```

#### lookup() 内部逻辑

```
1. stats.lookups += 1
2. 遍历 table，找到 ip 匹配且 state == .resolved 的条目
3. 如果找到 → 复制 mac 到 mac_out，返回 .found
4. 遍历 table，找到 ip 匹配且 state == .pending 的条目
5. 如果找到 → 返回 .pending
6. stats.misses += 1
7. 发送 ARP request: 构建 ARP request payload，调用 eth.send(BROADCAST_MAC, ETHERTYPE_ARP, ...)
8. 在表中插入 pending 条目
9. stats.requests_sent += 1
10. 返回 .not_found
```

#### 发送 ARP request 帧构建

```
payload 共 28 字节:
  [0..2]   htype = 0x0001
  [2..4]   ptype = 0x0800
  [4]      hlen  = 6
  [5]      plen  = 4
  [6..8]   oper  = 0x0001 (request)
  [8..14]  sender_mac = 本机 MAC
  [14..18] sender_ip  = 本机 IP
  [18..24] target_mac = 00:00:00:00:00:00
  [24..28] target_ip  = 目标 IP
```

### 4.2 对 src/arp.zig 的修改

保持 `arp.zig` 的所有公共函数签名不变，内部改为调用 `arp_cache`：

```zig
// arp.zig 修改后
const arp_cache = @import("arp_cache.zig");

pub fn sendRequest(target_ip: Ipv4, sender_ip: Ipv4) SendStatus {
    // 保持原有逻辑，但同时在 arp_cache 中创建 pending 条目
    // ... 原有帧构建和发送逻辑不变 ...
    // 新增：
    var mac_out: [6]u8 = undefined;
    _ = arp_cache.lookup(target_ip, &mac_out); // 触发缓存条目创建
}

pub fn pollReply() PollStatus {
    // 保持原有逻辑，但 reply 解析后写入 arp_cache
    // ... 原有逻辑 ...
    // 新增：在 parseReply 成功时
    // arp_cache.addStatic(reply_ip, reply_mac);
}
```

> 注意：这是渐进式改造。旧的 shell 命令 (arpreq/arppoll) 继续工作。
> 新的网络栈（ipv4/udp/tcp）只使用 arp_cache.lookup()。

---

## 5. Phase 7d: IPv4 层

### 5.1 src/ipv4.zig — IPv4 收发与路由

#### 常量

```zig
const IPV4_VERSION_IHL: u8 = 0x45;   // version=4, IHL=5 (20 bytes)
const IPV4_HEADER_LEN: usize = 20;
const IPV4_FLAG_DF: u16 = 0x4000;    // Don't Fragment
const IPV4_FLAG_MF: u16 = 0x2000;    // More Fragments
const IPV4_FRAG_OFFSET_MASK: u16 = 0x1FFF;

// IPv4 头部字段偏移
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

#### 类型

```zig
/// 收到的 IPv4 包的解析结果
pub const RxIpPacket = struct {
    src_ip: net.Ipv4Addr,
    dst_ip: net.Ipv4Addr,
    protocol: u8,
    ttl: u8,
    payload: []const u8,    // IP 载荷（不含 IP 头）
    header: []const u8,     // IP 头部（含选项）
};

/// 发送状态
pub const SendStatus = enum {
    sent,
    no_route,          // 无法确定下一跳
    arp_pending,       // ARP 未解析完，包被丢弃（调用者应稍后重试）
    frame_too_large,   // 超过 MTU
    tx_error,          // e1000 发送失败
};

/// 协议处理器回调类型
/// 上层协议（UDP/TCP/ICMP）注册自己的处理函数
pub const ProtocolHandler = *const fn (packet: RxIpPacket) void;

/// 路由条目
pub const Route = struct {
    dest: net.Ipv4Addr,     // 目标网络
    mask: net.Ipv4Addr,     // 子网掩码
    gateway: net.Ipv4Addr,  // 下一跳（ZERO_IP 表示直连）
};

/// 统计信息
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

#### 全局状态

```zig
const MAX_PROTOCOL_HANDLERS: usize = 8;

var handlers: [MAX_PROTOCOL_HANDLERS]struct {
    protocol: u8,
    handler: ?ProtocolHandler,
} = [_]@TypeOf(handlers[0]){.{ .protocol = 0, .handler = null }} ** MAX_PROTOCOL_HANDLERS;

var next_ident: u16 = 1;  // IP identification 自增
var stats: Stats = zeroed Stats;
```

#### 公共函数

```zig
/// 初始化
pub fn init() void;

/// 注册协议处理器（ICMP=1, TCP=6, UDP=17）
pub fn registerHandler(protocol: u8, handler: ProtocolHandler) void;

/// 处理收到的 IPv4 帧（由 eth.zig 调用）
pub fn handleRx(meta: net.RxPacketMeta) void;

/// 发送 IPv4 包
/// protocol: IPPROTO_ICMP / IPPROTO_UDP / IPPROTO_TCP
/// dst_ip: 目标 IP
/// payload: IP 载荷（不含 IP 头）
/// 自动处理：构建 IP 头、计算校验和、路由查找、ARP 解析、eth.send()
pub fn send(protocol: u8, dst_ip: net.Ipv4Addr, payload: []const u8) SendStatus;

/// 发送时指定 src_ip（用于特殊场景如 DHCP）
pub fn sendFrom(protocol: u8, src_ip: net.Ipv4Addr, dst_ip: net.Ipv4Addr, payload: []const u8) SendStatus;

/// 获取统计
pub fn getStats() Stats;
```

#### handleRx() 内部逻辑

```
1. data = meta.payload
2. 如果 data.len < IPV4_HEADER_LEN → return
3. version_ihl = data[OFF_VERSION_IHL]
4. version = version_ihl >> 4, 如果 != 4 → stats.bad_version += 1, return
5. ihl = (version_ihl & 0x0f) * 4, 如果 ihl < 20 → return
6. total_len = readBe16(data, OFF_TOTAL_LEN)
7. 如果 data.len < total_len → return (截断包)
8. 验证 IP 头校验和: internetChecksum(data[0..ihl]) != 0 → stats.bad_checksum += 1, return
9. flags_frag = readBe16(data, OFF_FLAGS_FRAG)
10. 如果有分片 (offset != 0 或 MF 位) → stats.fragmented_dropped += 1, return
    （MVP 不支持分片重组，直接丢弃）
11. protocol = data[OFF_PROTOCOL]
12. src_ip = data[OFF_SRC_IP..][0..4].*
13. dst_ip = data[OFF_DST_IP..][0..4].*
14. 如果 dst_ip != 本机 IP 且 dst_ip != 255.255.255.255 → return（不是发给我的）
15. 构建 RxIpPacket { src_ip, dst_ip, protocol, ttl, payload = data[ihl..total_len], header = data[0..ihl] }
16. 查找 handlers 中 protocol 匹配的 handler
17. 如果找到 → handler(packet), stats.packets_received += 1
18. 否则 → stats.no_handler += 1
```

#### send() 内部逻辑

```
1. src_ip = net.getConfig().local_ip
2. 调用 sendFrom(protocol, src_ip, dst_ip, payload)
```

#### sendFrom() 内部逻辑

```
1. 如果 payload.len > ETH_MTU - IPV4_HEADER_LEN → return .frame_too_large
2. 确定下一跳 IP:
   如果 sameSubnet(dst_ip, src_ip, config.subnet_mask) → next_hop = dst_ip
   否则 → next_hop = config.gateway_ip
   如果 next_hop == ZERO_IP → return .no_route
3. ARP 查找: arp_cache.lookup(next_hop, &dst_mac)
   如果 .pending 或 .not_found → return .arp_pending
4. 构建 IP 头 (20 bytes):
   [0]      = 0x45 (v4, IHL=5)
   [1]      = 0x00 (TOS)
   [2..4]   = total_len = 20 + payload.len (大端)
   [4..6]   = next_ident (大端), next_ident += 1
   [6..8]   = IPV4_FLAG_DF (Don't Fragment)
   [8]      = DEFAULT_TTL (64)
   [9]      = protocol
   [10..12] = 0x0000 (checksum 先填零)
   [12..16] = src_ip
   [16..20] = dst_ip
   计算 checksum → 写入 [10..12]
5. 构建完整 IP 包: var packet: [ETH_MTU]u8
   @memcpy(packet[0..20], ip_header)
   @memcpy(packet[20..20+payload.len], payload)
6. eth.send(dst_mac, ETHERTYPE_IPV4, packet[0..20+payload.len])
7. 映射 eth.TxStatus → SendStatus, stats.packets_sent += 1
```

---

## 6. Phase 7e: UDP

### 6.1 src/udp.zig — UDP 协议

#### 常量

```zig
const UDP_HEADER_LEN: usize = 8;
const MAX_BINDINGS: usize = 8;

// UDP 头部字段偏移
const OFF_SRC_PORT: usize = 0;
const OFF_DST_PORT: usize = 2;
const OFF_LENGTH: usize = 4;
const OFF_CHECKSUM: usize = 6;
```

#### 类型

```zig
/// 收到的 UDP 数据报
pub const RxDatagram = struct {
    src_ip: net.Ipv4Addr,
    dst_ip: net.Ipv4Addr,
    src_port: u16,
    dst_port: u16,
    data: []const u8,
};

/// 端口绑定的回调类型
pub const DatagramHandler = *const fn (dgram: RxDatagram) void;

/// 发送状态
pub const SendStatus = enum {
    sent,
    payload_too_large,
    ip_error,
};

/// 统计
pub const Stats = struct {
    datagrams_sent: u64,
    datagrams_received: u64,
    bad_checksum: u64,
    no_binding: u64,
};
```

#### 全局状态

```zig
var bindings: [MAX_BINDINGS]struct {
    port: u16,
    handler: ?DatagramHandler,
} = [_]@TypeOf(bindings[0]){.{ .port = 0, .handler = null }} ** MAX_BINDINGS;

var stats: Stats = zeroed Stats;
```

#### 公共函数

```zig
/// 初始化，注册到 ipv4 作为 protocol=17 的处理器
pub fn init() void;

/// 绑定端口，注册回调
/// 返回 true 成功，false 表示 bindings 已满
pub fn bind(port: u16, handler: DatagramHandler) bool;

/// 解绑端口
pub fn unbind(port: u16) void;

/// 发送 UDP 数据报
/// src_port: 源端口
/// dst_ip: 目标 IP
/// dst_port: 目标端口
/// data: 载荷数据
pub fn send(src_port: u16, dst_ip: net.Ipv4Addr, dst_port: u16, data: []const u8) SendStatus;

/// 处理收到的 IPv4 包（由 ipv4 注册的回调）
/// 不需要公开，但实现时注册为 ipv4.registerHandler(IPPROTO_UDP, handleRx)
fn handleRx(packet: ipv4.RxIpPacket) void;

/// 获取统计
pub fn getStats() Stats;
```

#### handleRx() 内部逻辑

```
1. data = packet.payload
2. 如果 data.len < UDP_HEADER_LEN → return
3. src_port = readBe16(data, OFF_SRC_PORT)
4. dst_port = readBe16(data, OFF_DST_PORT)
5. udp_len = readBe16(data, OFF_LENGTH)
6. 如果 udp_len < 8 或 udp_len > data.len → return
7. checksum = readBe16(data, OFF_CHECKSUM)
8. 如果 checksum != 0:
   验证 pseudoHeaderChecksum(packet.src_ip, packet.dst_ip, IPPROTO_UDP, data[0..udp_len])
   如果 != 0 → stats.bad_checksum += 1, return
9. payload = data[UDP_HEADER_LEN..udp_len]
10. 在 bindings 中查找 dst_port 匹配的 handler
11. 如果找到 → handler(RxDatagram{ src_ip, dst_ip, src_port, dst_port, data = payload })
    stats.datagrams_received += 1
12. 否则 → stats.no_binding += 1
```

#### send() 内部逻辑

```
1. udp_len = UDP_HEADER_LEN + data.len
2. 如果 udp_len > net.ETH_MTU - net.IPV4_HEADER_MIN → return .payload_too_large
3. 构建 UDP 包: var packet: [net.ETH_MTU - net.IPV4_HEADER_MIN]u8
   writeBe16(packet, 0, src_port)
   writeBe16(packet, 2, dst_port)
   writeBe16(packet, 4, udp_len)
   writeBe16(packet, 6, 0)  // checksum 先填零
   @memcpy(packet[8..8+data.len], data)
4. 计算 UDP 校验和（含伪头）:
   cs = pseudoHeaderChecksum(local_ip, dst_ip, IPPROTO_UDP, packet[0..udp_len])
   如果 cs == 0 → cs = 0xFFFF（UDP 校验和 0 表示未使用）
   writeBe16(packet, 6, cs)
5. ipv4.send(IPPROTO_UDP, dst_ip, packet[0..udp_len])
6. 映射结果 → SendStatus, stats.datagrams_sent += 1
```

---

## 7. Phase 7f: TCP

### 7.1 src/tcp.zig — TCP 状态机

TCP 实现采用简化设计：
- 最多 4 个并发连接
- 仅支持主动连接（connect），不支持 listen/accept（MVP 不做服务器）
- 固定接收窗口 2048 字节
- 无拥塞控制（内核环境、低速场景）
- 超时重传使用简单固定计时器

#### 常量

```zig
const TCP_HEADER_MIN: usize = 20;
const MAX_CONNECTIONS: usize = 4;
const RX_BUFFER_SIZE: usize = 2048;
const TX_BUFFER_SIZE: usize = 2048;
const DEFAULT_WINDOW_SIZE: u16 = 2048;
const RETRANSMIT_TICKS: u64 = 300;    // 3 秒 @ 100Hz
const MAX_RETRANSMITS: u8 = 5;
const TIME_WAIT_TICKS: u64 = 1000;    // 10 秒
const CONNECT_TIMEOUT_TICKS: u64 = 500; // 5 秒

// TCP 头部字段偏移
const OFF_SRC_PORT: usize = 0;
const OFF_DST_PORT: usize = 2;
const OFF_SEQ_NUM: usize = 4;
const OFF_ACK_NUM: usize = 8;
const OFF_DATA_OFF_FLAGS: usize = 12;
const OFF_WINDOW: usize = 14;
const OFF_CHECKSUM: usize = 16;
const OFF_URGENT: usize = 18;

// TCP 标志位
const FLAG_FIN: u8 = 0x01;
const FLAG_SYN: u8 = 0x02;
const FLAG_RST: u8 = 0x04;
const FLAG_PSH: u8 = 0x08;
const FLAG_ACK: u8 = 0x10;
```

#### 类型

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

pub const ConnId = u8;  // 连接索引 0..MAX_CONNECTIONS-1

pub const Connection = struct {
    state: State,
    local_port: u16,
    remote_port: u16,
    remote_ip: net.Ipv4Addr,

    // 序号管理
    snd_una: u32,    // 最早未确认的序号
    snd_nxt: u32,    // 下一个要发送的序号
    rcv_nxt: u32,    // 期望收到的下一个序号
    iss: u32,        // 初始发送序号

    // 缓冲区
    rx_buf: [RX_BUFFER_SIZE]u8,
    rx_len: usize,   // 接收缓冲区中可读的数据量
    tx_buf: [TX_BUFFER_SIZE]u8,
    tx_len: usize,   // 发送缓冲区中待发送的数据量

    // 定时器
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

#### 全局状态

```zig
var connections: [MAX_CONNECTIONS]Connection = [_]Connection{emptyConnection()} ** MAX_CONNECTIONS;
var next_local_port: u16 = 49152;  // 临时端口起始
var stats: Stats = zeroed Stats;
```

#### 公共函数

```zig
/// 初始化，注册到 ipv4 作为 protocol=6 的处理器
pub fn init() void;

/// 主动连接到 remote_ip:remote_port
/// 返回 ConnId（连接句柄）和结果
/// 内部：分配连接槽、生成 ISS、发送 SYN、状态 → syn_sent
pub fn connect(remote_ip: net.Ipv4Addr, remote_port: u16, conn_out: *ConnId) ConnectResult;

/// 发送数据（将数据放入 TX 缓冲区，由 tick() 实际发送）
pub fn send(conn: ConnId, data: []const u8) SendResult;

/// 读取接收缓冲区中的数据
/// 返回可读数据的切片和当前连接状态
/// 读取后清空接收缓冲区
pub fn recv(conn: ConnId) RecvResult;

/// 主动关闭连接（发送 FIN）
pub fn close(conn: ConnId) void;

/// 定时器 tick（由 netpoll 调用）
/// - 处理重传
/// - 处理 TIME_WAIT 超时
/// - 发送 TX 缓冲区数据
pub fn tick() void;

/// 获取连接状态
pub fn getConnection(conn: ConnId) ?*const Connection;

/// 获取统计
pub fn getStats() Stats;

/// 处理收到的 IPv4 包（注册为 ipv4 handler）
fn handleRx(packet: ipv4.RxIpPacket) void;
```

#### connect() 内部逻辑

```
1. 查找 state == .closed 的空槽
2. 如果没有 → return .no_free_slot, conn_out 不写入
3. 分配临时端口: local_port = next_local_port, next_local_port += 1
4. 生成初始序号: iss = 简单的 pit.ticks() * 64000 + local_port
   （不做复杂的 ISN 生成，内核环境无安全顾虑）
5. 初始化连接:
   state = .syn_sent
   local_port, remote_port, remote_ip 填入
   snd_una = iss, snd_nxt = iss + 1, rcv_nxt = 0, iss = iss
   清空缓冲区
   retransmit_tick = pit.ticks(), retransmit_count = 0
6. 发送 SYN 段: sendSegment(conn, FLAG_SYN, iss, 0, &.{})
7. conn_out.* = slot_index
8. stats.connections_opened += 1
9. return .ok
```

#### handleRx() 内部逻辑

```
1. data = packet.payload
2. 如果 data.len < TCP_HEADER_MIN → return
3. src_port = readBe16(data, OFF_SRC_PORT)
4. dst_port = readBe16(data, OFF_DST_PORT)
5. 查找匹配的连接: remote_ip == packet.src_ip, remote_port == src_port, local_port == dst_port
6. 如果没找到 → 发送 RST, return
7. 验证校验和: pseudoHeaderChecksum(src_ip, dst_ip, IPPROTO_TCP, data)
   如果 != 0 → stats.bad_checksum += 1, return
8. 解析字段:
   seq = readBe32(data, OFF_SEQ_NUM)
   ack = readBe32(data, OFF_ACK_NUM)
   data_offset = (data[OFF_DATA_OFF_FLAGS] >> 4) * 4
   flags = data[OFF_DATA_OFF_FLAGS + 1] (低字节)
   payload = data[data_offset..]

9. 根据连接状态处理:

   .syn_sent:
     如果 flags 有 SYN + ACK:
       如果 ack == snd_nxt:
         rcv_nxt = seq + 1
         snd_una = ack
         state = .established
         发送 ACK 段
     如果 flags 有 RST:
       state = .closed

   .established:
     如果 flags 有 RST → state = .closed, return
     如果 flags 有 ACK → snd_una = max(snd_una, ack)
     如果 seq == rcv_nxt 且 payload.len > 0:
       复制 payload 到 rx_buf[rx_len..]（不超过 RX_BUFFER_SIZE）
       rx_len += copied_len
       rcv_nxt += copied_len
       发送 ACK 段
     如果 flags 有 FIN:
       rcv_nxt = seq + 1（如果有 payload 则 +payload.len+1）
       state = .close_wait
       发送 ACK 段

   .fin_wait_1:
     如果 flags 有 ACK 且 ack == snd_nxt:
       state = .fin_wait_2
     如果 flags 有 FIN:
       rcv_nxt = seq + 1
       如果 state == .fin_wait_2:
         state = .time_wait, time_wait_tick = pit.ticks()
       否则:
         state = .time_wait, time_wait_tick = pit.ticks()
       发送 ACK 段

   .fin_wait_2:
     如果 flags 有 FIN:
       rcv_nxt = seq + 1
       state = .time_wait, time_wait_tick = pit.ticks()
       发送 ACK 段

   .last_ack:
     如果 flags 有 ACK:
       state = .closed

   .time_wait:
     // 忽略或重发 ACK

10. stats.segments_received += 1
```

#### sendSegment() 内部函数

```zig
/// 构建并发送一个 TCP 段
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
4. 构建 TCP 头:
   writeBe16(segment, 0, conn.local_port)
   writeBe16(segment, 2, conn.remote_port)
   writeBe32(segment, 4, seq)
   writeBe32(segment, 8, ack)
   segment[12] = (5 << 4)  // data offset = 5 (20 bytes), 无选项
   segment[13] = flags
   writeBe16(segment, 14, DEFAULT_WINDOW_SIZE)
   writeBe16(segment, 16, 0)  // checksum 先填零
   writeBe16(segment, 18, 0)  // urgent pointer
5. 如果有 payload → @memcpy(segment[20..20+payload.len], payload)
6. 计算校验和:
   cs = pseudoHeaderChecksum(local_ip, conn.remote_ip, IPPROTO_TCP, segment[0..tcp_len])
   writeBe16(segment, 16, cs)
7. ipv4.send(IPPROTO_TCP, conn.remote_ip, segment[0..tcp_len])
8. stats.segments_sent += 1
```

#### tick() 内部逻辑

```
1. now = pit.ticks()
2. 遍历所有连接:
   .syn_sent:
     如果 now - retransmit_tick > RETRANSMIT_TICKS:
       如果 retransmit_count >= MAX_RETRANSMITS → state = .closed
       否则 → 重发 SYN, retransmit_count += 1, retransmit_tick = now
       stats.retransmits += 1

   .established:
     如果 tx_len > 0:
       发送 tx_buf[0..tx_len] 作为数据段
       （简化：一次发送整个缓冲区，不做分段）
       tx_len = 0

   .time_wait:
     如果 now - time_wait_tick > TIME_WAIT_TICKS:
       state = .closed
       stats.connections_closed += 1

   .close_wait:
     // 自动发送 FIN（简化：不等用户显式 close）
     sendSegment(i, FLAG_FIN | FLAG_ACK, snd_nxt, rcv_nxt, &.{})
     snd_nxt += 1
     state = .last_ack

   .last_ack:
     如果 now - retransmit_tick > RETRANSMIT_TICKS:
       如果 retransmit_count >= MAX_RETRANSMITS → state = .closed
       否则 → 重发 FIN+ACK, retransmit_count += 1
```

#### close() 内部逻辑

```
1. conn = &connections[conn]
2. 如果 state == .established:
   发送 FIN+ACK: sendSegment(conn, FLAG_FIN | FLAG_ACK, snd_nxt, rcv_nxt, &.{})
   snd_nxt += 1
   state = .fin_wait_1
   retransmit_tick = pit.ticks(), retransmit_count = 0
3. 如果 state == .close_wait:
   发送 FIN+ACK
   state = .last_ack
4. 其他状态 → state = .closed
```

---

## 8. Phase 7g: DNS 客户端

### 8.1 src/dns.zig — DNS 客户端

基于 UDP 的简单 DNS 解析器。仅支持 A 记录查询（IPv4 地址）。

#### 常量

```zig
const DNS_PORT: u16 = 53;
const DNS_LOCAL_PORT: u16 = 10053;
const DNS_HEADER_LEN: usize = 12;
const DNS_MAX_RESPONSE: usize = 512;
const DNS_QUERY_TIMEOUT_TICKS: u64 = 300;  // 3 秒
const MAX_CACHED_ENTRIES: usize = 8;

// DNS 头部字段
const DNS_FLAG_QR: u16 = 0x8000;       // Response
const DNS_FLAG_RD: u16 = 0x0100;       // Recursion Desired
const DNS_FLAG_RA: u16 = 0x0080;       // Recursion Available
const DNS_RCODE_MASK: u16 = 0x000F;
const DNS_TYPE_A: u16 = 1;
const DNS_CLASS_IN: u16 = 1;
```

#### 类型

```zig
pub const ResolveStatus = enum {
    resolved,
    pending,        // 查询已发送，等待响应
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

#### 全局状态

```zig
var cache: [MAX_CACHED_ENTRIES]CacheEntry = [_]CacheEntry{emptyCacheEntry()} ** MAX_CACHED_ENTRIES;
var next_query_id: u16 = 1;

// 最近一次查询的状态（简化：同一时刻只能有一个 pending 查询）
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

#### 公共函数

```zig
/// 初始化，绑定 UDP 端口 10053
pub fn init() void;

/// 解析域名
/// name: 如 "example.com"
/// ip_out: 解析成功时填充
/// 返回值:
///   .resolved → ip_out 有效（来自缓存或已完成的查询）
///   .pending  → 查询已发送，调用者需要通过 netpoll 等待然后再次调用
///   .timeout / .not_found / .server_error → 失败
pub fn resolve(name: []const u8, ip_out: *net.Ipv4Addr) ResolveStatus;

/// 检查 pending 查询是否超时（由 tick 调用）
pub fn tick() void;

/// 获取缓存内容
pub fn getCache() []const CacheEntry;

/// 清空缓存
pub fn flushCache() void;

/// 获取统计
pub fn getStats() Stats;
```

#### resolve() 内部逻辑

```
1. 如果 name.len > 63 → return .name_too_long
2. 先查缓存: 遍历 cache，找到 name 匹配且 valid 的条目
   如果找到 → ip_out.* = entry.ip, stats.cache_hits += 1, return .resolved
3. stats.cache_misses += 1
4. 如果 pending_query.active:
   如果 name 匹配当前 pending 查询:
     如果 status != .pending → ip_out.* = result_ip, return status
     否则 → return .pending（还在等）
   否则 → 取消当前查询（简化处理）
5. 构建 DNS 查询包:
   a. DNS 头 (12 bytes):
      query_id (2), flags=RD (2), qdcount=1 (2), ancount=0, nscount=0, arcount=0
   b. Question section:
      编码域名: "example.com" → [7]"example"[3]"com"[0]
      qtype = A (2), qclass = IN (2)
6. 通过 udp.send(DNS_LOCAL_PORT, dns_server, DNS_PORT, query_packet) 发送
7. 设置 pending_query: active=true, query_id, name, start_tick=pit.ticks(), status=.pending
8. stats.queries_sent += 1
9. return .pending
```

#### UDP 回调 handleDnsResponse()（注册在 UDP 端口 10053）

```
1. dgram: udp.RxDatagram
2. data = dgram.data
3. 如果 data.len < DNS_HEADER_LEN → return
4. response_id = readBe16(data, 0)
5. 如果 response_id != pending_query.query_id → return
6. flags = readBe16(data, 2)
7. 如果 (flags & DNS_FLAG_QR) == 0 → return（不是响应）
8. rcode = flags & DNS_RCODE_MASK
9. 如果 rcode == 3 → pending_query.status = .not_found, return
10. 如果 rcode != 0 → pending_query.status = .server_error, return
11. ancount = readBe16(data, 6)
12. 如果 ancount == 0 → pending_query.status = .not_found, return
13. 跳过 Question section（从 offset=12 开始，跳过域名和 4 字节 qtype/qclass）
14. 解析第一个 Answer RR:
    跳过 name（可能是压缩指针 0xC0xx）
    type = readBe16, class = readBe16, ttl = readBe32, rdlength = readBe16
    如果 type == A 且 class == IN 且 rdlength == 4:
      @memcpy(pending_query.result_ip[0..], rdata[0..4])
      pending_query.status = .resolved
      写入缓存
      stats.responses_received += 1
```

#### DNS 域名编码函数

```zig
/// 将 "example.com" 编码为 DNS 格式 [7]example[3]com[0]
/// 写入 buf，返回写入的字节数
fn encodeDnsName(name: []const u8, buf: []u8) usize;
```

```
1. 逐段处理，以 '.' 分隔
2. 每段前写入长度字节，然后写入段内容
3. 最后写入 0x00 终止
```

#### DNS 名称跳过函数

```zig
/// 跳过 DNS 响应中的域名（支持压缩指针）
/// 返回名称之后的偏移
fn skipDnsName(data: []const u8, offset: usize) usize;
```

```
1. 如果 data[offset] 的高两位 == 0xC0 → 压缩指针，返回 offset + 2
2. 否则逐段跳过直到遇到 0x00
```

---

## 9. Phase 7h: Shell 命令集成

### 9.1 src/shell_cmds.zig 新增命令

在 `commands` 数组中添加以下命令：

```zig
// 新增到 commands 数组
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

#### 新增 import

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
用法: ifconfig
      ifconfig ip 10.0.2.15
      ifconfig gw 10.0.2.2
      ifconfig dns 10.0.2.3

无参数时显示:
  eth0: MAC xx:xx:xx:xx:xx:xx
        IP  10.0.2.15
        GW  10.0.2.2
        DNS 10.0.2.3
        Mask 255.255.255.0
  ETH stats: rx=N tx=N
  IPv4 stats: rx=N tx=N bad_csum=N
  UDP stats: rx=N tx=N
  TCP stats: rx=N tx=N retrans=N

有参数时调用 net.setLocalIp / net.setGatewayIp / net.setDnsServer
```

#### cmdNetpoll

```
用法: netpoll [count]

默认 count=10
循环调用 eth.poll() count 次
同时调用 arp_cache.tick(), tcp.tick(), dns.tick()
显示: "netpoll: processed N frames"
```

> 这是 MVP 的核心命令。由于没有中断驱动收包，所有网络交互都需要用户手动 netpoll。
> 典型工作流: `arpreq` → `netpoll` → `dns example.com` → `netpoll` → `tcpconnect ...`

#### cmdArp

```
用法: arp

显示 ARP 缓存表:
  IP              MAC                State
  10.0.2.2        52:54:00:12:34:56  resolved
  10.0.2.3        52:54:00:12:34:57  pending

显示统计: requests=N replies=N lookups=N misses=N
```

#### cmdUdpsend

```
用法: udpsend <ip> <port> <message>
示例: udpsend 10.0.2.2 9999 "Hello from MerlionOS"

1. 解析 IP 和端口
2. udp.send(12345, dst_ip, dst_port, message_bytes)
3. 显示结果
```

#### cmdTcpconnect

```
用法: tcpconnect <ip> <port>
示例: tcpconnect 10.0.2.2 80

1. 解析 IP 和端口
2. tcp.connect(ip, port, &conn_id)
3. 显示: "TCP connecting to x.x.x.x:port (conn=N)..."
4. 循环 netpoll 直到连接建立或超时（最多 50 次，每次 poll 10 帧）
5. 显示: "TCP connected" 或 "TCP connection failed"
```

#### cmdTcpsend

```
用法: tcpsend <conn_id> <data>
示例: tcpsend 0 "GET / HTTP/1.0\r\nHost: example.com\r\n\r\n"

支持 \r\n 转义
```

#### cmdTcprecv

```
用法: tcprecv <conn_id>

1. 先 netpoll 几轮收数据
2. tcp.recv(conn_id)
3. 显示收到的数据（hex dump + ASCII）
```

#### cmdTcpclose

```
用法: tcpclose <conn_id>

1. tcp.close(conn_id)
2. netpoll 几轮等待关闭完成
3. 显示最终状态
```

#### cmdTcpstat

```
用法: tcpstat

显示所有连接:
  Conn  State        Local      Remote           SndUna    SndNxt    RcvNxt
  0     established  :49152     10.0.2.2:80      1000      1050      5000
  1     closed       -          -                -         -         -
```

#### cmdDns

```
用法: dns <domain>
示例: dns example.com

1. dns.resolve(name, &ip)
2. 如果 .pending → 循环 netpoll + dns.resolve 直到解析完成或超时
3. 显示: "example.com → 93.184.216.34" 或错误信息
```

#### cmdHttpget

```
用法: httpget <ip> <port> <path>
示例: httpget 10.0.2.2 80 /index.html

这是一个组合命令，演示完整的 TCP 工作流:
1. tcp.connect(ip, port)
2. netpoll 等待连接
3. tcp.send(conn, "GET <path> HTTP/1.0\r\nHost: <ip>\r\nConnection: close\r\n\r\n")
4. netpoll 循环接收
5. tcp.recv(conn) 显示响应
6. tcp.close(conn)
```

---

## 10. 集成与初始化顺序

### 10.1 src/main.zig 修改

在现有的 `e1000.init()` 和 `ai.init()` 之间插入网络栈初始化：

```zig
// 已有
e1000.init();
// ... e1000 日志 ...

// 新增：网络栈初始化
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

// 已有
ai.init();
```

### 10.2 初始化依赖链

```
e1000.init()           ← NIC 驱动
  ↓
net.init()             ← 读取 MAC，设置默认 IP
  ↓
eth.init()             ← 重置统计
  ↓
arp_cache.init()       ← 清空 ARP 表
  ↓
ipv4.init()            ← 注册协议处理器（预留槽位）
  ↓
udp.init()             ← 注册到 ipv4 (protocol=17)，绑定 DNS 端口
  ↓
tcp.init()             ← 注册到 ipv4 (protocol=6)
  ↓
dns.init()             ← 绑定 UDP 端口 10053
```

---

## 11. QEMU 测试方法

### 11.1 基本网络连通性

QEMU 默认使用 user-mode networking (SLIRP)：
- 虚拟网关: 10.0.2.2
- 虚拟 DNS: 10.0.2.3
- Guest IP: 10.0.2.15

```bash
# 启动（已有的 zig build run 即可，QEMU 默认启用网络）
zig build run
```

### 11.2 测试 ARP + 新缓存

```
MerlionOS> arpreq 10.0.2.2
MerlionOS> netpoll
MerlionOS> arp
```

### 11.3 测试 UDP

在宿主机启动 UDP echo 服务器：

```bash
# 终端1: 启动简单的 UDP echo
nc -u -l 9999
```

QEMU 需要端口转发才能让 guest 访问宿主机：

```bash
# 用 hostfwd 启动 QEMU（需要修改 build.zig 或 QEMU 参数）
# -netdev user,id=n0,hostfwd=udp::9999-:9999
```

但更简单的方法是向网关 10.0.2.2 发送（SLIRP 会处理）。

### 11.4 测试 TCP

SLIRP 支持 TCP 连接到宿主机（通过端口转发）或外部网络。

```bash
# 宿主机启动简单 HTTP 服务器
python3 -m http.server 8080
```

```bash
# QEMU 参数增加端口转发（修改 build.zig）
# -netdev user,id=n0,hostfwd=tcp::8080-:8080 不对
# 正确做法：guest 直接连 10.0.2.2:8080（SLIRP 的 host gateway）
```

在 shell 中：

```
MerlionOS> arpreq 10.0.2.2
MerlionOS> netpoll
MerlionOS> httpget 10.0.2.2 8080 /
```

### 11.5 测试 DNS

SLIRP 内置 DNS 转发（10.0.2.3）：

```
MerlionOS> dns example.com
MerlionOS> netpoll
MerlionOS> dns example.com    # 第二次应该从缓存返回
```

### 11.6 build.zig QEMU 参数建议

如果当前 QEMU 没有显式配置网络，确认 `-nic` 或 `-netdev` 参数正确。e1000 已经在工作（从 git log 看 ARP/ICMP 都通了），所以现有的 QEMU 配置应该足够。

如需宿主机端口转发，在 build.zig 的 QEMU 参数中添加：

```
-netdev user,id=net0,hostfwd=tcp::8080-:8080 -device e1000,netdev=net0
```

---

## 附录: 实现顺序检查清单

按此顺序实现，每完成一个文件即可编译测试：

- [x] `src/net.zig` — 编译即可验证，无运行时依赖
- [x] `src/eth.zig` — 编译后可在 shell 中用 `netpoll` 测试帧分发
- [x] `src/arp_cache.zig` — 用 `arpreq` + `netpoll` + `arp` 验证缓存
- [x] 修改 `src/arp.zig` — 确保旧命令仍工作
- [x] `src/ipv4.zig` — 用 `pingtest` + `netpoll` 验证（ICMP 走新的 IPv4 层）
- [x] 修改 `src/icmp.zig` — 改用 ipv4.zig，验证 ping 仍工作
- [x] `src/udp.zig` — 用 `udpsend` 测试
- [x] `src/tcp.zig` — 用 `tcpconnect` + `netpoll` 测试三次握手、发送、接收和关闭
- [x] `src/dns.zig` — 用 `dns example.com` + `netpoll` 测试，第二次查询验证缓存命中
- [ ] Shell 命令集成 — 逐个添加验证（已完成 `netpoll`, `arp`, `udpsend`, `tcpconnect`, `tcpsend`, `tcprecv`, `tcpclose`, `tcpstat`, `dns`, `httpget`）
- [x] `src/main.zig` — 添加初始化调用（已接入 net/eth/arp_cache/ipv4/icmp/udp/tcp/dns）
