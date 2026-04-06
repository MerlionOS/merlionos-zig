const limine = @import("limine.zig");

pub const PAGE_SIZE: u64 = 4096;

const MAX_PAGES: usize = 1024 * 1024;

var bitmap: [MAX_PAGES / 8]u8 = [_]u8{0xFF} ** (MAX_PAGES / 8);
var total_pages: u64 = 0;
var used_pages: u64 = 0;
var hhdm_offset: u64 = 0;

pub fn init() void {
    bitmap = [_]u8{0xFF} ** (MAX_PAGES / 8);
    total_pages = 0;
    used_pages = 0;
    hhdm_offset = if (limine.hhdm_request.response) |r| r.offset else 0;

    const resp = limine.memmap_request.response orelse return;
    for (0..resp.entry_count) |i| {
        const entry = resp.entries[i];
        if (entry.entry_type != limine.MEMMAP_USABLE) continue;

        var addr = alignForward(entry.base, PAGE_SIZE);
        const end = entry.base + entry.length;
        while (addr + PAGE_SIZE <= end) : (addr += PAGE_SIZE) {
            const page = addr / PAGE_SIZE;
            if (page < MAX_PAGES) {
                clearBit(@intCast(page));
                total_pages += 1;
            }
        }
    }
}

pub fn allocFrame() ?u64 {
    for (0..MAX_PAGES) |page| {
        if (!getBit(page)) {
            setBit(page);
            used_pages += 1;
            return @as(u64, @intCast(page)) * PAGE_SIZE;
        }
    }
    return null;
}

pub fn freeFrame(phys_addr: u64) void {
    const page = phys_addr / PAGE_SIZE;
    if (page < MAX_PAGES and getBit(@intCast(page))) {
        clearBit(@intCast(page));
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

pub fn physToVirt(phys: u64) u64 {
    return phys + hhdm_offset;
}

fn alignForward(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn getBit(page: usize) bool {
    return (bitmap[page / 8] & (@as(u8, 1) << @intCast(page % 8))) != 0;
}

fn setBit(page: usize) void {
    bitmap[page / 8] |= @as(u8, 1) << @intCast(page % 8);
}

fn clearBit(page: usize) void {
    bitmap[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
}
