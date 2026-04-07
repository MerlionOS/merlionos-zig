const pci = @import("pci.zig");
const vmm = @import("vmm.zig");

const MMIO_VIRT_BASE: u64 = 0xFFFF_FFFF_C000_0000;
const REG_CTRL: u32 = 0x0000;
const REG_STATUS: u32 = 0x0008;

pub const BarKind = enum {
    none,
    io,
    memory32,
    memory64,
};

pub const BarInfo = struct {
    raw: u32,
    base: u32,
    kind: BarKind,
    prefetchable: bool,
};

pub const Detection = struct {
    device: *const pci.Device,
    model: []const u8,
    bar0: BarInfo,
    mmio_mapped: bool,
    mmio_uncached: bool,
    mmio_virt: u64,
    ctrl: u32,
    status: u32,
};

var is_detected: bool = false;
var detected_index: usize = 0;
var detected_model: []const u8 = "";
var detected_bar0: BarInfo = .{
    .raw = 0,
    .base = 0,
    .kind = .none,
    .prefetchable = false,
};
var mmio_mapped: bool = false;
var mmio_uncached: bool = false;
var mmio_virt: u64 = 0;
var ctrl: u32 = 0;
var status: u32 = 0;

pub fn init() void {
    is_detected = false;
    mmio_mapped = false;
    mmio_uncached = false;
    mmio_virt = 0;
    ctrl = 0;
    status = 0;

    for (0..pci.deviceCount()) |i| {
        const device = pci.deviceAt(i) orelse continue;
        const model = modelName(device) orelse continue;

        detected_index = i;
        detected_model = model;
        detected_bar0 = decodeBar(device.bar0);
        mapMmio();
        refresh();
        is_detected = true;
        return;
    }
}

pub fn refresh() void {
    if (!mmio_mapped) return;

    ctrl = readReg32(REG_CTRL);
    status = readReg32(REG_STATUS);
}

pub fn detected() ?Detection {
    if (!is_detected) return null;

    return .{
        .device = pci.deviceAt(detected_index) orelse return null,
        .model = detected_model,
        .bar0 = detected_bar0,
        .mmio_mapped = mmio_mapped,
        .mmio_uncached = mmio_uncached,
        .mmio_virt = mmio_virt,
        .ctrl = ctrl,
        .status = status,
    };
}

pub fn modelName(device: *const pci.Device) ?[]const u8 {
    if (device.vendor_id != 0x8086) return null;
    if (device.class_code != 0x02 or device.subclass != 0x00) return null;

    return switch (device.device_id) {
        0x100E => "Intel 82540EM (e1000)",
        0x100F => "Intel 82545EM (e1000)",
        0x1019 => "Intel 82547EI (e1000)",
        0x10D3 => "Intel 82574L (e1000e)",
        0x10F6 => "Intel 82574L (e1000e)",
        0x150C => "Intel 82583V (e1000e)",
        else => null,
    };
}

fn mapMmio() void {
    if (detected_bar0.kind != .memory32 and detected_bar0.kind != .memory64) return;

    mmio_virt = MMIO_VIRT_BASE;
    mmio_mapped = vmm.mapPageWithFlags(mmio_virt, detected_bar0.base, .{
        .writable = true,
        .write_through = true,
        .cache_disable = true,
    });
    mmio_uncached = mmio_mapped;
}

fn readReg32(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_virt + offset);
    return ptr.*;
}

fn decodeBar(raw: u32) BarInfo {
    if (raw == 0) {
        return .{
            .raw = raw,
            .base = 0,
            .kind = .none,
            .prefetchable = false,
        };
    }

    if ((raw & 0x1) != 0) {
        return .{
            .raw = raw,
            .base = raw & 0xFFFF_FFFC,
            .kind = .io,
            .prefetchable = false,
        };
    }

    const kind: BarKind = if (((raw >> 1) & 0x3) == 0x2) .memory64 else .memory32;
    return .{
        .raw = raw,
        .base = raw & 0xFFFF_FFF0,
        .kind = kind,
        .prefetchable = (raw & 0x8) != 0,
    };
}
