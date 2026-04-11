# MerlionOS-Zig Project Context

## Project Overview
MerlionOS-Zig is a bare-metal x86_64 operating system kernel written in Zig (0.15+), following the Limine boot protocol. It is a clean reimplementation of the Rust-based [MerlionOS](https://github.com/lai3d/merlionos), leveraging Zig's `comptime`, explicit allocators, and error unions.

### Core Technologies
- **Language:** Zig 0.15+ (Freestanding, no libc)
- **Architecture:** x86_64 (Higher-half kernel at `0xffffffff80000000`)
- **Bootloader:** [Limine](https://limine-bootloader.org/)
- **Virtualization:** QEMU for testing

### System Architecture
- **Boot:** Limine protocol handling in `src/limine.zig`.
- **Hardware Drivers:** UART Serial (COM1/COM2), VGA Text Mode, PS/2 Keyboard, PIT Timer, 8259 PIC, PCI Bus, e1000/e1000e NIC.
- **CPU Setup:** GDT, IDT (exceptions and IRQs), TSS.
- **Memory Management:** Bitmap-based Physical Memory Manager (PMM), Page-table Virtual Memory Manager (VMM), Explicit Heap Allocator.
- **Multitasking:** Cooperative and preemptive round-robin scheduler with context switching.
- **Filesystem:** In-memory VFS with `/proc` and `/dev` support.
- **Networking:** TCP/IP stack (Phase 9 - Active) including ARP, IPv4, ICMP, and future TCP/UDP.
- **AI Integration:** COM2 LLM proxy line protocol for interacting with external AI models via a host-side bridge.

## Building and Running

### Key Commands
- `zig build run`: Full pipeline (compile, build ISO, launch QEMU with display).
- `zig build run-serial`: Launch QEMU in headless mode (serial output only).
- `zig build run-ai`: Launch QEMU with COM2 wired to a UNIX socket for AI proxying.
- `zig build kernel`: Compile the kernel ELF (uses `tools/build.sh`).
- `zig build iso`: Package the kernel into a bootable ISO (uses `tools/mkiso.sh`).

### AI Proxy Bridge
When using AI features (`aiask`, `aipoll` in shell), the host bridge must be running:
```bash
python3 tools/ai_proxy.py --socket /tmp/merlionos-ai.sock --backend openai
```

## Development Conventions

### Zig 0.15 Requirements
Strictly adhere to Zig 0.15 syntax to avoid compilation errors:
- **Calling Conventions:** Use lowercase (e.g., `callconv(.c)`, `callconv(.naked)`, `callconv(.interrupt)`).
- **Inline Asm:** Use `"{dx}"` constraints instead of `"N{dx}"` for port I/O.
- **Builtins:** Use `@intFromEnum`, `@intFromPtr`, `@ptrFromInt` instead of legacy `@enumToInt`, etc.
- **Build System:** Use `root_module` instead of `root_source_file` in `build.zig`.

### Coding Style
- **Indentation:** 4 spaces, no tabs.
- **Naming:**
    - Types: `PascalCase` (e.g., `MemoryMapEntry`)
    - Functions/Variables: `camelCase` (e.g., `allocFrame`)
    - Constants: `UPPER_SNAKE_CASE` (e.g., `PAGE_SIZE`)
- **Memory:** Prefer explicit allocator passing (`std.mem.Allocator`) over global state.
- **Types:** Use `extern struct` for hardware/protocol-mapped structures to ensure C-compatible layout.

### Technical Integrity
- **No Libc:** Do not use `std.os` or any host-dependent modules.
- **Validation:** Always verify changes by booting in QEMU and checking serial logs.
- **Commit Trailer:** When preparing commits, append `Co-authored-by: Gemini <gemini@google.com>` to the message.

## Key Files
- `src/main.zig`: Kernel entry point and initialization sequence.
- `src/cpu.zig`: Foundational port I/O and CPU utility functions.
- `src/log.zig`: Dual-output logging system (Serial + VGA).
- `docs/DESIGN.md`: Detailed architectural design and Phase 1-6 specs.
- `docs/DESIGN-TCPIP.md`: Phase 9 networking stack design.
- `linker.ld`: Higher-half linker script ensuring correct section placement for Limine.
- `AGENTS.md` / `CLAUDE.md`: Additional context for AI collaborators.
