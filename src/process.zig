const cpu = @import("cpu.zig");
const elf = @import("elf.zig");
const gdt = @import("gdt.zig");
const keyboard = @import("keyboard.zig");
const log = @import("log.zig");
const pmm = @import("pmm.zig");
const task = @import("task.zig");
const user_mem = @import("user_mem.zig");
const vfs = @import("vfs.zig");

const MAX_PROCESSES: usize = task.MAX_TASKS;
pub const MAX_FILE_DESCRIPTORS: usize = 16;
pub const FIRST_USER_FD: u64 = 3;
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
    fds: [MAX_FILE_DESCRIPTORS]FileDescriptor,
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

pub const MmapResult = union(enum) {
    ok: u64,
    not_user,
    invalid,
    no_memory,
};

pub const ForkResult = union(enum) {
    parent: u32,
    not_user,
    no_memory,
};

pub const OpenFileResult = union(enum) {
    ok: u64,
    not_user,
    invalid,
    no_fd,
};

pub const CloseFileResult = enum {
    ok,
    not_user,
    bad_fd,
};

pub const ReadFileResult = union(enum) {
    ok: usize,
    not_user,
    bad_fd,
};

pub const FileStat = extern struct {
    node_type: u64,
    size: u64,
    inode: u64,
};

pub const FileDescriptor = struct {
    active: bool = false,
    inode: u16 = 0,
    offset: usize = 0,
};

const EMPTY_FILE_DESCRIPTORS = [_]FileDescriptor{.{}} ** MAX_FILE_DESCRIPTORS;

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
        .fds = EMPTY_FILE_DESCRIPTORS,
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
        .fds = EMPTY_FILE_DESCRIPTORS,
    };

    return spawned.pid;
}

pub fn exitCurrent(exit_code: i32) noreturn {
    if (task.currentTask()) |current| {
        if (getProcessInfoMutable(current.pid)) |info| {
            info.exit_code = exit_code;
            info.active = false;
            clearFileDescriptors(info);
            if (info.address_space_slot) |slot| {
                info.address_space_slot = null;
                releaseAddressSpace(slot);
            }
        }
        keyboard.endUserInput(current.pid);
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

    keyboard.endUserInput(pid);
    info.active = false;
    clearFileDescriptors(info);
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

pub fn mmapCurrent(addr: u64, length: u64) MmapResult {
    const current = task.currentTask() orelse return .not_user;
    const info = getProcessInfoMutable(current.pid) orelse return .not_user;
    const slot = info.address_space_slot orelse return .not_user;
    const addr_space = &address_spaces[slot];

    return switch (user_mem.mmap(addr_space, addr, length)) {
        .ok => |mapped_addr| .{ .ok = mapped_addr },
        .invalid => .invalid,
        .no_memory => .no_memory,
    };
}

pub fn forkCurrent(saved_context: u64) ForkResult {
    const parent_task = task.currentTask() orelse return .not_user;
    if (!parent_task.is_user) return .not_user;

    const parent_info = getProcessInfoMutable(parent_task.pid) orelse return .not_user;
    const parent_slot = parent_info.address_space_slot orelse return .not_user;
    const child_slot = findFreeSlot() orelse return .no_memory;

    const child_addr_space = &address_spaces[child_slot];
    if (!user_mem.cloneAddressSpace(&address_spaces[parent_slot], child_addr_space)) return .no_memory;
    address_space_used[child_slot] = true;

    const child_task = task.forkUserFromContext(parent_task, saved_context) orelse {
        releaseAddressSpace(child_slot);
        return .no_memory;
    };
    const child = task.getTask(child_task.index) orelse {
        _ = task.kill(child_task.pid);
        releaseAddressSpace(child_slot);
        return .no_memory;
    };

    process_table[child_slot] = .{
        .pid = child_task.pid,
        .proc_type = .user,
        .address_space_slot = child_slot,
        .kernel_stack_top = child.stack_top,
        .entry_point = parent_info.entry_point,
        .exit_code = 0,
        .active = true,
        .fds = parent_info.fds,
    };

    return .{ .parent = child_task.pid };
}

pub fn openCurrentFile(inode_idx: u16) OpenFileResult {
    const info = currentProcessInfoMutable() orelse return .not_user;
    const inode = vfs.getInode(inode_idx) orelse return .invalid;
    if (inode.node_type == .directory) return .invalid;

    for (&info.fds, 0..) |*fd, index| {
        if (fd.active) continue;
        fd.* = .{
            .active = true,
            .inode = inode_idx,
            .offset = 0,
        };
        return .{ .ok = FIRST_USER_FD + @as(u64, @intCast(index)) };
    }

    return .no_fd;
}

pub fn closeCurrentFile(fd: u64) CloseFileResult {
    const info = currentProcessInfoMutable() orelse return .not_user;
    const index = fdIndex(fd) orelse return .bad_fd;
    if (!info.fds[index].active) return .bad_fd;

    info.fds[index] = .{};
    return .ok;
}

pub fn readCurrentFile(fd: u64, dest: []u8) ReadFileResult {
    const info = currentProcessInfoMutable() orelse return .not_user;
    const index = fdIndex(fd) orelse return .bad_fd;
    const descriptor = &info.fds[index];
    if (!descriptor.active) return .bad_fd;

    const data = vfs.readFile(descriptor.inode) orelse return .bad_fd;
    if (descriptor.offset >= data.len) return .{ .ok = 0 };

    const remaining = data.len - descriptor.offset;
    const copy_len = @min(dest.len, remaining);
    @memcpy(dest[0..copy_len], data[descriptor.offset .. descriptor.offset + copy_len]);
    descriptor.offset += copy_len;
    return .{ .ok = copy_len };
}

pub fn statInode(inode_idx: u16) ?FileStat {
    const inode = vfs.getInode(inode_idx) orelse return null;
    return .{
        .node_type = @intCast(@intFromEnum(inode.node_type)),
        .size = @intCast(inode.data_len),
        .inode = @intCast(inode_idx),
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

fn currentProcessInfoMutable() ?*ProcessInfo {
    const pid = task.currentPid() orelse return null;
    const info = getProcessInfoMutable(pid) orelse return null;
    if (!info.active or info.address_space_slot == null) return null;
    return info;
}

fn getProcessInfoMutable(pid: u32) ?*ProcessInfo {
    for (&process_table) |*info| {
        if (info.pid == pid and info.proc_type == .user) return info;
    }
    return null;
}

fn fdIndex(fd: u64) ?usize {
    if (fd < FIRST_USER_FD) return null;
    const index = fd - FIRST_USER_FD;
    if (index >= @as(u64, @intCast(MAX_FILE_DESCRIPTORS))) return null;
    return @intCast(index);
}

fn clearFileDescriptors(info: *ProcessInfo) void {
    info.fds = EMPTY_FILE_DESCRIPTORS;
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
        .fds = EMPTY_FILE_DESCRIPTORS,
    };
}
