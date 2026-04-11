# MerlionOS-Zig 用户态设计文档

> 本文档供 AI 代码生成工具（Codex 等）直接实现使用。
> 同时包含详细的原理讲解，帮助读者理解 x86_64 用户态的核心概念。
> 实现顺序严格按 Phase 编号进行。

## 目录

1. [背景知识：什么是用户态](#1-背景知识什么是用户态)
2. [当前内核状态分析](#2-当前内核状态分析)
3. [Phase 8a: syscall 基础设施](#3-phase-8a-syscall-基础设施)
4. [Phase 8b: 用户态地址空间](#4-phase-8b-用户态地址空间)
5. [Phase 8c: 用户进程加载与运行](#5-phase-8c-用户进程加载与运行)
6. [Phase 8d: ELF 加载器](#6-phase-8d-elf-加载器)
7. [Phase 8e: 进程生命周期](#7-phase-8e-进程生命周期)
8. [Phase 8f: Shell 集成](#8-phase-8f-shell-集成)
9. [集成与初始化顺序](#9-集成与初始化顺序)
10. [QEMU 测试方法](#10-qemu-测试方法)
11. [安全模型总结](#11-安全模型总结)

---

## 1. 背景知识：什么是用户态

### 1.1 特权级（Protection Rings）

x86_64 CPU 有 4 个特权级（Ring 0-3），但现代 OS 只用两个：

```
Ring 0 (内核态/Supervisor)        Ring 3 (用户态/User)
┌─────────────────────────┐     ┌─────────────────────────┐
│ 可以执行任何指令          │     │ 不能执行特权指令          │
│ 可以访问任何内存          │     │ 只能访问标记为 User 的页  │
│ 可以操作 I/O 端口        │     │ 不能直接操作硬件          │
│ 可以修改页表             │     │ 不能修改页表              │
│ 可以禁用/启用中断        │     │ 不能执行 CLI/STI         │
└─────────────────────────┘     └─────────────────────────┘
        ↑                                ↑
    我们的内核现在在这里           我们要让程序跑在这里
```

**为什么要有用户态？** 隔离。如果所有代码都在 Ring 0 运行，一个有 bug 的程序可以覆盖内核内存、操作硬件、破坏其他程序。用户态让 CPU 硬件强制执行隔离——用户程序试图做越权操作时，CPU 会触发异常（#GP 或 #PF），内核可以选择杀掉这个程序而不影响系统。

### 1.2 特权级切换的机制

从内核态进入用户态（"落地"到 Ring 3）：

```
内核 (Ring 0)                     用户程序 (Ring 3)
     │                                  ↑
     │  准备好栈帧:                      │
     │  push USER_DATA_SEL (ss)         │
     │  push user_rsp                   │
     │  push user_rflags                │
     │  push USER_CODE_SEL (cs)         │
     │  push user_rip (程序入口)         │
     │                                  │
     └──── iretq ───────────────────────┘
           CPU 看到 CS 的 RPL=3，
           自动切换到 Ring 3
```

从用户态回到内核态（系统调用）：

```
用户程序 (Ring 3)                 内核 (Ring 0)
     │                                  ↑
     │  int 0x80                        │
     │  或 syscall 指令                  │
     └──────────────────────────────────┘
           CPU 自动:
           1. 从 TSS 加载 RSP0 (内核栈)
           2. 保存用户的 RIP, CS, RFLAGS, RSP, SS
           3. 跳转到中断处理函数
           4. 特权级变为 Ring 0
```

### 1.3 关键硬件机制

**GDT（全局描述符表）** — 已有 `gdt.zig`

我们的 GDT 已经定义了 4 个段：

| 选择子 | 用途 | DPL | 说明 |
|--------|------|-----|------|
| 0x08 | KERNEL_CODE_SEL | 0 | 内核代码段 |
| 0x10 | KERNEL_DATA_SEL | 0 | 内核数据段 |
| 0x18 | USER_DATA_SEL | 3 | 用户数据段（access=0xF2, DPL=3）|
| 0x20 | USER_CODE_SEL | 3 | 用户代码段（access=0xFA, DPL=3）|

> 注意 USER_DATA_SEL 在 USER_CODE_SEL **前面**。这是 `syscall`/`sysret` 指令要求的布局。`sysret` 硬件要求 SS = STAR[63:48]，CS = STAR[63:48] + 16。所以 data 在前，code 在后。我们的 GDT 已经按这个顺序排列了。

**TSS（任务状态段）** — 已有 `gdt.zig`

TSS 里的 `rsp0` 字段告诉 CPU：当用户态发生中断/异常时，切换到哪个内核栈。每次切换到不同进程时，必须更新 `tss.rsp0` 为该进程的内核栈顶。

**页表** — 已有 `vmm.zig`

`vmm.mapPage` 的 `user` 参数对应页表项的 U/S 位（bit 2）。设置了 U/S 位的页，Ring 3 代码可以访问；未设置的页，只有 Ring 0 能访问。这就是用户态内存隔离的核心。

### 1.4 系统调用是什么

用户程序不能直接操作硬件，但需要做 I/O（打印、读文件、发网络包等）。怎么办？通过系统调用（syscall）"请求"内核代劳：

```
用户程序:                     内核:
  "我要打印 Hello"              收到 syscall
  → rax = 1 (WRITE)           → 检查参数合法性
  → rdi = 1 (stdout)          → 从用户内存复制数据
  → rsi = buf_ptr             → 调用 serial/vga 输出
  → rdx = 5 (长度)             → 返回写入的字节数
  → int 0x80                   → iretq 回到用户态
```

这个设计的关键原则：**内核不信任用户传入的任何参数**。用户传来的指针可能指向内核内存、可能越界、可能是 NULL。内核必须验证每一个参数。

### 1.5 虚拟地址空间布局

```
0xFFFF_FFFF_FFFF_FFFF ┐
                      │ 内核空间（高半部分）
                      │ 内核代码、堆、VGA、MMIO...
                      │ 页表标记为 Supervisor (U/S=0)
                      │ 用户态代码无法访问
0xFFFF_FFFF_8000_0000 ┤ ← 内核基地址（linker.ld 里的 0xffffffff80000000）
         ...          │
0x0000_8000_0000_0000 ┤ ← 非规范地址空洞（CPU 会 #GP）
         ...          │
0x0000_7FFF_FFFF_FFFF ┤ ← 用户空间上限
                      │
0x0000_0000_0080_0000 │ ← 用户程序 .text 加载地址
         ...          │
0x0000_0000_0010_0000 │ ← 用户堆起始
         ...          │
0x0000_7FFF_FFFF_0000 │ ← 用户栈顶（向下增长）
                      │
0x0000_0000_0000_0000 ┘ ← NULL 区域（不映射，访问会 #PF）
```

---

## 2. 当前内核状态分析

### 2.1 已有的基础设施（可直接复用）

| 组件 | 文件 | 用户态需要的能力 | 状态 |
|------|------|----------------|------|
| GDT + TSS | gdt.zig | Ring 3 段选择子 + rsp0 切换 | **已就绪** — USER_DATA_SEL(0x18) + USER_CODE_SEL(0x20) 已定义，`setKernelStack()` 已存在 |
| IDT | idt.zig | int 0x80 syscall 入口 | **已有骨架** — `syscallStub` 在 0x80，type_attr=0xEE（DPL=3，用户态可触发），但 handler 只打印日志 |
| VMM | vmm.zig | 用户页映射（user=true） | **已就绪** — `mapPage` 支持 user 参数 |
| PMM | pmm.zig | 分配用户页帧 | **已就绪** |
| 任务管理 | task.zig | 进程概念 | **需要扩展** — 当前只有内核任务，需要增加用户态上下文 |
| 调度器 | scheduler.zig | 内核/用户任务统一调度 | **需要小改** — 切换时需更新 TSS.rsp0 |

### 2.2 需要新增/修改的部分

```
需要新写:
  src/syscall.zig      — syscall 分发 + 各个系统调用实现
  src/user_mem.zig     — 用户地址空间管理（独立页表、内存映射）
  src/elf.zig          — ELF 解析器
  src/process.zig      — 进程管理（对 task.zig 的高层封装）
  user/                — 用户态测试程序（汇编 + Zig）

需要修改:
  src/idt.zig          — syscallStub 改为完整的 syscall 分发
  src/task.zig         — Task 结构体增加用户态字段
  src/scheduler.zig    — 切换时更新 TSS.rsp0
  src/gdt.zig          — 无需修改（已就绪）
  src/vmm.zig          — 新增 createAddressSpace / cloneKernelMappings
  src/shell_cmds.zig   — 新增 exec / ps 命令增强
```

---

## 3. Phase 8a: syscall 基础设施

### 3.1 概念讲解：syscall 分发

当用户程序执行 `int 0x80`，CPU 跳转到 IDT[0x80] 指向的处理函数。我们需要：

1. **保存所有寄存器**（用户程序的状态不能丢）
2. **读取 rax**（syscall 编号）
3. **分发到对应的处理函数**
4. **把返回值放到 rax**
5. **恢复寄存器，iretq 返回用户态**

寄存器约定（类 Linux）：

| 寄存器 | 用途 |
|--------|------|
| rax | 系统调用编号（输入）/ 返回值（输出）|
| rdi | 第 1 个参数 |
| rsi | 第 2 个参数 |
| rdx | 第 3 个参数 |
| r10 | 第 4 个参数（注意不是 rcx，因为 `syscall` 指令会覆盖 rcx）|
| r8 | 第 5 个参数 |
| r9 | 第 6 个参数 |

### 3.2 src/syscall.zig — 系统调用实现

#### 系统调用编号

```zig
// 系统调用编号定义
// 用 comptime enum 方便两端共享
pub const SYS = enum(u64) {
    EXIT = 0,        // 退出当前进程
    WRITE = 1,       // 写输出（serial + VGA）
    READ = 2,        // 读输入（keyboard buffer）
    YIELD = 3,       // 主动让出 CPU
    GETPID = 4,      // 获取当前进程 PID
    SLEEP = 5,       // 睡眠 N 个 tick
    BRK = 6,         // 调整堆顶（简易内存分配）
    OPEN = 7,        // 打开文件（VFS）
    CLOSE = 8,       // 关闭文件描述符
    STAT = 9,        // 获取文件信息
    MMAP = 10,       // 映射匿名内存页
};

pub const MAX_SYSCALL: u64 = 10;

// 错误码（负数表示错误，放在 rax 中返回）
pub const ENOSYS: i64 = -1;    // 未知系统调用
pub const EFAULT: i64 = -2;    // 无效地址
pub const EINVAL: i64 = -3;    // 无效参数
pub const ENOMEM: i64 = -4;    // 内存不足
pub const EBADF: i64 = -5;     // 无效文件描述符
pub const ENOENT: i64 = -6;    // 文件不存在
```

#### 类型

```zig
/// 系统调用上下文（从保存的寄存器中提取）
pub const SyscallContext = struct {
    number: u64,    // rax
    arg1: u64,      // rdi
    arg2: u64,      // rsi
    arg3: u64,      // rdx
    arg4: u64,      // r10
    arg5: u64,      // r8
    arg6: u64,      // r9
};

/// 统计信息
pub const Stats = struct {
    total_calls: u64,
    by_number: [MAX_SYSCALL + 1]u64,
    unknown_calls: u64,
    fault_returns: u64,
};
```

#### 全局状态

```zig
var stats: Stats = std.mem.zeroes(Stats);
```

#### 公共函数

```zig
/// 系统调用分发入口（由 idt.zig 的 syscallStub 调用）
/// 参数从栈上保存的寄存器中获取
/// 返回值写入 rax
pub export fn syscallDispatch(
    number: u64,    // rax
    arg1: u64,      // rdi
    arg2: u64,      // rsi
    arg3: u64,      // rdx
    arg4: u64,      // r10
    arg5: u64,      // r8
) callconv(.c) u64;

/// 获取统计
pub fn getStats() Stats;
```

#### syscallDispatch() 内部逻辑

```
1. stats.total_calls += 1
2. 如果 number > MAX_SYSCALL → stats.unknown_calls += 1, return ENOSYS
3. stats.by_number[number] += 1
4. switch (number):
     EXIT  → sysExit(arg1)
     WRITE → sysWrite(arg1, arg2, arg3)
     READ  → sysRead(arg1, arg2, arg3)
     YIELD → sysYield()
     GETPID → sysGetpid()
     SLEEP → sysSleep(arg1)
     BRK   → sysBrk(arg1)
     OPEN  → sysOpen(arg1, arg2)
     CLOSE → sysClose(arg1)
     STAT  → sysStat(arg1, arg2, arg3)
     MMAP  → sysMmap(arg1, arg2)
```

#### 各系统调用实现

```zig
/// SYS_EXIT: 终止当前用户进程
/// arg1: 退出码
/// 不返回
fn sysExit(exit_code: u64) noreturn;
```

```
1. 获取当前 task，记录 exit_code
2. 设置 task.state = .finished
3. 释放用户地址空间的所有页帧
4. 调度下一个任务
5. 如果没有其他任务 → 回到 shell（idle 任务）
```

```zig
/// SYS_WRITE: 写数据到输出
/// fd: 文件描述符（1=stdout/serial, 2=stderr/serial）
/// buf_ptr: 用户态缓冲区地址
/// count: 写入字节数
/// 返回: 实际写入的字节数，或错误码
fn sysWrite(fd: u64, buf_ptr: u64, count: u64) u64;
```

```
1. 如果 fd != 1 且 fd != 2 → return EBADF
2. 如果 count == 0 → return 0
3. 如果 count > 4096 → count = 4096（限制单次写入量）
4. 验证用户缓冲区:
   如果 buf_ptr >= 0x0000_8000_0000_0000 → return EFAULT（地址在内核空间）
   如果 buf_ptr + count 溢出 → return EFAULT
   对每一页调用 vmm.translateAddr() 确认映射存在 → 不存在则 return EFAULT
5. 从用户内存复制到内核临时缓冲区（不直接传用户指针给内核函数）
6. 逐字节输出到 serial + VGA (通过 log 模块)
7. return count
```

> **安全要点**：为什么不能直接用用户传来的指针？
> 
> 虽然我们的内核可以访问所有内存，用户传来的 `buf_ptr` 可能：
> - 指向内核代码/数据 → 泄露内核信息
> - 指向未映射的页 → 触发内核 page fault（如果内核没有处理，就崩了）
> - 指向其他进程的内存（如果以后支持多地址空间）
> 
> 所以必须先验证地址落在用户空间范围内，再验证页表确实有映射。

```zig
/// SYS_READ: 从输入读取数据
/// fd: 文件描述符（0=stdin/keyboard）
/// buf_ptr: 用户态缓冲区地址
/// count: 最大读取字节数
/// 返回: 实际读取的字节数
fn sysRead(fd: u64, buf_ptr: u64, count: u64) u64;
```

```
1. 如果 fd != 0 → return EBADF
2. 验证用户缓冲区（同 sysWrite）
3. 从 keyboard 缓冲区读取最多 count 字节
4. 复制到用户内存
5. return 实际读取的字节数（可能为 0，表示暂无输入）
```

```zig
/// SYS_YIELD: 主动让出 CPU
fn sysYield() u64;
```

```
1. scheduler.yield()
2. return 0
```

```zig
/// SYS_GETPID: 获取当前进程 PID
fn sysGetpid() u64;
```

```
1. return task.currentPid() 或 0
```

```zig
/// SYS_SLEEP: 休眠
/// ticks: PIT tick 数（100Hz 下，100 = 1 秒）
fn sysSleep(ticks: u64) u64;
```

```
1. 记录当前 tick: start = pit.ticks()
2. 设置 task.state = .blocked, task.wake_tick = start + ticks
3. scheduler.yield()
4. return 0
（需要在 scheduler.timerTick 中检查 blocked 任务的 wake_tick）
```

```zig
/// SYS_BRK: 调整进程堆顶
/// new_brk: 新的堆顶地址（0 表示查询当前值）
/// 返回: 当前堆顶地址
fn sysBrk(new_brk: u64) u64;
```

```
1. 获取当前进程的 brk 值
2. 如果 new_brk == 0 → return 当前 brk
3. 验证 new_brk 在用户空间范围内
4. 如果 new_brk > 当前 brk:
   为新增的页分配物理帧，mapPage(virt, phys, writable=true, user=true)
5. 如果 new_brk < 当前 brk:
   释放多余的页
6. 更新 brk，return 新的 brk
```

```zig
/// SYS_MMAP: 映射匿名内存页
/// addr: 期望的虚拟地址（0 表示内核自动选择）
/// length: 映射长度（向上对齐到页）
/// 返回: 映射的虚拟地址，或 ENOMEM
fn sysMmap(addr: u64, length: u64) u64;
```

```
1. pages = (length + PAGE_SIZE - 1) / PAGE_SIZE
2. 如果 addr == 0 → 从进程的 mmap 区域分配
3. 为每一页 allocFrame + mapPage(user=true, writable=true)
4. return 映射的起始虚拟地址
```

### 3.3 修改 src/idt.zig — syscall 分发

当前的 `syscallStub` 使用 `pushRegsAndCall`，只保存 caller-saved 寄存器。需要改为保存完整上下文并传递参数：

```zig
// 替换现有的 syscallStub
fn syscallStub() callconv(.naked) void {
    // 保存所有通用寄存器
    // 从寄存器中提取 syscall 参数，调用 syscallDispatch
    // 把返回值放入栈上保存的 rax 位置
    // 恢复寄存器，iretq
    asm volatile (
        // 保存寄存器
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
        //
        // 调用 syscallDispatch(number=rax, arg1=rdi, arg2=rsi, arg3=rdx, arg4=r10, arg5=r8)
        // System V AMD64 调用约定: rdi, rsi, rdx, rcx, r8, r9
        // 注意寄存器重排: 我们需要把 rax→rdi, rdi→rsi, rsi→rdx, rdx→rcx, r10→r8, r8→r9
        // 但是这些寄存器已经 push 到栈上了,从栈上读取来避免冲突
        \\movq 112(%%rsp), %%rdi   // number = saved rax (第15个push, 14*8=112)
        \\movq 64(%%rsp), %%rsi    // arg1 = saved rdi (第8个push, 8*8=64)
        \\movq 72(%%rsp), %%rdx    // arg2 = saved rsi (第9个push, 9*8=72)
        \\movq 88(%%rsp), %%rcx    // arg3 = saved rdx (第11个push, 11*8=88)
        \\movq 40(%%rsp), %%r8     // arg4 = saved r10 (第5个push, 5*8=40)
        \\movq 56(%%rsp), %%r9     // arg5 = saved r8 (第7个push, 7*8=56)
        \\call syscallDispatch
        //
        // 返回值在 rax, 需要写入栈上保存的 rax 位置
        \\movq %%rax, 112(%%rsp)
        //
        // 恢复寄存器
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
```

> **讲解：栈偏移怎么算的？**
>
> push 顺序是 rax, rbx, rcx, rdx, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15。
> 栈是向下增长的，所以最后 push 的（r15）在最低地址（rsp+0）。
>
> ```
> RSP+112: rax  (第1个push)
> RSP+104: rbx  (第2个push)
> RSP+96:  rcx  (第3个push)
> RSP+88:  rdx  (第4个push)
> RSP+80:  rbp  (第5个push)
> RSP+72:  rsi  (第6个push)
> RSP+64:  rdi  (第7个push)
> RSP+56:  r8   (第8个push)
> RSP+48:  r9   (第9个push)
> RSP+40:  r10  (第10个push)
> RSP+32:  r11  (第11个push)
> RSP+24:  r12  (第12个push)
> RSP+16:  r13  (第13个push)
> RSP+8:   r14  (第14个push)
> RSP+0:   r15  (第15个push)
> ```

### 3.4 用户地址验证工具

```zig
// 在 syscall.zig 中

/// 用户空间地址上限（非规范地址边界）
const USER_ADDR_MAX: u64 = 0x0000_7FFF_FFFF_FFFF;

/// 验证用户态缓冲区合法性
/// 检查: 地址在用户空间范围内, 不溢出, 每一页都有映射
fn validateUserBuffer(ptr: u64, len: u64) bool {
    if (ptr == 0) return false;
    if (ptr > USER_ADDR_MAX) return false;
    if (len > USER_ADDR_MAX) return false;
    if (ptr + len < ptr) return false;  // 溢出检查
    if (ptr + len > USER_ADDR_MAX) return false;

    // 检查每一页是否映射
    var page = ptr & ~@as(u64, 0xFFF);
    const end = ptr + len;
    while (page < end) : (page += 0x1000) {
        if (vmm.translateAddr(page) == null) return false;
    }
    return true;
}

/// 从用户内存安全复制到内核缓冲区
fn copyFromUser(dest: []u8, user_src: u64, len: usize) bool {
    if (!validateUserBuffer(user_src, len)) return false;
    const src: [*]const u8 = @ptrFromInt(user_src);
    @memcpy(dest[0..len], src[0..len]);
    return true;
}

/// 从内核缓冲区安全复制到用户内存
fn copyToUser(user_dest: u64, src: []const u8) bool {
    if (!validateUserBuffer(user_dest, src.len)) return false;
    const dest: [*]u8 = @ptrFromInt(user_dest);
    @memcpy(dest[0..src.len], src);
    return true;
}
```

---

## 4. Phase 8b: 用户态地址空间

### 4.1 概念讲解：每进程页表

当前整个系统共用一个页表（CR3 指向的 PML4）。所有任务看到的虚拟地址空间完全相同。这对内核态任务没问题，但用户进程需要隔离的地址空间。

方案选择：

| 方案 | 优点 | 缺点 | 选择 |
|------|------|------|------|
| **A. 完全独立页表** | 真正的进程隔离 | 需要复制内核映射到每个新页表 | ✓ MVP |
| B. 共享高半部分 | 更简单 | 用户进程能看到彼此的低半部分 | |

我们选方案 A：每个用户进程有自己的 PML4。高半部分（内核空间）的 PML4 条目复制自内核页表，低半部分（用户空间）是进程独有的。

```
进程 A 的 PML4                  进程 B 的 PML4
┌─────────────────┐            ┌─────────────────┐
│ [256] kernel ... │ ←──────── │ [256] kernel ... │  相同的内核映射
│ [257] kernel ... │            │ [257] kernel ... │
│ ...              │            │ ...              │
│ [511] kernel ... │            │ [511] kernel ... │
├─────────────────┤            ├─────────────────┤
│ [0] 进程A的代码   │            │ [0] 进程B的代码   │  不同的用户映射
│ [1] 进程A的堆     │            │ [1] 进程B的堆     │
│ ...              │            │ ...              │
│ [255] 进程A的栈   │            │ [255] 进程B的栈   │
└─────────────────┘            └─────────────────┘
```

> PML4 有 512 个条目。条目 [256..511] 覆盖高半部分（0xFFFF800000000000+），
> 条目 [0..255] 覆盖低半部分（用户空间）。

### 4.2 src/user_mem.zig — 用户地址空间管理

#### 常量

```zig
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const cpu = @import("cpu.zig");

/// 用户空间布局
pub const USER_TEXT_BASE: u64 = 0x0000_0000_0040_0000;    // 4MB, 程序加载地址
pub const USER_HEAP_BASE: u64 = 0x0000_0000_1000_0000;    // 256MB, 堆起始
pub const USER_STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;    // 用户栈顶
pub const USER_STACK_SIZE: u64 = 16 * 4096;               // 64KB 用户栈
pub const USER_MMAP_BASE: u64 = 0x0000_0000_4000_0000;    // 1GB, mmap 区域

pub const USER_ADDR_MAX: u64 = 0x0000_7FFF_FFFF_FFFF;
const KERNEL_PML4_START: usize = 256;  // PML4[256..511] = 内核空间
const ENTRIES_PER_TABLE: usize = 512;
const PAGE_SIZE: u64 = 4096;

const MAX_USER_PAGES: usize = 256;  // 每进程最多 256 页 = 1MB（MVP 限制）
```

#### 类型

```zig
/// 用户地址空间描述符
pub const AddressSpace = struct {
    pml4_phys: u64,         // PML4 物理地址（用于写入 CR3）
    page_count: usize,      // 已分配的用户页数
    pages: [MAX_USER_PAGES]PageRecord,  // 记录每个映射的页（用于释放）
    brk: u64,               // 当前堆顶
    mmap_next: u64,         // 下一个 mmap 分配地址
};

/// 页映射记录
pub const PageRecord = struct {
    virt: u64,
    phys: u64,
    active: bool,
};

pub const CreateError = enum {
    ok,
    out_of_memory,
};
```

#### 公共函数

```zig
/// 创建新的用户地址空间
/// 1. 分配一个新的 PML4 页帧
/// 2. 清零低半部分 [0..255]
/// 3. 从当前内核页表复制高半部分 [256..511]
/// 4. 分配并映射用户栈
/// 返回: AddressSpace 或 null
pub fn create() ?AddressSpace;

/// 在用户地址空间中映射一页
/// 必须在 activate() 之前或者当地址空间是活跃的时候调用
pub fn mapUserPage(as: *AddressSpace, virt: u64, writable: bool) bool;

/// 在用户地址空间中映射已有的物理页（用于 ELF 加载）
pub fn mapUserPagePhys(as: *AddressSpace, virt: u64, phys: u64, writable: bool) bool;

/// 激活地址空间（写 CR3）
pub fn activate(as: *const AddressSpace) void;

/// 激活内核地址空间（恢复原始 CR3）
/// 用于从用户态返回内核态后，如果需要操作内核数据结构
pub fn activateKernel() void;

/// 释放用户地址空间所有页帧
/// 包括 PML4 本身和所有用户页
/// 不释放内核部分的页表（那些是共享的）
pub fn destroy(as: *AddressSpace) void;

/// 扩展堆（实现 brk 系统调用）
pub fn expandBrk(as: *AddressSpace, new_brk: u64) bool;
```

#### create() 内部逻辑

```
1. pml4_phys = pmm.allocFrame() 或 return null
2. pml4_virt: *[512]u64 = @ptrFromInt(pmm.physToVirt(pml4_phys))
3. 清零整个 PML4: @memset(pml4_virt[0..], 0)
4. 从内核页表复制高半部分:
   kernel_cr3 = 保存的内核 CR3 值
   kernel_pml4: *[512]u64 = @ptrFromInt(pmm.physToVirt(kernel_cr3))
   for (KERNEL_PML4_START..512) |i| {
       pml4_virt[i] = kernel_pml4[i];  // 复制条目（指向相同的 PDPT 页帧）
   }
5. 初始化 AddressSpace:
   .pml4_phys = pml4_phys
   .page_count = 0
   .pages = all inactive
   .brk = USER_HEAP_BASE
   .mmap_next = USER_MMAP_BASE
6. 分配用户栈:
   stack_bottom = USER_STACK_TOP - USER_STACK_SIZE
   for each page in [stack_bottom..USER_STACK_TOP]:
     如果 !mapUserPage(&as, page_addr, true) → destroy(&as), return null
7. return as
```

> **讲解：为什么复制 PML4 高半部分就够了？**
>
> PML4 条目指向 PDPT。内核的 PDPT/PD/PT 是全局共享的——我们只复制了 PML4 中的指针，
> 不是深拷贝整个页表树。这意味着：
> - 所有进程看到的内核内存映射完全一致（因为指向同一个 PDPT）
> - 如果内核后来新增了映射（修改了 PDPT/PD/PT），所有进程自动看到
> - 但如果内核新增了 PML4 条目（新的 512GB 区域），需要同步到所有进程的 PML4
>   （对 MVP 来说不会发生，内核只用 [511] 这一个 PML4 条目）

#### activate() 内部逻辑

```
1. cpu.writeCr3(as.pml4_phys)
   // 写 CR3 会自动刷新 TLB
   // 之后 CPU 用新的页表翻译地址
```

#### mapUserPage() 内部逻辑

```
1. 如果 page_count >= MAX_USER_PAGES → return false
2. phys = pmm.allocFrame() 或 return false
3. 需要在 as 的页表中映射，不是当前活跃的页表
   这里有个问题：vmm.mapPage 操作当前 CR3 指向的页表
   方案：临时切换 CR3 → 映射 → 切回
   a. saved_cr3 = cpu.readCr3()
   b. cpu.writeCr3(as.pml4_phys)
   c. vmm.mapPage(virt, phys, writable, user=true)
   d. cpu.writeCr3(saved_cr3)
4. 记录到 as.pages[page_count]
5. page_count += 1
6. return true
```

> **讲解：为什么需要临时切换 CR3？**
>
> `vmm.mapPage` 读写页表时通过 `cpu.readCr3()` 获取当前 PML4 地址。
> 如果我们不切换 CR3，`mapPage` 会修改当前活跃的页表（内核的），而不是新进程的。
> 切换 CR3 → 映射 → 切回，保证我们操作的是目标地址空间的页表。
>
> 另一种方案是修改 vmm 接受显式的 PML4 地址，但改动更大。临时切换 CR3 对 MVP 够用。

#### destroy() 内部逻辑

```
1. 遍历 as.pages:
   对每个 active 的记录:
     pmm.freeFrame(record.phys)
     record.active = false
2. 释放低半部分的中间页表（PDPT/PD/PT 页帧）:
   遍历 pml4[0..256]，递归释放子表
   （简化：MVP 可以跳过中间表的释放，只释放叶子页。小规模下泄漏几页问题不大）
3. pmm.freeFrame(as.pml4_phys)
```

---

## 5. Phase 8c: 用户进程加载与运行

### 5.1 概念讲解：从内核跳到用户态

把一个用户程序跑起来需要这些步骤：

```
1. 准备地址空间（创建页表，映射代码/数据/栈）
2. 把程序代码复制到用户空间的页
3. 切换到用户地址空间（写 CR3）
4. 设置 TSS.rsp0 = 该进程的内核栈顶
5. 通过 iretq 跳到 Ring 3

详细看第 5 步:

            内核栈
     ┌──────────────────┐
     │ SS = USER_DATA_SEL│  0x18 | 3 = 0x1B (RPL=3)
     │ RSP = user_stack  │  用户栈顶
     │ RFLAGS = 0x202    │  IF=1 (允许中断)
     │ CS = USER_CODE_SEL│  0x20 | 3 = 0x23 (RPL=3)
     │ RIP = entry_point │  程序入口地址
     └──────────────────┘
              ↓
           iretq
              ↓
     CPU 看到 CS.RPL = 3
     切换到 Ring 3
     加载 SS:RSP 为用户栈
     跳转到 RIP 开始执行
```

> **关键细节**：CS 和 SS 的低 2 位是 RPL (Requested Privilege Level)。
> `USER_CODE_SEL = 0x20`，加上 RPL=3 → `0x23`。
> `USER_DATA_SEL = 0x18`，加上 RPL=3 → `0x1B`。
> CPU 通过 RPL 判断特权级切换。

### 5.2 src/process.zig — 进程管理

这是对 task.zig 的高层封装，增加用户态支持。

#### 常量

```zig
const task = @import("task.zig");
const gdt = @import("gdt.zig");
const user_mem = @import("user_mem.zig");
const pmm = @import("pmm.zig");

const KERNEL_STACK_SIZE: usize = 8192; // 每个用户进程的内核栈大小
```

#### 类型

```zig
/// 进程类型
pub const ProcessType = enum {
    kernel,    // 内核任务（现有行为）
    user,      // 用户态进程
};

/// 用户态进程附加信息
/// 存储在 task.Task 之外（Task 结构体不改，通过 pid 关联）
pub const ProcessInfo = struct {
    pid: u32,
    proc_type: ProcessType,
    address_space: ?user_mem.AddressSpace,
    kernel_stack_phys: u64,          // 该进程的内核栈物理页
    kernel_stack_top: u64,           // 内核栈顶虚拟地址
    entry_point: u64,                // 用户程序入口
    exit_code: i32,
    active: bool,
};

const MAX_PROCESSES: usize = task.MAX_TASKS;

pub const SpawnResult = enum {
    ok,
    no_slot,
    no_memory,
    load_error,
};
```

#### 全局状态

```zig
var process_table: [MAX_PROCESSES]ProcessInfo = [_]ProcessInfo{emptyProcessInfo()} ** MAX_PROCESSES;
var kernel_cr3: u64 = 0;  // 保存内核原始 CR3
```

#### 公共函数

```zig
/// 初始化：保存内核 CR3
pub fn init() void;

/// 创建并启动用户进程
/// program: 用户程序的二进制数据（ELF 或 flat binary）
/// name: 进程名
/// 返回: pid 或 null
pub fn spawnUser(name: []const u8, program: []const u8) ?u32;

/// 创建用户进程（从 flat binary）
/// entry: 入口地址
/// code: 代码数据
/// code_vaddr: 代码加载到的虚拟地址
pub fn spawnFlat(name: []const u8, code: []const u8, code_vaddr: u64, entry: u64) ?u32;

/// 进程退出（从 syscall EXIT 调用）
pub fn exitCurrent(exit_code: i32) noreturn;

/// 获取进程信息
pub fn getProcessInfo(pid: u32) ?*const ProcessInfo;

/// 在上下文切换时调用：更新 TSS.rsp0 并切换地址空间
pub fn onContextSwitch(new_task_index: usize) void;

/// 获取内核 CR3
pub fn getKernelCr3() u64;
```

#### spawnFlat() 内部逻辑

```
1. 创建用户地址空间: as = user_mem.create() 或 return null
2. 在用户地址空间中映射代码页:
   pages_needed = (code.len + PAGE_SIZE - 1) / PAGE_SIZE
   for 0..pages_needed:
     user_mem.mapUserPage(&as, code_vaddr + i * PAGE_SIZE, false)  // 代码页只读
3. 激活用户地址空间（临时）复制代码:
   saved_cr3 = cpu.readCr3()
   cpu.writeCr3(as.pml4_phys)
   @memcpy(用户虚拟地址, code)  // 现在虚拟地址指向用户页表
   cpu.writeCr3(saved_cr3)
4. 分配内核栈（每个用户进程需要独立的内核栈）:
   kernel_stack_phys = pmm.allocFrame() 或 cleanup + return null
   kernel_stack_virt = pmm.physToVirt(kernel_stack_phys)
   kernel_stack_top = kernel_stack_virt + PAGE_SIZE
5. 在 task 中创建任务:
   使用 task.spawn() 的变体，或者直接操作 task 内部结构
   关键: 初始栈帧必须模拟 iretq 到 Ring 3 的格式

   构建初始栈（伪代码）:
   push (USER_DATA_SEL | 3)          // ss = 0x1B
   push (USER_STACK_TOP - 8)         // rsp = 用户栈顶
   push 0x202                        // rflags (IF=1)
   push (USER_CODE_SEL | 3)          // cs = 0x23
   push entry                        // rip = 用户入口
   push 0 (rax, rbx, ... r15)       // 15 个通用寄存器 = 0

6. 记录到 process_table
7. return pid
```

> **讲解：为什么用户进程需要独立的内核栈？**
>
> 当用户程序在 Ring 3 执行时，如果发生中断（比如 PIT 定时器），CPU 需要切换到 Ring 0。
> CPU 从 TSS.rsp0 获取内核栈指针，在那里保存用户的寄存器状态。
>
> 如果两个用户进程共享内核栈，进程 A 被中断时保存到内核栈的状态，
> 可能被进程 B 的中断覆盖。所以每个用户进程必须有自己的内核栈，
> 每次上下文切换时更新 TSS.rsp0。

#### onContextSwitch() 内部逻辑

```
1. 根据 new_task_index 找到对应的 ProcessInfo
2. 如果是内核任务:
   gdt.setKernelStack(默认内核栈)
   cpu.writeCr3(kernel_cr3)
3. 如果是用户进程:
   gdt.setKernelStack(process_info.kernel_stack_top)
   cpu.writeCr3(process_info.address_space.pml4_phys)
```

### 5.3 修改 src/task.zig — 增加用户态字段

Task 结构体增加最小的字段变更：

```zig
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
    // 新增字段
    is_user: bool = false,        // 是否为用户态进程
    wake_tick: u64 = 0,           // SYS_SLEEP 唤醒时刻
};
```

> 最小侵入式改动。用户态的详细信息（地址空间、内核栈等）存在 process.zig 的 process_table 中，
> 通过 pid 关联。不在 Task 里塞太多东西，保持现有代码兼容。

### 5.4 修改 src/scheduler.zig — 上下文切换时更新 TSS

```zig
// 在 switchFromContext 中，切换到新任务后:
fn switchFromContext(current_rsp: u64) u64 {
    // ... 现有逻辑 ...

    // 新增：通知 process 模块更新 TSS 和 CR3
    process.onContextSwitch(next_index);

    return new_task.rsp;
}
```

同时在 `timerTickFromContext` 中增加对 blocked 任务的唤醒检查：

```zig
// 在 timerTickFromContext 中新增:
// 检查 blocked 任务是否该唤醒
for (0..task.MAX_TASKS) |i| {
    if (task.getTask(i)) |t| {
        if (t.state == .blocked and t.wake_tick > 0 and tick_count >= t.wake_tick) {
            t.state = .ready;
            t.wake_tick = 0;
        }
    }
}
```

---

## 6. Phase 8d: ELF 加载器

### 6.1 概念讲解：ELF 是什么

ELF (Executable and Linkable Format) 是 Linux/Unix 世界的标准可执行文件格式。当你编译一个 C/Zig 程序，输出的就是 ELF 文件。

ELF 文件结构（简化）：

```
┌──────────────────────────┐
│ ELF Header (64 bytes)    │  "这个文件是什么"
│   magic: 0x7F 'E' 'L' 'F'│
│   class: 64-bit          │
│   entry: 程序入口地址      │
│   phoff: Program Header偏移│
│   phnum: Program Header数量│
├──────────────────────────┤
│ Program Headers          │  "怎么加载到内存"
│   [0] LOAD: 加载代码段     │   vaddr=0x400000, filesz=0x1000
│   [1] LOAD: 加载数据段     │   vaddr=0x401000, filesz=0x100
│   ...                    │
├──────────────────────────┤
│ .text (代码)              │  实际的机器指令
├──────────────────────────┤
│ .rodata (只读数据)        │  字符串常量等
├──────────────────────────┤
│ .data (可写数据)          │  全局变量初始值
├──────────────────────────┤
│ .bss (零初始化数据)       │  全局变量（文件中不占空间）
└──────────────────────────┘
```

加载器只关心 **Program Headers**（不是 Section Headers）。每个 PT_LOAD 类型的 Program Header 告诉我们：把文件中的哪段数据，加载到虚拟地址的什么位置。

### 6.2 src/elf.zig — ELF 解析器

#### 常量

```zig
// ELF magic
const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };

// ELF class
const ELFCLASS64: u8 = 2;

// ELF data encoding
const ELFDATA2LSB: u8 = 1;  // Little-endian

// ELF type
const ET_EXEC: u16 = 2;     // Executable

// ELF machine
const EM_X86_64: u16 = 62;

// Program header types
const PT_NULL: u32 = 0;
const PT_LOAD: u32 = 1;

// Program header flags
const PF_X: u32 = 1;    // Execute
const PF_W: u32 = 2;    // Write
const PF_R: u32 = 4;    // Read

// ELF header 大小
const ELF_HEADER_SIZE: usize = 64;
const PHDR_ENTRY_SIZE: usize = 56;
```

#### ELF 头部字段偏移

```zig
// 我们用 offset + read 方式解析（不用 packed struct），和项目风格一致
const OFF_MAGIC: usize = 0;       // [4]u8
const OFF_CLASS: usize = 4;       // u8
const OFF_DATA: usize = 5;        // u8
const OFF_TYPE: usize = 16;       // u16 LE
const OFF_MACHINE: usize = 18;    // u16 LE
const OFF_ENTRY: usize = 24;      // u64 LE
const OFF_PHOFF: usize = 32;      // u64 LE (program header table offset)
const OFF_PHENTSIZE: usize = 54;  // u16 LE
const OFF_PHNUM: usize = 56;      // u16 LE

// Program Header 字段偏移（每个条目内）
const PH_OFF_TYPE: usize = 0;     // u32 LE
const PH_OFF_FLAGS: usize = 4;    // u32 LE
const PH_OFF_OFFSET: usize = 8;   // u64 LE (在文件中的偏移)
const PH_OFF_VADDR: usize = 16;   // u64 LE (加载到的虚拟地址)
const PH_OFF_FILESZ: usize = 32;  // u64 LE (文件中的大小)
const PH_OFF_MEMSZ: usize = 40;   // u64 LE (内存中的大小, >= filesz)
```

#### 类型

```zig
/// 解析结果：一个可加载段
pub const LoadSegment = struct {
    vaddr: u64,        // 加载目标虚拟地址
    file_offset: u64,  // 文件中的偏移
    file_size: u64,    // 文件中的数据大小
    mem_size: u64,     // 内存中的大小（>= file_size, 多出部分零填充 = .bss）
    writable: bool,    // 是否可写
    executable: bool,  // 是否可执行
};

pub const ParseResult = struct {
    entry_point: u64,
    segments: [8]LoadSegment,   // 最多 8 个 LOAD 段
    segment_count: usize,
};

pub const ParseError = enum {
    ok,
    too_small,
    bad_magic,
    not_64bit,
    not_little_endian,
    not_executable,
    not_x86_64,
    too_many_segments,
    invalid_segment,
};
```

#### 公共函数

```zig
/// 解析 ELF 文件，提取加载信息
/// data: 完整的 ELF 文件内容
/// result: 输出解析结果
/// 返回: ParseError
pub fn parse(data: []const u8, result: *ParseResult) ParseError;

/// 加载 ELF 到用户地址空间
/// 对 parse() 返回的每个 segment:
///   1. 在 address_space 中映射所需的页（user=true）
///   2. 复制文件数据到对应虚拟地址
///   3. 零填充 mem_size - file_size 部分（.bss）
pub fn load(
    data: []const u8,
    result: *const ParseResult,
    addr_space: *user_mem.AddressSpace,
) bool;
```

#### parse() 内部逻辑

```
1. 如果 data.len < ELF_HEADER_SIZE → return .too_small
2. 验证 magic: data[0..4] != ELF_MAGIC → return .bad_magic
3. 验证 class: data[OFF_CLASS] != ELFCLASS64 → return .not_64bit
4. 验证 data encoding: data[OFF_DATA] != ELFDATA2LSB → return .not_little_endian
5. 验证 type: readLe16(data, OFF_TYPE) != ET_EXEC → return .not_executable
6. 验证 machine: readLe16(data, OFF_MACHINE) != EM_X86_64 → return .not_x86_64
7. entry = readLe64(data, OFF_ENTRY)
8. phoff = readLe64(data, OFF_PHOFF)
9. phentsize = readLe16(data, OFF_PHENTSIZE)
10. phnum = readLe16(data, OFF_PHNUM)
11. result.entry_point = entry
12. result.segment_count = 0
13. 遍历 program headers:
    for 0..phnum:
      ph_offset = phoff + i * phentsize
      如果 ph_offset + PHDR_ENTRY_SIZE > data.len → return .invalid_segment
      p_type = readLe32(data, ph_offset + PH_OFF_TYPE)
      如果 p_type != PT_LOAD → continue
      如果 result.segment_count >= 8 → return .too_many_segments
      填充 LoadSegment:
        vaddr = readLe64(data, ph_offset + PH_OFF_VADDR)
        file_offset = readLe64(data, ph_offset + PH_OFF_OFFSET)
        file_size = readLe64(data, ph_offset + PH_OFF_FILESZ)
        mem_size = readLe64(data, ph_offset + PH_OFF_MEMSZ)
        flags = readLe32(data, ph_offset + PH_OFF_FLAGS)
        writable = (flags & PF_W) != 0
        executable = (flags & PF_X) != 0
      验证:
        如果 file_offset + file_size > data.len → return .invalid_segment
        如果 vaddr > user_mem.USER_ADDR_MAX → return .invalid_segment
      result.segments[result.segment_count] = segment
      result.segment_count += 1
14. return .ok
```

#### load() 内部逻辑

```
1. 遍历 result.segments[0..result.segment_count]:
   for each segment:
     a. 计算需要的页数:
        start_page = segment.vaddr & ~0xFFF
        end_addr = segment.vaddr + segment.mem_size
        end_page = (end_addr + 0xFFF) & ~0xFFF
        pages = (end_page - start_page) / PAGE_SIZE
     b. 映射页:
        for 0..pages:
          user_mem.mapUserPage(addr_space, start_page + i * PAGE_SIZE, segment.writable)
     c. 激活地址空间并复制数据:
        saved_cr3 = cpu.readCr3()
        cpu.writeCr3(addr_space.pml4_phys)
        dest: [*]u8 = @ptrFromInt(segment.vaddr)
        @memcpy(dest[0..segment.file_size], data[segment.file_offset..][0..segment.file_size])
        // 零填充 .bss 部分
        if (segment.mem_size > segment.file_size):
          @memset(dest[segment.file_size..segment.mem_size], 0)
        cpu.writeCr3(saved_cr3)
2. return true
```

#### LE 读取工具

```zig
fn readLe16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readLe32(data: []const u8, offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

fn readLe64(data: []const u8, offset: usize) u64 {
    return @as(u64, readLe32(data, offset)) |
        (@as(u64, readLe32(data, offset + 4)) << 32);
}
```

> **注意**：ELF 文件用小端序（Little-endian），和我们的 x86_64 CPU 字节序相同。
> 这和网络协议（大端序）相反。所以这里用 readLe16 而不是 readBe16。

---

## 7. Phase 8e: 进程生命周期

### 7.1 概念讲解：进程的一生

```
          spawnFlat / spawnUser
                  │
                  ↓
            ┌──────────┐
            │  READY   │ ←─── 被创建，等待调度
            └────┬─────┘
                 │ 被调度器选中
                 ↓
            ┌──────────┐
            │ RUNNING  │ ←─── 在 CPU 上执行（Ring 3）
            └─┬──┬──┬──┘
              │  │  │
   中断/syscall│  │  │ SYS_SLEEP
              │  │  ↓
              │  │ ┌──────────┐
              │  │ │ BLOCKED  │ ←── 等待条件（睡眠、I/O）
              │  │ └────┬─────┘
              │  │      │ 条件满足（wake_tick 到达）
              │  │      ↓
              │  │   回到 READY
              │  │
              │  │ SYS_EXIT
              │  ↓
              │ ┌──────────┐
              │ │ FINISHED │ ←── 进程结束，等待回收
              │ └──────────┘
              │       │
              │       ↓ 回收资源
              │    (slot freed)
              │
              │ 时间片用完
              ↓
          回到 READY（抢占）
```

### 7.2 内核态 → 用户态的首次跳转

新创建的用户进程第一次被调度时，需要从内核态"跳"到 Ring 3。这是通过在内核栈上构造一个假的中断返回帧来实现的：

```zig
/// 在 process.zig 中
/// 构建用于 iretq 到 Ring 3 的初始栈帧
fn buildUserInitialStack(kernel_stack_top: u64, entry: u64, user_stack_top: u64) u64 {
    var sp = kernel_stack_top;

    // iretq 会弹出这 5 个值
    pushStack(&sp, gdt.USER_DATA_SEL | 3);   // ss (RPL=3)
    pushStack(&sp, user_stack_top);            // rsp
    pushStack(&sp, 0x202);                     // rflags (IF=1)
    pushStack(&sp, gdt.USER_CODE_SEL | 3);    // cs (RPL=3)
    pushStack(&sp, entry);                     // rip

    // 15 个通用寄存器（全部清零，干净的初始状态）
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
```

当调度器选中这个任务时，`switchFromContext` 返回这个 RSP，中断返回路径 popq 15 个寄存器后执行 `iretq`，CPU 看到 CS.RPL=3，自动切到 Ring 3 执行用户代码。

> **讲解：这是一个优雅的技巧**
>
> 我们没有专门的 "进入用户态" 指令。而是复用了中断返回机制——
> `iretq` 不知道自己是不是在"返回"，它只是从栈上弹出 RIP/CS/RFLAGS/RSP/SS 并跳转。
> 如果我们把 CS 设为用户态的选择子，iretq 就会"返回"到一个从未被"中断"过的用户态程序。
> 所有操作系统都用这个技巧。

---

## 8. Phase 8f: Shell 集成

### 8.1 内嵌测试程序

MVP 阶段不从磁盘加载 ELF，而是在内核中内嵌几个简单的用户态测试程序（汇编编写，作为字节数组）。

#### 测试程序 1: hello_user（最小可行程序）

```zig
// 在 shell_cmds.zig 或单独的 user_programs.zig 中

/// 最简单的用户态程序：打印 "Hello from Ring 3!" 然后退出
/// 手工编写的 x86_64 机器码
pub const hello_user = [_]u8{
    // mov rax, 1          ; SYS_WRITE
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1          ; fd = stdout
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+msg]  ; buf = message
    0x48, 0x8d, 0x35, 0x1e, 0x00, 0x00, 0x00,
    // mov rdx, 19         ; count = 19
    0x48, 0xc7, 0xc2, 0x13, 0x00, 0x00, 0x00,
    // int 0x80            ; syscall
    0xcd, 0x80,
    // mov rax, 0          ; SYS_EXIT
    0x48, 0xc7, 0xc0, 0x00, 0x00, 0x00, 0x00,
    // mov rdi, 0          ; exit_code = 0
    0x48, 0xc7, 0xc7, 0x00, 0x00, 0x00, 0x00,
    // int 0x80            ; syscall
    0xcd, 0x80,
    // msg: "Hello from Ring 3!\n"
    'H', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm',
    ' ', 'R', 'i', 'n', 'g', ' ', '3', '!', '\n',
};
```

> **讲解：为什么用手写机器码？**
>
> 用户程序运行在 Ring 3，用完全不同的地址空间。它不能调用内核的 Zig 函数，
> 唯一的通信方式是系统调用（int 0x80）。最简单的测试方式就是手写几条指令。
>
> 后续可以用 Zig 交叉编译用户态程序（target: x86_64-freestanding-none），
> 链接到固定地址，输出 flat binary 或 ELF。

#### 测试程序 2: loop_user（测试抢占）

```zig
/// 无限循环程序：测试用户态被抢占是否工作
pub const loop_user = [_]u8{
    // mov rax, 1          ; SYS_WRITE
    0x48, 0xc7, 0xc0, 0x01, 0x00, 0x00, 0x00,
    // mov rdi, 1          ; stdout
    0x48, 0xc7, 0xc7, 0x01, 0x00, 0x00, 0x00,
    // lea rsi, [rip+msg]
    0x48, 0x8d, 0x35, 0x1e, 0x00, 0x00, 0x00,
    // mov rdx, 6          ; "tick\n" + null
    0x48, 0xc7, 0xc2, 0x05, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // mov rax, 3          ; SYS_YIELD
    0x48, 0xc7, 0xc0, 0x03, 0x00, 0x00, 0x00,
    // int 0x80
    0xcd, 0x80,
    // jmp -46              ; 跳回开头 (loop)
    0xeb, 0xd2,
    // msg: "tick\n"
    't', 'i', 'c', 'k', '\n',
};
```

### 8.2 新增 Shell 命令

```zig
// 添加到 shell_cmds.zig 的 commands 数组
.{ .name = "runuser", .description = "Run a built-in user-mode test program", .handler = cmdRunuser },
.{ .name = "ps", .description = "Show process list with type info", .handler = cmdPs },
.{ .name = "killuser", .description = "Kill a user process by PID", .handler = cmdKilluser },
.{ .name = "syscallstat", .description = "Show syscall statistics", .handler = cmdSyscallstat },
```

#### cmdRunuser

```
用法: runuser <program>
可选: runuser hello     — 运行 hello_user
      runuser loop      — 运行 loop_user
      runuser <addr>    — 运行 ELF（未来）

1. 根据参数选择内嵌程序
2. process.spawnFlat(name, program_bytes, USER_TEXT_BASE, USER_TEXT_BASE)
3. 显示: "Spawned user process 'hello' (pid N)"
4. netpoll 式循环等待（或者立即返回，让调度器在后台运行用户进程）
```

#### cmdPs（增强现有的 ps 命令）

```
用法: ps

PID  Name       Type    State       Ticks   Switches
1    shell      kernel  running     50000   300
2    worker     kernel  ready       12000   150
3    hello      user    finished    5       1
4    loop       user    ready       100     10
```

#### cmdKilluser

```
用法: killuser <pid>

1. 获取 ProcessInfo，确认是 user 类型
2. process.exitCurrent 或 task.kill
3. 释放地址空间
4. 显示结果
```

#### cmdSyscallstat

```
用法: syscallstat

Syscall statistics:
  Total calls: 150
  EXIT:    3
  WRITE:   120
  READ:    15
  YIELD:   10
  GETPID:  2
  Unknown: 0
  Faults:  0
```

---

## 9. 集成与初始化顺序

### 9.1 src/main.zig 修改

在现有初始化序列中添加：

```zig
// 已有
gdt.init();
idt.init();

// 新增（在 task.init 之后）
const process = @import("process.zig");
process.init();
log.kprintln("[proc] Process subsystem initialized", .{});
```

### 9.2 初始化依赖链

```
gdt.init()      ← GDT + TSS（已有）
  ↓
idt.init()      ← IDT（已有，syscallStub 改为完整分发）
  ↓
pmm.init()      ← 物理内存管理（已有）
  ↓
vmm 初始化       ← 虚拟内存（已有，由 Limine 建立初始页表）
  ↓
heap.init()     ← 内核堆（已有）
  ↓
task.init()     ← 任务管理（已有，小改）
  ↓
process.init()  ← 新增：保存内核 CR3，初始化 process_table
  ↓
scheduler.init() ← 调度器（小改）
```

### 9.3 新增文件列表

```
src/
├── syscall.zig      # 系统调用分发 + 实现
├── user_mem.zig     # 用户地址空间管理
├── elf.zig          # ELF 解析器
├── process.zig      # 进程管理
└── user_programs.zig # 内嵌的用户态测试程序（机器码）
```

### 9.4 修改文件列表

```
src/idt.zig          # syscallStub 改为完整的 syscall 分发
src/task.zig         # Task 增加 is_user, wake_tick 字段
src/scheduler.zig    # switchFromContext 中调用 process.onContextSwitch
                     # timerTick 中检查 blocked 任务唤醒
src/shell_cmds.zig   # 新增 runuser, ps, killuser, syscallstat 命令
src/main.zig         # 新增 process.init() 调用
```

---

## 10. QEMU 测试方法

### 10.1 测试 hello_user

```
MerlionOS> runuser hello
Spawned user process 'hello' (pid 2)
Hello from Ring 3!
Process 'hello' exited with code 0
```

如果看到 "Hello from Ring 3!"，说明：
- 用户地址空间创建成功
- Ring 0 → Ring 3 跳转成功
- int 0x80 → syscall 分发 → SYS_WRITE 成功
- SYS_EXIT 正确回收了进程

### 10.2 测试 loop_user + 抢占

```
MerlionOS> runuser loop &     # 后台运行（如果支持的话）
Spawned user process 'loop' (pid 3)
tick
tick
tick
MerlionOS> ps                  # 验证 shell 仍然可用（抢占工作正常）
MerlionOS> killuser 3
Killed process 3
```

### 10.3 测试保护机制

```
# 用户程序尝试执行特权指令 → 应该触发 #GP，内核杀掉进程
# 用户程序尝试访问内核地址 → 应该触发 #PF，内核杀掉进程
```

可以创建专门的测试程序：

```zig
/// 尝试执行 CLI（特权指令），应该被杀掉
pub const bad_cli = [_]u8{
    0xFA,       // cli — Ring 3 不允许
    0xEB, 0xFE, // jmp $ (不应该到达这里)
};

/// 尝试读取内核内存，应该触发 Page Fault
pub const bad_read = [_]u8{
    // mov rax, 0xFFFFFFFF80000000  ; 内核地址
    0x48, 0xB8, 0x00, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0xFF,
    // mov al, [rax]               ; 尝试读取
    0x8A, 0x00,
    0xEB, 0xFE, // jmp $
};
```

### 10.4 测试用例清单

```
- [ ] hello_user: 打印并正常退出
- [ ] loop_user: 循环打印 + yield，验证调度器工作
- [ ] bad_cli: 验证 #GP 被捕获，进程被杀而非内核崩溃
- [ ] bad_read: 验证 #PF 被捕获，进程被杀
- [ ] 同时运行多个用户进程 + shell，验证抢占式调度
- [ ] ps 命令显示正确的进程类型和状态
- [ ] syscallstat 显示正确的调用计数
```

---

## 11. 安全模型总结

```
保护层次:

1. CPU 硬件 (Ring 0 vs Ring 3)
   - 用户代码无法执行 CLI/STI/HLT/LGDT/LIDT/MOV CR*/IN/OUT 等特权指令
   - 违反 → #GP 异常 → 内核捕获 → 杀进程

2. 页表 (U/S 位)
   - 用户页标记 U/S=1，内核页 U/S=0
   - Ring 3 代码访问 U/S=0 的页 → #PF 异常 → 内核捕获 → 杀进程

3. 系统调用参数验证
   - 所有用户传入的指针必须验证在用户地址空间内
   - 所有用户传入的长度必须验证不越界
   - 内核不直接解引用用户指针（先复制到内核缓冲区）

4. TSS.rsp0 切换
   - 每次上下文切换更新 TSS.rsp0
   - 确保中断发生时使用正确进程的内核栈
   - 防止进程间通过内核栈泄露信息
```

---

## 附录: 实现顺序检查清单

```
Phase 8a: syscall 基础设施
- [ ] src/syscall.zig — 系统调用分发 + SYS_WRITE + SYS_EXIT + SYS_GETPID
- [ ] 修改 src/idt.zig — syscallStub 改为完整分发

Phase 8b: 用户地址空间
- [ ] src/user_mem.zig — create / mapUserPage / activate / destroy
- [ ] 验证: 创建地址空间，映射一页，切换 CR3，不崩

Phase 8c: 用户进程
- [ ] src/process.zig — init / spawnFlat / onContextSwitch / exitCurrent
- [ ] src/user_programs.zig — hello_user 机器码
- [ ] 修改 src/task.zig — 增加 is_user, wake_tick
- [ ] 修改 src/scheduler.zig — 切换时调用 process.onContextSwitch
- [ ] 验证: runuser hello 打印 "Hello from Ring 3!"

Phase 8d: ELF 加载器
- [ ] src/elf.zig — parse / load
- [ ] 验证: 解析一个 ELF，打印段信息

Phase 8e: 进程生命周期
- [ ] syscall.zig 补充: SYS_READ / SYS_YIELD / SYS_SLEEP / SYS_BRK
- [ ] scheduler.zig: blocked 任务唤醒
- [ ] 验证: loop_user + 抢占 + killuser

Phase 8f: Shell 集成
- [ ] shell_cmds.zig: runuser / ps / killuser / syscallstat
- [ ] user_programs.zig: loop_user / bad_cli / bad_read
- [ ] 验证: 所有测试用例
- [ ] main.zig: 添加 process.init()
```
