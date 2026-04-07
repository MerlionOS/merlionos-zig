const cpu = @import("cpu.zig");
const pmm = @import("pmm.zig");

const ENTRIES_PER_TABLE: usize = 512;

const PageTable = [ENTRIES_PER_TABLE]u64;

const FLAG_PRESENT: u64 = 0x001;
const FLAG_WRITABLE: u64 = 0x002;
const FLAG_USER: u64 = 0x004;
const FLAG_WRITE_THROUGH: u64 = 0x008;
const FLAG_CACHE_DISABLE: u64 = 0x010;

pub const MapFlags = struct {
    writable: bool = false,
    user: bool = false,
    write_through: bool = false,
    cache_disable: bool = false,
};

pub fn mapPage(virt: u64, phys: u64, writable: bool, user: bool) bool {
    return mapPageWithFlags(virt, phys, .{
        .writable = writable,
        .user = user,
    });
}

pub fn mapPageWithFlags(virt: u64, phys: u64, map_flags: MapFlags) bool {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const cr3 = cpu.readCr3();
    const pml4: *PageTable = @ptrFromInt(pmm.physToVirt(cr3 & 0x000F_FFFF_FFFF_F000));

    const pdpt = getOrCreateTable(&pml4[pml4_idx]) orelse return false;
    const pd = getOrCreateTable(&pdpt[pdpt_idx]) orelse return false;
    const pt = getOrCreateTable(&pd[pd_idx]) orelse return false;

    var flags: u64 = FLAG_PRESENT;
    if (map_flags.writable) flags |= FLAG_WRITABLE;
    if (map_flags.user) flags |= FLAG_USER;
    if (map_flags.write_through) flags |= FLAG_WRITE_THROUGH;
    if (map_flags.cache_disable) flags |= FLAG_CACHE_DISABLE;
    pt[pt_idx] = (phys & 0x000F_FFFF_FFFF_F000) | flags;

    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
    return true;
}

pub fn unmapPage(virt: u64) ?u64 {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;

    const cr3 = cpu.readCr3();
    const pml4: *PageTable = @ptrFromInt(pmm.physToVirt(cr3 & 0x000F_FFFF_FFFF_F000));

    const pdpt = getTable(pml4[pml4_idx]) orelse return null;
    const pd = getTable(pdpt[pdpt_idx]) orelse return null;
    const pt = getTable(pd[pd_idx]) orelse return null;

    const entry = pt[pt_idx];
    if (entry & 0x01 == 0) return null;

    pt[pt_idx] = 0;
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
    return entry & 0x000F_FFFF_FFFF_F000;
}

pub fn translateAddr(virt: u64) ?u64 {
    const pml4_idx = (virt >> 39) & 0x1FF;
    const pdpt_idx = (virt >> 30) & 0x1FF;
    const pd_idx = (virt >> 21) & 0x1FF;
    const pt_idx = (virt >> 12) & 0x1FF;
    const offset = virt & 0xFFF;

    const cr3 = cpu.readCr3();
    const pml4: *PageTable = @ptrFromInt(pmm.physToVirt(cr3 & 0x000F_FFFF_FFFF_F000));

    const pdpt = getTable(pml4[pml4_idx]) orelse return null;
    const pd = getTable(pdpt[pdpt_idx]) orelse return null;
    const pt = getTable(pd[pd_idx]) orelse return null;

    const entry = pt[pt_idx];
    if (entry & 0x01 == 0) return null;
    return (entry & 0x000F_FFFF_FFFF_F000) + offset;
}

fn getTable(entry: u64) ?*PageTable {
    if (entry & 0x01 == 0) return null;
    return @ptrFromInt(pmm.physToVirt(entry & 0x000F_FFFF_FFFF_F000));
}

fn getOrCreateTable(entry: *u64) ?*PageTable {
    if (entry.* & 0x01 != 0) {
        return @ptrFromInt(pmm.physToVirt(entry.* & 0x000F_FFFF_FFFF_F000));
    }

    const frame = pmm.allocFrame() orelse return null;
    const table: *PageTable = @ptrFromInt(pmm.physToVirt(frame));
    @memset(table[0..], 0);
    entry.* = frame | 0x07;
    return table;
}

const std = @import("std");
