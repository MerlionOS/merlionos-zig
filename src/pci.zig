const cpu = @import("cpu.zig");

const CONFIG_ADDRESS: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

pub const MAX_DEVICES = 64;

pub const Device = struct {
    bus: u8,
    slot: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    revision: u8,
    header_type: u8,
    bar0: u32,
    bar1: u32,
    interrupt_line: u8,
    interrupt_pin: u8,
};

var devices: [MAX_DEVICES]Device = undefined;
var count: usize = 0;

pub fn init() void {
    count = 0;

    for (0..256) |bus_i| {
        const bus: u8 = @intCast(bus_i);
        for (0..32) |slot_i| {
            const slot: u8 = @intCast(slot_i);
            if (readConfig16(bus, slot, 0, 0x00) == 0xFFFF) continue;

            scanFunction(bus, slot, 0);

            const header_type = readConfig8(bus, slot, 0, 0x0E);
            if ((header_type & 0x80) == 0) continue;

            for (1..8) |function_i| {
                const function: u8 = @intCast(function_i);
                if (readConfig16(bus, slot, function, 0x00) != 0xFFFF) {
                    scanFunction(bus, slot, function);
                }
            }
        }
    }
}

pub fn deviceCount() usize {
    return count;
}

pub fn deviceAt(index: usize) ?*const Device {
    if (index >= count) return null;
    return &devices[index];
}

pub fn forEach(callback: *const fn (*const Device) void) void {
    for (devices[0..count]) |*device| {
        callback(device);
    }
}

pub fn className(device: *const Device) []const u8 {
    if (device.class_code == 0x02 and device.subclass == 0x00) return "ethernet";

    return switch (device.class_code) {
        0x00 => "unclassified",
        0x01 => "storage",
        0x02 => "network",
        0x03 => "display",
        0x04 => "multimedia",
        0x05 => "memory",
        0x06 => "bridge",
        0x07 => "serial-bus",
        0x08 => "system",
        0x09 => "input",
        0x0A => "docking",
        0x0B => "processor",
        0x0C => "controller",
        else => "unknown",
    };
}

fn scanFunction(bus: u8, slot: u8, function: u8) void {
    if (count >= MAX_DEVICES) return;

    devices[count] = .{
        .bus = bus,
        .slot = slot,
        .function = function,
        .vendor_id = readConfig16(bus, slot, function, 0x00),
        .device_id = readConfig16(bus, slot, function, 0x02),
        .revision = readConfig8(bus, slot, function, 0x08),
        .prog_if = readConfig8(bus, slot, function, 0x09),
        .subclass = readConfig8(bus, slot, function, 0x0A),
        .class_code = readConfig8(bus, slot, function, 0x0B),
        .header_type = readConfig8(bus, slot, function, 0x0E),
        .bar0 = readConfig32(bus, slot, function, 0x10),
        .bar1 = readConfig32(bus, slot, function, 0x14),
        .interrupt_line = readConfig8(bus, slot, function, 0x3C),
        .interrupt_pin = readConfig8(bus, slot, function, 0x3D),
    };
    count += 1;
}

fn readConfig32(bus: u8, slot: u8, function: u8, offset: u8) u32 {
    const address: u32 = 0x80000000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, function) << 8) |
        (@as(u32, offset) & 0xFC);

    cpu.outl(CONFIG_ADDRESS, address);
    return cpu.inl(CONFIG_DATA);
}

fn readConfig16(bus: u8, slot: u8, function: u8, offset: u8) u16 {
    const shift: u5 = @intCast((offset & 0x02) * 8);
    return @intCast((readConfig32(bus, slot, function, offset) >> shift) & 0xFFFF);
}

fn readConfig8(bus: u8, slot: u8, function: u8, offset: u8) u8 {
    const shift: u5 = @intCast((offset & 0x03) * 8);
    return @intCast((readConfig32(bus, slot, function, offset) >> shift) & 0xFF);
}
