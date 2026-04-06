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

### Phase 3: Memory Management (current)
- [x] Physical frame allocator (bitmap-based)
- [x] Virtual memory / page table manager
- [x] Kernel heap allocator (`std.mem.Allocator` interface)

### Phase 4: Keyboard + Shell
- [ ] PS/2 keyboard driver (comptime scancode table)
- [ ] Interactive shell with line editing and history
- [ ] Commands: help, clear, echo, info, mem, uptime

### Phase 5: Multitasking
- [ ] Task management with context switching
- [ ] Round-robin scheduler (PIT-driven preemption)
- [ ] Process commands: ps, spawn, kill

### Phase 6: Filesystem
- [ ] In-memory VFS (inode-based)
- [ ] /proc (uptime, meminfo, tasks)
- [ ] /dev (null, serial)
- [ ] File commands: ls, cat, mkdir, echo > file

### Future
- [ ] Networking (e1000e + TCP/IP stack)
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

- [Zig vs Rust comparison (中文)](../zig-hello-world/docs/zig-vs-rust-zh.md) | [English](../zig-hello-world/docs/zig-vs-rust-en.md)
- [Zig OS Development (中文)](../zig-hello-world/docs/zig-os-dev-zh.md) | [English](../zig-hello-world/docs/zig-os-dev-en.md)

## License

MIT
