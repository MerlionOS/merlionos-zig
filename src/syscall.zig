const std = @import("std");

const log = @import("log.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const vmm = @import("vmm.zig");

pub const SYS = enum(u64) {
    EXIT = 0,
    WRITE = 1,
    READ = 2,
    YIELD = 3,
    GETPID = 4,
    SLEEP = 5,
    BRK = 6,
    OPEN = 7,
    CLOSE = 8,
    STAT = 9,
    MMAP = 10,
};

pub const MAX_SYSCALL = 10;

pub const ENOSYS: i64 = -1;
pub const EFAULT: i64 = -2;
pub const EINVAL: i64 = -3;
pub const ENOMEM: i64 = -4;
pub const EBADF: i64 = -5;
pub const ENOENT: i64 = -6;

const USER_ADDR_MAX: u64 = 0x0000_7FFF_FFFF_FFFF;
const PAGE_MASK: u64 = 0xFFF;
const PAGE_SIZE: u64 = 4096;
const MAX_WRITE_BYTES: usize = 4096;

pub const SyscallContext = struct {
    number: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
    arg6: u64,
};

pub const Stats = struct {
    total_calls: u64,
    by_number: [MAX_SYSCALL + 1]u64,
    unknown_calls: u64,
    fault_returns: u64,
};

var stats: Stats = std.mem.zeroes(Stats);

pub fn init() void {
    stats = std.mem.zeroes(Stats);
}

pub export fn syscallDispatch(
    number: u64,
    arg1: u64,
    arg2: u64,
    arg3: u64,
    arg4: u64,
    arg5: u64,
) callconv(.c) u64 {
    const ctx: SyscallContext = .{
        .number = number,
        .arg1 = arg1,
        .arg2 = arg2,
        .arg3 = arg3,
        .arg4 = arg4,
        .arg5 = arg5,
        .arg6 = 0,
    };
    const result = dispatch(ctx);
    if (isError(result)) stats.fault_returns += 1;
    return result;
}

pub fn getStats() Stats {
    return stats;
}

pub fn syscallName(number: usize) []const u8 {
    return switch (number) {
        0 => "EXIT",
        1 => "WRITE",
        2 => "READ",
        3 => "YIELD",
        4 => "GETPID",
        5 => "SLEEP",
        6 => "BRK",
        7 => "OPEN",
        8 => "CLOSE",
        9 => "STAT",
        10 => "MMAP",
        else => "UNKNOWN",
    };
}

fn dispatch(ctx: SyscallContext) u64 {
    stats.total_calls += 1;
    if (ctx.number > MAX_SYSCALL) {
        stats.unknown_calls += 1;
        return err(ENOSYS);
    }

    const index: usize = @intCast(ctx.number);
    stats.by_number[index] += 1;

    const syscall_number: SYS = @enumFromInt(ctx.number);
    return switch (syscall_number) {
        .EXIT => sysExit(ctx.arg1),
        .WRITE => sysWrite(ctx.arg1, ctx.arg2, ctx.arg3),
        .YIELD => sysYield(),
        .GETPID => sysGetpid(),
        .SLEEP => sysSleep(ctx.arg1),
        .READ, .BRK, .OPEN, .CLOSE, .STAT, .MMAP => err(ENOSYS),
    };
}

fn sysExit(exit_code: u64) u64 {
    const code: i32 = @bitCast(@as(u32, @truncate(exit_code)));
    process.exitCurrent(code);
}

fn sysWrite(fd: u64, buf_ptr: u64, count: u64) u64 {
    if (fd != 1 and fd != 2) return err(EBADF);
    if (count == 0) return 0;

    const capped_count = if (count > MAX_WRITE_BYTES) MAX_WRITE_BYTES else count;
    const len: usize = @intCast(capped_count);
    var buffer: [MAX_WRITE_BYTES]u8 = undefined;
    if (!copyFromUser(buffer[0..len], buf_ptr)) return err(EFAULT);

    log.writeBytes(buffer[0..len]);
    return capped_count;
}

fn sysGetpid() u64 {
    return task.currentPid() orelse 0;
}

fn sysYield() u64 {
    _ = scheduler.yield();
    return 0;
}

fn sysSleep(ticks: u64) u64 {
    if (!scheduler.sleepCurrent(ticks)) return err(EINVAL);
    return 0;
}

fn validateUserBuffer(ptr: u64, len: usize) bool {
    if (len == 0) return true;
    if (ptr == 0 or ptr > USER_ADDR_MAX) return false;

    const len64: u64 = @intCast(len);
    const end = ptr +% len64;
    if (end <= ptr) return false;
    if (end - 1 > USER_ADDR_MAX) return false;

    var page = ptr & ~PAGE_MASK;
    const last_page = (end - 1) & ~PAGE_MASK;
    while (page <= last_page) : (page += PAGE_SIZE) {
        if (vmm.translateAddr(page) == null) return false;
    }
    return true;
}

fn copyFromUser(dest: []u8, user_src: u64) bool {
    if (!validateUserBuffer(user_src, dest.len)) return false;
    const src: [*]const u8 = @ptrFromInt(user_src);
    @memcpy(dest, src[0..dest.len]);
    return true;
}

fn err(value: i64) u64 {
    return @bitCast(value);
}

fn isError(value: u64) bool {
    const signed: i64 = @bitCast(value);
    return signed < 0;
}
