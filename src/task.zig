pub const MAX_TASKS = 32;
const MAX_NAME = 32;
const STACK_SIZE = 16384;
const STACK_CANARY: u64 = 0xDEAD_BEEF_CAFE_BABE;

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
};

pub const KillResult = enum {
    killed,
    not_found,
    busy_current,
};

pub const TaskEntryFn = *const fn () callconv(.c) noreturn;

pub extern fn contextSwitch(old_rsp: *volatile u64, new_rsp: u64) void;

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

pub fn kill(pid: u32) KillResult {
    const index = findIndexByPid(pid) orelse return .not_found;
    if (current_task_index != null and current_task_index.? == index) return .busy_current;

    if (tasks[index]) |task_entry| {
        if (task_entry.stack_slot) |stack_slot| {
            stack_used[stack_slot] = false;
        }
    }

    tasks[index] = null;
    return .killed;
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

    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = @intFromPtr(entry_fn);
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;
    sp -= 8;
    @as(*u64, @ptrFromInt(sp)).* = 0;

    return sp;
}
