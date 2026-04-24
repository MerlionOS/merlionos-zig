const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const keyboard = @import("keyboard.zig");
const log = @import("log.zig");
const pic = @import("pic.zig");
const pit = @import("pit.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");

pub const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

pub const InterruptFrame = extern struct {
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

var idt: [256]IdtEntry = undefined;

pub fn init() void {
    for (0..idt.len) |i| {
        idt[i] = makeGate(@ptrCast(&defaultInterruptStub), 0, 0x8E);
    }

    idt[0] = makeGate(@ptrCast(&divisionErrorStub), 0, 0x8E);
    idt[1] = makeGate(@ptrCast(&debugStub), 0, 0x8E);
    idt[3] = makeGate(@ptrCast(&breakpointStub), 0, 0x8E);
    idt[6] = makeGate(@ptrCast(&invalidOpcodeStub), 0, 0x8E);
    idt[8] = makeGate(@ptrCast(&doubleFaultStub), 1, 0x8E);
    idt[13] = makeGate(@ptrCast(&generalProtectionStub), 0, 0x8E);
    idt[14] = makeGate(@ptrCast(&pageFaultStub), 0, 0x8E);
    idt[32] = makeGate(@ptrCast(&irq0Stub), 0, 0x8E);
    idt[33] = makeGate(@ptrCast(&irq1Stub), 0, 0x8E);
    idt[0x80] = makeGate(@ptrCast(&syscallStub), 0, 0xEE);
    idt[0x81] = makeGate(@ptrCast(&yieldStub), 0, 0x8E);

    const idtr = cpu.IdtRegister{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    cpu.lidt(&idtr);
}

fn makeGate(handler: *const anyopaque, ist: u8, type_attr: u8) IdtEntry {
    const addr = @intFromPtr(handler);
    return .{
        .offset_low = @intCast(addr & 0xFFFF),
        .selector = gdt.KERNEL_CODE_SEL,
        .ist = ist,
        .type_attr = type_attr,
        .offset_mid = @intCast((addr >> 16) & 0xFFFF),
        .offset_high = @intCast((addr >> 32) & 0xFFFF_FFFF),
    };
}

export fn defaultInterruptInner() void {
    log.kprintln("[int] Unhandled interrupt", .{});
}

export fn divisionErrorInner() void {
    log.kprintln("[cpu] Division error", .{});
    cpu.halt();
}

export fn debugInner() void {
    log.kprintln("[cpu] Debug trap", .{});
}

export fn breakpointInner() void {
    log.kprintln("[cpu] Breakpoint", .{});
}

export fn invalidOpcodeInner() void {
    log.kprintln("[cpu] Invalid opcode", .{});
    cpu.halt();
}

export fn doubleFaultInner(error_code: u64, rip: u64, cs: u64) void {
    _ = error_code;
    _ = rip;
    _ = cs;
    log.kprintln("[cpu] Double fault", .{});
    cpu.halt();
}

export fn generalProtectionInner(error_code: u64, rip: u64, cs: u64) void {
    if (isUserFault(cs)) {
        process.faultCurrent("general protection fault", -13, error_code, rip, 0, false);
    }

    log.kprintln("[cpu] General protection fault rip=0x{x} cs=0x{x} err=0x{x}", .{ rip, cs, error_code });
    cpu.halt();
}

export fn pageFaultInner(error_code: u64, rip: u64, cs: u64) void {
    const fault_addr = cpu.readCr2();
    if (isUserFault(cs)) {
        process.faultCurrent("page fault", -14, error_code, rip, fault_addr, true);
    }

    log.kprintln("[cpu] Page fault at 0x{x} rip=0x{x} cs=0x{x} err=0x{x}", .{ fault_addr, rip, cs, error_code });
    cpu.halt();
}

export fn irq0Inner(current_rsp: u64) callconv(.c) u64 {
    pit.tick();
    pic.sendEoi(0);
    return scheduler.timerTickFromContext(current_rsp);
}

export fn irq1Inner() void {
    keyboard.handleInterrupt();
    pic.sendEoi(1);
}

export fn yieldInner(current_rsp: u64) callconv(.c) u64 {
    return scheduler.yieldFromContext(current_rsp);
}

fn isUserFault(cs: u64) bool {
    return (cs & 0x3) == 0x3;
}

fn defaultInterruptStub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("defaultInterruptInner", false));
}

fn divisionErrorStub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("divisionErrorInner", false));
}

fn debugStub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("debugInner", false));
}

fn breakpointStub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("breakpointInner", false));
}

fn invalidOpcodeStub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("invalidOpcodeInner", false));
}

fn doubleFaultStub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("doubleFaultInner", true));
}

fn generalProtectionStub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("generalProtectionInner", true));
}

fn pageFaultStub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("pageFaultInner", true));
}

fn irq0Stub() callconv(.naked) void {
    asm volatile (pushFullRegsAndSwitch("irq0Inner"));
}

fn irq1Stub() callconv(.naked) void {
    asm volatile (pushRegsAndCall("irq1Inner", false));
}

fn syscallStub() callconv(.naked) void {
    asm volatile (
        \\pushq %%rax
        \\pushq %%rbx
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rbp
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\pushq %%r12
        \\pushq %%r13
        \\pushq %%r14
        \\pushq %%r15
        \\movq %%rsp, %%rdi
        \\call syscallSetCurrentFrame
        \\movq 112(%%rsp), %%rdi
        \\movq 64(%%rsp), %%rsi
        \\movq 72(%%rsp), %%rdx
        \\movq 88(%%rsp), %%rcx
        \\movq 40(%%rsp), %%r8
        \\movq 56(%%rsp), %%r9
        \\call syscallDispatch
        \\movq %%rax, 112(%%rsp)
        \\popq %%r15
        \\popq %%r14
        \\popq %%r13
        \\popq %%r12
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rbp
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rbx
        \\popq %%rax
        \\iretq
    );
}

fn yieldStub() callconv(.naked) void {
    asm volatile (pushFullRegsAndSwitch("yieldInner"));
}

fn pushRegsAndCall(comptime target: []const u8, comptime has_error_code: bool) []const u8 {
    if (has_error_code) {
        return 
        \\pushq %%rax
        \\pushq %%rcx
        \\pushq %%rdx
        \\pushq %%rsi
        \\pushq %%rdi
        \\pushq %%r8
        \\pushq %%r9
        \\pushq %%r10
        \\pushq %%r11
        \\movq 72(%%rsp), %%rdi
        \\movq 80(%%rsp), %%rsi
        \\movq 88(%%rsp), %%rdx
        \\call 
    ++ target ++
        \\
        \\popq %%r11
        \\popq %%r10
        \\popq %%r9
        \\popq %%r8
        \\popq %%rdi
        \\popq %%rsi
        \\popq %%rdx
        \\popq %%rcx
        \\popq %%rax
        \\addq $8, %%rsp
        \\iretq
        ;
    }

    return 
    \\pushq %%rax
    \\pushq %%rcx
    \\pushq %%rdx
    \\pushq %%rsi
    \\pushq %%rdi
    \\pushq %%r8
    \\pushq %%r9
    \\pushq %%r10
    \\pushq %%r11
    \\call 
++ target ++
    \\
    \\popq %%r11
    \\popq %%r10
    \\popq %%r9
    \\popq %%r8
    \\popq %%rdi
    \\popq %%rsi
    \\popq %%rdx
    \\popq %%rcx
    \\popq %%rax
    \\iretq
    ;
}

fn pushFullRegsAndSwitch(comptime target: []const u8) []const u8 {
    return "pushq %%rax\n" ++
        "pushq %%rbx\n" ++
        "pushq %%rcx\n" ++
        "pushq %%rdx\n" ++
        "pushq %%rbp\n" ++
        "pushq %%rsi\n" ++
        "pushq %%rdi\n" ++
        "pushq %%r8\n" ++
        "pushq %%r9\n" ++
        "pushq %%r10\n" ++
        "pushq %%r11\n" ++
        "pushq %%r12\n" ++
        "pushq %%r13\n" ++
        "pushq %%r14\n" ++
        "pushq %%r15\n" ++
        "movq %%rsp, %%rdi\n" ++
        "call " ++ target ++ "\n" ++
        "movq %%rax, %%rsp\n" ++
        "popq %%r15\n" ++
        "popq %%r14\n" ++
        "popq %%r13\n" ++
        "popq %%r12\n" ++
        "popq %%r11\n" ++
        "popq %%r10\n" ++
        "popq %%r9\n" ++
        "popq %%r8\n" ++
        "popq %%rdi\n" ++
        "popq %%rsi\n" ++
        "popq %%rbp\n" ++
        "popq %%rdx\n" ++
        "popq %%rcx\n" ++
        "popq %%rbx\n" ++
        "popq %%rax\n" ++
        "iretq\n";
}
