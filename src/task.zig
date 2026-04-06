pub const MAX_TASKS = 32;
const MAX_NAME = 32;

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
    ticks: u64 = 0,
    priority: u8 = 128,
};

var tasks: [MAX_TASKS]?Task = [_]?Task{null} ** MAX_TASKS;
var current_task_index: ?usize = null;
var next_pid: u32 = 1;

pub fn init() void {
    tasks = [_]?Task{null} ** MAX_TASKS;
    current_task_index = null;
    next_pid = 1;
}

pub fn registerBootTask(name: []const u8) ?u32 {
    if (current_task_index != null) return currentPid();

    const index = allocSlot() orelse return null;
    var new_task = Task{
        .pid = next_pid,
        .state = .running,
    };
    setName(&new_task, name);

    tasks[index] = new_task;
    current_task_index = index;
    next_pid += 1;
    return new_task.pid;
}

pub fn currentTask() ?*Task {
    const index = current_task_index orelse return null;
    return getTask(index);
}

pub fn currentPid() ?u32 {
    if (currentTask()) |task| return task.pid;
    return null;
}

pub fn getTask(index: usize) ?*Task {
    if (index >= MAX_TASKS) return null;
    if (tasks[index]) |*task| return task;
    return null;
}

pub fn getCurrentIndex() ?usize {
    return current_task_index;
}

pub fn accountCurrentTick() void {
    if (currentTask()) |task| {
        task.ticks += 1;
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
        if (entry) |task| {
            if (task.state == .ready or task.state == .running) count += 1;
        }
    }
    return count;
}

pub fn forEach(callback: *const fn (*const Task, bool) void) void {
    for (0..MAX_TASKS) |i| {
        if (tasks[i]) |*task| {
            callback(task, current_task_index != null and current_task_index.? == i);
        }
    }
}

pub fn nameSlice(task: *const Task) []const u8 {
    return task.name[0..task.name_len];
}

fn allocSlot() ?usize {
    for (0..MAX_TASKS) |i| {
        if (tasks[i] == null) return i;
    }
    return null;
}

fn setName(task: *Task, value: []const u8) void {
    const copy_len = @min(value.len, MAX_NAME - 1);
    @memcpy(task.name[0..copy_len], value[0..copy_len]);
    task.name[copy_len] = 0;
    task.name_len = @intCast(copy_len);
}
