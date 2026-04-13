const cpu = @import("cpu.zig");
const elf = @import("elf.zig");
const gdt = @import("gdt.zig");
const log = @import("log.zig");
const pmm = @import("pmm.zig");
const task = @import("task.zig");
const user_mem = @import("user_mem.zig");

const MAX_PROCESSES: usize = task.MAX_TASKS;
const PAGE_SIZE: u64 = pmm.PAGE_SIZE;
const PAGE_FRAME_MASK: u64 = 0x000F_FFFF_FFFF_F000;

pub const ProcessType = enum {
    kernel,
    user,
};

pub const ProcessInfo = struct {
    pid: u32,
    proc_type: ProcessType,
    address_space_slot: ?usize,
    kernel_stack_top: u64,
    entry_point: u64,
    exit_code: i32,
    active: bool,
};

pub const KillUserResult = enum {
    killed,
    not_found,
    not_user,
    busy_current,
};

pub const BrkResult = union(enum) {
    ok: u64,
    not_user,
    invalid,
    no_memory,
};

var process_table: [MAX_PROCESSES]ProcessInfo = [_]ProcessInfo{emptyProcessInfo()} ** MAX_PROCESSES;
var address_spaces: [MAX_PROCESSES]user_mem.AddressSpace = undefined;
var address_space_used: [MAX_PROCESSES]bool = [_]bool{false} ** MAX_PROCESSES;
var kernel_cr3: u64 = 0;
var kernel_stack_top: u64 = 0;

pub fn init() void {
    for (&process_table) |*info| {
        info.* = emptyProcessInfo();
    }
    address_space_used = [_]bool{false} ** MAX_PROCESSES;
    kernel_cr3 = cpu.readCr3() & PAGE_FRAME_MASK;
    kernel_stack_top = gdt.defaultKernelStack();
}

pub fn spawnFlat(name: []const u8, code: []const u8, code_vaddr: u64, entry: u64) ?u32 {
    const proc_slot = findFreeSlot() orelse {
        log.kprintln("[proc] spawnFlat: no process slot", .{});
        return null;
    };
    const addr_space = &address_spaces[proc_slot];
    if (!user_mem.createInto(addr_space)) {
        log.kprintln("[proc] spawnFlat: address space create failed", .{});
        return null;
    }
    address_space_used[proc_slot] = true;

    const pages_needed = (code.len + @as(usize, @intCast(PAGE_SIZE - 1))) / @as(usize, @intCast(PAGE_SIZE));
    var page_index: usize = 0;
    while (page_index < pages_needed) : (page_index += 1) {
        const virt = code_vaddr + @as(u64, @intCast(page_index)) * PAGE_SIZE;
        if (!user_mem.mapUserPage(addr_space, virt, true)) {
            log.kprintln("[proc] spawnFlat: code page map failed virt=0x{x}", .{virt});
            releaseAddressSpace(proc_slot);
            return null;
        }
    }

    const saved_cr3 = cpu.readCr3() & PAGE_FRAME_MASK;
    user_mem.activate(addr_space);
    copyToActiveAddressSpace(code_vaddr, code);
    cpu.writeCr3(saved_cr3);

    const spawned = task.spawnUserWithIndex(name, entry, user_mem.USER_STACK_TOP - 8) orelse {
        log.kprintln("[proc] spawnFlat: task spawn failed", .{});
        releaseAddressSpace(proc_slot);
        return null;
    };
    const user_task = task.getTask(spawned.index) orelse {
        log.kprintln("[proc] spawnFlat: task index {d} missing after spawn", .{spawned.index});
        _ = task.kill(spawned.pid);
        releaseAddressSpace(proc_slot);
        return null;
    };

    process_table[proc_slot] = .{
        .pid = spawned.pid,
        .proc_type = .user,
        .address_space_slot = proc_slot,
        .kernel_stack_top = user_task.stack_top,
        .entry_point = entry,
        .exit_code = 0,
        .active = true,
    };

    return spawned.pid;
}

pub fn spawnElf(name: []const u8, data: []const u8) ?u32 {
    var parse_result: elf.ParseResult = undefined;
    const parse_status = elf.parse(data, &parse_result);
    if (parse_status != .ok) {
        log.kprintln("[proc] spawnElf: parse failed: {s}", .{@tagName(parse_status)});
        return null;
    }
    if (!entryWithinLoadSegment(&parse_result)) {
        log.kprintln("[proc] spawnElf: entry point is not covered by a LOAD segment", .{});
        return null;
    }

    const proc_slot = findFreeSlot() orelse {
        log.kprintln("[proc] spawnElf: no process slot", .{});
        return null;
    };
    const addr_space = &address_spaces[proc_slot];
    if (!user_mem.createInto(addr_space)) {
        log.kprintln("[proc] spawnElf: address space create failed", .{});
        return null;
    }
    address_space_used[proc_slot] = true;

    if (!elf.load(data, &parse_result, addr_space)) {
        log.kprintln("[proc] spawnElf: load failed", .{});
        releaseAddressSpace(proc_slot);
        return null;
    }

    const spawned = task.spawnUserWithIndex(name, parse_result.entry_point, user_mem.USER_STACK_TOP - 8) orelse {
        log.kprintln("[proc] spawnElf: task spawn failed", .{});
        releaseAddressSpace(proc_slot);
        return null;
    };
    const user_task = task.getTask(spawned.index) orelse {
        log.kprintln("[proc] spawnElf: task index {d} missing after spawn", .{spawned.index});
        _ = task.kill(spawned.pid);
        releaseAddressSpace(proc_slot);
        return null;
    };

    process_table[proc_slot] = .{
        .pid = spawned.pid,
        .proc_type = .user,
        .address_space_slot = proc_slot,
        .kernel_stack_top = user_task.stack_top,
        .entry_point = parse_result.entry_point,
        .exit_code = 0,
        .active = true,
    };

    return spawned.pid;
}

pub fn exitCurrent(exit_code: i32) noreturn {
    if (task.currentTask()) |current| {
        if (getProcessInfoMutable(current.pid)) |info| {
            info.exit_code = exit_code;
            info.active = false;
            if (info.address_space_slot) |slot| {
                info.address_space_slot = null;
                releaseAddressSpace(slot);
            }
        }
        current.state = .finished;
        log.kprintln("[proc] user process {d} exited code={d}", .{ current.pid, exit_code });
    }

    task.yieldCurrent();
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn faultCurrent(kind: []const u8, exit_code: i32, error_code: u64, rip: u64, fault_addr: u64, has_fault_addr: bool) noreturn {
    if (task.currentTask()) |current| {
        if (current.is_user and getProcessInfoMutable(current.pid) != null) {
            if (has_fault_addr) {
                log.kprintln("[proc] killing user process {d}: {s} rip=0x{x} err=0x{x} addr=0x{x}", .{
                    current.pid,
                    kind,
                    rip,
                    error_code,
                    fault_addr,
                });
            } else {
                log.kprintln("[proc] killing user process {d}: {s} rip=0x{x} err=0x{x}", .{
                    current.pid,
                    kind,
                    rip,
                    error_code,
                });
            }
            exitCurrent(exit_code);
        }
    }

    log.kprintln("[proc] unhandled process fault: {s} rip=0x{x} err=0x{x}", .{ kind, rip, error_code });
    cpu.halt();
}

pub fn killUser(pid: u32) KillUserResult {
    const info = getProcessInfoMutable(pid) orelse {
        return if (task.pidExists(pid)) .not_user else .not_found;
    };
    if (task.currentPid() == pid) return .busy_current;

    info.active = false;
    if (info.address_space_slot) |slot| {
        info.address_space_slot = null;
        releaseAddressSpace(slot);
    }

    const result = task.kill(pid);
    switch (result) {
        .killed, .not_found => info.* = emptyProcessInfo(),
        .busy_current => {},
    }

    return switch (result) {
        .killed => .killed,
        .not_found => .not_found,
        .busy_current => .busy_current,
    };
}

pub fn getProcessInfo(pid: u32) ?*const ProcessInfo {
    return getProcessInfoMutable(pid);
}

pub fn brkCurrent(new_brk: u64) BrkResult {
    const current = task.currentTask() orelse return .not_user;
    const info = getProcessInfoMutable(current.pid) orelse return .not_user;
    const slot = info.address_space_slot orelse return .not_user;
    const addr_space = &address_spaces[slot];

    if (new_brk == 0) return .{ .ok = addr_space.brk };
    return switch (user_mem.setBrk(addr_space, new_brk)) {
        .ok => .{ .ok = addr_space.brk },
        .invalid => .invalid,
        .no_memory => .no_memory,
    };
}

pub fn onContextSwitch(new_task_index: usize) void {
    const next_task = task.getTask(new_task_index) orelse {
        activateKernel();
        return;
    };

    if (!next_task.is_user) {
        activateKernel();
        return;
    }

    const info = getProcessInfoMutable(next_task.pid) orelse {
        activateKernel();
        return;
    };
    if (!info.active or info.address_space_slot == null) {
        activateKernel();
        return;
    }

    gdt.setKernelStack(info.kernel_stack_top);
    user_mem.activate(&address_spaces[info.address_space_slot.?]);
}

pub fn getKernelCr3() u64 {
    return kernel_cr3;
}

fn activateKernel() void {
    if (kernel_stack_top != 0) gdt.setKernelStack(kernel_stack_top);
    if (kernel_cr3 != 0) cpu.writeCr3(kernel_cr3);
}

fn getProcessInfoMutable(pid: u32) ?*ProcessInfo {
    for (&process_table) |*info| {
        if (info.pid == pid and info.proc_type == .user) return info;
    }
    return null;
}

fn findFreeSlot() ?usize {
    for (process_table, 0..) |info, i| {
        if (info.proc_type == .kernel and !address_space_used[i]) return i;
    }
    return null;
}

fn releaseAddressSpace(slot: usize) void {
    if (!address_space_used[slot]) return;
    user_mem.destroy(&address_spaces[slot]);
    address_space_used[slot] = false;
}

fn entryWithinLoadSegment(parse_result: *const elf.ParseResult) bool {
    var index: usize = 0;
    while (index < parse_result.segment_count) : (index += 1) {
        const segment = parse_result.segments[index];
        if (segment.mem_size == 0) continue;
        const end = segment.vaddr + segment.mem_size;
        if (parse_result.entry_point >= segment.vaddr and parse_result.entry_point < end) return true;
    }
    return false;
}

fn copyToActiveAddressSpace(dest_vaddr: u64, src: []const u8) void {
    const dest: [*]volatile u8 = @ptrFromInt(dest_vaddr);
    for (src, 0..) |byte, offset| {
        dest[offset] = byte;
    }
}

fn emptyProcessInfo() ProcessInfo {
    return .{
        .pid = 0,
        .proc_type = .kernel,
        .address_space_slot = null,
        .kernel_stack_top = 0,
        .entry_point = 0,
        .exit_code = 0,
        .active = false,
    };
}
