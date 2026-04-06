# CLAUDE.md

## Project Overview

MerlionOS-Zig — a bare-metal x86_64 operating system kernel written in Zig, inspired by the Rust-based [MerlionOS](https://github.com/lai3d/merlionos). Not a line-by-line port, but a clean reimplementation leveraging Zig's comptime, explicit allocators, and error unions.

## Build & Run

```bash
# Build kernel ELF
sh tools/build.sh

# Build bootable ISO (requires xorriso, auto-downloads Limine)
sh tools/mkiso.sh

# Build all and run in QEMU
zig build run

# Or step by step:
zig build           # compile kernel
zig build iso       # build ISO
zig build run       # compile + ISO + QEMU
zig build run-serial  # headless QEMU (serial only)
```

## Project Structure

```
src/main.zig         # Kernel entry point (_start)
src/limine.zig       # Limine boot protocol structures
src/serial.zig       # UART COM1 driver + port I/O
src/vga.zig          # VGA text mode 80x25
src/log.zig          # Dual output (serial + VGA)
src/panic.zig        # Kernel panic handler
src/mem.zig          # Compiler builtins (memcpy, etc.)
linker.ld            # Higher-half kernel linker script
limine.conf          # Limine bootloader config
build.zig            # Zig build system
tools/build.sh       # Kernel compile script
tools/mkiso.sh       # ISO packaging script
```

## Conventions

- Target: x86_64-freestanding-none
- Boot protocol: Limine (higher-half at 0xffffffff80000000)
- Build: Two-step (zig build-obj + zig ld.lld) due to Zig 0.15 cross-compile quirks on macOS ARM
- No external dependencies — all implemented from scratch
- Explicit allocator pattern — no global allocator
- Zig 0.15 calling convention: `.c` not `.C`, `.naked` not `.Naked`
- Port I/O asm constraints: `"{dx}"` not `"N{dx}"`
