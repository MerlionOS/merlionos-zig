# MerlionOS-Zig 网络栈阅读指南

> 本文是一篇写给开发者和学生的“网络从零讲起”导览。
> 它不是规范，规范请参考 [`docs/spec/DESIGN-TCPIP.md`](../spec/DESIGN-TCPIP.md)。
> 本文的作用是：在你打开源码之前，先让你心里有一张“为什么这样写”的地图。

---

## 1. 引言：为什么一个 OS 需要网络栈

一个只会读写磁盘、能显示字符、能调度进程的内核已经是一个“系统”了。
但只要它无法和外部世界通信，它就永远只是一台孤岛机器。
网络栈是把操作系统接入宇宙的那根线。

对一个教学级内核（比如 MerlionOS-Zig）而言，网络栈的意义尤其大：

- 它是一个“多层抽象能不能撑住”的试金石：链路层、网络层、传输层、应用层，
  每一层都要有正确的数据结构、错误处理、字节序和超时策略。
- 它强迫你面对 DMA、MMIO、volatile、内存屏障这些真实硬件细节。
- 它让 shell 能做 `ping`、`dns`、`tcpconnect` 这种让人兴奋的事。

MerlionOS-Zig 目前处于“刚学会说话”的阶段：
能把帧塞进网卡，能做 ARP 地址解析，能回答一次 ping。
再往后就是完整 IPv4 / UDP / TCP / DNS 栈——这就是
[`docs/spec/DESIGN-TCPIP.md`](../spec/DESIGN-TCPIP.md) 描绘的未来。

本篇教程按“数据在线上流动的顺序”逐层解释：从一根以太网线上的字节，
到一个能 `dns google.com` 的 shell 命令。每一节都会告诉你：

- 这层在网络里解决什么问题；
- 对应头部字段长什么样；
- MerlionOS-Zig 里哪个文件实现了它、或计划实现它。

---

## 2. 以太网帧：字节流是怎么被装起来的

### 2.1 什么是帧

物理层的网卡发给你的是比特流，但比特流本身没有“边界”。
以太网（Ethernet）这一层的职责就是：**把字节流切成有头有尾的帧**，
让接收方知道“这一包到哪里结束、下一包从哪里开始”。

一个最常见的以太网 II（DIX）帧长这样：

```
 0                   6                   12     14                          N
 +-------------------+-------------------+------+---------------------------+
 |   Dst MAC (6B)    |   Src MAC (6B)    |Type  |        Payload            |
 +-------------------+-------------------+------+---------------------------+
                                          2B          46 .. 1500 字节
```

- **Dst MAC / Src MAC**：6 字节的目的/源硬件地址。广播地址是
  `ff:ff:ff:ff:ff:ff`。
- **EtherType**：大端 16 位。常见值：
  - `0x0800` → IPv4（见 `src/net.zig` 中的 `ETHERTYPE_IPV4`）
  - `0x0806` → ARP（`ETHERTYPE_ARP`）
- **Payload**：载荷，长度在 46–1500 之间（低于 46 会被硬件或驱动填零补到 60 字节
  的最小帧长）。

以太网帧后面其实还有 4 字节 CRC（FCS），但这是硬件自动处理的，
软件层拿到的缓冲区里通常不包含它。MerlionOS-Zig 的 e1000 驱动也通过
`RCTL_SECRC` 位让网卡把 CRC 剥掉。

### 2.2 NIC 硬件视角：e1000、MMIO、DMA 环形队列

当我们说“驱动发包”时，我们实际在做一件听起来很魔幻的事：
**让 CPU 和网卡同时操作同一块物理内存**，而且两边互不阻塞。
做到这点的核心机制是 **DMA 环形描述符队列**。

来看 `src/e1000.zig`。开头这一堆常量其实就是 Intel 82540EM 数据手册的摘录：

```
REG_RDBAL / REG_RDBAH   -- RX 描述符环的物理基地址（低 32 / 高 32）
REG_RDLEN               -- RX 环的长度
REG_RDH / REG_RDT       -- RX 环的 Head / Tail 指针
REG_TDBAL ... REG_TDT   -- TX 同构的一套寄存器
```

这些寄存器在物理地址空间里（由 PCI BAR0 暴露），CPU 必须通过 MMIO 访问它们。
所以 `mapMmio()` 做的事情就是把 BAR0 指向的物理页映射到一个保留的高地址
（`0xFFFF_FFFF_C000_0000`），并且设置 **cache-disable + write-through**——
因为对硬件寄存器的访问必须立刻生效，不能被 CPU 缓存。

```
┌─────────────┐  PCI 配置空间告诉我们 BAR0 的物理地址
│    CPU      │─────────┐
└─────────────┘         │ MMIO (volatile u32 读写)
                        ▼
               ┌───────────────────┐
               │  e1000 寄存器组     │  控制 RX/TX 环
               └───────────────────┘
                        │
                        │ 总线主 DMA
                        ▼
          ┌──────────────────────────────┐
          │  RX 描述符环 (8 × 16 bytes)    │ ←─ RDH / RDT
          │  每个描述符指向一个 2KB 缓冲区   │
          └──────────────────────────────┘
```

**为什么是环形？** 因为收发是生产者-消费者关系：

- **RX 环**：网卡是生产者，软件是消费者。
  硬件把收到的帧 DMA 进 `rx_buffers[i]`，写好 `desc.status |= DD`（Descriptor Done），
  推进 `RDH`；软件轮询发现 `DD` 为 1 就读取、清零、推进 `RDT`。
- **TX 环**：软件是生产者，网卡是消费者。
  软件填好描述符，推进 `RDT`（在代码里是 `REG_TDT`），
  网卡发出去之后把 `DD` 置位并推进 `RDH`。

`pollReceiveInternal()` 和 `transmitInternal()` 里的核心逻辑就是这两段循环。
注意两处 `mfence` 内存屏障——没有它，编译器或 CPU 可能重排写入顺序，
导致网卡看到一个“描述符长度已经写好但地址还没写好”的中间态。

目前 MerlionOS-Zig 把 e1000 的**所有中断都屏蔽**了（`writeReg32(REG_IMC, 0xFFFF_FFFF)`），
原因见第 9 节“设计取舍”。

---

## 3. ARP：当你只知道 IP，你要怎么寄信？

### 3.1 为什么需要 ARP

以太网只懂 MAC 地址，而上层应用（ping、curl、浏览器）只说 IP。
中间必须有一个翻译器把 IPv4 地址翻译成 MAC——这就是
**ARP（Address Resolution Protocol）**。

想象你知道某人的身份证号（IP），但要把信投到他家邮箱（MAC），你得先问邻居：
“哪位的身份证号是 10.0.2.2？”这就是 ARP 请求。

### 3.2 ARP 报文结构

ARP 本身不跑在 IP 之上，它直接作为一个以太网 payload，EtherType 为 `0x0806`。
一帧 ARP 请求总长 42 字节：

```
Ethernet header (14)                    ARP payload (28)
┌───────────────────────────────┬───────────────────────────────────┐
│ dst=ff:ff:ff:ff:ff:ff  (广播)  │ htype=1 (Ethernet)                │
│ src=本机 MAC                   │ ptype=0x0800 (IPv4)               │
│ type=0x0806                   │ hlen=6  plen=4                    │
├───────────────────────────────┤ oper=1 (request) / 2 (reply)      │
│                               │ sha=本机 MAC                      │
│                               │ spa=本机 IP                        │
│                               │ tha=00:00:00:00:00:00 (请求时未知) │
│                               │ tpa=目标 IP                        │
└───────────────────────────────┴───────────────────────────────────┘
```

对照 `src/arp.zig` 里的 `buildRequest()`，每一行都能直接对上。
请求是**广播**的（dst MAC 填 `ff:ff:ff:ff:ff:ff`），因为问的人还不知道目标的 MAC；
回复是**单播**的，目标机器直接把自己的 MAC 填到 `sha`，IP 填到 `spa`，然后
`oper` 改成 2 发回来。

### 3.3 当前实现 vs 规划

`src/arp.zig` 是 MVP：它只记住最后一次 reply 的 MAC 地址（`stats.last_reply_mac`），
本质是个单条目缓存。

`docs/spec/DESIGN-TCPIP.md` 里规划的 `src/arp_cache.zig`（已经存在雏形）
会把它升级成一张真正的 ARP 缓存表：支持多条记录、老化（aging）、
以及“请求未完成时暂存数据包、reply 到达后 flush”的状态机。
这是做真正的 IPv4 发送所必须的——否则每次发送都要重新 ARP。

---

## 4. IPv4：分层抽象的第一次体现

### 4.1 网络层解决什么问题

以太网能把帧送到“同一张网线上的所有人”，但互联网是由无数个这样的局域网
拼接而成的。要跨子网通信，我们就需要一个**逻辑寻址**系统——IPv4——
以及一个“下一跳（next hop）”机制：**路由**。

### 4.2 IPv4 头

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|Version|  IHL  |    TOS        |          Total Length         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         Identification        |Flags|      Fragment Offset    |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|      TTL      |   Protocol    |         Header Checksum       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                    Source IP Address                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                  Destination IP Address                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

关键字段解读：

- **Version** = 4。
- **IHL** = 头部长度（以 4 字节为单位）。没有 options 的典型值是 5，也就是 20 字节。
- **Total Length** = 整个 IP 包（头 + 数据）的长度。
- **Identification / Flags / Fragment Offset**：分片相关。MerlionOS-Zig 计划
  **只在收端做重组**，发端永远不分片（所有上层协议自己保证不超过 MTU）。
- **TTL（Time To Live）**：每经过一跳减 1，到 0 就被丢弃。默认用 64（`IPV4_DEFAULT_TTL`）。
- **Protocol**：载荷类型。`1 = ICMP`、`6 = TCP`、`17 = UDP`，见 `src/net.zig` 里的
  `IPPROTO_*` 常量。
- **Header Checksum**：**只覆盖 IP 头**的 16 位反码和。计算时把 checksum 字段置 0，
  算完填回去。验证时把整个头（含 checksum）加起来应得 `0xffff` 再取反后为 0。

### 4.3 路由：直连还是网关？

一台机器要把包送到目标 IP 时，决策树是这样的：

```
   要发到 dst_ip
        │
        ▼
   dst_ip 与 local_ip 在同一子网？  (local_ip AND mask) == (dst_ip AND mask)
    ├── 是 ──► 直接 ARP 查 dst_ip 的 MAC，目的 MAC 就是它
    └── 否 ──► ARP 查网关 (gateway_ip) 的 MAC，目的 MAC 是网关的
```

`src/net.zig` 的 `sameSubnet()` 就是在做这个掩码比较。
默认配置里：`local_ip=10.0.2.15`，`mask=255.255.255.0`，`gateway=10.0.2.2`，
这是 QEMU 用户态网络（SLIRP）的固定拓扑。

### 4.4 为什么需要 Internet checksum

互联网早期的物理层并不总可靠，TCP/UDP/IP 各自都做了校验。
**Internet checksum** 是一个很便宜的算法：16 位块按大端做“反码加和”，末尾做 end-around carry，最后取反。
看 `src/net.zig::internetChecksum()` / `sumBytes()` / `finishChecksum()` 的实现，
寥寥几行，却覆盖了从 IP 头到 TCP 段的所有校验。

当前 `src/ipv4.zig` 已经实现了发送、接收、按协议号分发的框架，
ICMP 就是通过 `ipv4.registerHandler(IPPROTO_ICMP, ...)` 注册到这个分发器的。

---

## 5. ICMP：ping 是怎么工作的

### 5.1 封装关系

`ping` 的每一次“咚”都是一条 **ICMP Echo Request**，对方回一条
**ICMP Echo Reply**。它的完整封装是这样的：

```
┌──────────────────┬──────────────┬──────────────┬─────────────────┐
│  Ethernet (14B)  │  IPv4 (20B)  │  ICMP (8B)   │   Payload       │
│  type=0x0800     │  proto=1     │  type=8/0    │  "MerlionOS..." │
└──────────────────┴──────────────┴──────────────┴─────────────────┘
```

### 5.2 ICMP Echo 报文

```
 0                   1                   2                   3
 +-------+-------+---------------+---------------+---------------+
 | Type  | Code  |         Checksum              |
 +-------+-------+-------------------------------+
 |       Identifier              |   Sequence    |
 +-------------------------------+---------------+
 |                    Payload ...                |
 +-----------------------------------------------+
```

- `Type = 8, Code = 0`：Echo Request
- `Type = 0, Code = 0`：Echo Reply
- **Identifier**：发送方自定义标识（`src/icmp.zig` 里是固定值 `0x4d5a`，即 ASCII "MZ"），
  用来把 reply 匹配回是哪一次 ping。
- **Sequence**：每发一个请求递增，用来区分第几次 ping。
- **Checksum**：覆盖整个 ICMP 报文（头 + payload）的 Internet checksum。

`src/icmp.zig::buildEchoRequest()` 就是直接按这张图写的：
先把 checksum 字段置 0，填 type/code/identifier/sequence/payload，
最后算 checksum 回填到第 2–3 字节。

### 5.3 调用链

在 MerlionOS-Zig 里，一条 ping 经过的函数栈是：

```
shell: ping 10.0.2.2
  └── icmp.sendEchoRequest(target, source)
        └── ipv4.sendFrom(IPPROTO_ICMP, src, dst, packet)
              └── arp 查 dst 的 MAC（直连或网关）
              └── eth 封装以太网帧
                    └── e1000.transmit(frame)
                          └── 写 TX 描述符 + 推进 TDT
```

收包反过来：e1000 poll → eth 分发 → ipv4 按 proto 分发 → `icmp.handleRx()`
验证 checksum / type / identifier，更新 `stats.last_reply_sequence`。

---

## 6. UDP：最简单的传输层

### 6.1 无连接的意思

UDP 没有“连接”概念。你把一个数据报（datagram）扔出去，它可能到、可能不到、
可能顺序错乱、可能重复。UDP 的唯一贡献是：

1. **端口号**：在同一台机器上区分不同的应用。
2. **校验和**：验证数据完整性（可选但强烈建议开）。

### 6.2 UDP 头

```
 0              2              4              6              8
 +--------------+--------------+--------------+--------------+
 |  Source Port |  Dst Port    |    Length    |   Checksum   |
 +--------------+--------------+--------------+--------------+
 |                     Payload ...                           |
 +-----------------------------------------------------------+
```

一共 8 字节。`Length = 头 + payload`。

### 6.3 端口号为什么重要

一个 IP 地址标识一台主机。但一台主机上可能同时有 DNS 客户端（源端口随机）、
NTP 客户端（123）、HTTP 服务器（一般跑在 TCP 而不是 UDP，但结构一样）。
**(src_ip, src_port, dst_ip, dst_port) 这个四元组**就是一条“会话”的唯一标识。

在 MerlionOS-Zig 的规划里，`src/udp.zig` 会提供 `bind(port)` / `sendTo()` / `recvFrom()`
三个核心 API，给 DNS 客户端和未来的 shell 命令用。

### 6.4 伪头校验和

UDP 和 TCP 的 checksum 有个奇怪的地方：它不只覆盖自己的头和数据，
**还要包含一个“伪头”**：

```
 +----------------+----------------+
 |      Source IP Address          |
 +---------------------------------+
 |   Destination IP Address        |
 +--------+--------+---------------+
 |  zero  |protocol|   UDP length  |
 +--------+--------+---------------+
```

这是为了防止“包错投”——就算某个中间设备篡改了 IP 头的源/目的地址，
checksum 也会失配。`src/net.zig::pseudoHeaderChecksum()` 就是专门算这块的。
UDP 的 checksum = 伪头 + UDP 头 + payload 的 Internet checksum。

---

## 7. TCP：复杂度的爆炸点

### 7.1 为什么 TCP 这么难

UDP 是“把信扔进邮筒”，TCP 是“打电话”：

- 需要先拨号（建连接）
- 通话过程要保证对方确实听到了每一个字（ACK）
- 听不清要重说（重传）
- 对方耳朵听不过来要放慢语速（窗口、流控）
- 挂电话要双方都同意（4 次挥手）

TCP 头 20 字节起步，载荷之前还有好多字段：

```
 0                   1                   2                   3
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |        Source Port            |       Destination Port        |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                      Sequence Number                          |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                   Acknowledgment Number                       |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 | Offs| Rsv |U A P R S F |            Window                    |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |           Checksum            |         Urgent Pointer        |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 |                     Options (可变长)                          |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 7.2 三次握手与四次挥手

```
  Client                              Server
    │                                   │
    │──── SYN, seq=x ─────────────────►│  (CLOSED → SYN_SENT)
    │                                   │
    │◄──── SYN+ACK, seq=y, ack=x+1 ────│  (LISTEN → SYN_RCVD)
    │                                   │
    │──── ACK, ack=y+1 ───────────────►│  (SYN_SENT → ESTABLISHED)
    │                                   │       (SYN_RCVD → ESTABLISHED)
    │       ===== 数据传输 =====         │
    │                                   │
    │──── FIN, seq=m ─────────────────►│  (ESTABLISHED → FIN_WAIT_1)
    │◄──── ACK, ack=m+1 ──────────────│
    │◄──── FIN, seq=n ────────────────│
    │──── ACK, ack=n+1 ───────────────►│  (TIME_WAIT)
```

**Sequence / Acknowledgment Number** 是 TCP 的灵魂：
每一个字节都有一个编号。接收方回 ACK 时说的是
“我下一个期望收到的字节编号是 N”——这隐含地确认了 N 之前的所有字节。
这就是 TCP 能做重传的基础：如果对方一直没 ACK 到 N，我就重发 N 开始的数据。

**Window** 是流控——接收方告诉发送方“我还能接受 W 字节，别再发了”。

### 7.3 状态机

TCP 的完整状态机有 11 个状态，这是你必须亲手画一遍才真正理解的东西：

```
    CLOSED
      │ passive open
      ▼                                          ┌──► FIN_WAIT_1 ──► FIN_WAIT_2
    LISTEN ──recv SYN──► SYN_RCVD ──►            │             │          │
      ▲                     │        ESTABLISHED─┤           recv FIN    recv FIN
      │              send SYN+ACK        │       │             │          │
      │                                  │       └──► CLOSE_WAIT ──► LAST_ACK
      └───active open───► SYN_SENT ──────┘                                │
                            └─recv SYN+ACK, send ACK                      ▼
                                                                       CLOSED
```

规划中的 `src/tcp.zig` 会实现这张图的一个**简化子集**——具体简化到什么程度，
见下面第 9 节。

---

## 8. DNS：把名字变成 IP

### 8.1 为什么 DNS 通常跑在 UDP 上

DNS 查询小（一般一两个包）、延迟敏感、允许丢了重来。
这些特征完全匹配 UDP：无连接、开销小、不阻塞。
服务端口是 **53**。

### 8.2 DNS 报文结构

```
 ┌─────────────── Header (12 字节) ───────────────┐
 │ ID │ Flags │ QDCOUNT │ ANCOUNT │ NSCOUNT │ ARCOUNT │
 └────┴───────┴─────────┴─────────┴─────────┴─────────┘
 │                 Questions (QDCOUNT 条)              │
 │                 Answers   (ANCOUNT 条)              │
 │                 Authority (NSCOUNT 条)              │
 │                 Additional(ARCOUNT 条)              │
```

每个 Question 的域名以**长度-字节串**的形式编码：

```
   "www.google.com"
 → 3 'w' 'w' 'w' 6 'g' 'o' 'o' 'g' 'l' 'e' 3 'c' 'o' 'm' 0
```

### 8.3 DNS 压缩指针

早期 DNS 规范有个优化：如果同一个域名在一个响应里出现多次，第二次可以用一个
**指针**代替——两个字节，最高两位都是 1，剩下 14 位是偏移量。
比如 `0xC0 0x0C` 表示“从报文第 12 字节开始读域名”。
解析时要一边往前跳一边防止死循环（指针链长度必须限定）。

规划的 `src/dns.zig` 会实现：构造 Query、解析 Response、处理压缩指针、
返回第一条 A 记录。

---

## 9. 我们的设计取舍

一个“教学级”的栈不可能做到 Linux 水平，关键是讲清楚**为什么选择不做**某些事。

### 9.1 为什么 poll-based，而不是中断驱动

中断驱动的网络栈是生产系统的标配，但对教学来说代价很高：

- 需要稳定的 APIC/IOAPIC 配置
- 需要考虑中断上下文、下半部（bottom half）、软中断模型
- 调试时定时器中断和网卡中断混在一起，排障困难

MerlionOS-Zig 目前把 e1000 的所有中断都屏蔽了（`REG_IMC = 0xFFFF_FFFF`），
所有收包都靠 shell 里敲 `netpoll` 触发一次 `pollReceive()`。
这带来两个好处：

1. **确定性**：收包只发生在你按回车的那一刻，单步调试友好。
2. **栈简单**：没有并发、没有锁、没有中断上下文限制。

代价是：没人帮你 ACK TCP 段，只要你不敲命令就没人推进状态机。
以后可以加一个定时器驱动的 `netpoll_tick()` 来自动驱动，但核心仍然是 polling。

### 9.2 为什么 TCP 简化（无拥塞控制）

完整的 TCP 要做 Slow Start、Congestion Avoidance、Fast Retransmit、Fast Recovery、
SACK、Nagle、Delayed ACK——每一个都是一个 RFC。
MerlionOS-Zig 的 TCP 打算：

- **没有拥塞控制**：窗口固定，该发就发。在 QEMU SLIRP 里永远不会真正拥塞。
- **没有 Nagle**：每次 send 立刻发一个段。
- **超时重传**：有，但用固定超时而不是 Karn/RTT 估计。
- **状态机完整**：三次握手、四次挥手、RST 都要支持，否则和外界没法互操作。

教学价值在状态机，不在拥塞控制算法。后者值得单独再开一个项目。

### 9.3 为什么限制 4 个并发连接

没有动态分配的 socket 表就不需要考虑生命周期、泄漏、复用。
4 条连接足够同时做一次 DNS 查询、一次 HTTP 请求、留一条给 shell 命令实验，
剩一条 buffer。这是内核栈的常见取舍——OpenBSD 的早期网络栈也是静态表。
如果将来接上 heap 分配器，这个限制随时可以去掉。

### 9.4 为什么不做 IPv6、不做 IP 分片发送

- IPv6 头部更简单、更现代，但和现有 MAC/ARP 生态不搭。
  为了教学清晰只做 IPv4。
- 分片发送很少用到（上层协议自己保证不超过 MTU），但**收端重组**必须做，
  否则无法正确接收从真实网络进来的分片包。

---

## 10. 阅读路线图

推荐的源码阅读顺序：

1. **`src/e1000.zig`**
   先理解 DMA 环、MMIO、描述符状态位。这里没有协议，只有硬件。

2. **`src/net.zig`**
   公共类型、字节序、checksum 函数。所有上层都会用到。

3. **`src/arp.zig`**
   最小的一个“协议”。一共 156 行，读完你就理解“构造以太网帧 + 解析响应”的套路了。

4. **`src/arp_cache.zig`**
   在 `arp.zig` 的基础上看缓存表是怎么存放、怎么老化的。

5. **`src/eth.zig`**
   EtherType 分发：收进来的帧该交给 ARP 还是 IPv4？

6. **`src/ipv4.zig`**
   分层的第一次“真正”体现：IP 头构造、路由、协议号分发。
   读完这个你会发现 ICMP 只是注册了一个 handler 到这里。

7. **`src/icmp.zig`**
   176 行，一个完整的“ping 客户端”。看 `buildEchoRequest` 和 `handleRx` 如何呼应。

8. **`src/udp.zig`**
   上层的第一个“用户态风格 API”。

9. **`src/tcp.zig`**
   这里才是真正展示状态机和序号空间的地方。读之前先自己在纸上画一遍状态机。

10. **`src/dns.zig`**
    综合应用：UDP + 大端字节流 + 指针压缩。

11. **`src/socket.zig`**
    UDP/TCP/DNS 的统一上层 facade，shell 命令和未来用户态网络接口都应该优先从这里接入。

12. **`docs/spec/DESIGN-TCPIP.md`**
    所有新文件的接口、常量、数据结构定义都在这里。把它当 API reference 翻。

---

## 附录：QEMU 用户态网络拓扑

QEMU 默认的 user-mode（SLIRP）网络提供一个固定的虚拟以太网：

```
   ┌──────────────────────────┐
   │  MerlionOS-Zig guest     │   IP: 10.0.2.15
   │  (e1000 NIC)             │   MAC: QEMU 分配
   └───────────┬──────────────┘
               │
   ┌───────────▼──────────────┐
   │  SLIRP (in QEMU)         │   gateway: 10.0.2.2
   │  NAT / DHCP / DNS proxy  │   DNS:     10.0.2.3
   └───────────┬──────────────┘
               │
   ┌───────────▼──────────────┐
   │   Host 真实网络           │
   └──────────────────────────┘
```

所以你在 guest 里 ping `10.0.2.2`，得到的是 SLIRP 里一个虚拟 router 的回复；
ping `10.0.2.3` 得到的是 SLIRP 的 DNS proxy；ping 真正的公网 IP 则会通过
host 的 NAT 出去。这种可预测的固定拓扑非常适合写协议栈时做断言和回归测试。

---

祝玩得开心。当你的内核第一次打出 `echo reply seq=1 from 10.0.2.2` 时，
你会明白为什么有人愿意花一整个周末只为换来那一行日志。
