const cpu = @import("cpu.zig");

pub const KERNEL_CODE_SEL: u16 = 0x08;
pub const KERNEL_DATA_SEL: u16 = 0x10;
pub const USER_DATA_SEL: u16 = 0x18;
pub const USER_CODE_SEL: u16 = 0x20;
pub const TSS_SEL: u16 = 0x28;

pub const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
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

var tss: Tss = .{};
var interrupt_stack: [8192]u8 align(16) = undefined;
var double_fault_stack: [4096]u8 align(16) = undefined;
var gdt_entries: [7]u64 = .{
    0,
    makeEntry(0, 0xFFFFF, 0x9A, 0xA),
    makeEntry(0, 0xFFFFF, 0x92, 0xC),
    makeEntry(0, 0xFFFFF, 0xF2, 0xC),
    makeEntry(0, 0xFFFFF, 0xFA, 0xA),
    0,
    0,
};

pub fn init() void {
    tss.rsp0 = @intFromPtr(&interrupt_stack) + interrupt_stack.len;
    tss.ist1 = @intFromPtr(&double_fault_stack) + double_fault_stack.len;

    const tss_addr = @intFromPtr(&tss);
    const tss_limit = @sizeOf(Tss) - 1;
    const tss_desc = makeSystemEntry(tss_addr, tss_limit, 0x89, 0x0);
    gdt_entries[5] = tss_desc[0];
    gdt_entries[6] = tss_desc[1];

    const gdtr = cpu.GdtRegister{
        .limit = @sizeOf(@TypeOf(gdt_entries)) - 1,
        .base = @intFromPtr(&gdt_entries),
    };
    cpu.lgdt(&gdtr);

    asm volatile (
        \\mov $0x10, %%ax
        \\mov %%ax, %%ds
        \\mov %%ax, %%es
        \\mov %%ax, %%fs
        \\mov %%ax, %%gs
        \\mov %%ax, %%ss
        ::: .{ .ax = true });

    asm volatile (
        \\pushq $0x08
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        ::: .{ .rax = true, .memory = true });

    cpu.ltr(TSS_SEL);
}

pub fn setKernelStack(stack_top: u64) void {
    tss.rsp0 = stack_top;
}

fn makeEntry(base: u32, limit: u32, access: u8, flags: u8) u64 {
    return (@as(u64, limit & 0xFFFF)) |
        (@as(u64, base & 0xFFFF) << 16) |
        (@as(u64, (base >> 16) & 0xFF) << 32) |
        (@as(u64, access) << 40) |
        (@as(u64, (limit >> 16) & 0x0F) << 48) |
        (@as(u64, flags & 0x0F) << 52) |
        (@as(u64, (base >> 24) & 0xFF) << 56);
}

fn makeSystemEntry(base: u64, limit: usize, access: u8, flags: u8) [2]u64 {
    const limit32: u32 = @intCast(limit);
    const low = (@as(u64, limit32 & 0xFFFF)) |
        (@as(u64, @intCast(base & 0xFFFF)) << 16) |
        (@as(u64, @intCast((base >> 16) & 0xFF)) << 32) |
        (@as(u64, access) << 40) |
        (@as(u64, (limit32 >> 16) & 0x0F) << 48) |
        (@as(u64, flags & 0x0F) << 52) |
        (@as(u64, @intCast((base >> 24) & 0xFF)) << 56);
    const high = (base >> 32) & 0xFFFFFFFF;
    return .{ low, high };
}
