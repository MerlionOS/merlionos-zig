# MerlionOS-Zig

<p align="center">
  <img src="assets/mascot-512.png" width="240" alt="MerlionOS-Zig mascot">
</p>

A bare-metal x86_64 operating system kernel written in Zig, inspired by [MerlionOS](https://github.com/lai3d/merlionos) (Rust). Clean reimplementation leveraging Zig's comptime, explicit allocators, and error unions.

**Born for AI. Built by AI. Now in Zig.**

## Prerequisites

- [Zig](https://ziglang.org/download/) (0.15+)
- [QEMU](https://www.qemu.org/) (for testing)
- [xorriso](https://www.gnu.org/software/xorriso/) (for ISO creation)

```bash
# macOS
brew install zig qemu xorriso
```

## Quick Start

```bash
zig build run    # Build kernel + ISO, launch in QEMU
```

For the COM2 AI proxy path:

```bash
# Terminal 1: boot QEMU with COM2 on a UNIX socket
zig build run-ai

# Terminal 2: connect the host-side bridge before using aiask/aipoll
python3 tools/ai_proxy.py --socket /tmp/merlionos-ai.sock

# Optional: delegate prompts to an external LLM CLI or script
python3 tools/ai_proxy.py --socket /tmp/merlionos-ai.sock \
  --backend command --command 'your-llm-command --read-stdin'

# Optional: use OpenAI Responses API from the host bridge
OPENAI_API_KEY=... python3 tools/ai_proxy.py --socket /tmp/merlionos-ai.sock \
  --backend openai --openai-model "${OPENAI_MODEL:-gpt-5.4-mini}"
```

## Roadmap

### Phase 1: Boot + Output
- [x] Limine boot protocol (higher-half kernel)
- [x] UART serial COM1 driver
- [x] VGA text mode 80x25 with colors and scrolling
- [x] Dual output logging (serial + VGA)
- [x] Kernel panic handler
- [x] Boot verification in QEMU

### Phase 2: CPU Setup
- [x] GDT with kernel/user segments + TSS
- [x] IDT with exception handlers (page fault, double fault, etc.)
- [x] 8259 PIC initialization
- [x] PIT timer at 100Hz

### Phase 3: Memory Management
- [x] Physical frame allocator (bitmap-based)
- [x] Virtual memory / page table manager
- [x] Kernel heap allocator (`std.mem.Allocator` interface)

### Phase 4: Keyboard + Shell
- [x] PS/2 keyboard driver (comptime scancode table)
- [x] Interactive shell with line editing and history
- [x] Cursor-aware editing: insert, backspace, delete, left/right, home/end
- [x] Commands: help, clear, echo, info, mem, uptime, version
- [ ] Manual GUI verification for extended keys in QEMU

### Phase 5: Multitasking
- [x] Task management with context switching
- [x] Cooperative round-robin task switching via `yield`
- [x] Process commands: ps, spawn, kill
- [x] Scheduler tick accounting
- [x] Round-robin scheduler (IRQ-time PIT-driven preemption)

### Phase 6: Filesystem
- [x] In-memory VFS (inode-based)
- [x] /proc (version, uptime, meminfo, tasks)
- [x] /dev (null, zero)
- [x] Shell working directory with `cd` and `pwd`
- [x] File commands: ls, tree, cat, mkdir, touch, write, rm, `echo > file`
- [x] `echo > file` redirection verified end-to-end in QEMU

### Phase 7: Networking
- [x] PCI bus enumeration
- [x] `lspci` shell command
- [x] e1000/e1000e device detection
- [x] `netinfo` shell command
- [x] e1000 BAR0 uncached MMIO mapping + CTRL/STATUS register read
- [x] e1000 MAC address register discovery
- [x] e1000 TX/RX DMA descriptor ring initialization
- [x] Raw Ethernet test-frame TX path
- [x] Raw Ethernet RX descriptor polling path
- [x] Ethernet frame receive with external traffic validation
- [x] ARP request frame construction and `arpreq`
- [x] ARP reply polling and stats
- [x] IPv4 + ICMP echo request frame construction
- [x] ICMP echo reply polling and stats

### Phase 8: AI Integration
- [x] COM2 UART plumbing and detection
- [x] COM2 LLM proxy line protocol commands: `aistatus`, `aiask`, `aipoll`
- [x] Host-side COM2 proxy bridge validation
- [x] External command-backed host bridge
- [x] OpenAI Responses API host bridge adapter

### Phase 9: TCP/IP Stack (complete)
- [x] TCP/IP stack design document: `docs/spec/DESIGN-TCPIP.md`
- [x] Shared network types, configuration, endian helpers, and checksum helpers in `net.zig`
- [x] Ethernet frame send/receive dispatch layer and `netpoll`
- [x] ARP cache table with pending/resolved entries and legacy `arpreq` compatibility
- [x] IPv4 send/receive/routing layer and ICMP migration onto IPv4
- [x] UDP datagram send/receive path
- [x] Shell commands: `ifconfig`, `netpoll`, `arp`, `udpsend`, `tcpconnect`, `tcpsend`, `tcprecv`, `tcpclose`, `tcpstat`, `dns`, `httpget`
- [x] TCP connection state machine with connect/send/recv/close
- [x] DNS A-record client over UDP
- [x] Socket-like API for future shell/userland integration

### Phase 10: User Mode (current)
- [x] User mode design document: `docs/spec/DESIGN-USERMODE.md`
- [x] Syscall infrastructure: `int 0x80` dispatch, `SYS_WRITE`, `SYS_GETPID`, `SYS_EXIT` teardown, syscall stats
- [x] `syscallstat` shell command for dispatcher stats
- [x] User address space management in `user_mem.zig`
- [x] `usermemtest` shell command verifies user page mapping and CR3 restore
- [x] User process loading and context switching via `process.zig`, `user_programs.zig`, `task.zig`, and `scheduler.zig`
- [x] Built-in `hello_user` flat program runs through Ring 3, `SYS_WRITE`, and `SYS_EXIT`
- [x] Shell integration: `runuser hello` and user/process details in `ps`
- [x] Process lifecycle syscall: `SYS_YIELD`
- [x] Built-in `loop_user` flat program runs through Ring 3, `SYS_WRITE`, and `SYS_YIELD`
- [x] Scheduling smoke test: `runuser loop`, shell preemption, and live `killuser`
- [x] ELF parser/load helper in `elf.zig` with `elftest` segment/load smoke check
- [x] ELF-backed user process execution from VFS with `/bin/hello.elf` and `runelf`
- [x] Process lifecycle syscall: `SYS_SLEEP` with blocked-task wakeups
- [ ] Process lifecycle syscalls: `SYS_READ` and `SYS_BRK`
- [x] Shell integration: `killuser`
- [x] Protection tests: `bad_cli` and `bad_read`
- [x] Multi-user-process preemption with `runuser pair`

## Zig vs Rust: Why Rewrite?

| Feature | Zig Approach | Rust Approach |
|---|---|---|
| GDT/IDT | comptime — zero runtime cost | Lazy (runtime init) |
| Allocator | Explicit, per-call | Global `#[global_allocator]` |
| Error handling | Error unions (unified) | Mix of Option/Result/panic |
| Inline asm | Stable, first-class | Requires nightly features |
| C interop | Native `@cImport` | FFI + unsafe blocks |
| Dependencies | Zero — all from scratch | x86_64, spin, pic8259, etc. |

## Documentation

- [Design and implementation plan](docs/DESIGN.md)
- [User mode implementation spec](docs/spec/DESIGN-USERMODE.md)
- [Contributor guide](AGENTS.md)
- [Agent workflow notes](CLAUDE.md)

## License

MIT
