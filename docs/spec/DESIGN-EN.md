# MerlionOS-Zig Detailed Design Document

> This document is intended for direct implementation by AI code generation tools (Codex, etc.).
> Interfaces, data structures, function signatures, and constant values for each file are provided — implement them file by file.

## Table of Contents

1. [Global Constraints and Build Configuration](#1-global-constraints-and-build-configuration)
2. [Phase 1: Boot and Output](#2-phase-1-boot-and-output)
3. [Phase 2: CPU Initialization](#3-phase-2-cpu-initialization)
4. [Phase 3: Memory Management](#4-phase-3-memory-management)
5. [Phase 4: Keyboard and Shell](#5-phase-4-keyboard-and-shell)
6. [Phase 5: Multitasking](#6-phase-5-multitasking)
7. [Phase 6: Filesystem](#7-phase-6-filesystem)
8. [Known Zig 0.15 Caveats](#8-known-zig-015-caveats)

---

## 1. Global Constraints and Build Configuration

### 1.1 Target Platform

- CPU: x86_64
- OS: freestanding (no libc, no std OS)
- ABI: none
- Code model: kernel (addresses in upper 2GB: 0xffffffff80000000+)
- Red zone: disabled (-mno-red-zone)
- SSE/AVX: not used (kernel code only uses integer ops)
- Optimization: ReleaseSmall (Debug mode has relocation issues on macOS ARM cross-compile)

### 1.2 Build Steps

Due to a SIGBUS crash in Zig 0.15 on macOS ARM when using `zig build-exe` with `-mcmodel=kernel` and `--listen`, a two-step build is used:

```bash
# Step 1: Compile to .o file
zig build-obj \
    -mno-red-zone \
    -OReleaseSmall \
    -mcmodel=kernel \
    -target x86_64-freestanding-none \
    -Mroot=src/main.zig \
    --name kernel

# Step 2: Link with LLD
zig ld.lld \
    -T linker.ld \
    -z max-page-size=4096 \
    -o zig-out/bin/kernel.elf \
    kernel.o
```

### 1.3 Project File Structure (Final State)

```
merlionos-zig/
├── build.zig              # Zig build system wrapper
├── linker.ld              # Linker script (higher-half)
├── limine.conf            # Limine bootloader config
├── tools/
│   ├── build.sh           # Kernel compile script
│   └── mkiso.sh           # ISO packaging script
├── src/
│   ├── main.zig           # Entry point + init sequence
│   ├── limine.zig         # Limine protocol structs
│   ├── serial.zig         # UART COM1 driver
│   ├── vga.zig            # VGA text mode driver
│   ├── log.zig            # Dual-output kernel logging
│   ├── panic.zig          # Panic handler
│   ├── mem.zig            # Compiler builtins (memcpy etc.)
│   ├── cpu.zig            # Port I/O, CPU utilities
│   ├── gdt.zig            # GDT + TSS
│   ├── idt.zig            # IDT + exception/IRQ handlers
│   ├── pic.zig            # 8259 PIC controller
│   ├── pit.zig            # PIT timer
│   ├── pmm.zig            # Physical memory manager
│   ├── vmm.zig            # Virtual memory manager
│   ├── heap.zig           # Kernel heap allocator
│   ├── keyboard.zig       # PS/2 keyboard driver
│   ├── shell.zig          # Interactive shell
│   ├── shell_cmds.zig     # Shell commands
│   ├── task.zig           # Task struct + context switch
│   ├── scheduler.zig      # Round-robin scheduler
│   ├── vfs.zig            # Virtual filesystem
│   ├── procfs.zig         # /proc filesystem
│   └── devfs.zig          # /dev filesystem
├── CLAUDE.md
└── README.md
```

### 1.4 Zig 0.15 Syntax Notes (Important!)

Zig 0.15 introduces several syntax changes compared to older versions — these must be followed during implementation:

```zig
// 1. Calling convention uses lowercase
export fn _start() callconv(.c) noreturn { ... }    // ✓ .c
// NOT: callconv(.C)                                  // ✗

// 2. Naked calling convention
fn contextSwitch() callconv(.naked) void { ... }     // ✓ .naked
// NOT: callconv(.Naked)                              // ✗

// 3. Inline asm port I/O constraints use "{dx}" instead of "N{dx}"
asm volatile ("outb %[value], %[port]"
    : : [value] "{al}" (value), [port] "{dx}" (port));  // ✓
// NOT: [port] "N{dx}" (port)                             // ✗

// 4. build.zig uses root_module instead of root_source_file
b.addExecutable(.{
    .name = "kernel.elf",
    .root_module = b.createModule(.{ ... }),  // ✓ Zig 0.15
});

// 5. GenericWriter path
const Writer = std.io.GenericWriter(Context, Error, writeFn);

// 6. linksection follows the type declaration
pub export var foo: [4]u64 linksection(".section_name") = .{ ... };

// 7. @intFromEnum / @intCast replace the old @enumToInt / @intCast
```

---

## 2. Phase 1: Boot and Output

### 2.1 linker.ld

Already implemented, no modifications needed. Key points:
- Entry: `_start`
- Base address: `0xffffffff80000000`
- `.limine_requests_start` → `.limine_requests` → `.limine_requests_end` ordering must be guaranteed
- `/DISCARD/` section discards `.eh_frame`, `.note`, `.comment`

### 2.2 src/limine.zig — Limine Protocol

#### Data Structures

All structs must use `extern struct` (C ABI layout); Zig's default struct layout must not be used.

```zig
// Limine common magic numbers
const LIMINE_COMMON_MAGIC = [2]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// --- Framebuffer ---
pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    _unused: [7]u8,
    edid_size: u64,
    edid: [*]u8,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]const *const Framebuffer,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const FramebufferResponse,
};

// --- Memory Map ---
pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    entry_type: u64,  // 0=usable, 1=reserved, 2=ACPI recl, ...
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]const *const MemmapEntry,
};

pub const MemmapRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const MemmapResponse,
};

// --- HHDM ---
pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const HhdmResponse,
};
```

#### Request Instances (linksection Placement)

Each request must use `pub export var` + `linksection`, and marker ordering is guaranteed by linker.ld:

```zig
// Exact magic values (do not modify)
pub export var requests_start_marker: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
    0x785c6ed015d3e316, 0x181e920a7852b9d9,
};

pub export var base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 2,  // revision 2
};

pub export var framebuffer_request: FramebufferRequest linksection(".limine_requests") = .{
    .id = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    .revision = 0,
    .response = null,
};

pub export var memmap_request: MemmapRequest linksection(".limine_requests") = .{
    .id = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
    .response = null,
};

pub export var hhdm_request: HhdmRequest linksection(".limine_requests") = .{
    .id = .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    .revision = 0,
    .response = null,
};

pub export var requests_end_marker: [2]u64 linksection(".limine_requests_end") = .{
    0xadc0e0531bb10d03, 0x9572709f31764c62,
};
```

#### Memory Map Type Constants

```zig
pub const MEMMAP_USABLE: u64 = 0;
pub const MEMMAP_RESERVED: u64 = 1;
pub const MEMMAP_ACPI_RECLAIMABLE: u64 = 2;
pub const MEMMAP_ACPI_NVS: u64 = 3;
pub const MEMMAP_BAD_MEMORY: u64 = 4;
pub const MEMMAP_BOOTLOADER_RECLAIMABLE: u64 = 5;
pub const MEMMAP_KERNEL_AND_MODULES: u64 = 6;
pub const MEMMAP_FRAMEBUFFER: u64 = 7;
```

### 2.3 src/cpu.zig — Port I/O and CPU Utilities

This is the foundational utility file for the entire kernel; all modules that need port I/O import from here.

```zig
// --- Port I/O ---

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub fn ioWait() void {
    outb(0x80, 0); // Write to unused port for a short delay
}

pub fn halt() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn disableInterrupts() void {
    asm volatile ("cli");
}

pub fn enableInterrupts() void {
    asm volatile ("sti");
}

pub fn lidt(idtr: *const IdtRegister) void {
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (idtr),
    );
}

pub fn lgdt(gdtr: *const GdtRegister) void {
    asm volatile ("lgdt (%[gdtr])"
        :
        : [gdtr] "r" (gdtr),
    );
}

pub fn ltr(selector: u16) void {
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (selector),
    );
}

pub fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "=r" (-> u64),
    );
}

pub fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[result]"
        : [result] "=r" (-> u64),
    );
}

pub fn writeCr3(value: u64) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "r" (value),
    );
}

// GDTR/IDTR structures (packed, 6 bytes)
pub const GdtRegister = packed struct {
    limit: u16,
    base: u64,
};

pub const IdtRegister = packed struct {
    limit: u16,
    base: u64,
};
```

### 2.4 src/serial.zig — UART Serial Driver

Import port I/O from cpu.zig (do not redefine it in serial.zig).

```zig
const std = @import("std");
const cpu = @import("cpu.zig");

pub const COM1_PORT: u16 = 0x3F8;
pub const COM2_PORT: u16 = 0x2F8;

pub const SerialPort = struct {
    base: u16,

    /// Initialize UART: 115200 baud, 8N1, FIFO enabled
    pub fn init(self: SerialPort) void {
        cpu.outb(self.base + 1, 0x00); // Disable interrupts
        cpu.outb(self.base + 3, 0x80); // DLAB = 1
        cpu.outb(self.base + 0, 0x01); // Baud rate 115200 (divisor = 1)
        cpu.outb(self.base + 1, 0x00); // High byte = 0
        cpu.outb(self.base + 3, 0x03); // 8 bits, no parity, 1 stop bit
        cpu.outb(self.base + 2, 0xC7); // FIFO: enable, clear, 14-byte threshold
        cpu.outb(self.base + 4, 0x0B); // RTS/DSR set, IRQ enabled
    }

    fn isTransmitEmpty(self: SerialPort) bool {
        return (cpu.inb(self.base + 5) & 0x20) != 0;
    }

    pub fn writeByte(self: SerialPort, byte: u8) void {
        while (!self.isTransmitEmpty()) {}
        cpu.outb(self.base, byte);
    }

    pub fn readByte(self: SerialPort) ?u8 {
        if ((cpu.inb(self.base + 5) & 0x01) != 0) {
            return cpu.inb(self.base);
        }
        return null;
    }

    pub fn writer(self: SerialPort) Writer {
        return .{ .context = self };
    }

    pub const Writer = std.io.GenericWriter(SerialPort, error{}, writeImpl);

    fn writeImpl(self: SerialPort, bytes: []const u8) error{}!usize {
        for (bytes) |byte| {
            if (byte == '\n') self.writeByte('\r');
            self.writeByte(byte);
        }
        return bytes.len;
    }
};

pub var com1 = SerialPort{ .base = COM1_PORT };
pub var com2 = SerialPort{ .base = COM2_PORT };
```

### 2.5 src/vga.zig — VGA Text Mode

```zig
const std = @import("std");
const limine = @import("limine.zig");

pub const WIDTH = 80;
pub const HEIGHT = 25;
const VGA_PHYS_ADDR = 0xB8000;

pub const Color = enum(u4) {
    black = 0, blue = 1, green = 2, cyan = 3,
    red = 4, magenta = 5, brown = 6, light_gray = 7,
    dark_gray = 8, light_blue = 9, light_green = 10, light_cyan = 11,
    light_red = 12, pink = 13, yellow = 14, white = 15,
};

fn colorAttr(fg: Color, bg: Color) u8 {
    return @as(u8, @intFromEnum(fg)) | (@as(u8, @intFromEnum(bg)) << 4);
}

fn vgaEntry(char: u8, color: u8) u16 {
    return @as(u16, char) | (@as(u16, color) << 8);
}

pub var writer = VgaWriter{};

pub const VgaWriter = struct {
    col: usize = 0,
    row: usize = 0,
    color: u8 = colorAttr(.light_green, .black),
    buffer: ?[*]volatile u16 = null,

    /// Must be called after obtaining the HHDM offset
    pub fn init(self: *VgaWriter) void {
        const hhdm_offset: u64 = if (limine.hhdm_request.response) |r| r.offset else 0;
        self.buffer = @ptrFromInt(VGA_PHYS_ADDR + hhdm_offset);
        self.clear();
    }

    pub fn clear(self: *VgaWriter) void {
        const buf = self.buffer orelse return;
        for (0..HEIGHT) |r| {
            for (0..WIDTH) |c| {
                buf[r * WIDTH + c] = vgaEntry(' ', self.color);
            }
        }
        self.col = 0;
        self.row = 0;
    }

    pub fn setColor(self: *VgaWriter, fg: Color, bg: Color) void {
        self.color = colorAttr(fg, bg);
    }

    pub fn putChar(self: *VgaWriter, char: u8) void {
        const buf = self.buffer orelse return;
        switch (char) {
            '\n' => { self.col = 0; self.row += 1; },
            '\r' => { self.col = 0; },
            '\t' => {
                self.col = (self.col + 8) & ~@as(usize, 7);
                if (self.col >= WIDTH) { self.col = 0; self.row += 1; }
            },
            0x08 => { // backspace
                if (self.col > 0) {
                    self.col -= 1;
                    buf[self.row * WIDTH + self.col] = vgaEntry(' ', self.color);
                }
            },
            else => {
                buf[self.row * WIDTH + self.col] = vgaEntry(char, self.color);
                self.col += 1;
                if (self.col >= WIDTH) { self.col = 0; self.row += 1; }
            },
        }
        if (self.row >= HEIGHT) self.scroll();
    }

    fn scroll(self: *VgaWriter) void {
        const buf = self.buffer orelse return;
        for (1..HEIGHT) |r| {
            for (0..WIDTH) |c| {
                buf[(r - 1) * WIDTH + c] = buf[r * WIDTH + c];
            }
        }
        for (0..WIDTH) |c| {
            buf[(HEIGHT - 1) * WIDTH + c] = vgaEntry(' ', self.color);
        }
        self.row = HEIGHT - 1;
    }

    pub fn getWriter(self: *VgaWriter) StdWriter {
        return .{ .context = self };
    }

    pub const StdWriter = std.io.GenericWriter(*VgaWriter, error{}, writeImpl);

    fn writeImpl(self: *VgaWriter, bytes: []const u8) error{}!usize {
        for (bytes) |b| self.putChar(b);
        return bytes.len;
    }
};
```

### 2.6 src/log.zig — Kernel Logging

```zig
const std = @import("std");
const serial = @import("serial.zig");
const vga = @import("vga.zig");

pub fn kprint(comptime fmt: []const u8, args: anytype) void {
    serial.com1.writer().print(fmt, args) catch {};
    vga.writer.getWriter().print(fmt, args) catch {};
}

pub fn kprintln(comptime fmt: []const u8, args: anytype) void {
    kprint(fmt ++ "\n", args);
}
```

### 2.7 src/panic.zig

```zig
const serial = @import("serial.zig");
const cpu = @import("cpu.zig");

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    cpu.disableInterrupts();
    const w = serial.com1.writer();
    w.print("\r\n!!! KERNEL PANIC: {s} !!!\r\n", .{msg}) catch {};
    cpu.halt();
}
```

### 2.8 src/mem.zig — Compiler Built-in Functions

The compiler requires these symbols in freestanding mode. They must use `export fn`.

```zig
export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    for (0..len) |i| dest[i] = src[i];
    return dest;
}

export fn memmove(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        for (0..len) |i| dest[i] = src[i];
    } else {
        var i = len;
        while (i > 0) { i -= 1; dest[i] = src[i]; }
    }
    return dest;
}

export fn memset(dest: [*]u8, val: i32, len: usize) [*]u8 {
    const byte: u8 = @intCast(val & 0xFF);
    for (0..len) |i| dest[i] = byte;
    return dest;
}

export fn memcmp(s1: [*]const u8, s2: [*]const u8, len: usize) i32 {
    for (0..len) |i| {
        if (s1[i] != s2[i]) return @as(i32, s1[i]) - @as(i32, s2[i]);
    }
    return 0;
}
```

### 2.9 src/main.zig — Entry Point

```zig
const limine = @import("limine.zig");
const serial = @import("serial.zig");
const vga = @import("vga.zig");
const log = @import("log.zig");
const cpu = @import("cpu.zig");

// Phase 2+
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");
const pit = @import("pit.zig");
// Phase 3+
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
// Phase 4+
const keyboard = @import("keyboard.zig");
const shell = @import("shell.zig");

pub const panic = @import("panic.zig").panic;
comptime { _ = @import("mem.zig"); }  // Ensure memcpy etc. are linked

const VERSION = "0.1.0";

export fn _start() callconv(.c) noreturn {
    // 1. Serial init (earliest, used for all subsequent debug output)
    serial.com1.init();
    log.kprintln("[boot] MerlionOS-Zig v{s} starting...", .{VERSION});

    // 2. HHDM
    const hhdm_offset: u64 = if (limine.hhdm_request.response) |r| r.offset else 0;
    log.kprintln("[boot] HHDM offset: 0x{x}", .{hhdm_offset});

    // 3. VGA
    vga.writer.init();

    // 4. Banner
    log.kprintln("", .{});
    log.kprintln("  MerlionOS-Zig v{s}", .{VERSION});
    log.kprintln("  Zig 0.15 | x86_64 | Limine boot", .{});
    log.kprintln("", .{});

    // 5. Memory map
    if (limine.memmap_request.response) |resp| {
        log.kprintln("[mem] {d} entries:", .{resp.entry_count});
        var total: u64 = 0;
        for (0..resp.entry_count) |i| {
            const e = resp.entries[i];
            if (e.entry_type == limine.MEMMAP_USABLE) total += e.length;
        }
        log.kprintln("[mem] Total usable: {d} MB", .{total / 1048576});
    }

    // === Phase 2: CPU init ===
    gdt.init();
    log.kprintln("[cpu] GDT loaded", .{});

    idt.init();
    log.kprintln("[cpu] IDT loaded", .{});

    pic.init();
    log.kprintln("[cpu] PIC initialized", .{});

    pit.init(100); // 100 Hz
    log.kprintln("[cpu] PIT: 100 Hz", .{});

    cpu.enableInterrupts();
    log.kprintln("[cpu] Interrupts enabled", .{});

    // === Phase 3: Memory ===
    pmm.init();
    log.kprintln("[mem] PMM: {d} MB free", .{pmm.freeMemory() / 1048576});

    heap.init();
    log.kprintln("[mem] Heap: 4 MB initialized", .{});

    // === Phase 4: Shell ===
    log.kprintln("", .{});
    shell.run(); // Enter shell main loop, never returns

    cpu.halt();
}
```

---

## 3. Phase 2: CPU Initialization

### 3.1 src/gdt.zig — Global Descriptor Table

The GDT is constructed at comptime; at runtime only lgdt + ltr are needed.

#### Segment Layout

| Index | Selector | Description | Base | Limit | Access | Flags |
|-------|----------|-------------|------|-------|--------|-------|
| 0 | 0x00 | Null | 0 | 0 | 0 | 0 |
| 1 | 0x08 | Kernel Code 64-bit | 0 | 0xFFFFF | 0x9A | 0xA (L=1,G=1) |
| 2 | 0x10 | Kernel Data | 0 | 0xFFFFF | 0x92 | 0xC (G=1,DB=1) |
| 3 | 0x18 | User Data | 0 | 0xFFFFF | 0xF2 | 0xC |
| 4 | 0x20 | User Code 64-bit | 0 | 0xFFFFF | 0xFA | 0xA |
| 5-6 | 0x28 | TSS (16 bytes) | tss_addr | sizeof(TSS)-1 | 0x89 | 0x0 |

#### GDT Entry Encoding (8 bytes)

```
Bits 0-15:   limit[0:15]
Bits 16-31:  base[0:15]
Bits 32-39:  base[16:23]
Bits 40-47:  access byte
Bits 48-51:  limit[16:19]
Bits 52-55:  flags (G, DB/L, L, AVL)
Bits 56-63:  base[24:31]
```

#### TSS Structure (104 bytes, packed struct)

```zig
pub const Tss = packed struct {
    reserved0: u32 = 0,
    /// Ring 0 stack pointer — set to top of kernel interrupt stack
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    /// Interrupt Stack Table — IST1 used for double fault handler
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = @sizeOf(Tss),
};
```

#### Interface

```zig
pub const KERNEL_CODE_SEL: u16 = 0x08;
pub const KERNEL_DATA_SEL: u16 = 0x10;
pub const USER_DATA_SEL: u16 = 0x18;
pub const USER_CODE_SEL: u16 = 0x20;
pub const TSS_SEL: u16 = 0x28;

var tss: Tss = .{};

// 8KB interrupt stack (used for ring3→ring0 transitions + double fault IST)
var interrupt_stack: [8192]u8 align(16) = undefined;
var double_fault_stack: [4096]u8 align(16) = undefined;

pub fn init() void {
    // 1. Set TSS.rsp0 = top of interrupt_stack
    tss.rsp0 = @intFromPtr(&interrupt_stack) + interrupt_stack.len;
    // 2. Set TSS.ist1 = top of double_fault_stack
    tss.ist1 = @intFromPtr(&double_fault_stack) + double_fault_stack.len;
    // 3. Construct GDT (entries built at comptime, TSS address filled at runtime)
    // 4. lgdt
    // 5. Reload segment registers (mov $0x10, %ax; mov %ax, %ds/es/fs/gs/ss)
    // 6. Far jump to reload CS (inline asm: push KERNEL_CODE_SEL; push .reload_cs; retfq)
    // 7. ltr(TSS_SEL)
}

/// Used in Phase 5: set TSS.rsp0 to the current task's kernel stack
pub fn setKernelStack(stack_top: u64) void {
    tss.rsp0 = stack_top;
}
```

#### Inline Assembly for Reloading Segment Registers

```zig
// Reload data segment registers
asm volatile (
    \\mov $0x10, %%ax
    \\mov %%ax, %%ds
    \\mov %%ax, %%es
    \\mov %%ax, %%fs
    \\mov %%ax, %%gs
    \\mov %%ax, %%ss
);

// Far jump to reload CS
asm volatile (
    \\push $0x08
    \\lea 1f(%%rip), %%rax
    \\push %%rax
    \\retfq
    \\1:
);
```

### 3.2 src/idt.zig — Interrupt Descriptor Table

#### IDT Gate Encoding (16 bytes)

```
Bytes 0-1:   offset[0:15]
Bytes 2-3:   segment selector (KERNEL_CODE_SEL = 0x08)
Byte 4:      IST entry (0 = no IST, 1 = IST1 for double fault)
Byte 5:      type_attr (0x8E = interrupt gate, present, DPL=0)
                        (0xEE = interrupt gate, present, DPL=3, for syscall)
Bytes 6-7:   offset[16:31]
Bytes 8-11:  offset[32:63]
Bytes 12-15: reserved (0)
```

```zig
pub const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};
```

#### 256 IDT Entries

```zig
var idt: [256]IdtEntry = undefined;

pub fn init() void {
    // Fill all 256 entries with the default handler
    for (0..256) |i| {
        idt[i] = makeGate(defaultHandler, 0, 0x8E);
    }

    // Set specific exception handlers
    idt[0]  = makeGate(divisionError, 0, 0x8E);       // #DE
    idt[1]  = makeGate(debug, 0, 0x8E);                // #DB
    idt[3]  = makeGate(breakpoint, 0, 0x8E);           // #BP
    idt[6]  = makeGate(invalidOpcode, 0, 0x8E);        // #UD
    idt[8]  = makeGate(doubleFault, 1, 0x8E);          // #DF (IST=1)
    idt[13] = makeGate(generalProtection, 0, 0x8E);    // #GP
    idt[14] = makeGate(pageFault, 0, 0x8E);            // #PF

    // Hardware IRQ handlers (PIC remapped to 32-47)
    idt[32] = makeGate(irq0Handler, 0, 0x8E);  // PIT timer
    idt[33] = makeGate(irq1Handler, 0, 0x8E);  // Keyboard

    // Syscall (int 0x80) — DPL=3 allows user-mode invocation
    idt[0x80] = makeGate(syscallHandler, 0, 0xEE);

    // Load IDT
    const idtr = cpu.IdtRegister{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    cpu.lidt(&idtr);
}
```

#### Exception Handler Signatures

Each exception handler needs to save registers, handle the exception, and restore registers.
Use naked functions to write assembly stubs that call Zig handler functions.

**Approach A (Recommended):** If Zig 0.15 supports `callconv(.interrupt)`, use it directly:

```zig
fn pageFault(frame: *InterruptFrame, error_code: u64) callconv(.interrupt) void {
    const addr = cpu.readCr2();
    log.kprintln("PAGE FAULT at 0x{x}, error={x}", .{addr, error_code});
    cpu.halt();
}
```

**Approach B (Fallback):** Naked assembly stub:

```zig
fn irq0Handler() callconv(.naked) void {
    asm volatile (
        \\push %%rax
        \\push %%rcx
        \\push %%rdx
        \\push %%rdi
        \\push %%rsi
        \\push %%r8
        \\push %%r9
        \\push %%r10
        \\push %%r11
        \\call irq0HandlerInner
        \\pop %%r11
        \\pop %%r10
        \\pop %%r9
        \\pop %%r8
        \\pop %%rsi
        \\pop %%rdi
        \\pop %%rdx
        \\pop %%rcx
        \\pop %%rax
        \\iretq
    );
}

export fn irq0HandlerInner() void {
    pit.tick();
    pic.sendEoi(0);
}
```

#### InterruptFrame Structure

```zig
pub const InterruptFrame = packed struct {
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};
```

### 3.3 src/pic.zig — 8259 PIC

```zig
const cpu = @import("cpu.zig");

const PIC1_CMD: u16 = 0x20;
const PIC1_DATA: u16 = 0x21;
const PIC2_CMD: u16 = 0xA0;
const PIC2_DATA: u16 = 0xA1;

const ICW1_INIT: u8 = 0x11;
const ICW4_8086: u8 = 0x01;
const EOI: u8 = 0x20;

/// Primary PIC offset (IRQ 0-7 mapped to interrupts 32-39)
pub const PRIMARY_OFFSET: u8 = 32;
/// Secondary PIC offset (IRQ 8-15 mapped to interrupts 40-47)
pub const SECONDARY_OFFSET: u8 = 40;

pub fn init() void {
    // Save old masks
    const mask1 = cpu.inb(PIC1_DATA);
    const mask2 = cpu.inb(PIC2_DATA);

    // ICW1: Initialize + ICW4
    cpu.outb(PIC1_CMD, ICW1_INIT);
    cpu.ioWait();
    cpu.outb(PIC2_CMD, ICW1_INIT);
    cpu.ioWait();

    // ICW2: Offsets
    cpu.outb(PIC1_DATA, PRIMARY_OFFSET);
    cpu.ioWait();
    cpu.outb(PIC2_DATA, SECONDARY_OFFSET);
    cpu.ioWait();

    // ICW3: Primary PIC's IRQ2 connects to secondary PIC
    cpu.outb(PIC1_DATA, 4); // bit 2 = IRQ2
    cpu.ioWait();
    cpu.outb(PIC2_DATA, 2); // cascade identity
    cpu.ioWait();

    // ICW4: 8086 mode
    cpu.outb(PIC1_DATA, ICW4_8086);
    cpu.ioWait();
    cpu.outb(PIC2_DATA, ICW4_8086);
    cpu.ioWait();

    // Restore masks (or set new ones: only allow IRQ0=timer, IRQ1=keyboard)
    _ = mask1;
    _ = mask2;
    cpu.outb(PIC1_DATA, 0xFC); // Allow IRQ0 (timer) and IRQ1 (keyboard)
    cpu.outb(PIC2_DATA, 0xFF); // Mask all secondary PIC IRQs
}

pub fn sendEoi(irq: u8) void {
    if (irq >= 8) {
        cpu.outb(PIC2_CMD, EOI);
    }
    cpu.outb(PIC1_CMD, EOI);
}

pub fn setMask(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const line = irq % 8;
    const val = cpu.inb(port) | (@as(u8, 1) << @intCast(line));
    cpu.outb(port, val);
}

pub fn clearMask(irq: u8) void {
    const port: u16 = if (irq < 8) PIC1_DATA else PIC2_DATA;
    const line = irq % 8;
    const val = cpu.inb(port) & ~(@as(u8, 1) << @intCast(line));
    cpu.outb(port, val);
}
```

### 3.4 src/pit.zig — Programmable Interval Timer

```zig
const cpu = @import("cpu.zig");

const PIT_CHANNEL0: u16 = 0x40;
const PIT_CMD: u16 = 0x43;
const PIT_BASE_FREQ: u32 = 1193182;

var ticks: u64 = 0;
var frequency: u32 = 100;

pub fn init(hz: u32) void {
    frequency = hz;
    const divisor: u16 = @intCast(PIT_BASE_FREQ / hz);

    // Channel 0, access mode lo/hi, mode 3 (square wave)
    cpu.outb(PIT_CMD, 0x36);
    cpu.outb(PIT_CHANNEL0, @intCast(divisor & 0xFF));
    cpu.outb(PIT_CHANNEL0, @intCast((divisor >> 8) & 0xFF));
}

/// Called once per IRQ0
pub fn tick() void {
    ticks += 1;
}

pub fn getTicks() u64 {
    return ticks;
}

/// Returns seconds elapsed since boot
pub fn uptimeSeconds() u64 {
    return ticks / frequency;
}

/// Returns milliseconds elapsed since boot
pub fn uptimeMs() u64 {
    return (ticks * 1000) / frequency;
}
```

---

## 4. Phase 3: Memory Management

### 4.1 src/pmm.zig — Physical Memory Manager (Bitmap)

```zig
const limine = @import("limine.zig");
const log = @import("log.zig");

const PAGE_SIZE: u64 = 4096;

/// Maximum support for 4GB physical memory = 1M pages = 128KB bitmap
const MAX_PAGES: usize = 1024 * 1024;
var bitmap: [MAX_PAGES / 8]u8 = [_]u8{0xFF} ** (MAX_PAGES / 8); // Initially all marked as used
var total_pages: u64 = 0;
var used_pages: u64 = 0;
var hhdm_offset: u64 = 0;

pub fn init() void {
    hhdm_offset = if (limine.hhdm_request.response) |r| r.offset else 0;

    const resp = limine.memmap_request.response orelse return;

    // Mark all USABLE regions as available
    for (0..resp.entry_count) |i| {
        const entry = resp.entries[i];
        if (entry.entry_type != limine.MEMMAP_USABLE) continue;

        var addr = entry.base;
        const end = entry.base + entry.length;

        // Align to page boundary
        addr = (addr + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);

        while (addr + PAGE_SIZE <= end) : (addr += PAGE_SIZE) {
            const page = addr / PAGE_SIZE;
            if (page < MAX_PAGES) {
                clearBit(page);
                total_pages += 1;
            }
        }
    }

    used_pages = 0;
}

pub fn allocFrame() ?u64 {
    // Linear scan to find the first free page
    for (0..MAX_PAGES) |page| {
        if (!getBit(page)) {
            setBit(page);
            used_pages += 1;
            return page * PAGE_SIZE;
        }
    }
    return null; // OOM
}

pub fn freeFrame(phys_addr: u64) void {
    const page = phys_addr / PAGE_SIZE;
    if (page < MAX_PAGES and getBit(page)) {
        clearBit(page);
        if (used_pages > 0) used_pages -= 1;
    }
}

pub fn freeMemory() u64 {
    return (total_pages - used_pages) * PAGE_SIZE;
}

pub fn totalMemory() u64 {
    return total_pages * PAGE_SIZE;
}

pub fn usedMemory() u64 {
    return used_pages * PAGE_SIZE;
}

/// Convert a physical address to a virtual address (via HHDM)
pub fn physToVirt(phys: u64) u64 {
    return phys + hhdm_offset;
}

// --- Bitmap helpers ---

fn getBit(page: usize) bool {
    return (bitmap[page / 8] & (@as(u8, 1) << @intCast(page % 8))) != 0;
}

fn setBit(page: usize) void {
    bitmap[page / 8] |= @as(u8, 1) << @intCast(page % 8);
}

fn clearBit(page: usize) void {
    bitmap[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
}
```

### 4.2 src/vmm.zig — Virtual Memory Manager

x86_64 four-level page tables (PML4 → PDPT → PD → PT → Page).

```zig
const pmm = @import("pmm.zig");
const cpu = @import("cpu.zig");

const PAGE_SIZE: u64 = 4096;
const ENTRIES_PER_TABLE: usize = 512;

pub const PageFlags = packed struct {
    present: bool = true,
    writable: bool = true,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    huge_page: bool = false,
    global: bool = false,
    _available: u3 = 0,
    _phys_high: u40 = 0,  // physical address bits 12-51
    _available2: u11 = 0,
    no_execute: bool = false,
};

const PageTable = [ENTRIES_PER_TABLE]u64;

/// Map a virtual address to a physical address
pub fn mapPage(virt: u64, phys: u64, writable: bool, user: bool) bool {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const cr3 = cpu.readCr3();
    const pml4: *PageTable = @ptrFromInt(pmm.physToVirt(cr3 & 0x000FFFFFFFFFF000));

    // Walk/create PDPT
    const pdpt = getOrCreateTable(&pml4[pml4_idx]) orelse return false;
    // Walk/create PD
    const pd = getOrCreateTable(&pdpt[pdpt_idx]) orelse return false;
    // Walk/create PT
    const pt = getOrCreateTable(&pd[pd_idx]) orelse return false;

    // Set entry
    var flags: u64 = 0x01; // present
    if (writable) flags |= 0x02;
    if (user) flags |= 0x04;
    pt[pt_idx] = (phys & 0x000FFFFFFFFFF000) | flags;

    // Flush TLB for this address
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
    );

    return true;
}

/// Unmap a virtual address, returning the previously mapped physical address
pub fn unmapPage(virt: u64) ?u64 {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const cr3 = cpu.readCr3();
    const pml4: *PageTable = @ptrFromInt(pmm.physToVirt(cr3 & 0x000FFFFFFFFFF000));

    const pdpt = getTable(pml4[pml4_idx]) orelse return null;
    const pd = getTable(pdpt[pdpt_idx]) orelse return null;
    const pt = getTable(pd[pd_idx]) orelse return null;

    const entry = pt[pt_idx];
    if (entry & 0x01 == 0) return null;

    pt[pt_idx] = 0;
    asm volatile ("invlpg (%[addr])" : : [addr] "r" (virt));
    return entry & 0x000FFFFFFFFFF000;
}

/// Translate a virtual address to a physical address
pub fn translateAddr(virt: u64) ?u64 {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;
    const offset = virt & 0xFFF;

    const cr3 = cpu.readCr3();
    const pml4: *PageTable = @ptrFromInt(pmm.physToVirt(cr3 & 0x000FFFFFFFFFF000));

    const pdpt = getTable(pml4[pml4_idx]) orelse return null;
    const pd = getTable(pdpt[pdpt_idx]) orelse return null;
    const pt = getTable(pd[pd_idx]) orelse return null;

    const entry = pt[pt_idx];
    if (entry & 0x01 == 0) return null;
    return (entry & 0x000FFFFFFFFFF000) + offset;
}

// --- Internal ---

fn getTable(entry: u64) ?*PageTable {
    if (entry & 0x01 == 0) return null;
    return @ptrFromInt(pmm.physToVirt(entry & 0x000FFFFFFFFFF000));
}

fn getOrCreateTable(entry: *u64) ?*PageTable {
    if (entry.* & 0x01 != 0) {
        return @ptrFromInt(pmm.physToVirt(entry.* & 0x000FFFFFFFFFF000));
    }
    // Allocate a new page table
    const frame = pmm.allocFrame() orelse return null;
    // Zero it out
    const ptr: [*]u8 = @ptrFromInt(pmm.physToVirt(frame));
    for (0..4096) |i| ptr[i] = 0;
    // Set entry: present + writable + user
    entry.* = frame | 0x07;
    return @ptrFromInt(pmm.physToVirt(frame));
}
```

### 4.3 src/heap.zig — Kernel Heap

A simple free-list allocator implementing the `std.mem.Allocator` interface.

```zig
const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

const HEAP_START: u64 = 0xFFFF_C000_0000_0000; // Heap virtual address
const HEAP_SIZE: u64 = 4 * 1024 * 1024;        // 4 MB

const FreeBlock = struct {
    size: usize,
    next: ?*FreeBlock,
};

var free_list: ?*FreeBlock = null;
var heap_initialized: bool = false;

pub fn init() void {
    // Map physical pages for the heap
    var offset: u64 = 0;
    while (offset < HEAP_SIZE) : (offset += 4096) {
        const frame = pmm.allocFrame() orelse return;
        _ = vmm.mapPage(HEAP_START + offset, frame, true, false);
    }

    // Initialize free list: one single free block
    free_list = @ptrFromInt(HEAP_START);
    free_list.?.size = HEAP_SIZE - @sizeOf(FreeBlock);
    free_list.?.next = null;
    heap_initialized = true;
}

/// Return a std.mem.Allocator interface
pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        },
    };
}

fn alloc(_: *anyopaque, len: usize, _: u8, _: usize) ?[*]u8 {
    // First-fit allocation
    var prev: ?*FreeBlock = null;
    var current = free_list;

    while (current) |block| {
        if (block.size >= len) {
            const remaining = block.size - len - @sizeOf(FreeBlock);
            if (remaining > 32) {
                // Split block
                const new_block: *FreeBlock = @ptrFromInt(@intFromPtr(block) + @sizeOf(FreeBlock) + len);
                new_block.size = remaining;
                new_block.next = block.next;
                block.size = len;
                if (prev) |p| { p.next = new_block; } else { free_list = new_block; }
            } else {
                // Use entire block
                if (prev) |p| { p.next = block.next; } else { free_list = block.next; }
            }
            return @ptrFromInt(@intFromPtr(block) + @sizeOf(FreeBlock));
        }
        prev = block;
        current = block.next;
    }
    return null; // OOM
}

fn resize(_: *anyopaque, _: [*]u8, _: usize, _: usize, _: usize) bool {
    return false; // Resize not supported
}

fn free(_: *anyopaque, buf: [*]u8, len: usize, _: usize) void {
    const block: *FreeBlock = @ptrFromInt(@intFromPtr(buf) - @sizeOf(FreeBlock));
    block.size = len;
    block.next = free_list;
    free_list = block;
    // TODO: coalesce adjacent free blocks
}
```

---

## 5. Phase 4: Keyboard and Shell

### 5.1 src/keyboard.zig — PS/2 Keyboard

```zig
const cpu = @import("cpu.zig");

const KB_DATA_PORT: u16 = 0x60;
const KB_STATUS_PORT: u16 = 0x64;

/// Keyboard event (written to ring buffer from interrupt handler)
pub const KeyEvent = union(enum) {
    char: u8,
    enter,
    backspace,
    tab,
    escape,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    home,
    end,
    delete,
    page_up,
    page_down,
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
};

// Ring buffer
const BUFFER_SIZE = 128;
var key_buffer: [BUFFER_SIZE]KeyEvent = undefined;
var buf_read: usize = 0;
var buf_write: usize = 0;

var shift_pressed: bool = false;
var ctrl_pressed: bool = false;
var extended: bool = false;

/// Called from IRQ1 interrupt
pub fn handleInterrupt() void {
    const scancode = cpu.inb(KB_DATA_PORT);

    if (scancode == 0xE0) {
        extended = true;
        return;
    }

    const is_release = (scancode & 0x80) != 0;
    const code = scancode & 0x7F;

    if (extended) {
        extended = false;
        if (!is_release) {
            const event: ?KeyEvent = switch (code) {
                0x48 => .arrow_up,
                0x50 => .arrow_down,
                0x4B => .arrow_left,
                0x4D => .arrow_right,
                0x47 => .home,
                0x4F => .end,
                0x53 => .delete,
                0x49 => .page_up,
                0x51 => .page_down,
                else => null,
            };
            if (event) |e| pushEvent(e);
        }
        return;
    }

    // Shift tracking
    if (code == 0x2A or code == 0x36) {
        shift_pressed = !is_release;
        return;
    }
    // Ctrl tracking
    if (code == 0x1D) {
        ctrl_pressed = !is_release;
        return;
    }

    if (is_release) return;

    // Special keys
    switch (code) {
        0x1C => pushEvent(.enter),
        0x0E => pushEvent(.backspace),
        0x0F => pushEvent(.tab),
        0x01 => pushEvent(.escape),
        0x3B => pushEvent(.f1),
        0x3C => pushEvent(.f2),
        0x3D => pushEvent(.f3),
        // ... f4-f12 similar
        else => {
            // Regular characters
            const char = scancodeToChar(code);
            if (char != 0) {
                var c = char;
                if (shift_pressed) c = shiftChar(c);
                if (ctrl_pressed and c >= 'a' and c <= 'z') c = c - 'a' + 1; // Ctrl+A = 0x01
                pushEvent(.{ .char = c });
            }
        },
    }
}

pub fn readEvent() ?KeyEvent {
    if (buf_read == buf_write) return null;
    const event = key_buffer[buf_read];
    buf_read = (buf_read + 1) % BUFFER_SIZE;
    return event;
}

fn pushEvent(event: KeyEvent) void {
    const next = (buf_write + 1) % BUFFER_SIZE;
    if (next == buf_read) return; // buffer full
    key_buffer[buf_write] = event;
    buf_write = next;
}

/// Scancode Set 1 → ASCII (lookup table generated at comptime)
fn scancodeToChar(code: u8) u8 {
    const table = comptime blk: {
        var t: [128]u8 = [_]u8{0} ** 128;
        // Row 1: number row
        t[0x02] = '1'; t[0x03] = '2'; t[0x04] = '3'; t[0x05] = '4'; t[0x06] = '5';
        t[0x07] = '6'; t[0x08] = '7'; t[0x09] = '8'; t[0x0A] = '9'; t[0x0B] = '0';
        t[0x0C] = '-'; t[0x0D] = '='; t[0x29] = '`';
        // Row 2: QWERTY
        t[0x10] = 'q'; t[0x11] = 'w'; t[0x12] = 'e'; t[0x13] = 'r'; t[0x14] = 't';
        t[0x15] = 'y'; t[0x16] = 'u'; t[0x17] = 'i'; t[0x18] = 'o'; t[0x19] = 'p';
        t[0x1A] = '['; t[0x1B] = ']'; t[0x2B] = '\\';
        // Row 3: ASDF
        t[0x1E] = 'a'; t[0x1F] = 's'; t[0x20] = 'd'; t[0x21] = 'f'; t[0x22] = 'g';
        t[0x23] = 'h'; t[0x24] = 'j'; t[0x25] = 'k'; t[0x26] = 'l';
        t[0x27] = ';'; t[0x28] = '\'';
        // Row 4: ZXCV
        t[0x2C] = 'z'; t[0x2D] = 'x'; t[0x2E] = 'c'; t[0x2F] = 'v'; t[0x30] = 'b';
        t[0x31] = 'n'; t[0x32] = 'm';
        t[0x33] = ','; t[0x34] = '.'; t[0x35] = '/';
        // Space
        t[0x39] = ' ';
        break :blk t;
    };
    if (code < 128) return table[code];
    return 0;
}

fn shiftChar(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32; // uppercase
    return switch (c) {
        '1' => '!', '2' => '@', '3' => '#', '4' => '$', '5' => '%',
        '6' => '^', '7' => '&', '8' => '*', '9' => '(', '0' => ')',
        '-' => '_', '=' => '+', '[' => '{', ']' => '}', '\\' => '|',
        ';' => ':', '\'' => '"', ',' => '<', '.' => '>', '/' => '?',
        '`' => '~',
        else => c,
    };
}
```

### 5.2 src/shell.zig — Interactive Shell

```zig
const log = @import("log.zig");
const vga = @import("vga.zig");
const keyboard = @import("keyboard.zig");
const shell_cmds = @import("shell_cmds.zig");

const MAX_INPUT = 256;
const HISTORY_SIZE = 16;

var input_buf: [MAX_INPUT]u8 = undefined;
var input_len: usize = 0;
var cursor_pos: usize = 0;

// Command history
var history: [HISTORY_SIZE][MAX_INPUT]u8 = undefined;
var history_lens: [HISTORY_SIZE]usize = [_]usize{0} ** HISTORY_SIZE;
var history_count: usize = 0;
var history_index: usize = 0;

pub fn run() noreturn {
    printPrompt();
    while (true) {
        if (keyboard.readEvent()) |event| {
            switch (event) {
                .enter => {
                    log.kprint("\n", .{});
                    if (input_len > 0) {
                        // Save to history
                        addHistory();
                        // Execute command
                        executeCommand(input_buf[0..input_len]);
                    }
                    input_len = 0;
                    cursor_pos = 0;
                    printPrompt();
                },
                .backspace => {
                    if (cursor_pos > 0) {
                        cursor_pos -= 1;
                        input_len -= 1;
                        // Shift subsequent characters
                        var i = cursor_pos;
                        while (i < input_len) : (i += 1) {
                            input_buf[i] = input_buf[i + 1];
                        }
                        // Redraw line
                        redrawLine();
                    }
                },
                .arrow_up => {
                    if (history_count > 0) {
                        if (history_index > 0) history_index -= 1;
                        loadHistory(history_index);
                        redrawLine();
                    }
                },
                .arrow_down => {
                    if (history_index < history_count) {
                        history_index += 1;
                        if (history_index == history_count) {
                            input_len = 0;
                            cursor_pos = 0;
                        } else {
                            loadHistory(history_index);
                        }
                        redrawLine();
                    }
                },
                .char => |c| {
                    if (input_len < MAX_INPUT - 1) {
                        input_buf[input_len] = c;
                        input_len += 1;
                        cursor_pos += 1;
                        log.kprint("{c}", .{c});
                    }
                },
                else => {},
            }
        } else {
            asm volatile ("hlt"); // Wait for interrupt
        }
    }
}

fn executeCommand(line: []const u8) void {
    // Parse command name (before first space)
    var cmd_end: usize = 0;
    while (cmd_end < line.len and line[cmd_end] != ' ') : (cmd_end += 1) {}
    const cmd = line[0..cmd_end];
    const args = if (cmd_end < line.len) line[cmd_end + 1 ..] else "";

    shell_cmds.dispatch(cmd, args);
}

fn printPrompt() void {
    vga.writer.setColor(.light_cyan, .black);
    log.kprint("merlion", .{});
    vga.writer.setColor(.white, .black);
    log.kprint("> ", .{});
    vga.writer.setColor(.light_green, .black);
}

fn redrawLine() void {
    // Simplified implementation: clear line and reprint
    log.kprint("\r", .{});
    printPrompt();
    for (input_buf[0..input_len]) |c| {
        log.kprint("{c}", .{c});
    }
    // Clear trailing characters at end of line
    log.kprint("  ", .{});
    log.kprint("\r", .{});
    printPrompt();
    for (input_buf[0..input_len]) |c| {
        log.kprint("{c}", .{c});
    }
}

fn addHistory() void {
    const idx = history_count % HISTORY_SIZE;
    @memcpy(history[idx][0..input_len], input_buf[0..input_len]);
    history_lens[idx] = input_len;
    if (history_count < HISTORY_SIZE) history_count += 1;
    history_index = history_count;
}

fn loadHistory(idx: usize) void {
    const real_idx = idx % HISTORY_SIZE;
    input_len = history_lens[real_idx];
    @memcpy(input_buf[0..input_len], history[real_idx][0..input_len]);
    cursor_pos = input_len;
}
```

### 5.3 src/shell_cmds.zig — Shell Commands

```zig
const log = @import("log.zig");
const vga = @import("vga.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
// Phase 5: const scheduler = @import("scheduler.zig");
// Phase 6: const vfs = @import("vfs.zig");

const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn ([]const u8) void,
};

const commands = [_]Command{
    .{ .name = "help", .description = "Show available commands", .handler = cmdHelp },
    .{ .name = "clear", .description = "Clear the screen", .handler = cmdClear },
    .{ .name = "echo", .description = "Print text", .handler = cmdEcho },
    .{ .name = "info", .description = "System information", .handler = cmdInfo },
    .{ .name = "mem", .description = "Memory statistics", .handler = cmdMem },
    .{ .name = "uptime", .description = "Time since boot", .handler = cmdUptime },
    .{ .name = "version", .description = "Kernel version", .handler = cmdVersion },
    // Phase 5:
    // .{ .name = "ps", .description = "List tasks", .handler = cmdPs },
    // Phase 6:
    // .{ .name = "ls", .description = "List directory", .handler = cmdLs },
    // .{ .name = "cat", .description = "Print file contents", .handler = cmdCat },
};

pub fn dispatch(cmd: []const u8, args: []const u8) void {
    for (commands) |c| {
        if (strEql(cmd, c.name)) {
            c.handler(args);
            return;
        }
    }
    log.kprintln("Unknown command: {s}. Type 'help' for commands.", .{cmd});
}

fn cmdHelp(_: []const u8) void {
    log.kprintln("Available commands:", .{});
    for (commands) |c| {
        log.kprintln("  {s: <12} {s}", .{ c.name, c.description });
    }
}

fn cmdClear(_: []const u8) void {
    vga.writer.clear();
}

fn cmdEcho(args: []const u8) void {
    log.kprintln("{s}", .{args});
}

fn cmdInfo(_: []const u8) void {
    log.kprintln("MerlionOS-Zig v0.1.0", .{});
    log.kprintln("Architecture: x86_64", .{});
    log.kprintln("Boot: Limine", .{});
    log.kprintln("Uptime: {d}s", .{pit.uptimeSeconds()});
    log.kprintln("Memory: {d}/{d} MB free", .{
        pmm.freeMemory() / 1048576,
        pmm.totalMemory() / 1048576,
    });
}

fn cmdMem(_: []const u8) void {
    log.kprintln("Physical memory:", .{});
    log.kprintln("  Total:  {d} MB", .{pmm.totalMemory() / 1048576});
    log.kprintln("  Used:   {d} MB", .{pmm.usedMemory() / 1048576});
    log.kprintln("  Free:   {d} MB", .{pmm.freeMemory() / 1048576});
}

fn cmdUptime(_: []const u8) void {
    const secs = pit.uptimeSeconds();
    const mins = secs / 60;
    const hours = mins / 60;
    log.kprintln("Uptime: {d}h {d}m {d}s ({d} ticks)", .{
        hours, mins % 60, secs % 60, pit.getTicks(),
    });
}

fn cmdVersion(_: []const u8) void {
    log.kprintln("MerlionOS-Zig v0.1.0", .{});
    log.kprintln("Built with Zig 0.15", .{});
}

// --- Helpers ---

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
```

---

## 6. Phase 5: Multitasking

### 6.1 src/task.zig — Task Management

```zig
const pmm = @import("pmm.zig");

pub const MAX_TASKS = 32;
const STACK_SIZE = 16384; // 16 KB per task stack
const STACK_CANARY: u64 = 0xDEAD_BEEF_CAFE_BABE;

pub const TaskState = enum {
    ready,
    running,
    blocked,
    finished,
};

pub const Task = struct {
    pid: u32,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    state: TaskState = .ready,
    rsp: u64 = 0,                    // Saved stack pointer
    stack_bottom: u64 = 0,           // Stack bottom (used for deallocation)
    stack_top: u64 = 0,              // Stack top
    ticks: u64 = 0,                  // Accumulated CPU ticks
    priority: u8 = 128,             // 0=highest, 255=lowest
};

var tasks: [MAX_TASKS]?Task = [_]?Task{null} ** MAX_TASKS;
var current_task: u32 = 0;
var next_pid: u32 = 1;

/// Create a new task
/// entry_fn is the task entry function pointer (fn() callconv(.c) void or noreturn)
pub fn spawn(name: []const u8, entry_fn: u64) ?u32 {
    // Find a free slot
    for (0..MAX_TASKS) |i| {
        if (tasks[i] == null) {
            var task = Task{
                .pid = next_pid,
                .state = .ready,
            };

            // Set name
            const copy_len = @min(name.len, 31);
            @memcpy(task.name[0..copy_len], name[0..copy_len]);
            task.name_len = @intCast(copy_len);

            // Allocate stack (4 physical pages = 16KB)
            // Simplified: uses a global stack array
            // In practice, should allocate from PMM
            task.stack_bottom = allocStack() orelse return null;
            task.stack_top = task.stack_bottom + STACK_SIZE;

            // Set stack canary
            const canary_ptr: *volatile u64 = @ptrFromInt(task.stack_bottom);
            canary_ptr.* = STACK_CANARY;

            // Initialize stack frame (simulate registers saved by context_switch)
            // context_switch expects: push rbx, rbp, r12, r13, r14, r15
            // then ret to entry_fn
            var sp = task.stack_top;
            sp -= 8; @as(*u64, @ptrFromInt(sp)).* = entry_fn; // return address
            sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0; // r15
            sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0; // r14
            sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0; // r13
            sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0; // r12
            sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0; // rbp
            sp -= 8; @as(*u64, @ptrFromInt(sp)).* = 0; // rbx
            task.rsp = sp;

            tasks[i] = task;
            next_pid += 1;
            return task.pid;
        }
    }
    return null; // no free slots
}

pub fn currentTask() ?*Task {
    return if (tasks[current_task]) |*t| t else null;
}

pub fn getTask(index: usize) ?*Task {
    return if (tasks[index]) |*t| t else null;
}

pub fn setCurrentIndex(index: u32) void {
    current_task = index;
}

pub fn getCurrentIndex() u32 {
    return current_task;
}

/// Naked context switch
/// old_rsp: pointer to the location where the current task's RSP is saved
/// new_rsp: RSP value of the new task
pub fn contextSwitch(old_rsp: *volatile u64, new_rsp: u64) callconv(.naked) void {
    asm volatile (
        \\push %%rbx
        \\push %%rbp
        \\push %%r12
        \\push %%r13
        \\push %%r14
        \\push %%r15
        \\mov %%rsp, (%%rdi)
        \\mov %%rsi, %%rsp
        \\pop %%r15
        \\pop %%r14
        \\pop %%r13
        \\pop %%r12
        \\pop %%rbp
        \\pop %%rbx
        \\ret
    );
}

// Simplified stack allocation (using static arrays)
var stack_pool: [MAX_TASKS][STACK_SIZE]u8 align(16) = undefined;
var stack_used: [MAX_TASKS]bool = [_]bool{false} ** MAX_TASKS;

fn allocStack() ?u64 {
    for (0..MAX_TASKS) |i| {
        if (!stack_used[i]) {
            stack_used[i] = true;
            return @intFromPtr(&stack_pool[i]);
        }
    }
    return null;
}
```

### 6.2 src/scheduler.zig — Scheduler

```zig
const task = @import("task.zig");
const gdt = @import("gdt.zig");
const log = @import("log.zig");

var context_switches: u64 = 0;
const QUANTUM = 10; // ticks per time slice
var tick_count: u64 = 0;

/// Called on every PIT interrupt
pub fn timerTick() void {
    tick_count += 1;

    // Update current task's CPU ticks
    if (task.currentTask()) |t| {
        t.ticks += 1;
    }

    // Check if time slice has expired
    if (tick_count % QUANTUM == 0) {
        schedule();
    }
}

/// Round-robin scheduling
pub fn schedule() void {
    const current = task.getCurrentIndex();
    var next = current;

    // Find next ready task
    var i: u32 = 0;
    while (i < task.MAX_TASKS) : (i += 1) {
        next = (current + i + 1) % task.MAX_TASKS;
        if (task.getTask(next)) |t| {
            if (t.state == .ready) break;
        }
    }

    if (next == current) return; // No other ready tasks

    // State transition
    if (task.currentTask()) |old| {
        if (old.state == .running) old.state = .ready;
    }
    if (task.getTask(next)) |new| {
        new.state = .running;
    }

    // Get RSP pointers
    const old_rsp: *volatile u64 = &(task.getTask(current).?.rsp);
    const new_rsp = task.getTask(next).?.rsp;

    task.setCurrentIndex(next);
    context_switches += 1;

    // Context switch
    task.contextSwitch(old_rsp, new_rsp);
}

/// Voluntarily yield the CPU
pub fn yield() void {
    schedule();
}

pub fn getContextSwitches() u64 {
    return context_switches;
}
```

---

## 7. Phase 6: Filesystem

### 7.1 src/vfs.zig — Virtual Filesystem

```zig
const std = @import("std");
const log = @import("log.zig");

pub const MAX_INODES = 256;
pub const MAX_NAME = 64;
pub const MAX_DATA = 4096;

pub const NodeType = enum(u8) {
    directory,
    regular_file,
    device,
    proc_node,
};

pub const Inode = struct {
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    node_type: NodeType = .regular_file,
    parent: u16 = 0,           // parent inode index
    data: [MAX_DATA]u8 = [_]u8{0} ** MAX_DATA,
    data_len: u32 = 0,
    children_count: u16 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    permissions: u16 = 0o755,
    active: bool = false,
};

var inodes: [MAX_INODES]Inode = [_]Inode{.{}} ** MAX_INODES;

pub fn init() void {
    // Root directory (inode 0)
    createDir(0, "/", 0); // root is its own parent

    // Standard directories
    const root = 0;
    _ = createDir(root, "tmp", root);
    _ = createDir(root, "dev", root);
    _ = createDir(root, "proc", root);
    _ = createDir(root, "etc", root);

    // /proc files initialized by procfs.zig
    // /dev files initialized by devfs.zig
}

/// Create a directory
pub fn createDir(parent: u16, name: []const u8, _parent_explicit: u16) ?u16 {
    _ = _parent_explicit;
    const idx = allocInode() orelse return null;
    var inode = &inodes[idx];
    inode.active = true;
    inode.node_type = .directory;
    inode.parent = parent;
    setName(inode, name);
    return idx;
}

/// Create a file
pub fn createFile(parent: u16, name: []const u8) ?u16 {
    const idx = allocInode() orelse return null;
    var inode = &inodes[idx];
    inode.active = true;
    inode.node_type = .regular_file;
    inode.parent = parent;
    setName(inode, name);
    return idx;
}

/// Write data to a file
pub fn writeFile(idx: u16, data: []const u8) bool {
    if (idx >= MAX_INODES) return false;
    var inode = &inodes[idx];
    if (!inode.active) return false;
    const len = @min(data.len, MAX_DATA);
    @memcpy(inode.data[0..len], data[0..len]);
    inode.data_len = @intCast(len);
    return true;
}

/// Read data from a file
pub fn readFile(idx: u16) ?[]const u8 {
    if (idx >= MAX_INODES) return null;
    const inode = &inodes[idx];
    if (!inode.active) return null;
    return inode.data[0..inode.data_len];
}

/// Path resolution: "/tmp/test.txt" → inode index
pub fn resolve(path: []const u8) ?u16 {
    if (path.len == 0) return null;
    if (path[0] != '/') return null;

    var current: u16 = 0; // root
    var start: usize = 1;

    while (start < path.len) {
        // Skip consecutive '/'
        while (start < path.len and path[start] == '/') start += 1;
        if (start >= path.len) break;

        // Find component end
        var end = start;
        while (end < path.len and path[end] != '/') end += 1;

        const component = path[start..end];
        current = findChild(current, component) orelse return null;
        start = end;
    }

    return current;
}

/// List child inodes under a directory
pub fn listDir(dir_idx: u16, callback: *const fn (u16, *const Inode) void) void {
    for (0..MAX_INODES) |i| {
        const inode = &inodes[i];
        if (inode.active and inode.parent == dir_idx and i != dir_idx) {
            callback(@intCast(i), inode);
        }
    }
}

/// Get inode name
pub fn getName(inode: *const Inode) []const u8 {
    return inode.name[0..inode.name_len];
}

pub fn getInode(idx: u16) ?*Inode {
    if (idx >= MAX_INODES) return null;
    if (!inodes[idx].active) return null;
    return &inodes[idx];
}

// --- Internal ---

fn allocInode() ?u16 {
    for (0..MAX_INODES) |i| {
        if (!inodes[i].active) return @intCast(i);
    }
    return null;
}

fn findChild(parent: u16, name: []const u8) ?u16 {
    for (0..MAX_INODES) |i| {
        const inode = &inodes[i];
        if (inode.active and inode.parent == parent and i != parent) {
            if (strEql(getName(inode), name)) return @intCast(i);
        }
    }
    return null;
}

fn setName(inode: *Inode, name: []const u8) void {
    const len = @min(name.len, MAX_NAME - 1);
    @memcpy(inode.name[0..len], name[0..len]);
    inode.name_len = @intCast(len);
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| { if (ca != cb) return false; }
    return true;
}
```

### 7.2 src/procfs.zig — /proc Filesystem

```zig
const vfs = @import("vfs.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const std = @import("std");

pub fn init() void {
    const proc_dir = vfs.resolve("/proc") orelse return;

    // Create virtual files under /proc
    if (vfs.createFile(proc_dir, "version")) |idx| {
        _ = vfs.writeFile(idx, "MerlionOS-Zig v0.1.0\n");
    }
}

/// Dynamically update /proc file contents (called when shell reads them)
pub fn updateUptime() void {
    if (vfs.resolve("/proc/uptime")) |idx| {
        var buf: [64]u8 = undefined;
        const secs = pit.uptimeSeconds();
        const len = std.fmt.bufPrint(&buf, "{d}\n", .{secs}) catch return;
        _ = vfs.writeFile(idx, buf[0..len.len]);
    }
}

pub fn updateMeminfo() void {
    if (vfs.resolve("/proc/meminfo")) |idx| {
        var buf: [256]u8 = undefined;
        const len = std.fmt.bufPrint(&buf,
            "MemTotal: {d} kB\nMemFree: {d} kB\nMemUsed: {d} kB\n",
            .{ pmm.totalMemory() / 1024, pmm.freeMemory() / 1024, pmm.usedMemory() / 1024 },
        ) catch return;
        _ = vfs.writeFile(idx, buf[0..len.len]);
    }
}
```

### 7.3 src/devfs.zig — /dev Filesystem

```zig
const vfs = @import("vfs.zig");

pub fn init() void {
    const dev_dir = vfs.resolve("/dev") orelse return;

    // /dev/null — writes are discarded, reads return empty
    _ = vfs.createFile(dev_dir, "null");

    // /dev/zero — reads return zero bytes
    if (vfs.createFile(dev_dir, "zero")) |idx| {
        var zeros: [256]u8 = [_]u8{0} ** 256;
        _ = vfs.writeFile(idx, &zeros);
    }
}
```

---

## 8. Known Zig 0.15 Caveats

### 8.1 Build Issues

1. **macOS ARM SIGBUS**: `zig build-exe` with `-mcmodel=kernel` or `-mcpu=baseline-...` may SIGBUS on macOS ARM. Solution: use the two-step build (build-obj + ld.lld).

2. **Debug mode link failure**: `-ODebug` + `-mcmodel=kernel` produces `R_X86_64_32` relocations that cannot be linked to higher-half addresses. Use `-OReleaseSmall`.

3. **`__zig_probe_stack` undefined**: `-OReleaseSafe` requires a stack probing function. Use `-OReleaseSmall` or provide the symbol yourself.

### 8.2 Syntax Differences Table

| Zig 0.14 and earlier | Zig 0.15 |
|---|---|
| `callconv(.C)` | `callconv(.c)` |
| `callconv(.Naked)` | `callconv(.naked)` |
| `callconv(.Interrupt)` | `callconv(.interrupt)` |
| `"N{dx}"` (asm constraint) | `"{dx}"` |
| `root_source_file` in build.zig | `root_module = b.createModule(...)` |
| `@enumToInt(x)` | `@intFromEnum(x)` |
| `@intToEnum(T, x)` | `@enumFromInt(x)` |
| `@ptrToInt(x)` | `@intFromPtr(x)` |
| `@intToPtr(T, x)` | `@ptrFromInt(x)` |
| `@ptrCast(*T, x)` | `@ptrCast(x)` (type inferred) |

### 8.3 std Modules Available in Freestanding Mode

| Available | Not Available |
|-----------|---------------|
| `std.fmt` (formatting) | `std.fs` (filesystem) |
| `std.mem` (memory utilities) | `std.net` (networking) |
| `std.math` (math) | `std.os` (operating system) |
| `std.io.GenericWriter` | `std.heap` (requires OS support) |
| `std.debug` (partial) | `std.Thread` (requires OS support) |
| `std.builtin` | `std.process` |

### 8.4 Interrupt Handling Notes

- `callconv(.interrupt)` may or may not be available in Zig 0.15 (depends on the target); if it does not work during testing, use naked + manual push/pop/iretq instead
- IRQ handlers must send EOI to the PIC, otherwise subsequent interrupts will not be received
- Some exceptions include an error code (#DF, #GP, #PF, #TS, etc.) while others do not; naked stubs must handle this accordingly
