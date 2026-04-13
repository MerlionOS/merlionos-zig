const process = @import("process.zig");
const task = @import("task.zig");

pub const DEFAULT_QUANTUM: u64 = 10;
pub extern fn backgroundWorkerLoop() callconv(.c) noreturn;

var tick_count: u64 = 0;
var quantum: u64 = DEFAULT_QUANTUM;
var context_switches: u64 = 0;
var yield_requests: u64 = 0;
var time_slice_expirations: u64 = 0;
var preempt_requests: u64 = 0;
var preempt_pending: bool = false;
var blocked_wakeups: u64 = 0;

pub fn init() void {
    tick_count = 0;
    quantum = DEFAULT_QUANTUM;
    context_switches = 0;
    yield_requests = 0;
    time_slice_expirations = 0;
    preempt_requests = 0;
    preempt_pending = false;
    blocked_wakeups = 0;
}

pub fn timerTickFromContext(current_rsp: u64) callconv(.c) u64 {
    tick_count += 1;
    task.accountCurrentTick();
    blocked_wakeups += task.wakeBlocked(tick_count);

    if (quantum != 0 and tick_count % quantum == 0) {
        time_slice_expirations += 1;
        if (task.runnableCount() > 1) {
            preempt_requests += 1;
            preempt_pending = false;
            return switchFromContext(current_rsp);
        }
    }

    return current_rsp;
}

pub fn spawnWorker(name: []const u8) ?u32 {
    return task.spawn(name, backgroundWorkerLoop);
}

pub export fn yieldFromContext(current_rsp: u64) callconv(.c) u64 {
    return switchFromContext(current_rsp);
}

pub fn yield() bool {
    if (task.runnableCount() <= 1) return false;

    yield_requests += 1;
    task.noteCurrentYield();
    preempt_pending = false;
    task.yieldCurrent();
    return true;
}

pub fn sleepCurrent(ticks: u64) bool {
    if (ticks == 0) return yield();
    if (~@as(u64, 0) - tick_count < ticks) return false;

    const current = task.currentTask() orelse return false;
    current.state = .blocked;
    current.wake_tick = tick_count + ticks;
    if (task.runnableCount() == 0) {
        current.state = .running;
        current.wake_tick = 0;
        return false;
    }

    yield_requests += 1;
    task.noteCurrentYield();
    preempt_pending = false;
    task.yieldCurrent();
    return true;
}

pub fn preemptIfNeeded() bool {
    return false;
}

pub fn getTickCount() u64 {
    return tick_count;
}

pub fn getQuantum() u64 {
    return quantum;
}

pub fn getContextSwitches() u64 {
    return context_switches;
}

pub fn getYieldRequests() u64 {
    return yield_requests;
}

pub fn getTimeSliceExpirations() u64 {
    return time_slice_expirations;
}

pub fn getPreemptRequests() u64 {
    return preempt_requests;
}

pub fn getBlockedWakeups() u64 {
    return blocked_wakeups;
}

pub fn hasPreemptPending() bool {
    return preempt_pending;
}

fn switchFromContext(current_rsp: u64) u64 {
    const current_index = task.getCurrentIndex() orelse return current_rsp;
    const next_index = task.findNextRunnable(current_index) orelse return current_rsp;

    const old_task = task.getTask(current_index) orelse return current_rsp;
    const new_task = task.getTask(next_index) orelse return current_rsp;

    if (old_task.state == .running) {
        old_task.state = .ready;
    }
    old_task.rsp = current_rsp;

    new_task.state = .running;
    task.setCurrentIndex(next_index);
    new_task.run_count += 1;
    context_switches += 1;
    process.onContextSwitch(next_index);

    return new_task.rsp;
}
