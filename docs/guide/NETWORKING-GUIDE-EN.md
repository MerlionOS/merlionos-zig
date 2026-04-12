# MerlionOS-Zig Networking Guide

> This is a "networking from the ground up" tour written for developers and students.
> It is not a specification — for that, see [`docs/spec/DESIGN-TCPIP.md`](../spec/DESIGN-TCPIP.md).
> The purpose of this document is: before you open the source code, give you a mental
> map of "why it's written this way."

---

## 1. Introduction: Why Does an OS Need a Network Stack?

A kernel that can read and write disks, display characters, and schedule processes
is already a "system." But as long as it cannot communicate with the outside world,
it will forever be an island machine. The network stack is the wire that connects
an operating system to the universe.

For a teaching-grade kernel (like MerlionOS-Zig), the network stack is especially meaningful:

- It is a touchstone for "whether multi-layer abstraction holds up": link layer,
  network layer, transport layer, application layer — each layer must have correct
  data structures, error handling, byte ordering, and timeout strategies.
- It forces you to face real hardware details like DMA, MMIO, volatile, and memory barriers.
- It lets the shell do exciting things like `ping`, `dns`, and `tcpconnect`.

MerlionOS-Zig is currently at the "just learned to speak" stage:
it can stuff frames into the NIC, do ARP address resolution, and reply to a ping.
Beyond that lies a full IPv4 / UDP / TCP / DNS stack — that's the future described in
[`docs/spec/DESIGN-TCPIP.md`](../spec/DESIGN-TCPIP.md).

This tutorial explains things layer by layer, following "the order in which data
flows on the wire": from the bytes on an Ethernet cable to a shell command that can
run `dns google.com`. Each section tells you:

- What problem this layer solves in networking;
- What the corresponding header fields look like;
- Which file in MerlionOS-Zig implements it, or plans to implement it.

---

## 2. Ethernet Frames: How a Byte Stream Gets Packaged

### 2.1 What Is a Frame

The physical-layer NIC gives you a bit stream, but the bit stream itself has no
"boundaries." The job of the Ethernet layer is: **slice the byte stream into frames
with a head and a tail**, so the receiver knows "where this packet ends, and where
the next one starts."

A typical Ethernet II (DIX) frame looks like this:

```
 0                   6                   12     14                          N
 +-------------------+-------------------+------+---------------------------+
 |   Dst MAC (6B)    |   Src MAC (6B)    |Type  |        Payload            |
 +-------------------+-------------------+------+---------------------------+
                                          2B          46 .. 1500 bytes
```

- **Dst MAC / Src MAC**: 6-byte destination/source hardware addresses. The broadcast
  address is `ff:ff:ff:ff:ff:ff`.
- **EtherType**: big-endian 16 bits. Common values:
  - `0x0800` → IPv4 (see `ETHERTYPE_IPV4` in `src/net.zig`)
  - `0x0806` → ARP (`ETHERTYPE_ARP`)
- **Payload**: the payload, 46–1500 bytes long (under 46 will be zero-padded by
  hardware or the driver up to the minimum frame length of 60 bytes).

There are actually 4 more bytes of CRC (FCS) after the Ethernet frame, but this is
handled automatically by the hardware; the buffer the software layer receives usually
does not include it. The MerlionOS-Zig e1000 driver also uses the `RCTL_SECRC` bit
to have the NIC strip the CRC.

### 2.2 NIC Hardware View: e1000, MMIO, and DMA Ring Queues

When we say "the driver sends a packet," we are actually doing something that sounds
magical: **letting the CPU and the NIC operate on the same block of physical memory
simultaneously**, without blocking each other. The core mechanism that makes this
possible is the **DMA ring descriptor queue**.

Take a look at `src/e1000.zig`. The cluster of constants at the top is essentially
an excerpt from the Intel 82540EM datasheet:

```
REG_RDBAL / REG_RDBAH   -- Physical base address of the RX descriptor ring (low 32 / high 32)
REG_RDLEN               -- Length of the RX ring
REG_RDH / REG_RDT       -- Head / Tail pointers of the RX ring
REG_TDBAL ... REG_TDT   -- The isomorphic set of registers for TX
```

These registers live in physical address space (exposed by PCI BAR0), and the CPU
must access them via MMIO. So what `mapMmio()` does is map the physical page pointed
to by BAR0 into a reserved high address (`0xFFFF_FFFF_C000_0000`), and set
**cache-disable + write-through** — because access to hardware registers must take
effect immediately and cannot be cached by the CPU.

```
┌─────────────┐  PCI configuration space tells us the physical address of BAR0
│    CPU      │─────────┐
└─────────────┘         │ MMIO (volatile u32 reads/writes)
                        ▼
               ┌───────────────────┐
               │  e1000 register set│  controls RX/TX rings
               └───────────────────┘
                        │
                        │ bus-master DMA
                        ▼
          ┌──────────────────────────────┐
          │  RX descriptor ring (8 × 16 bytes) │ ←─ RDH / RDT
          │  Each descriptor points to a 2KB buffer │
          └──────────────────────────────┘
```

**Why a ring?** Because sending and receiving are producer-consumer relationships:

- **RX ring**: the NIC is the producer, software is the consumer.
  The hardware DMAs received frames into `rx_buffers[i]`, writes `desc.status |= DD`
  (Descriptor Done), and advances `RDH`; software polling discovers that `DD` is 1,
  reads the frame, clears the bit, and advances `RDT`.
- **TX ring**: software is the producer, the NIC is the consumer.
  Software fills in the descriptor, advances `RDT` (`REG_TDT` in the code), and
  after the NIC sends it out, sets `DD` and advances `RDH`.

The core logic in `pollReceiveInternal()` and `transmitInternal()` is these two
loops. Notice the two `mfence` memory barriers — without them, the compiler or CPU
might reorder writes, causing the NIC to see an intermediate state "descriptor
length already written, but address not yet written."

Currently, MerlionOS-Zig **masks all interrupts** for the e1000
(`writeReg32(REG_IMC, 0xFFFF_FFFF)`); see section 9 "Design Trade-offs" for reasons.

---

## 3. ARP: When You Only Know the IP, How Do You Send a Letter?

### 3.1 Why We Need ARP

Ethernet only understands MAC addresses, but upper-layer applications (ping, curl,
browsers) only speak IP. There must be a translator in between that translates
IPv4 addresses to MACs — this is
**ARP (Address Resolution Protocol)**.

Imagine you know someone's ID number (IP), but to deliver a letter to their home
mailbox (MAC), you must first ask the neighbors: "Who has ID number 10.0.2.2?"
That's an ARP request.

### 3.2 ARP Packet Structure

ARP itself does not run on top of IP; it goes directly as an Ethernet payload with
EtherType `0x0806`. An ARP request frame is 42 bytes long in total:

```
Ethernet header (14)                    ARP payload (28)
┌───────────────────────────────┬───────────────────────────────────┐
│ dst=ff:ff:ff:ff:ff:ff (bcast) │ htype=1 (Ethernet)                │
│ src=local MAC                 │ ptype=0x0800 (IPv4)               │
│ type=0x0806                   │ hlen=6  plen=4                    │
├───────────────────────────────┤ oper=1 (request) / 2 (reply)      │
│                               │ sha=local MAC                     │
│                               │ spa=local IP                      │
│                               │ tha=00:00:00:00:00:00 (unknown)   │
│                               │ tpa=target IP                     │
└───────────────────────────────┴───────────────────────────────────┘
```

Compared against `buildRequest()` in `src/arp.zig`, every line maps directly.
The request is **broadcast** (dst MAC filled with `ff:ff:ff:ff:ff:ff`), because
the asker doesn't yet know the target's MAC; the reply is **unicast** — the target
machine fills its own MAC into `sha`, its IP into `spa`, changes `oper` to 2, and
sends it back.

### 3.3 Current Implementation vs. Plan

`src/arp.zig` is an MVP: it only remembers the MAC address of the last reply
(`stats.last_reply_mac`); essentially a single-entry cache.

The `src/arp_cache.zig` planned in `docs/spec/DESIGN-TCPIP.md` (already in an early
form) will upgrade this into a real ARP cache table: supporting multiple entries,
aging, and a state machine for "buffer packets while a request is pending, flush
once a reply arrives."
This is a prerequisite for real IPv4 sending — otherwise every send would require
a fresh ARP.

---

## 4. IPv4: The First Manifestation of Layered Abstraction

### 4.1 What Problem Does the Network Layer Solve

Ethernet can deliver a frame to "everyone on the same wire," but the internet is
stitched together from countless such LANs. To communicate across subnets, we need
a **logical addressing** system — IPv4 — and a "next hop" mechanism: **routing**.

### 4.2 The IPv4 Header

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

Key fields explained:

- **Version** = 4.
- **IHL** = header length (in 4-byte units). Typical value without options is 5,
  i.e. 20 bytes.
- **Total Length** = length of the entire IP packet (header + data).
- **Identification / Flags / Fragment Offset**: fragmentation-related. MerlionOS-Zig
  plans to **only do reassembly on the receive side**; the sender never fragments
  (all upper-layer protocols guarantee they stay below the MTU).
- **TTL (Time To Live)**: decremented by 1 at each hop; dropped when it reaches 0.
  Defaults to 64 (`IPV4_DEFAULT_TTL`).
- **Protocol**: payload type. `1 = ICMP`, `6 = TCP`, `17 = UDP`, see the `IPPROTO_*`
  constants in `src/net.zig`.
- **Header Checksum**: the 16-bit one's complement sum covering **only the IP header**.
  When computing, set the checksum field to 0, then fill in the result. When verifying,
  summing the entire header (including the checksum) should yield `0xffff`, which
  after negation is 0.

### 4.3 Routing: Direct or via a Gateway?

When a machine needs to send a packet to a destination IP, the decision tree is:

```
   Want to send to dst_ip
        │
        ▼
   Is dst_ip in the same subnet as local_ip?  (local_ip AND mask) == (dst_ip AND mask)
    ├── Yes ──► ARP dst_ip directly for its MAC; use it as the destination MAC
    └── No  ──► ARP the gateway (gateway_ip) for its MAC; use the gateway's MAC
```

`sameSubnet()` in `src/net.zig` does exactly this mask comparison.
In the default config: `local_ip=10.0.2.15`, `mask=255.255.255.0`,
`gateway=10.0.2.2` — this is the fixed topology of QEMU user-mode networking (SLIRP).

### 4.4 Why the Internet Checksum Is Needed

The physical layer in the early internet wasn't always reliable, so TCP/UDP/IP each
added their own checks.
The **Internet checksum** is a very cheap algorithm: 16-bit blocks summed in big-endian
with one's complement addition, with end-around carry at the end, then negated.
See the implementations of `internetChecksum()` / `sumBytes()` / `finishChecksum()`
in `src/net.zig` — just a few lines, yet covering every check from the IP header
to the TCP segment.

Currently `src/ipv4.zig` has implemented the framework for send, receive, and
protocol-number dispatch; ICMP is registered to this dispatcher via
`ipv4.registerHandler(IPPROTO_ICMP, ...)`.

---

## 5. ICMP: How ping Works

### 5.1 The Encapsulation Chain

Each "pong" of `ping` is an **ICMP Echo Request**, to which the peer replies with
an **ICMP Echo Reply**. Its full encapsulation looks like this:

```
┌──────────────────┬──────────────┬──────────────┬─────────────────┐
│  Ethernet (14B)  │  IPv4 (20B)  │  ICMP (8B)   │   Payload       │
│  type=0x0800     │  proto=1     │  type=8/0    │  "MerlionOS..." │
└──────────────────┴──────────────┴──────────────┴─────────────────┘
```

### 5.2 The ICMP Echo Packet

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

- `Type = 8, Code = 0`: Echo Request
- `Type = 0, Code = 0`: Echo Reply
- **Identifier**: sender-defined identifier (a fixed value `0x4d5a`, ASCII "MZ",
  in `src/icmp.zig`), used to match a reply back to a particular ping.
- **Sequence**: incremented with each request, used to distinguish which ping this is.
- **Checksum**: Internet checksum covering the entire ICMP packet (header + payload).

`buildEchoRequest()` in `src/icmp.zig` is written directly from this diagram:
first set the checksum field to 0, fill in type/code/identifier/sequence/payload,
then compute the checksum and write it back into bytes 2–3.

### 5.3 The Call Chain

In MerlionOS-Zig, the function stack a ping traverses is:

```
shell: ping 10.0.2.2
  └── icmp.sendEchoRequest(target, source)
        └── ipv4.sendFrom(IPPROTO_ICMP, src, dst, packet)
              └── arp look up dst's MAC (direct or via gateway)
              └── eth wrap into an Ethernet frame
                    └── e1000.transmit(frame)
                          └── write TX descriptor + advance TDT
```

Receive goes the other way: e1000 poll → eth dispatch → ipv4 dispatch by proto →
`icmp.handleRx()` verifies checksum / type / identifier, and updates
`stats.last_reply_sequence`.

---

## 6. UDP: The Simplest Transport Layer

### 6.1 What "Connectionless" Means

UDP has no concept of a "connection." You throw a datagram out, and it may arrive,
may not, may be reordered, may be duplicated. UDP's only contributions are:

1. **Port numbers**: distinguish different applications on the same machine.
2. **Checksum**: verify data integrity (optional, but strongly recommended).

### 6.2 The UDP Header

```
 0              2              4              6              8
 +--------------+--------------+--------------+--------------+
 |  Source Port |  Dst Port    |    Length    |   Checksum   |
 +--------------+--------------+--------------+--------------+
 |                     Payload ...                           |
 +-----------------------------------------------------------+
```

8 bytes total. `Length = header + payload`.

### 6.3 Why Port Numbers Matter

An IP address identifies a host. But one host may simultaneously have a DNS client
(random source port), an NTP client (123), an HTTP server (usually runs on TCP
rather than UDP, but the structure is the same).
**The four-tuple (src_ip, src_port, dst_ip, dst_port)** is the unique identifier of
a "session."

In the MerlionOS-Zig plan, `src/udp.zig` will provide three core APIs
— `bind(port)` / `sendTo()` / `recvFrom()` — for the DNS client and future shell
commands to use.

### 6.4 The Pseudo-Header Checksum

UDP and TCP checksums have a curious property: they don't just cover their own
header and data, **they also include a "pseudo-header"**:

```
 +----------------+----------------+
 |      Source IP Address          |
 +---------------------------------+
 |   Destination IP Address        |
 +--------+--------+---------------+
 |  zero  |protocol|   UDP length  |
 +--------+--------+---------------+
```

This is to prevent "misdelivery" — even if some intermediate device tampers with the
source/destination addresses in the IP header, the checksum will mismatch.
`pseudoHeaderChecksum()` in `src/net.zig` is dedicated to computing this piece.
The UDP checksum = Internet checksum over pseudo-header + UDP header + payload.

---

## 7. TCP: Where Complexity Explodes

### 7.1 Why TCP Is So Hard

UDP is "throwing a letter into a mailbox"; TCP is "making a phone call":

- You have to dial first (establish a connection)
- During the call, you must ensure the other side actually hears every word (ACK)
- If they can't hear clearly, say it again (retransmission)
- If their ears can't keep up, slow down (window, flow control)
- Hanging up requires both sides to agree (four-way handshake)

The TCP header starts at 20 bytes, with many fields before the payload:

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
 |                     Options (variable length)                |
 +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### 7.2 Three-Way Handshake and Four-Way Termination

```
  Client                              Server
    │                                   │
    │──── SYN, seq=x ─────────────────►│  (CLOSED → SYN_SENT)
    │                                   │
    │◄──── SYN+ACK, seq=y, ack=x+1 ────│  (LISTEN → SYN_RCVD)
    │                                   │
    │──── ACK, ack=y+1 ───────────────►│  (SYN_SENT → ESTABLISHED)
    │                                   │       (SYN_RCVD → ESTABLISHED)
    │       ===== Data Transfer =====   │
    │                                   │
    │──── FIN, seq=m ─────────────────►│  (ESTABLISHED → FIN_WAIT_1)
    │◄──── ACK, ack=m+1 ──────────────│
    │◄──── FIN, seq=n ────────────────│
    │──── ACK, ack=n+1 ───────────────►│  (TIME_WAIT)
```

**Sequence / Acknowledgment Number** is the soul of TCP:
every byte has a number. When the receiver replies with an ACK, it says
"the next byte number I expect to receive is N" — this implicitly acknowledges all
bytes before N. This is the basis of TCP retransmission: if the peer keeps not
ACKing up to N, I resend data starting at N.

**Window** is flow control — the receiver tells the sender "I can still accept W
more bytes, don't send more."

### 7.3 The State Machine

TCP's full state machine has 11 states — something you must draw by hand once before
you truly understand it:

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

The planned `src/tcp.zig` will implement a **simplified subset** of this diagram —
exactly how simplified is described in section 9 below.

---

## 8. DNS: Turning Names Into IPs

### 8.1 Why DNS Usually Runs on UDP

DNS queries are small (usually one or two packets), latency-sensitive, and tolerate
loss + retry. These characteristics perfectly match UDP: connectionless, low overhead,
non-blocking. The server port is **53**.

### 8.2 DNS Message Structure

```
 ┌─────────────── Header (12 bytes) ───────────────┐
 │ ID │ Flags │ QDCOUNT │ ANCOUNT │ NSCOUNT │ ARCOUNT │
 └────┴───────┴─────────┴─────────┴─────────┴─────────┘
 │                 Questions  (QDCOUNT entries)        │
 │                 Answers    (ANCOUNT entries)        │
 │                 Authority  (NSCOUNT entries)        │
 │                 Additional (ARCOUNT entries)        │
```

Each Question's domain name is encoded as a **length-prefixed byte string**:

```
   "www.google.com"
 → 3 'w' 'w' 'w' 6 'g' 'o' 'o' 'g' 'l' 'e' 3 'c' 'o' 'm' 0
```

### 8.3 DNS Compression Pointers

The early DNS spec had an optimization: if the same domain name appears multiple
times in a single response, subsequent occurrences can be replaced with a
**pointer** — two bytes, the top two bits both 1, the remaining 14 bits an offset.
For example, `0xC0 0x0C` means "read the domain name starting at byte 12 of the
message."
When parsing, you must follow jumps while preventing infinite loops (the pointer
chain length must be bounded).

The planned `src/dns.zig` will implement: building a Query, parsing the Response,
handling compression pointers, and returning the first A record.

---

## 9. Our Design Trade-offs

A "teaching-grade" stack cannot reach Linux's level; the key is explaining clearly
**why we choose not to do** certain things.

### 9.1 Why Poll-Based Instead of Interrupt-Driven

An interrupt-driven network stack is standard for production systems, but the cost
for teaching is high:

- Requires a stable APIC/IOAPIC configuration
- Requires dealing with interrupt context, bottom halves, softirq models
- When debugging, timer interrupts and NIC interrupts mix together, making
  troubleshooting hard

MerlionOS-Zig currently masks all e1000 interrupts (`REG_IMC = 0xFFFF_FFFF`); all
receives rely on typing `netpoll` in the shell to trigger one call to
`pollReceive()`. This brings two benefits:

1. **Determinism**: a receive only happens at the moment you press Enter, which is
   friendly for step-by-step debugging.
2. **Simple stack**: no concurrency, no locks, no interrupt-context restrictions.

The price is: nobody is ACKing TCP segments for you; as long as you don't type a
command, nobody advances the state machine. In the future we could add a
timer-driven `netpoll_tick()` to drive things automatically, but the core remains
polling.

### 9.2 Why Simplified TCP (No Congestion Control)

Full TCP requires Slow Start, Congestion Avoidance, Fast Retransmit, Fast Recovery,
SACK, Nagle, Delayed ACK — each is an RFC in itself.
MerlionOS-Zig's TCP plans to:

- **No congestion control**: fixed window, send when you can. QEMU SLIRP will never
  actually congest.
- **No Nagle**: each send immediately emits a segment.
- **Timeout retransmission**: yes, but with a fixed timeout rather than Karn/RTT
  estimation.
- **Complete state machine**: three-way handshake, four-way termination, RST must
  all be supported, otherwise there's no way to interoperate with the outside world.

The teaching value lies in the state machine, not in congestion control algorithms.
The latter deserves a separate project.

### 9.3 Why the 4-Connection Limit

Without a dynamically allocated socket table, you don't need to think about
lifetimes, leaks, or reuse. Four connections are enough to simultaneously do a
DNS lookup, an HTTP request, keep one for shell command experiments, and leave
one as a buffer. This is a common trade-off for kernel stacks — early OpenBSD's
network stack also used a static table. If a heap allocator is attached in the
future, this limit can be removed at any time.

### 9.4 Why No IPv6, and No IP Fragmentation on Send

- IPv6 has a simpler, more modern header, but doesn't fit with the existing MAC/ARP
  ecosystem. For teaching clarity, we only do IPv4.
- Fragmented sending is rarely used (upper-layer protocols guarantee staying below
  the MTU), but **receive-side reassembly** must be done; otherwise we cannot
  correctly receive fragmented packets coming from real networks.

---

## 10. Reading Roadmap

Recommended source-code reading order:

1. **`src/e1000.zig`**
   First understand the DMA ring, MMIO, and descriptor status bits. There are no
   protocols here, only hardware.

2. **`src/net.zig`**
   Common types, byte order, checksum functions. Used by every upper layer.

3. **`src/arp.zig`**
   The smallest "protocol." 156 lines total — once you read it, you understand the
   pattern of "build an Ethernet frame + parse the response."

4. **`src/arp_cache.zig`**
   On top of `arp.zig`, see how the cache table is stored and aged.

5. **`src/eth.zig`**
   EtherType dispatch: should an incoming frame go to ARP or IPv4?

6. **`src/ipv4.zig`**
   The first "real" manifestation of layering: IP header construction, routing,
   protocol-number dispatch. After reading this, you'll see that ICMP just
   registers a handler here.

7. **`src/icmp.zig`**
   176 lines, a complete "ping client." See how `buildEchoRequest` and `handleRx`
   mirror each other.

8. **`src/udp.zig`**
   The first "userspace-style API" on the upper layer.

9. **`src/tcp.zig`**
   This is where the state machine and sequence-number space are truly on display.
   Before reading, draw the state machine on paper yourself first.

10. **`src/dns.zig`**
    An integrated application: UDP + big-endian byte streams + pointer compression.

11. **`src/socket.zig`**
    The unified UDP/TCP/DNS facade. Shell commands and future userspace networking
    entry points should go through this layer first.

12. **`docs/spec/DESIGN-TCPIP.md`**
    Interfaces, constants, and data-structure definitions for all new files are
    here. Flip through it as an API reference.

---

## Appendix: QEMU User-Mode Network Topology

QEMU's default user-mode (SLIRP) network provides a fixed virtual Ethernet:

```
   ┌──────────────────────────┐
   │  MerlionOS-Zig guest     │   IP: 10.0.2.15
   │  (e1000 NIC)             │   MAC: assigned by QEMU
   └───────────┬──────────────┘
               │
   ┌───────────▼──────────────┐
   │  SLIRP (in QEMU)         │   gateway: 10.0.2.2
   │  NAT / DHCP / DNS proxy  │   DNS:     10.0.2.3
   └───────────┬──────────────┘
               │
   ┌───────────▼──────────────┐
   │   Host's real network    │
   └──────────────────────────┘
```

So when you ping `10.0.2.2` from inside the guest, you get a reply from a virtual
router inside SLIRP; ping `10.0.2.3` gets you SLIRP's DNS proxy; pinging a real
public IP goes out through the host's NAT. This predictable, fixed topology is
very well suited for making assertions and regression tests while writing a
protocol stack.

---

Have fun. When your kernel prints `echo reply seq=1 from 10.0.2.2` for the first
time, you'll understand why someone would be willing to spend an entire weekend
just for that one line of log output.
