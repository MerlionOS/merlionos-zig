const gdt = @import("gdt.zig");

pub const MAX_TASKS = 32;
const MAX_NAME = 32;
const STACK_SIZE = 16384;
const STACK_CANARY: u64 = 0xDEAD_BEEF_CAFE_BABE;
const INITIAL_RFLAGS: u64 = 0x202;
pub const SAVED_CONTEXT_SIZE: u64 = 160;
const SAVED_CONTEXT_RAX_OFFSET: u64 = 112;
const SAVED_CONTEXT_RIP_OFFSET: u64 = 120;
const SAVED_CONTEXT_CS_OFFSET: u64 = 128;
const SAVED_CONTEXT_RFLAGS_OFFSET: u64 = 136;
const SAVED_CONTEXT_RSP_OFFSET: u64 = 144;
const SAVED_CONTEXT_SS_OFFSET: u64 = 152;

pub const TaskState = enum {
    ready,
    running,
    blocked,
    finished,
};

pub const Task = struct {
    pid: u32,
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    state: TaskState = .ready,
    rsp: u64 = 0,
    stack_bottom: u64 = 0,
    stack_top: u64 = 0,
    stack_slot: ?usize = null,
    ticks: u64 = 0,
    run_count: u64 = 0,
    yield_count: u64 = 0,
    priority: u8 = 128,
    is_user: bool = false,
    wake_tick: u64 = 0,
    parent_pid: u32 = 0,
    exit_status: i32 = 0,
    wait_on_pid: u32 = 0,
};

pub const KillResult = enum {
    killed,
    not_found,
    busy_current,
};

pub const SpawnResult = struct {
    pid: u32,
    index: usize,
};

pub const TaskEntryFn = *const fn () callconv(.c) noreturn;

pub extern fn yieldCurrent() void;
pub extern fn taskBootstrap() callconv(.c) noreturn;

var tasks: [MAX_TASKS]?Task = [_]?Task{null} ** MAX_TASKS;
var current_task_index: ?usize = null;
var next_pid: u32 = 1;

var stack_pool: [MAX_TASKS][STACK_SIZE]u8 align(16) = undefined;
var stack_used: [MAX_TASKS]bool = [_]bool{false} ** MAX_TASKS;

pub fn init() void {
    tasks = [_]?Task{null} ** MAX_TASKS;
    current_task_index = null;
    next_pid = 1;
    stack_used = [_]bool{false} ** MAX_TASKS;
}

pub fn registerBootTask(name: []const u8) ?u32 {
    if (current_task_index != null) return currentPid();

    const index = allocSlot() orelse return null;
    var new_task = Task{
        .pid = next_pid,
        .state = .running,
        .run_count = 1,
    };
    setName(&new_task, name);

    tasks[index] = new_task;
    current_task_index = index;
    next_pid += 1;
    return new_task.pid;
}

pub fn spawn(name: []const u8, entry_fn: TaskEntryFn) ?u32 {
    const index = allocSlot() orelse return null;
    const stack_slot = allocStack() orelse return null;

    var new_task = Task{
        .pid = next_pid,
        .state = .ready,
        .stack_slot = stack_slot,
    };
    setName(&new_task, name);

    new_task.stack_bottom = @intFromPtr(&stack_pool[stack_slot][0]);
    new_task.stack_top = new_task.stack_bottom + STACK_SIZE;
    const canary_ptr: *volatile u64 = @ptrFromInt(new_task.stack_bottom);
    canary_ptr.* = STACK_CANARY;
    new_task.rsp = buildInitialStack(new_task.stack_top, entry_fn);

    tasks[index] = new_task;
    next_pid += 1;
    return new_task.pid;
}

pub fn spawnUser(name: []const u8, entry_point: u64, user_stack_top: u64) ?u32 {
    const result = spawnUserWithIndex(name, entry_point, user_stack_top) orelse return null;
    return result.pid;
}

pub fn spawnUserWithIndex(name: []const u8, entry_point: u64, user_stack_top: u64) ?SpawnResult {
    const index = allocSlot() orelse return null;
    const stack_slot = allocStack() orelse return null;

    var new_task = Task{
        .pid = next_pid,
        .state = .ready,
        .stack_slot = stack_slot,
        .is_user = true,
    };
    setName(&new_task, name);

    new_task.stack_bottom = @intFromPtr(&stack_pool[stack_slot][0]);
    new_task.stack_top = new_task.stack_bottom + STACK_SIZE;
    const canary_ptr: *volatile u64 = @ptrFromInt(new_task.stack_bottom);
    canary_ptr.* = STACK_CANARY;
    new_task.rsp = buildUserInitialStack(new_task.stack_top, entry_point, user_stack_top);

    tasks[index] = new_task;
    next_pid += 1;
    return .{ .pid = new_task.pid, .index = index };
}

pub fn forkUserFromContext(parent: *const Task, saved_context: u64) ?SpawnResult {
    const index = allocSlot() orelse return null;
    const stack_slot = allocStack() orelse return null;

    var new_task = Task{
        .pid = next_pid,
        .state = .ready,
        .stack_slot = stack_slot,
        .is_user = true,
        .parent_pid = parent.pid,
    };
    setName(&new_task, nameSlice(parent));

    new_task.stack_bottom = @intFromPtr(&stack_pool[stack_slot][0]);
    new_task.stack_top = new_task.stack_bottom + STACK_SIZE;
    const canary_ptr: *volatile u64 = @ptrFromInt(new_task.stack_bottom);
    canary_ptr.* = STACK_CANARY;

    new_task.rsp = new_task.stack_top - SAVED_CONTEXT_SIZE;
    const src: [*]const u8 = @ptrFromInt(saved_context);
    const dst: [*]u8 = @ptrFromInt(new_task.rsp);
    @memcpy(dst[0..SAVED_CONTEXT_SIZE], src[0..SAVED_CONTEXT_SIZE]);
    @as(*u64, @ptrFromInt(new_task.rsp + SAVED_CONTEXT_RAX_OFFSET)).* = 0;

    tasks[index] = new_task;
    next_pid += 1;
    return .{ .pid = new_task.pid, .index = index };
}

pub fn rewriteUserContext(saved_context: u64, entry_point: u64, user_stack_top: u64) void {
    const frame: [*]u8 = @ptrFromInt(saved_context);
    @memset(frame[0..SAVED_CONTEXT_SIZE], 0);
    writeContextSlot(saved_context, SAVED_CONTEXT_RIP_OFFSET, entry_point);
    writeContextSlot(saved_context, SAVED_CONTEXT_CS_OFFSET, gdt.USER_CODE_SEL | 3);
    writeContextSlot(saved_context, SAVED_CONTEXT_RFLAGS_OFFSET, INITIAL_RFLAGS);
    writeContextSlot(saved_context, SAVED_CONTEXT_RSP_OFFSET, user_stack_top);
    writeContextSlot(saved_context, SAVED_CONTEXT_SS_OFFSET, gdt.USER_DATA_SEL | 3);
}

pub fn kill(pid: u32) KillResult {
    for (0..MAX_TASKS) |index| {
        if (tasks[index]) |task_entry| {
            if (task_entry.pid != pid) continue;
            if (current_task_index != null and current_task_index.? == index) return .busy_current;

            if (task_entry.stack_slot) |stack_slot| {
                stack_used[stack_slot] = false;
            }
            tasks[index] = null;
            return .killed;
        }
    }

    return .not_found;
}

pub fn currentTask() ?*Task {
    const index = current_task_index orelse return null;
    return getTask(index);
}

pub fn currentPid() ?u32 {
    if (currentTask()) |task_entry| return task_entry.pid;
    return null;
}

pub fn getTask(index: usize) ?*Task {
    if (index >= MAX_TASKS) return null;
    if (tasks[index]) |*task_entry| return task_entry;
    return null;
}

pub fn getCurrentIndex() ?usize {
    return current_task_index;
}

pub fn indexOfPid(pid: u32) ?usize {
    return findIndexByPid(pid);
}

pub fn pidExists(pid: u32) bool {
    for (tasks) |entry| {
        if (entry) |task_entry| {
            if (task_entry.pid == pid) return true;
        }
    }
    return false;
}

pub fn wakeBlocked(now: u64) usize {
    var count: usize = 0;
    for (0..MAX_TASKS) |i| {
        if (tasks[i]) |*task_entry| {
            if (task_entry.state == .blocked and task_entry.wake_tick > 0 and now >= task_entry.wake_tick) {
                task_entry.state = .ready;
                task_entry.wake_tick = 0;
                count += 1;
            }
        }
    }
    return count;
}

pub fn setCurrentIndex(index: usize) void {
    current_task_index = index;
}

pub fn findNextRunnable(current_index: usize) ?usize {
    var offset: usize = 1;
    while (offset < MAX_TASKS) : (offset += 1) {
        const index = (current_index + offset) % MAX_TASKS;
        if (tasks[index]) |task_entry| {
            if (task_entry.state == .ready) return index;
        }
    }
    return null;
}

pub fn accountCurrentTick() void {
    if (currentTask()) |task_entry| {
        task_entry.ticks += 1;
    }
}

pub fn noteCurrentRun() void {
    if (currentTask()) |task_entry| {
        task_entry.run_count += 1;
    }
}

pub fn noteCurrentYield() void {
    if (currentTask()) |task_entry| {
        task_entry.yield_count += 1;
    }
}

pub fn taskCount() usize {
    var count: usize = 0;
    for (tasks) |entry| {
        if (entry != null) count += 1;
    }
    return count;
}

pub fn runnableCount() usize {
    var count: usize = 0;
    for (tasks) |entry| {
        if (entry) |task_entry| {
            if (task_entry.state == .ready or task_entry.state == .running) count += 1;
        }
    }
    return count;
}

pub fn forEach(callback: *const fn (*const Task, bool) void) void {
    for (0..MAX_TASKS) |i| {
        if (tasks[i]) |*task_entry| {
            callback(task_entry, current_task_index != null and current_task_index.? == i);
        }
    }
}

pub fn nameSlice(task_entry: *const Task) []const u8 {
    return task_entry.name[0..task_entry.name_len];
}

fn allocSlot() ?usize {
    for (0..MAX_TASKS) |i| {
        if (tasks[i] == null) return i;
    }
    return null;
}

fn allocStack() ?usize {
    for (0..MAX_TASKS) |i| {
        if (!stack_used[i]) {
            stack_used[i] = true;
            return i;
        }
    }
    return null;
}

fn findIndexByPid(pid: u32) ?usize {
    for (0..MAX_TASKS) |i| {
        if (tasks[i]) |task_entry| {
            if (task_entry.pid == pid) return i;
        }
    }
    return null;
}

fn setName(task_entry: *Task, value: []const u8) void {
    const copy_len = @min(value.len, MAX_NAME - 1);
    @memcpy(task_entry.name[0..copy_len], value[0..copy_len]);
    task_entry.name[copy_len] = 0;
    task_entry.name_len = @intCast(copy_len);
}

fn buildInitialStack(stack_top: u64, entry_fn: TaskEntryFn) u64 {
    var sp = stack_top;

    // The interrupt restore path pops 15 GPRs, then iretq consumes RIP/CS/RFLAGS.
    // Keep RSP/SS slots too so the first synthetic return has a valid stack.
    pushStack(&sp, gdt.KERNEL_DATA_SEL); // ss
    pushStack(&sp, stack_top); // rsp
    pushStack(&sp, INITIAL_RFLAGS);
    pushStack(&sp, gdt.KERNEL_CODE_SEL);
    pushStack(&sp, @intFromPtr(&taskBootstrap));

    pushStack(&sp, 0); // rax
    pushStack(&sp, 0); // rbx
    pushStack(&sp, 0); // rcx
    pushStack(&sp, 0); // rdx
    pushStack(&sp, 0); // rbp
    pushStack(&sp, 0); // rsi
    pushStack(&sp, 0); // rdi
    pushStack(&sp, 0); // r8
    pushStack(&sp, 0); // r9
    pushStack(&sp, 0); // r10
    pushStack(&sp, 0); // r11
    pushStack(&sp, @intFromPtr(entry_fn)); // r12
    pushStack(&sp, stack_top); // r13
    pushStack(&sp, 0); // r14
    pushStack(&sp, 0); // r15

    return sp;
}

fn buildUserInitialStack(stack_top: u64, entry_point: u64, user_stack_top: u64) u64 {
    var sp = stack_top;

    pushStack(&sp, gdt.USER_DATA_SEL | 3); // ss
    pushStack(&sp, user_stack_top); // rsp
    pushStack(&sp, INITIAL_RFLAGS);
    pushStack(&sp, gdt.USER_CODE_SEL | 3);
    pushStack(&sp, entry_point);

    pushStack(&sp, 0); // rax
    pushStack(&sp, 0); // rbx
    pushStack(&sp, 0); // rcx
    pushStack(&sp, 0); // rdx
    pushStack(&sp, 0); // rbp
    pushStack(&sp, 0); // rsi
    pushStack(&sp, 0); // rdi
    pushStack(&sp, 0); // r8
    pushStack(&sp, 0); // r9
    pushStack(&sp, 0); // r10
    pushStack(&sp, 0); // r11
    pushStack(&sp, 0); // r12
    pushStack(&sp, 0); // r13
    pushStack(&sp, 0); // r14
    pushStack(&sp, 0); // r15

    return sp;
}

fn pushStack(sp: *u64, value: u64) void {
    sp.* -= 8;
    @as(*u64, @ptrFromInt(sp.*)).* = value;
}

fn writeContextSlot(saved_context: u64, offset: u64, value: u64) void {
    @as(*u64, @ptrFromInt(saved_context + offset)).* = value;
}
