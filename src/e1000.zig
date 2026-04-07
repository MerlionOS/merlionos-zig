const pci = @import("pci.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

const MMIO_VIRT_BASE: u64 = 0xFFFF_FFFF_C000_0000;
const MMIO_MAP_SIZE: u64 = 0x4000;
const REG_CTRL: u32 = 0x0000;
const REG_STATUS: u32 = 0x0008;
const REG_IMC: u32 = 0x00D8;
const REG_RCTL: u32 = 0x0100;
const REG_TCTL: u32 = 0x0400;
const REG_TIPG: u32 = 0x0410;
const REG_RDBAL: u32 = 0x2800;
const REG_RDBAH: u32 = 0x2804;
const REG_RDLEN: u32 = 0x2808;
const REG_RDH: u32 = 0x2810;
const REG_RDT: u32 = 0x2818;
const REG_TDBAL: u32 = 0x3800;
const REG_TDBAH: u32 = 0x3804;
const REG_TDLEN: u32 = 0x3808;
const REG_TDH: u32 = 0x3810;
const REG_TDT: u32 = 0x3818;

const RX_DESC_COUNT: usize = 8;
const TX_DESC_COUNT: usize = 8;
const RX_BUFFER_SIZE: u16 = 2048;
const TX_BUFFER_SIZE: u16 = 2048;

const TXD_STAT_DD: u8 = 0x01;
const RCTL_EN: u32 = 1 << 1;
const RCTL_BAM: u32 = 1 << 15;
const RCTL_SECRC: u32 = 1 << 26;
const TCTL_EN: u32 = 1 << 1;
const TCTL_PSP: u32 = 1 << 3;
const TCTL_CT_SHIFT: u5 = 4;
const TCTL_COLD_SHIFT: u5 = 12;

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

pub const RingInfo = struct {
    initialized: bool,
    rx_desc_phys: u64,
    tx_desc_phys: u64,
    rx_count: u32,
    tx_count: u32,
    rx_head: u32,
    rx_tail: u32,
    tx_head: u32,
    tx_tail: u32,
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

const RxDesc = extern struct {
    addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};

const TxDesc = extern struct {
    addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

comptime {
    if (@sizeOf(RxDesc) != 16) @compileError("e1000 RX descriptor must be 16 bytes");
    if (@sizeOf(TxDesc) != 16) @compileError("e1000 TX descriptor must be 16 bytes");
}

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
var rings: RingInfo = emptyRingInfo();
var rx_buffers: [RX_DESC_COUNT]u64 = [_]u64{0} ** RX_DESC_COUNT;
var tx_buffers: [TX_DESC_COUNT]u64 = [_]u64{0} ** TX_DESC_COUNT;

pub fn init() void {
    is_detected = false;
    mmio_mapped = false;
    mmio_uncached = false;
    mmio_virt = 0;
    ctrl = 0;
    status = 0;
    rings = emptyRingInfo();
    rx_buffers = [_]u64{0} ** RX_DESC_COUNT;
    tx_buffers = [_]u64{0} ** TX_DESC_COUNT;

    for (0..pci.deviceCount()) |i| {
        const device = pci.deviceAt(i) orelse continue;
        const model = modelName(device) orelse continue;

        detected_index = i;
        detected_model = model;
        detected_bar0 = decodeBar(device.bar0);
        mapMmio();
        initRings();
        refresh();
        is_detected = true;
        return;
    }
}

pub fn refresh() void {
    if (!mmio_mapped) return;

    ctrl = readReg32(REG_CTRL);
    status = readReg32(REG_STATUS);

    if (rings.initialized) {
        rings.rx_head = readReg32(REG_RDH);
        rings.rx_tail = readReg32(REG_RDT);
        rings.tx_head = readReg32(REG_TDH);
        rings.tx_tail = readReg32(REG_TDT);
    }
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

pub fn ringInfo() *const RingInfo {
    return &rings;
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

    var offset: u64 = 0;
    while (offset < MMIO_MAP_SIZE) : (offset += pmm.PAGE_SIZE) {
        if (!vmm.mapPageWithFlags(mmio_virt + offset, detected_bar0.base + offset, .{
            .writable = true,
            .write_through = true,
            .cache_disable = true,
        })) {
            mmio_mapped = false;
            mmio_uncached = false;
            return;
        }
    }

    mmio_mapped = true;
    mmio_uncached = true;
}

fn initRings() void {
    if (!mmio_mapped) return;

    const rx_desc_phys = pmm.allocFrame() orelse return;
    const tx_desc_phys = pmm.allocFrame() orelse return;

    for (0..RX_DESC_COUNT) |i| {
        rx_buffers[i] = pmm.allocFrame() orelse return;
    }
    for (0..TX_DESC_COUNT) |i| {
        tx_buffers[i] = pmm.allocFrame() orelse return;
    }

    const rx_descs: [*]RxDesc = @ptrFromInt(pmm.physToVirt(rx_desc_phys));
    const tx_descs: [*]TxDesc = @ptrFromInt(pmm.physToVirt(tx_desc_phys));

    for (0..RX_DESC_COUNT) |i| {
        rx_descs[i] = .{
            .addr = rx_buffers[i],
            .length = 0,
            .checksum = 0,
            .status = 0,
            .errors = 0,
            .special = 0,
        };
    }

    for (0..TX_DESC_COUNT) |i| {
        tx_descs[i] = .{
            .addr = tx_buffers[i],
            .length = 0,
            .cso = 0,
            .cmd = 0,
            .status = TXD_STAT_DD,
            .css = 0,
            .special = 0,
        };
    }

    writeReg32(REG_IMC, 0xFFFF_FFFF);
    writeReg32(REG_RCTL, 0);
    writeReg32(REG_TCTL, 0);

    writeReg32(REG_RDBAL, @truncate(rx_desc_phys));
    writeReg32(REG_RDBAH, @truncate(rx_desc_phys >> 32));
    writeReg32(REG_RDLEN, @intCast(RX_DESC_COUNT * @sizeOf(RxDesc)));
    writeReg32(REG_RDH, 0);
    writeReg32(REG_RDT, @intCast(RX_DESC_COUNT - 1));

    writeReg32(REG_TDBAL, @truncate(tx_desc_phys));
    writeReg32(REG_TDBAH, @truncate(tx_desc_phys >> 32));
    writeReg32(REG_TDLEN, @intCast(TX_DESC_COUNT * @sizeOf(TxDesc)));
    writeReg32(REG_TDH, 0);
    writeReg32(REG_TDT, 0);
    writeReg32(REG_TIPG, 10 | (@as(u32, 8) << 10) | (@as(u32, 6) << 20));

    writeReg32(REG_RCTL, RCTL_EN | RCTL_BAM | RCTL_SECRC);
    writeReg32(REG_TCTL, TCTL_EN | TCTL_PSP | (@as(u32, 0x10) << TCTL_CT_SHIFT) | (@as(u32, 0x40) << TCTL_COLD_SHIFT));

    rings = .{
        .initialized = true,
        .rx_desc_phys = rx_desc_phys,
        .tx_desc_phys = tx_desc_phys,
        .rx_count = @intCast(RX_DESC_COUNT),
        .tx_count = @intCast(TX_DESC_COUNT),
        .rx_head = 0,
        .rx_tail = @intCast(RX_DESC_COUNT - 1),
        .tx_head = 0,
        .tx_tail = 0,
    };
}

fn readReg32(offset: u32) u32 {
    const ptr: *volatile u32 = @ptrFromInt(mmio_virt + offset);
    return ptr.*;
}

fn writeReg32(offset: u32, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(mmio_virt + offset);
    ptr.* = value;
}

fn emptyRingInfo() RingInfo {
    return .{
        .initialized = false,
        .rx_desc_phys = 0,
        .tx_desc_phys = 0,
        .rx_count = @intCast(RX_DESC_COUNT),
        .tx_count = @intCast(TX_DESC_COUNT),
        .rx_head = 0,
        .rx_tail = 0,
        .tx_head = 0,
        .tx_tail = 0,
    };
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
