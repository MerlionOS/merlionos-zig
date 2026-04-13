// MerlionOS-Zig kernel entry point.
// Boots via Limine protocol into 64-bit long mode.

const limine = @import("limine.zig");
const serial = @import("serial.zig");
const vga = @import("vga.zig");
const log = @import("log.zig");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const process = @import("process.zig");
const heap = @import("heap.zig");
const pci = @import("pci.zig");
const e1000 = @import("e1000.zig");
const net = @import("net.zig");
const eth = @import("eth.zig");
const arp_cache = @import("arp_cache.zig");
const ipv4 = @import("ipv4.zig");
const icmp = @import("icmp.zig");
const socket = @import("socket.zig");
const ai = @import("ai.zig");
const task = @import("task.zig");
const scheduler = @import("scheduler.zig");
const vfs = @import("vfs.zig");
const procfs = @import("procfs.zig");
const devfs = @import("devfs.zig");
const initfs = @import("initfs.zig");
const shell = @import("shell.zig");
const syscall = @import("syscall.zig");
const user_mem = @import("user_mem.zig");

pub const panic = @import("panic.zig").panic;

// Compiler builtins for freestanding
comptime {
    _ = @import("mem.zig");
}

const VERSION = "0.1.0";

export fn _start() callconv(.c) noreturn {
    // Phase 1: Serial output (works immediately)
    serial.com1.init();
    const sw = serial.com1.writer();
    sw.print("\r\n[boot] MerlionOS-Zig kernel _start reached\r\n", .{}) catch {};

    // Phase 2: Read HHDM offset
    if (limine.hhdm_request.response) |resp| {
        sw.print("[boot] HHDM offset: 0x{x}\r\n", .{resp.offset}) catch {};
    } else {
        sw.print("[boot] WARNING: no HHDM response\r\n", .{}) catch {};
    }

    // Phase 3: Initialize VGA text mode
    vga.vga_writer.init();

    // Phase 4: Print banner to both serial + VGA
    log.kprintln("", .{});
    log.kprintln("        |\\|__/|", .{});
    log.kprintln("       / o  o  \\     MerlionOS-Zig v{s}", .{VERSION});
    log.kprintln("      (    W     )    Built with Zig 0.15", .{});
    log.kprintln("       \\  ---  /     x86_64 | Limine boot", .{});
    log.kprintln("        |  |  |      ", .{});
    log.kprintln("        /      \\     Built for AI.", .{});
    log.kprintln("       |        |    Built by AI.", .{});
    log.kprintln("      /    /\\    \\   ", .{});
    log.kprintln("     |_|__|  |_|__|  ", .{});
    log.kprintln("", .{});

    // Phase 5: Print memory map
    if (limine.memmap_request.response) |resp| {
        log.kprintln("[mem] Memory map ({d} entries):", .{resp.entry_count});
        var total_usable: u64 = 0;
        for (0..resp.entry_count) |i| {
            const entry = resp.entries[i];
            const type_str = switch (entry.entry_type) {
                limine.MEMMAP_USABLE => "usable",
                limine.MEMMAP_RESERVED => "reserved",
                limine.MEMMAP_ACPI_RECLAIMABLE => "ACPI recl",
                limine.MEMMAP_ACPI_NVS => "ACPI NVS",
                limine.MEMMAP_BAD_MEMORY => "bad",
                limine.MEMMAP_BOOTLOADER_RECLAIMABLE => "boot recl",
                limine.MEMMAP_KERNEL_AND_MODULES => "kernel",
                limine.MEMMAP_FRAMEBUFFER => "framebuf",
                else => "unknown",
            };
            log.kprintln("  0x{x:0>16} - 0x{x:0>16} ({s})", .{
                entry.base,
                entry.base + entry.length,
                type_str,
            });
            if (entry.entry_type == limine.MEMMAP_USABLE) {
                total_usable += entry.length;
            }
        }
        log.kprintln("[mem] Total usable: {d} MB", .{total_usable / (1024 * 1024)});
    } else {
        log.kprintln("[mem] WARNING: no memory map response", .{});
    }

    gdt.init();
    log.kprintln("[cpu] GDT loaded", .{});

    idt.init();
    log.kprintln("[cpu] IDT loaded", .{});
    syscall.init();
    log.kprintln("[sys] Syscall dispatcher initialized", .{});

    pic.init();
    log.kprintln("[cpu] PIC initialized", .{});

    pit.init(100);
    log.kprintln("[cpu] PIT: 100 Hz", .{});

    pmm.init();
    log.kprintln("[mem] PMM: total={d} MB free={d} MB", .{
        pmm.totalMemory() / (1024 * 1024),
        pmm.freeMemory() / (1024 * 1024),
    });
    user_mem.init();
    log.kprintln("[mem] User address-space manager initialized", .{});

    heap.init();
    log.kprintln("[mem] Heap initialized: {s}", .{
        if (heap.isInitialized()) "yes" else "no",
    });

    pci.init();
    log.kprintln("[pci] Discovered {d} PCI devices", .{pci.deviceCount()});

    e1000.init();
    if (e1000.detected()) |nic| {
        log.kprintln("[net] Detected {s} at {x:0>2}:{x:0>2}.{d}", .{
            nic.model,
            nic.device.bus,
            nic.device.slot,
            nic.device.function,
        });
    } else {
        log.kprintln("[net] No supported e1000-family NIC detected", .{});
    }

    net.init();
    eth.init();
    arp_cache.init();
    ipv4.init();
    icmp.init();
    socket.init();
    const net_cfg = net.getConfig();
    var ip_buf: [16]u8 = undefined;
    if (net_cfg.mac_valid) {
        var mac_buf: [18]u8 = undefined;
        log.kprintln("[net] Stack config: mac={s} ip={s}", .{
            net.formatMac(net_cfg.local_mac, &mac_buf),
            net.formatIp(net_cfg.local_ip, &ip_buf),
        });
    } else {
        log.kprintln("[net] Stack config: no NIC ip={s}", .{
            net.formatIp(net_cfg.local_ip, &ip_buf),
        });
    }

    ai.init();
    log.kprintln("[ai] COM2 LLM proxy: {s}", .{
        if (ai.info().available) "available" else "unavailable",
    });

    vfs.init();
    procfs.init();
    devfs.init();
    initfs.init();
    log.kprintln("[fs] VFS initialized: /tmp /dev /proc /etc /bin", .{});

    task.init();
    scheduler.init();
    process.init();
    if (task.registerBootTask("shell")) |pid| {
        log.kprintln("[task] Boot task registered: shell (pid {d})", .{pid});
    } else {
        log.kprintln("[task] WARNING: failed to register boot task", .{});
    }

    cpu.enableInterrupts();
    log.kprintln("[cpu] Interrupts enabled", .{});
    log.kprintln("[boot] Entering shell.", .{});
    shell.run();
}
