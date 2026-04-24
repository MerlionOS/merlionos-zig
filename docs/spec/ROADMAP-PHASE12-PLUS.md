# MerlionOS-Zig Phase 12+ 路线图

> 本文档规划 Phase 11（用户态文件 ABI，含 `SYS_MMAP`）之后的演进路径。
> 每个 Phase 给出：**动机 / 交付物 / 依赖 / 触碰的文件 / 验收标准**。
> 详细实现规格另见同目录下 `DESIGN-PROCESS.md`（Phase 12 已展开）。
> 后续每开工一个 Phase 再补一份对应的 `DESIGN-*.md`，保持 Phase 规格与实现一对一。

## 目录

1. [当前内核状态（起跑线）](#1-当前内核状态起跑线)
2. [路线图总览](#2-路线图总览)
3. [Phase 12: 进程创建（fork / exec / waitpid）](#3-phase-12-进程创建fork--exec--waitpid)
4. [Phase 13: 管道与 I/O 重定向](#4-phase-13-管道与-io-重定向)
5. [Phase 14: 信号与作业控制](#5-phase-14-信号与作业控制)
6. [Phase 15: 块设备与持久化文件系统](#6-phase-15-块设备与持久化文件系统)
7. [Phase 16: 用户态网络 ABI](#7-phase-16-用户态网络-abi)
8. [Phase 17: Framebuffer 与字符终端](#8-phase-17-framebuffer-与字符终端)
9. [Phase 18: SMP 与多核调度](#9-phase-18-smp-与多核调度)
10. [Phase 19: 用户态 AI ABI](#10-phase-19-用户态-ai-abi)
11. [设计原则（跨 Phase 共享）](#11-设计原则跨-phase-共享)

---

## 1. 当前内核状态（起跑线）

Phase 11 收尾时内核应满足以下能力，本路线图以此为前置条件：

| 能力 | 模块 | 备注 |
|------|------|------|
| 启动 / 日志 / panic | limine / serial / vga / log | — |
| GDT / IDT / PIC / PIT 100Hz | gdt / idt / pic / pit | TSS.rsp0 随上下文切换更新 |
| 物理/虚拟内存、内核堆 | pmm / vmm / heap | `mapPage(user=true, writable=?)` 稳定 |
| 键盘、Shell、历史、cd/pwd | keyboard / shell / shell_cmds | |
| 合作 + 抢占式调度、ps/spawn/kill | task / scheduler | `wake_tick`, `sleepCurrent` 已有 |
| 内存型 VFS、/proc、/dev、重定向 | vfs / procfs / devfs | |
| PCI、e1000、ARP、IPv4、UDP、TCP、DNS | pci / e1000 / net / eth / arp_cache / ipv4 / udp / tcp / dns / socket | |
| COM2 AI 代理、aiask/aipoll | ai | 主机侧 `tools/ai_proxy.py` |
| 用户态 syscall 分发（int 0x80）| syscall / idt | SYS 编号 0..10 占用 |
| 用户地址空间、mmap 区域 | user_mem | `USER_MMAP_BASE=0x4000_0000`，`mmap_next` 字段 |
| 进程表 / fd 表（VFS） | process | `MAX_FILE_DESCRIPTORS=16`, `FIRST_USER_FD=3` |
| 平面 + ELF 用户程序 | elf / user_programs / `/bin/hello.elf` | `runuser`, `runelf` |
| SYS_EXIT/WRITE/READ/YIELD/GETPID/SLEEP/BRK/OPEN/CLOSE/STAT/MMAP | syscall | 末位 `SYS_MMAP` 由 codex 并行完成 |

---

## 2. 路线图总览

```
Phase 11 ──► 12 ──► 13 ──► 14 ──► 15 ──► 16 ──► 17 ──► 18 ──► 19
用户态     进程     管道     信号     块设备    用户    Framebuffer SMP   用户
文件 ABI  创建     I/O      /作业    /持久 FS  网络 ABI /终端      多核   AI ABI
(mmap)   (fork)   (pipe)   (signal) (virtblk)
```

选择这个顺序的三个理由：

1. **fork/exec 让 shell 真正走用户态。**Phase 11 结束后，用户态只能通过内核内置的 `runuser` 或 `runelf` 启动。把 shell 自己变成一个 ELF 用户程序是终极目标，但那之前必须先有 `fork + exec`。
2. **管道和信号是 shell 的刚需。**有了 fork 才能做 pipeline；有了信号才能做 Ctrl+C。两个一起，shell 才像样。
3. **持久化排在交互之后，网络 ABI 排在持久化之后。**没有持久化也能跑 AI、跑测试；先把交互与执行模型打磨好。

每个 Phase 的预期规模（粗估，用于日历规划）：

| Phase | 新文件 | 主要改动文件 | 预计代码量 | 预计时长 |
|-------|--------|-------------|-----------|---------|
| 12 fork/exec/waitpid | 0（扩展 process/user_mem） | syscall, process, user_mem, task, scheduler, shell_cmds | ~800 行 | 中 |
| 13 pipes + dup + 重定向 | `pipe.zig` | syscall, process, shell | ~500 行 | 中 |
| 14 signals | `signal.zig` | syscall, process, task, idt, keyboard, shell | ~800 行 | 大 |
| 15 virtio-blk + FS | `virtio_blk.zig`, `merfs.zig` | vfs, main, shell_cmds | ~1500 行 | 大 |
| 16 socket syscalls | — | syscall, process, socket, shell_cmds | ~500 行 | 中 |
| 17 framebuffer + console | `fb.zig`, `console.zig`, `font.zig` | main, log, vga（保留兼容） | ~900 行 | 大 |
| 18 SMP | `acpi.zig`, `apic.zig`, `smp.zig`, `spinlock.zig` | idt, scheduler, pit→hpet?, heap（锁化）| ~1500 行 | 很大 |
| 19 AI ABI | `ai_dev.zig` | syscall, vfs, devfs, ai | ~400 行 | 小 |

---

## 3. Phase 12: 进程创建（fork / exec / waitpid）

**动机：** 把"每个用户程序都是内核预置入口"变成"任何 ELF 都能在运行时派生子进程、替换映像、等待退出"。这是 shell 自举（把 shell 本身搬进 ring 3）、跑 `/bin/sh -c 'a | b'`、以及任何 POSIX 风格用户程序的前提。

**新系统调用（接续编号 11..14）：**

| # | 名称 | 原型 | 语义 |
|---|------|------|------|
| 11 | `SYS_FORK` | `fork() -> pid` | 复制当前进程；父返回子 pid，子返回 0 |
| 12 | `SYS_EXEC` | `exec(path_ptr) -> 无返回 / -errno` | 用 VFS 中 ELF 替换当前映像 |
| 13 | `SYS_WAITPID` | `waitpid(pid, status_ptr) -> pid` | 阻塞到目标子进程退出，回收僵尸 |
| 14 | `SYS_GETPPID` | `getppid() -> ppid` | 返回父进程 pid |

**核心改动：**

- `user_mem.zig`: 新增 `cloneAddressSpace(src: *const AddressSpace) ?AddressSpace`。先不做 COW，直接复制每一页内容（`MAX_USER_PAGES=256`，成本可控）。
- `task.zig`: `Task` 加 `parent_pid: u32 = 0`、`state` 扩展 `.zombie`。
- `process.zig`: 新增 `forkCurrent()`, `execCurrent(path)`, `waitpidCurrent(pid)`, `reapZombie(pid)`, 并在 `exitCurrent` 中不再立即释放 slot，而是先转 `.zombie`，由 `waitpidCurrent` 回收。
- `scheduler.zig`: 扩展 `sleepCurrent` 为更通用的 `block_on_exit(pid)`。
- `shell_cmds.zig`: 去掉 `runuser`/`runelf` 的内核路径预占，改为示例程序；新增 `exec` shell 命令（一行 shell `$ /bin/hello.elf`）。

**交付物：**

- `/bin/fork_demo.elf`：fork 后父子各打印一行然后退出，父 `waitpid(child)`。
- `/bin/sh_mini.elf`：一个 ≤200 行 ELF shell，支持 `echo`, 运行 `/bin/X.elf`, `exit`。**这是 Phase 12 的里程碑**——内核的 shell 和 ring 3 的 shell 能并存，后者由前者 `exec` 拉起。

**验收标准（QEMU 头屏）：**

```
merlion> runelf /bin/sh_mini.elf
[sh_mini] pid=7 ppid=1 ready
$ /bin/hello.elf
Hello from Ring 3!
$ exit
[pid=7] exited 0
merlion>
```

- `ps` 能看到子进程短暂存在、僵尸态、被 `waitpid` 回收的完整生命周期。
- `runelf /bin/bad_exec.elf`（有意 exec 不存在路径）返回 `-ENOENT` 而不会 panic。

详细规格见 `DESIGN-PROCESS.md`。

---

## 4. Phase 13: 管道与 I/O 重定向

**动机：** 让用户态 shell 能跑 `cmd1 | cmd2`、`cmd > file`、`cmd < file`。同时把内核目前硬编码的 `fd=1` 写和 `fd=0` 读解耦到 fd 表。

**新系统调用：**

| # | 名称 | 原型 | 语义 |
|---|------|------|------|
| 15 | `SYS_PIPE` | `pipe(fds_ptr: *[2]u64) -> 0 / -errno` | 分配一对读写端 |
| 16 | `SYS_DUP` | `dup(fd) -> new_fd` | 复制到最小空位 |
| 17 | `SYS_DUP2` | `dup2(old, new) -> new / -errno` | 覆盖指定槽 |

**新模块：** `src/pipe.zig`。每条管道一个 4KB 环形缓冲 + 读写 fd 指针。读空阻塞，写满阻塞（挂到 scheduler 的等待队列）。写端全部关闭后读端收 EOF（返回 0）。

**fd 种类分化：** 当前 `FileDescriptor { active, inode, offset }` 改为 `tagged union`：

```zig
pub const FdKind = enum { vfs_file, pipe_read, pipe_write, socket /* Phase 16 */ };
pub const FileDescriptor = union(FdKind) {
    vfs_file: struct { inode: u16, offset: usize },
    pipe_read: struct { pipe_id: u16 },
    pipe_write: struct { pipe_id: u16 },
    socket: struct { socket_id: u16 },
};
```

**SYS_WRITE / SYS_READ 改动：** 不再对 fd=0/1/2 特判字符设备，改为 `/dev/stdin`、`/dev/stdout`、`/dev/stderr` 在 exec 时被 `sh_mini` 预打开到 fd 0/1/2。

**交付物：**

- `/bin/sh_mini.elf`（Phase 12 的版本）升级支持 `|` 和 `>` `<`。
- 验证序列：

```
$ /bin/cat.elf < /proc/version | /bin/grep.elf Zig
MerlionOS-Zig ... Zig 0.15 ...
```

**依赖：** Phase 12 的 fork/exec。先分配管道，fork 后父子分别关掉不用的那一端。

---

## 5. Phase 14: 信号与作业控制

**动机：** Ctrl+C 杀前台进程、父进程收 `SIGCHLD`、用户程序安装自定义 handler。没有这些，交互式 shell 永远差一口气。

**新系统调用：**

| # | 名称 | 备注 |
|---|------|------|
| 18 | `SYS_KILL(pid, sig)` | 默认行为：TERM/KILL/INT → 杀；CHLD → 忽略 |
| 19 | `SYS_SIGACTION(sig, new_ptr, old_ptr)` | 安装用户 handler |
| 20 | `SYS_SIGRETURN` | 从 trampoline 返回（由 trampoline 内联 `int 0x80`） |
| 21 | `SYS_SIGPROCMASK` | 阻塞/解除阻塞信号集 |

**新模块：** `src/signal.zig`。

**信号集：** 仅实现 Unix 前 16 个的子集：`SIGINT=2, SIGKILL=9, SIGSEGV=11, SIGTERM=15, SIGCHLD=17, SIGSTOP=19, SIGCONT=18`。

**投递路径：**
- 内核态挂起：`task.pending_signals: u64` 位图 + `signal_mask: u64`。
- 每次从 syscall / 中断返回用户态前检查 `pending & ~mask`，若非零则在用户栈上构造 `ucontext` 帧并把 rip 改到 user handler、ret 地址改到一段用户态 trampoline（由内核安装在 `USER_TEXT_BASE` 附近的固定虚地址）。
- Trampoline 调用 handler，然后 `SYS_SIGRETURN` 让内核从保存的 ucontext 恢复。

**键盘 → SIGINT：** 新增"前台进程组（pgid）"概念。shell 的 fork+exec 设置子进程 pgid = child_pid；shell 把前台 pgid 设为 child_pid。键盘驱动遇到 Ctrl+C（scancode 0x2E & Ctrl 按下）时，给前台 pgid 所有成员投 `SIGINT`。

**进程表改动：** `Task` 新增 `pgid: u32`、`sid: u32`。

**交付物：**

- `/bin/sig_demo.elf`：安装 SIGINT handler 打印一行；无 handler 默认死亡。
- QEMU 头屏验证：`$ /bin/loop.elf` 然后 Ctrl+C → 进程退出、shell 重新提示符；若安装了 handler → handler 执行。
- `waitpid` 能观察到子的 `WIFSIGNALED` 状态（`status` 高 16 位编码信号号）。

---

## 6. Phase 15: 块设备与持久化文件系统

**动机：** Phase 1-14 做完后，VFS 仍全部内存。一次重启清零。有一块持久盘后，`/bin/*.elf`、日志、shell 历史都可以落盘，AI 对话也能存档。

**选型：**

- 块设备驱动：**virtio-blk**（legacy PCI，QEMU `-drive if=virtio,...`），比 ATA PIO 更现代也更好写。用轮询模式先跑通，虚拟队列只用一个。
- 文件系统：**MerFS**——原生 32MB 简单 FS。不做 FAT，因为 FAT 的长文件名和目录项开销会偏离"clean reimplementation"的风格。

**MerFS on-disk layout：**

```
+--------+---------+-------------+-----------+---------+
| Super  | Inode   | Block       | Reserved  | Data    |
| block  | table   | bitmap      |           | blocks  |
| 1 blk  | 1024    | 1 blk       | ..        | ..      |
|        | inodes  |             |           |         |
+--------+---------+-------------+-----------+---------+
block size = 4096, 每 inode 64B，单层直接块指针（12 个）。
```

Superblock 魔数 `"MERLION1"`，首次启动检测到无魔数则 `mkfs`。

**新文件：** `src/virtio_blk.zig`, `src/merfs.zig`, `src/blkdev.zig`（抽象 read/write 块接口）。

**VFS 集成：** 新增 `mount(path, fs_type)`。默认 `mount("/mnt", "merfs")`。MerFS 目录和文件通过 VFS 接口透明工作，`cat`, `ls`, `write`, `rm` 直接复用。

**交付物：**

- Shell 命令：`mount`, `umount`, `sync`, `df`。
- 冷启动脚本：检测到空盘自动 `mkfs`，把 `/bin/*.elf` 从内核 initramfs 拷贝到 `/mnt/bin`。
- 下次启动后，`/mnt/bin/hello.elf` 仍然存在。
- QEMU 命令：`qemu-system-x86_64 ... -drive file=merlionos.img,if=virtio,format=raw`（在 `build.zig` 的 `run` 选项增加 `-with-disk`）。

---

## 7. Phase 16: 用户态网络 ABI

**动机：** TCP/IP 栈（Phase 9）已经很完整，但只能通过 shell 命令或内核代码触发。这个 Phase 把 `socket.zig` 升级成用户态 ABI，让 `/bin/httpget.elf`、`/bin/dns.elf` 以 ELF 身份存在。

**新系统调用（Linux 风格子集）：**

| # | 名称 | 备注 |
|---|------|------|
| 22 | `SYS_SOCKET(domain, type, proto)` | 只支持 `AF_INET + SOCK_DGRAM / SOCK_STREAM` |
| 23 | `SYS_BIND(fd, addr_ptr, addr_len)` | |
| 24 | `SYS_CONNECT(fd, addr_ptr, addr_len)` | TCP 阻塞直到 ESTABLISHED 或 timeout |
| 25 | `SYS_LISTEN(fd, backlog)` | |
| 26 | `SYS_ACCEPT(fd, addr_out, len_out)` | 阻塞 |
| 27 | `SYS_SEND(fd, buf, len, flags)` | |
| 28 | `SYS_RECV(fd, buf, len, flags)` | |
| 29 | `SYS_SENDTO(fd, buf, len, flags, addr, addr_len)` | UDP |
| 30 | `SYS_RECVFROM(fd, buf, len, flags, addr_out, len_out)` | UDP |

`SYS_CLOSE` 不新增，复用 Phase 11 的 `SYS_CLOSE`（fd 表已是 tagged union，见 Phase 13）。

**交付物：**

- `/bin/httpget.elf`：从 shell `/bin/httpget.elf example.com /` 拉一页 HTML。
- `/bin/ncat.elf`：能作为 `nc -l -p 4444` 风格的服务。

**依赖：** Phase 13 的 fd tagged union。

---

## 8. Phase 17: Framebuffer 与字符终端

**动机：** 离开 VGA text 模式，准备 GUI/位图能力。Limine 已经在启动时提供了线性 framebuffer，只是当前没用。

**范围：**

- `src/fb.zig`：封装 Limine framebuffer request，暴露 `pixel(x,y,rgba)`、`rect`、`blit`。
- `src/font.zig`：嵌入一份 PSF v2 字体（8×16），comptime 解析为位图数组。
- `src/console.zig`：位图版 80×25 终端模拟器，接管 `log.writeBytes`。支持 ANSI SGR 颜色子集（30-37, 40-47, 1, 0）。
- `log.zig` 改动：同时输出到 serial + console（替换原来的 serial + vga）。VGA 路径保留为 `--no-fb` fallback。

**交付物：**

- 启动后直接是位图终端、颜色 kernel log。
- 新 shell 命令 `fbtest`：画一个渐变矩形 + 一只小狮子 logo。
- 预留后续：`console.zig` 为未来的多 tty 和窗口系统留接口（`createViewport(rect)` 返回 `*Viewport`）。

**依赖：** 只依赖 Phase 1。独立于其它 Phase，可以并行做。

---

## 9. Phase 18: SMP 与多核调度

**动机：** 单核调度器好写，但真实 AI workload（后续 Phase 19）需要至少把 LLM proxy polling 和用户 shell 放到不同核心。QEMU `-smp 4` 跑起来也好看。

**范围：**

- `src/acpi.zig`：最小 ACPI 解析——定位 RSDP（通过 Limine 的 `LIMINE_RSDP_REQUEST`），解析 XSDT 找到 MADT，枚举 Local APIC 和 IO APIC。
- `src/apic.zig`：xAPIC MMIO 访问、EOI、IPI 发送、Timer 模式初始化（每核本地 timer 取代 PIT 抢占）。
- `src/smp.zig`：AP trampoline（16 位 real mode 代码段搬到 0x8000）、INIT-SIPI-SIPI 启动序列、每核栈分配、`per_cpu_data`。
- `src/spinlock.zig`：TAS 自旋锁；替换 heap / scheduler / process / vfs 等关键位置的"关中断保护"。
- `scheduler.zig` 改写：per-CPU 就绪队列 + 全局负载均衡（每次 tick 周期性搬运）。
- `idt.zig` 改写：保留 IDT 全核共享，但每核初始化独立的 TSS 和内核栈。
- PIT 保留但降级为 wall-clock fallback；主时钟源改为 HPET 或 APIC timer。

**交付物：**

- `zig build run-smp` 启动 4 核。
- `cpuinfo` shell 命令列出所有核及其当前任务。
- `ps` 显示 `CPU` 列。
- 压力测试：4 个 `/bin/loop.elf` 能看到负载均摊到 4 核。

**依赖：** Phase 18 是最大的一次改动。建议推后，做完 12-17 再做，且专门开一个 `docs/spec/DESIGN-SMP.md`。

---

## 10. Phase 19: 用户态 AI ABI

**动机：** MerlionOS 的宣言是 "Born for AI, Built by AI"。现在 AI 代理只能通过内核 shell 命令 `aiask` / `aipoll` 触发。把它暴露到用户态，就能写 `/bin/chat.elf`、`/bin/codegen.elf`、甚至一个用户态的 `agent.elf`。

**设计选择（两条路线）：**

| 方案 | 优点 | 缺点 |
|------|------|------|
| A: `SYS_AI(op, arg_ptr)` | 直接、少文件 | 需要新协议、污染 syscall 表 |
| B: `/dev/ai` 字符设备 | 走 VFS + fd，自然 | 需要实现 devfs 非阻塞 read/write 和 poll |

**推荐 B。** 协议很简单：

- `write(fd, "你好", 6)` 把 prompt 投给 AI 代理。
- `read(fd, buf, n)` 读回复（阻塞，直到代理回包）。
- `ioctl(fd, AI_STATUS, status_ptr)`（Phase 19 顺带引入第一个 SYS_IOCTL=31）报连接状态。

**新模块：**
- `src/ai_dev.zig`：devfs 节点 `/dev/ai`，把 `ai.zig` 的 COM2 队列包装成 VFS read/write。
- `src/syscall.zig`: 新增 `SYS_IOCTL`（通用 ioctl，后续 tty / socket 也会用）。

**交付物：**

- `/bin/chat.elf`：命令行循环 → `write /dev/ai` → `read /dev/ai` → 打印。
- `/bin/agent.elf`（stretch）：把 `ps`、`cat`、`ls` 的结果喂给 AI 回答 "当前内核健康吗？"。
- 终极演示：在 shell 里 `/bin/chat.elf`，用户和模型对话，一切走 ring 3。

---

## 11. 设计原则（跨 Phase 共享）

1. **零外部依赖**。任何新 Phase 都不引入 third-party crate / zig package。
2. **显式分配器**。所有动态结构（pipe、socket、signal queue、blockdev cache）都接受 allocator 参数；内核内部使用 `heap.allocator()`。
3. **错误码用 `-errno`**。与 Phase 11 已建立的 `ENOSYS/EFAULT/EINVAL/ENOMEM/EBADF/ENOENT` 一致；新增编号在 `syscall.zig` 顶层集中声明。
4. **每个 Phase 必须有 QEMU 头屏回归**。在对应 `DESIGN-*.md` 的末尾列出 "QEMU 测试方法"，并把期望输出固化到 PR 描述。
5. **用户态测试程序走 VFS，不再走内核内置字节数组**。Phase 12 之后，`runuser hello` 应该等价于 `runelf /bin/hello.elf`。
6. **Phase 间解耦但允许合并 PR**。例如 Phase 12 完成前不能并行开 Phase 13，因为 13 依赖 fork；但 Phase 17 framebuffer 完全独立，可以和 12-16 任意穿插。
7. **文档优先于代码**。每个 Phase 开工前先写 `DESIGN-*.md`，经 review 后再让 codex 按文档实现。本路线图是总目录，各 Phase 的单独 spec 在同目录下。

---

## 附录 A: 与原 Rust MerlionOS 的对照

原项目 Rust MerlionOS 当前进展大约在 Phase 9（TCP）附近。本 Zig 再实现从 Phase 10（用户态）开始已经走在前面。Phase 12-19 预期两边会独立演进；如果原项目在 Phase 15 给出了 on-disk FS 设计，值得回读以对齐 UX（不是实现）。

## 附录 B: 推荐的实现顺序微调点

- **Phase 13 和 14 可以交换**。如果优先跑出 "Ctrl+C 能打断 loop" 的演示比 pipeline 演示更有冲击力，可以先 14 再 13。前提是 fork/exec 已有。
- **Phase 15 可以提前到 12 之后**。如果团队想先看到 "重启保留文件"，可以把 Phase 15 插到 13 之前。Phase 15 不依赖 fork。
- **Phase 19 可以随时插队**。它只依赖 Phase 11（VFS fd + open/read/write），不依赖 fork/exec 或网络 ABI。如果 demo 压力大，可以在 Phase 12 之后直接跳到 Phase 19 抢一个亮点，再回头补 13-18。
