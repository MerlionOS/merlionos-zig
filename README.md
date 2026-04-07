# MerlionOS-Zig

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

### Phase 7: Networking (current)
- [x] PCI bus enumeration
- [x] `lspci` shell command
- [x] e1000/e1000e device detection
- [x] `netinfo` shell command
- [x] e1000 BAR0 uncached MMIO mapping + CTRL/STATUS register read
- [x] e1000 MAC address register discovery
- [x] e1000 TX/RX DMA descriptor ring initialization
- [x] Raw Ethernet test-frame TX path
- [x] Raw Ethernet RX descriptor polling path
- [ ] Ethernet frame receive with external traffic validation
- [ ] ARP, IPv4, and ICMP

### Future
- [ ] AI integration (COM2 serial LLM proxy)

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
- [Contributor guide](AGENTS.md)
- [Agent workflow notes](CLAUDE.md)

## License

MIT
