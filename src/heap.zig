const std = @import("std");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

const HEAP_START: u64 = 0xFFFF_C000_0000_0000;
const HEAP_SIZE: u64 = 4 * 1024 * 1024;
const MIN_SPLIT_REMAINDER: usize = 32;

const FreeBlock = extern struct {
    size: usize,
    next: ?*FreeBlock,
};

var free_list: ?*FreeBlock = null;
var heap_initialized = false;

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = free,
};

pub fn init() void {
    if (heap_initialized) return;

    var offset: u64 = 0;
    while (offset < HEAP_SIZE) : (offset += pmm.PAGE_SIZE) {
        const frame = pmm.allocFrame() orelse return;
        if (!vmm.mapPage(HEAP_START + offset, frame, true, false)) return;
    }

    free_list = @ptrFromInt(HEAP_START);
    free_list.?.size = HEAP_SIZE - @sizeOf(FreeBlock);
    free_list.?.next = null;
    heap_initialized = true;
}

pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &vtable,
    };
}

pub fn isInitialized() bool {
    return heap_initialized;
}

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (!heap_initialized) return null;

    const align_bytes = alignment.toByteUnits();
    var prev: ?*FreeBlock = null;
    var current = free_list;

    while (current) |block| {
        const payload_addr = @intFromPtr(block) + @sizeOf(FreeBlock);
        const aligned_addr = std.mem.alignForward(usize, payload_addr, align_bytes);
        const padding = aligned_addr - payload_addr;

        if (block.size < padding or block.size - padding < len) {
            prev = block;
            current = block.next;
            continue;
        }

        if (padding != 0) {
            prev = block;
            current = block.next;
            continue;
        }

        const remaining = block.size - len;
        if (remaining > @sizeOf(FreeBlock) + MIN_SPLIT_REMAINDER) {
            const new_block: *FreeBlock = @ptrFromInt(aligned_addr + len);
            new_block.size = remaining - @sizeOf(FreeBlock);
            new_block.next = block.next;
            if (prev) |p| {
                p.next = new_block;
            } else {
                free_list = new_block;
            }
        } else {
            if (prev) |p| {
                p.next = block.next;
            } else {
                free_list = block.next;
            }
        }

        return @ptrFromInt(aligned_addr);
    }

    return null;
}

fn free(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    if (memory.len == 0) return;

    const block: *FreeBlock = @ptrFromInt(@intFromPtr(memory.ptr) - @sizeOf(FreeBlock));
    block.size = memory.len;
    block.next = free_list;
    free_list = block;
}
