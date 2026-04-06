const task = @import("task.zig");

pub const DEFAULT_QUANTUM: u64 = 10;

var tick_count: u64 = 0;
var quantum: u64 = DEFAULT_QUANTUM;
var context_switches: u64 = 0;
var yield_requests: u64 = 0;
var time_slice_expirations: u64 = 0;

pub fn init() void {
    tick_count = 0;
    quantum = DEFAULT_QUANTUM;
    context_switches = 0;
    yield_requests = 0;
    time_slice_expirations = 0;
}

pub fn timerTick() void {
    tick_count += 1;
    task.accountCurrentTick();

    if (quantum != 0 and tick_count % quantum == 0) {
        time_slice_expirations += 1;
    }
}

pub fn yield() bool {
    yield_requests += 1;
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
