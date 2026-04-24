# Phase 12 实现规格：进程创建（fork / exec / waitpid）

> 本文档是**实现规格（Spec）**，供 Codex / Claude 等 AI 代码生成工具直接实现使用。
> 依赖 Phase 11 全部完成（含 `SYS_MMAP`）。
> 同批次的路线图见 `ROADMAP-PHASE12-PLUS.md`。

## 目录

1. [动机与范围](#1-动机与范围)
2. [系统调用与编号](#2-系统调用与编号)
3. [数据结构改动](#3-数据结构改动)
4. [Phase 12a: 地址空间克隆](#4-phase-12a-地址空间克隆)
5. [Phase 12b: SYS_FORK](#5-phase-12b-sys_fork)
6. [Phase 12c: SYS_EXEC](#6-phase-12c-sys_exec)
7. [Phase 12d: 僵尸进程与 SYS_WAITPID](#7-phase-12d-僵尸进程与-sys_waitpid)
8. [Phase 12e: SYS_GETPPID](#8-phase-12e-sys_getppid)
9. [Phase 12f: Shell 集成与演示程序](#9-phase-12f-shell-集成与演示程序)
10. [QEMU 验收](#10-qemu-验收)
11. [实现顺序检查清单](#11-实现顺序检查清单)

---

## 1. 动机与范围

Phase 11 结束后，用户态唯一的进入方式是 `runuser <name>`（内嵌 flat binary）或 `runelf <path>`（VFS 上的 ELF）。两者都必须由**内核**发起。用户程序自身无法派生新进程，也无法把自己替换为另一段代码。

Phase 12 让以下三行程序合法并跑通：

```c
pid_t p = fork();
if (p == 0) exec("/bin/hello.elf");
else        waitpid(p, &status);
```

**不在本 Phase 范围内**：

- 写时复制（COW）。本 Phase 采用直接复制物理页，每次 fork 最多 `MAX_USER_PAGES * 4KB = 1MB`，接受这个开销。COW 留给未来的 Phase 12g（如有需要）。
- 多线程。`SYS_CLONE` 的 flags 语义不实现。
- `vfork`。
- 文件描述符引用计数（fd 在 fork 时按值复制到子进程 fd 表，pipe/socket 的引用计数由对应 Phase 引入）。

---

## 2. 系统调用与编号

接续 Phase 11 末位（`SYS_MMAP=10`），在 `src/syscall.zig` 顶层 `SYS` enum 追加：

```zig
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
    FORK = 11,
    EXEC = 12,
    WAITPID = 13,
    GETPPID = 14,
};

pub const MAX_SYSCALL = 14;
```

新增错误码（沿用负值约定）：

```zig
pub const ECHILD: i64 = -7;   // waitpid: 无子进程
pub const ENOEXEC: i64 = -8;  // exec: ELF 解析/段加载失败
```

`syscallName(n)` 扩展对应分支；`dispatch` 新增四条 arm：

```zig
.FORK => sysFork(),
.EXEC => sysExec(ctx.arg1),
.WAITPID => sysWaitpid(ctx.arg1, ctx.arg2),
.GETPPID => sysGetppid(),
```

---

## 3. 数据结构改动

### 3.1 `src/task.zig`

```zig
pub const TaskState = enum {
    ready,
    running,
    blocked,
    finished,
    zombie,    // 新增：已 exit，等父进程 waitpid
};

pub const Task = struct {
    // 既有字段不动
    parent_pid: u32 = 0,       // 新增：0 表示无父（boot / kernel 任务）
    wait_on_pid: u32 = 0,      // 新增：blocked 在 waitpid 时保存目标 pid；0 表示 any
    exit_status: u32 = 0,      // 新增：编码同 POSIX wstatus（低 8 位 exit code 或信号号）
};
```

原有的 `finished` 状态仍然保留，表示"已 exit 且无父要回收"——这会在 `parent_pid == 0` 的进程 exit 时直接采用，跳过僵尸阶段。

### 3.2 `src/process.zig`

`ProcessInfo` 增加：

```zig
pub const ProcessInfo = struct {
    // 既有字段
    parent_pid: u32 = 0,      // 新增
};
```

`process.zig` 新增四个公共函数（见 §5–§8）。

### 3.3 `src/user_mem.zig`

新增一个公共函数：

```zig
pub fn cloneAddressSpace(src: *const AddressSpace, dst: *AddressSpace) bool;
```

详见 §4。

---

## 4. Phase 12a: 地址空间克隆

### 4.1 目标

输入一个已激活或未激活的源地址空间 `src`，在堆外（调用者传入的 `dst`）构造一份独立副本：

- 新 PML4（共享内核半边，用户半边全新）
- 每个 `src.pages[i].active` 对应的虚拟页，分配一个新的物理帧，把源帧内容按 4KB 复制过去，并以相同 `virt` 和 writable 权限映射到 `dst`
- `brk` 和 `mmap_next` 复制
- 所有中间页表（PDPT / PD / PT）独立分配

失败时回滚所有已分配的帧和页表。

### 4.2 函数签名

```zig
pub fn cloneAddressSpace(src: *const AddressSpace, dst: *AddressSpace) bool;
```

### 4.3 实现要点（伪代码）

```
1. 基础初始化
   if !createInto(dst) return false      // 复用现有 PML4 + 内核半边共享 + 初始用户栈
   // createInto 已经为用户栈分配了新页；若 src 的用户栈映射已经就绪，这里会和克隆逻辑冲突——需要先清空
   for each record in dst.pages: unmap if active
   dst.page_count = 0
   dst.brk = src.brk
   dst.mmap_next = src.mmap_next

2. 逐页复制
   saved_cr3 = cpu.readCr3() & PAGE_FRAME_MASK
   for each src.pages[i] where active:
       new_phys = pmm.allocFrame() or goto rollback
       // 源数据复制到新帧（两边都走 physToVirt 的直映射窗口，不经用户地址空间）
       src_bytes = @ptrFromInt(pmm.physToVirt(record.phys))
       dst_bytes = @ptrFromInt(pmm.physToVirt(new_phys))
       @memcpy(dst_bytes[0..PAGE_SIZE], src_bytes[0..PAGE_SIZE])
       // 映射到 dst（使用 mapUserPagePhys，writable 与源一致——此处简化为 true，
       // 因为当前实现里所有用户页都是 writable；未来引入只读段再扩展）
       if !mapUserPagePhys(dst, record.virt, new_phys, /* writable */ true):
           pmm.freeFrame(new_phys); goto rollback

3. 恢复 cr3 并返回
   cpu.writeCr3(saved_cr3)
   return true

rollback:
   cpu.writeCr3(saved_cr3)
   destroy(dst)
   return false
```

> **注意**：`createInto` 默认为 dst 分配了用户栈页；如果 `src` 的用户栈本身已经映射（99% 会），克隆时会因 "has mapping" 失败。在步骤 1 中必须先把 `createInto` 分配的栈页释放，再让步骤 2 统一分配。
> 简化方案：新增 `createBlank(dst)`——与 `createInto` 相同但**不预分配用户栈**——供 clone 使用。`create`/`createInto` 仍保留给 `spawnFlat` / `execCurrent` 走原路径。

### 4.4 自检扩展

`selfTest()` 基础上新增 `cloneSelfTest()`：

1. 创建 `src`，映射两页并写入独特字节模式
2. `cloneAddressSpace(src, dst)`
3. 激活 `dst`，读取 `src` 对应虚地址的字节应等于原模式
4. 往 `dst` 的第二页写入另一种字节模式
5. 切回 `src`，确认第二页内容**未变**（验证物理隔离）
6. 销毁两者

暴露 `shell_cmds` 新命令 `clonememtest` 触发该检查。

---

## 5. Phase 12b: SYS_FORK

### 5.1 syscall 签名

```zig
fn sysFork() u64;
// 返回：父进程收到 child_pid；子进程收到 0；失败返回 -ENOMEM / -errno
```

### 5.2 `process.zig` 新增

```zig
pub const ForkResult = union(enum) {
    parent: u32,   // 子 pid
    child,         // 子进程收到
    no_memory,
    no_slot,
};

pub fn forkCurrent() ForkResult;
```

### 5.3 实现要点

当前进程一定是用户进程（否则返回 `ENOSYS` 语义的调用者——kernel 任务调 fork 无意义，`sysFork` 开头做保护）。

```
1. parent_pid = task.currentPid()
2. 找到当前 process.ProcessInfo 的 slot
3. 分配子 slot：process.reserveSlot() → 子 index
4. 分配子 address space: cloneAddressSpace(parent.as, &child.as)，失败 → ENOMEM
5. 分配子内核栈（复用 task.zig 的 stack_pool 机制；新 task slot 获得独立栈）
6. 子内核栈上构造"回到用户态"的初始帧：
   复制父进程发起 syscall 时的用户上下文寄存器快照（见 §5.4），
   但把 rax = 0（子返回值）
7. child.state = .ready, child.parent_pid = parent.pid
8. scheduler.enqueue(child)
9. 父进程直接返回 child.pid
```

### 5.4 用户上下文快照

Phase 11 的 `syscallStub` 在内核栈上保存了 15 个通用寄存器和 iretq 所需的 5 元组（ss, rsp, rflags, cs, rip）。fork 需要知道这段栈的地址。方案：

- `syscall.zig` 新增一个 **thread-local-ish** 的全局 `current_syscall_frame: ?u64 = null`。
- `syscallStub` 在 push 完所有寄存器、调用 `syscallDispatch` 之前额外 `mov rsp, (saved_frame_addr)`（或者在 Zig 侧 `syscallDispatch` 入口用 `asm("mov %rsp, %0"…)` 抓一次 rsp），把当前栈顶记进全局。
- `sysFork` 读取这个地址，把那块内存（15 regs + 5 iretq = 160 字节）`@memcpy` 到子内核栈对应位置，再把其中 "rax" 槽改为 0。
- 子被调度时，`switchFromContext` 把子的 rsp 加载好，`popq` 15 regs，`iretq`，回到用户态——rip 是父 syscall 返回点，rax=0。

> **注意**：Zig 0.15 没有真正的 TLS，而本内核目前是单核，因此 "全局变量"足够安全；Phase 18 SMP 时要升级成 per-CPU 字段。

### 5.5 错误路径

- `cloneAddressSpace` 失败 → 已分配的子 slot 释放，返回 `-ENOMEM`
- 内核栈分配失败 → 同上
- 进程槽位已满 → 返回 `-ENOMEM`（复用；或新增 `-EAGAIN`，但当前不强制）

---

## 6. Phase 12c: SYS_EXEC

### 6.1 syscall 签名

```zig
fn sysExec(path_ptr: u64) u64;
// 成功：无返回（当前进程的用户态上下文被替换，从新 entry 继续运行）
// 失败：返回 -ENOENT / -ENOEXEC / -ENOMEM / -EFAULT；调用者继续执行原映像
```

### 6.2 `process.zig` 新增

```zig
pub const ExecResult = union(enum) {
    ok,               // 返回后由 syscallDispatch 安排跳转
    not_found,
    not_user,
    bad_elf,
    no_memory,
    bad_path,
};

pub fn execCurrent(path: []const u8) ExecResult;
```

### 6.3 实现要点

```
1. 从用户地址复制 path（复用 copyUserString；失败返回 EFAULT→调用者）
2. vfs.resolve(path) → inode_idx，未找到 → not_found
3. inode = vfs.getInode(inode_idx)；非 regular file → bad_path
4. 读取文件内容到临时堆缓冲 elf_buf（限制 1MB），失败 → no_memory
5. elf.parse(elf_buf)，不是 ELF64 x86_64 → bad_elf
6. 构造一个新的临时 AddressSpace new_as:
   createInto(&new_as)  // 此路径已分配用户栈
7. 对 elf.segments 每段：mapUserPage + 写入 file_data + 零填充 bss
   失败 → destroy(&new_as); no_memory
8. 原子替换:
   old_as = current_process.address_space
   current_process.address_space = new_as
   user_mem.activate(&new_as)
   destroy(&old_as)
9. 重新构造用户初始栈帧（process.buildUserInitialStack，entry=elf.entry，
   user_stack_top=USER_STACK_TOP）
   current_task.rsp = new_rsp
10. 清空 fd 表中标记 FD_CLOEXEC 的条目（Phase 12 先全部保留；Phase 13/14 引入 cloexec）
11. syscallDispatch 检测到 exec 成功后，不再正常返回——把保存的 rax=0 并把 iretq 栈替换为
    buildUserInitialStack 的输出；或者直接让 sysExec 返回一个特殊 sentinel，让
    syscallStub 跳转到 scheduler.yield()（见 §6.4）
```

### 6.4 返回协议

exec 成功时"不返回"这件事很棘手，因为 `syscallDispatch` 的调用者（`syscallStub`）期望 rax 承载返回值。两个可行的实现：

**方案 A（推荐）：** `sysExec` 成功时：
- 直接在内核栈上把 iretq frame 覆盖为新程序的初始帧（ss/rsp/rflags/cs/rip + 15 regs 清零）。
- 把保存的 rax 槽写成 0（习惯上成功的"返回值"）。
- `syscallDispatch` 返回 0；`syscallStub` `popq` 寄存器、`iretq`，CPU 从新 rip 开始执行。

**方案 B：** `sysExec` 成功时 `scheduler.yield()`，让当前任务重新被选中时从新栈帧启动。但这引入多余的调度开销，不推荐。

`sysExec` 必须在"开始改写当前地址空间之前"完成所有可能失败的步骤（读 ELF、解析、预分配新 AS），保证失败路径不会让进程处于半替换状态。

### 6.5 副作用

- fd 表保留（简化版）。
- 信号 handler（Phase 14）在 exec 后重置为默认。
- process name（`ProcessInfo.name`？当前没有；加一个 `name: [32]u8` 并在 exec 时设为 path basename，`ps` 显示用）。

---

## 7. Phase 12d: 僵尸进程与 SYS_WAITPID

### 7.1 僵尸化的触发

`process.exitCurrent(code)` 当前的行为是：

```
task.finishCurrent(code) → scheduler 选下一个任务
```

改动为：

```
if (current.parent_pid != 0 and parent_exists):
    current.exit_status = encodeExit(code)
    current.state = .zombie
    // 保留 address space、进程槽、内核栈，直到 parent waitpid
    maybeWakeParentWaitingOn(current.pid)
else:
    // 无父或父已退出：直接回收（保留原有 finished 语义）
    destroyProcess(current)
```

`encodeExit(code)` 约定：低 8 位 = exit code，bit 8 = signaled flag（Phase 14），高 8 位 = 信号号。

### 7.2 syscall 签名

```zig
fn sysWaitpid(pid: u64, status_ptr: u64) u64;
// 成功：返回被回收子进程的 pid
// pid == u64(-1)（cast 自 i64(-1)）表示任意子进程
// 无对应子进程 → ECHILD
// 当前进程无任何子进程 → ECHILD
// 如果 status_ptr != 0，把 exit_status 写回用户内存（4 字节 u32）
```

### 7.3 `process.zig` 新增

```zig
pub const WaitResult = union(enum) {
    ok: struct { pid: u32, status: u32 },
    no_child,
    bad_pid,
    interrupted,   // 预留给 Phase 14
};

pub fn waitpidCurrent(target_pid: u32) WaitResult;
// target_pid == 0 表示 "any child"
```

### 7.4 实现要点

```
1. 找出当前进程有多少子进程（遍历 process_table，parent_pid == me.pid && active）
   总数 == 0 → no_child
2. 遍历子进程，找已 zombie 的：
   for child in children:
       if child.state == .zombie and (target_pid == 0 or child.pid == target_pid):
           result = { pid: child.pid, status: child.exit_status }
           reapZombie(child)
           return .ok = result
3. 若指定了 target_pid 但该 pid 不是本进程的 child → bad_pid
4. 没有 zombie 命中 → 阻塞：
   current.wait_on_pid = target_pid
   task.block(current)   // 新增：scheduler.blockCurrent()
5. 被唤醒后回到步骤 2
```

子进程 exit 时（`exitCurrent`）检查所有父为自己的 waiter：若 `parent.state == .blocked and parent.wait_on_pid in (0, me.pid)`，`scheduler.unblock(parent)`。

### 7.5 reapZombie

```
fn reapZombie(child: *ProcessInfo) void:
    user_mem.destroy(&child.address_space)
    task.freeSlot(child.task_slot)
    process_table[child.slot] = empty
```

### 7.6 用户拷贝

`status_ptr != 0` 时，用 `copyToUser(status_ptr, std.mem.asBytes(&status_u32))`。失败 → `-EFAULT`。

---

## 8. Phase 12e: SYS_GETPPID

最简单的一条：

```zig
fn sysGetppid() u64 {
    const me = process.currentInfo() orelse return 0;
    return me.parent_pid;
}
```

kernel 任务 / init 返回 0。

---

## 9. Phase 12f: Shell 集成与演示程序

### 9.1 新的 VFS 常驻程序

在 initfs / 内核内嵌资源中新增以下 ELF（由 `build.zig` 的 `user-programs` step 编译，目标 `x86_64-freestanding-none`，二阶段 `build-obj + ld.lld`）：

| 路径 | 说明 |
|------|------|
| `/bin/hello.elf` | Phase 11 已有，仅 SYS_WRITE + SYS_EXIT |
| `/bin/fork_demo.elf` | 新：fork 一次，父子各打印一行，父 waitpid |
| `/bin/exec_demo.elf` | 新：exec("/bin/hello.elf")，不等待 |
| `/bin/sh_mini.elf` | 新：Phase 12 的里程碑 —— 用户态小 shell |
| `/bin/bad_exec.elf` | 新：exec 一个不存在路径，打印 errno 并退出 |

### 9.2 `/bin/sh_mini.elf` 功能范围

- 提示符 `$ `
- 内建：`exit`, `pwd`（需要 SYS_GETCWD？本 Phase 暂不需要，hardcode "/"），`help`
- 执行外部命令：`<path>` 直接 fork + exec + waitpid
- 退出码显示：`[pid=X] exited N`
- 不支持管道、重定向、信号（留给 Phase 13/14）

Zig 源文件建议：`user_src/sh_mini.zig`。约 200 行。要点：
- 自带一个极简 readline（走 SYS_READ fd=0）
- 自带一个 SYS_WRITE 的 `print`/`println` 辅助
- errno 从 syscall 返回值解码（`if rax as i64 < 0 → -rax as errno`）

### 9.3 新 shell 命令（内核 shell 的）

保留内核 shell，但让它能把 `/bin/sh_mini.elf` 拉起：

```
merlion> runelf /bin/sh_mini.elf
[sh_mini] pid=7 ppid=1
$ /bin/hello.elf
Hello from Ring 3!
[pid=8] exited 0
$ exit
[pid=7] exited 0
merlion>
```

`shell_cmds.zig` 新增：
- `fork_demo`（别名 `runelf /bin/fork_demo.elf`，方便演示）
- `ps` 列扩展："S"（state: R/r/B/Z/F）、"PPID"

### 9.4 废弃路径

内核内嵌的 `hello_user` / `loop_user` / `bad_cli` / `bad_read` / `file_user` 字节数组在 Phase 12 收尾时可以**保留但不再新增**。新增测试程序全部走 ELF + VFS。

---

## 10. QEMU 验收

### 10.1 标准回归序列

```
$ zig build run-serial
...
merlion> runelf /bin/fork_demo.elf
[fork_demo] parent pid=7 forking
[fork_demo] child pid=8 ppid=7
[fork_demo] child exiting 42
[fork_demo] parent waited on 8, status=42
[pid=7] exited 0
merlion> ps
PID  PPID  S  NAME
  1     0  R  kernel-boot
  7     1  F  fork_demo   (already reaped - should not appear)
merlion> runelf /bin/sh_mini.elf
[sh_mini] pid=9 ppid=1
$ /bin/hello.elf
Hello from Ring 3!
[pid=10] exited 0
$ /bin/bad_exec.elf
exec: ENOENT (-6)
[pid=11] exited 1
$ exit
[pid=9] exited 0
merlion>
```

### 10.2 压力与边界

1. **100 次 fork/exec/wait 循环**：`/bin/stress.elf`（可选 stretch）确认无内存泄漏（`meminfo` 前后一致）。
2. **进程槽耗尽**：连续 fork 到上限，观察 `-ENOMEM`；随后 `waitpid` 回收后还能继续。
3. **exec 失败后原进程继续**：`bad_exec.elf` 在 exec 失败后仍能打印并走正常 exit，不 panic。
4. **孤儿进程**：父先 exit、子后 exit。子进程应直接走 "finished"（或被 pid=1 回收——本 Phase 不引入 init 回收，采用"父先退则子无父可等"规则，子 exit 时直接 destroy）。
5. **waitpid ECHILD**：一个从未 fork 的进程调用 waitpid → `-7`。

### 10.3 记录格式

每个小 Phase（12a–12f）完成时向 PR 附上：

- `runelf <path>` 的 serial 输出片段
- `ps` 在该 Phase 关键时刻的快照
- `meminfo` 前后对比（确认无泄漏）

---

## 11. 实现顺序检查清单

```
Phase 12a: 地址空间克隆
- [x] user_mem.zig: createBlank（无用户栈变种）
- [x] user_mem.zig: cloneAddressSpace
- [x] user_mem.zig: cloneSelfTest
- [x] shell_cmds.zig: clonememtest 命令
- [x] 验证: clonememtest ok，且两个 AS 的同一虚地址物理隔离

Phase 12b: SYS_FORK
- [x] syscall.zig: SYS.FORK=11, MAX_SYSCALL 更新
- [x] syscall.zig: current_syscall_frame 捕获逻辑（idt.syscallStub 侧 + Zig 侧）
- [x] task.zig: parent_pid, exit_status, wait_on_pid 字段
- [x] process.zig: forkCurrent, ForkResult, reserveSlot
- [x] syscall.zig: sysFork 连接
- [x] 验证: runuser fork 父子输出、rax=0/child_pid 分流

Phase 12c: SYS_EXEC
- [x] process.zig: execCurrent, ExecResult
- [x] syscall.zig: sysExec + 成功时覆盖 iretq 栈帧
- [x] process.zig: ProcessInfo.name 字段 + basename 提取
- [x] shell_cmds.zig: ps 显示 NAME
- [x] 验证: runuser exec 打印 "Hello from Ring 3!" 且未走失败路径

Phase 12d: SYS_WAITPID
- [ ] task.zig: TaskState.zombie
- [ ] process.zig: waitpidCurrent, WaitResult, reapZombie, maybeWakeParentWaitingOn
- [ ] process.zig: exitCurrent 改造（zombie vs destroy 分支）
- [ ] scheduler.zig: blockCurrent / unblock（如尚无，复用 sleep 机制扩展）
- [ ] syscall.zig: sysWaitpid
- [ ] 验证: fork_demo 的 waitpid 返回 child.pid 与正确 status

Phase 12e: SYS_GETPPID
- [ ] syscall.zig: sysGetppid
- [ ] 验证: fork_demo 子进程打印 ppid == parent.pid

Phase 12f: Shell 集成
- [ ] build.zig: user-programs step（支持编译多个 user_src/*.zig → /bin/*.elf 塞进 initfs）
- [ ] user_src/fork_demo.zig
- [ ] user_src/exec_demo.zig
- [ ] user_src/bad_exec.elf
- [ ] user_src/sh_mini.zig（里程碑）
- [ ] shell_cmds.zig: ps 扩展 PPID/STATE 列
- [ ] 验证: 完整 QEMU 头屏 §10.1

Phase 12g (可选): COW
- [ ] vmm.zig: 页表项 copy-on-write 标记（bit 9/10/11 用户可用位）
- [ ] idt.zig: #PF handler 识别 COW 并 dup 页
- [ ] user_mem.zig: cloneAddressSpace 改为共享 + 只读映射
- [ ] 验证: fork + 立即 exec 不复制任何页（meminfo 显示可预期的省量）
```
