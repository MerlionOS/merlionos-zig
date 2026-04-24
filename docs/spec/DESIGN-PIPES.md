# Phase 13 实现规格：管道与 I/O 重定向（pipe / dup / redirection）

> 本文档是**实现规格（Spec）**，供 Codex / Claude 等 AI 代码生成工具直接实现使用。
> **依赖**：Phase 12 全部完成（fork / exec / waitpid / getppid）。syscall 编号 0..14 已占用。
> **配套**：路线图见 `ROADMAP-PHASE12-PLUS.md`，Phase 12 规格见 `DESIGN-PROCESS.md`。

## 目录

1. [动机与范围](#1-动机与范围)
2. [系统调用与编号](#2-系统调用与编号)
3. [FD 表重构](#3-fd-表重构)
4. [Phase 13a: Pipe 模块](#4-phase-13a-pipe-模块)
5. [Phase 13b: SYS_PIPE](#5-phase-13b-sys_pipe)
6. [Phase 13c: SYS_DUP / SYS_DUP2](#6-phase-13c-sys_dup--sys_dup2)
7. [Phase 13d: SYS_READ / SYS_WRITE 泛化](#7-phase-13d-sys_read--sys_write-泛化)
8. [Phase 13e: fork / exec 的 fd 语义](#8-phase-13e-fork--exec-的-fd-语义)
9. [Phase 13f: /dev/tty 与 stdin/stdout/stderr 初始化](#9-phase-13f-devtty-与-stdinstdoutstderr-初始化)
10. [Phase 13g: sh_mini 升级](#10-phase-13g-sh_mini-升级)
11. [QEMU 验收](#11-qemu-验收)
12. [实现顺序检查清单](#12-实现顺序检查清单)

---

## 1. 动机与范围

Phase 12 结束后 `/bin/sh_mini.elf` 能跑单条命令。Phase 13 让它能跑：

```sh
$ cat < /proc/version
$ echo hello > /mnt/tmp.txt    # 写入 VFS，持久化留给 Phase 15
$ cat /proc/version | grep Zig
$ ls | wc
```

三件事：**fd 可以指向管道**、**fd 可以 dup 到指定槽**、**fork 继承 fd / exec 保留 fd**。

**不在本 Phase 范围内**：

- `FD_CLOEXEC`。exec 后保留所有 fd（Phase 14 随 `SYS_FCNTL` 一起引入）。
- `select` / `poll`（留给 Phase 16 或更后）。
- 非阻塞 fd（`O_NONBLOCK`）。
- 命名管道（FIFO）。本 Phase 只做匿名 pipe（`SYS_PIPE` 返回的两个 fd）。
- `SIGPIPE`。写端在读端全关时返回 `-EPIPE`，不投递信号（`SIGPIPE` 要等 Phase 14）。

---

## 2. 系统调用与编号

接续 Phase 12 末位（`SYS_GETPPID=14`），追加：

```zig
pub const SYS = enum(u64) {
    // ... 0..14 同 Phase 12 ...
    PIPE = 15,
    DUP = 16,
    DUP2 = 17,
};

pub const MAX_SYSCALL = 17;
```

错误码沿用 Phase 12，新增：

```zig
pub const EPIPE: i64 = -9;       // 写端写入时读端已全关
pub const EMFILE: i64 = -10;     // 进程 fd 表满
pub const ENFILE: i64 = -11;     // 全局 pipe 池满
pub const EINTR: i64 = -12;      // 预留给 Phase 14（阻塞中被信号打断）
```

`syscallName(n)` 和 `dispatch` 分支同步扩展。

---

## 3. FD 表重构

### 3.1 现状（Phase 11）

```zig
pub const FileDescriptor = struct {
    active: bool = false,
    inode: u16 = 0,
    offset: usize = 0,
};
```

只支持 VFS 文件。Phase 13 需要 fd 再承载 pipe、tty（字符设备），Phase 16 还要再加 socket。一次把结构改对，后续 Phase 只扩 enum。

### 3.2 新结构

```zig
pub const FdKind = enum(u8) {
    none = 0,
    vfs_file,
    pipe_read,
    pipe_write,
    char_dev,   // /dev/tty 等；Phase 13 初步支持
};

pub const FileDescriptor = struct {
    kind: FdKind = .none,
    payload: Payload = .{ .none = {} },

    pub const Payload = union(FdKind) {
        none: void,
        vfs_file: VfsFile,
        pipe_read: PipeEnd,
        pipe_write: PipeEnd,
        char_dev: CharDev,
    };

    pub const VfsFile = struct {
        inode: u16,
        offset: usize,
    };

    pub const PipeEnd = struct {
        pipe_id: u16,
    };

    pub const CharDev = struct {
        inode: u16,     // devfs 节点
    };

    pub fn isActive(self: FileDescriptor) bool {
        return self.kind != .none;
    }
};
```

> Zig 0.15 注：`union(FdKind)` 的标签类型必须与 `kind` 字段一致；若保留两者需在 setter 里人工同步。更简洁的做法是只用 `payload`（tagged union 自带标签），去掉顶层 `kind` 字段；本文 §后续代码按此简化写：

```zig
pub const FileDescriptor = union(FdKind) {
    none,
    vfs_file: VfsFile,
    pipe_read: PipeEnd,
    pipe_write: PipeEnd,
    char_dev: CharDev,
    // ...
    pub fn isActive(self: FileDescriptor) bool {
        return self != .none;
    }
};
```

### 3.3 迁移清单

旧代码中用到 `fd.active` / `fd.inode` / `fd.offset` 的每一处都要改：

| 文件 | 函数 | 原代码 | 新代码 |
|------|------|--------|--------|
| `process.zig` | `openCurrentFile` | `for (&info.fds) if (!fd.active)` | `for (&info.fds) if (fd.* == .none)` |
| `process.zig` | `closeCurrentFile` | `fds[i].active = false` → `.{}` | `fds[i] = .none` |
| `process.zig` | `readCurrentFile` | `if (!fd.active) return .bad_fd` | 走 §7 的 `dispatchRead` |
| `process.zig` | `clearFileDescriptors` | `fds = EMPTY_FILE_DESCRIPTORS` | `fds = [_]FileDescriptor{.none} ** MAX_FILE_DESCRIPTORS` |
| `process.zig` | `EMPTY_FILE_DESCRIPTORS` 常量 | 旧值 | `[_]FileDescriptor{.none} ** N` |
| `syscall.zig` | `sysReadFile` | 直接访问 offset | 改走 `process.readFd(fd_num, dest)` |

Phase 12 已经引入 fork（需要复制 fd 表），fork 的 `cloneAddressSpace` 路径里同步复制 `fds`，复制时对 pipe 端执行 `pipe.acquireEnd(pipe_id, .read_or_write)` 增加引用计数（见 §4.4）。

---

## 4. Phase 13a: Pipe 模块

### 4.1 新文件 `src/pipe.zig`

```zig
pub const MAX_PIPES: usize = 16;
pub const PIPE_BUFFER_SIZE: usize = 4096;
pub const MAX_WAITERS_PER_END: usize = 4;  // 单端最多 4 个阻塞任务

pub const Pipe = struct {
    active: bool = false,
    buffer: [PIPE_BUFFER_SIZE]u8 = [_]u8{0} ** PIPE_BUFFER_SIZE,
    read_pos: usize = 0,
    write_pos: usize = 0,
    len: usize = 0,
    reader_count: u16 = 0,
    writer_count: u16 = 0,
    // 阻塞等待队列（保存 task 索引；Phase 18 SMP 时改为每 CPU 队列）
    blocked_readers: [MAX_WAITERS_PER_END]u32 = [_]u32{0} ** MAX_WAITERS_PER_END,
    blocked_reader_count: u8 = 0,
    blocked_writers: [MAX_WAITERS_PER_END]u32 = [_]u32{0} ** MAX_WAITERS_PER_END,
    blocked_writer_count: u8 = 0,
};

pub const AllocResult = union(enum) {
    ok: u16,   // pipe_id
    no_slot,
};

pub const AcquireKind = enum { read_end, write_end };

pub fn init() void;
pub fn allocate() AllocResult;
pub fn acquire(pipe_id: u16, kind: AcquireKind) bool;       // 引用计数 +1
pub fn release(pipe_id: u16, kind: AcquireKind) void;       // 引用计数 -1，清零时收尾
pub fn read(pipe_id: u16, dst: []u8) ReadResult;
pub fn write(pipe_id: u16, src: []const u8) WriteResult;
pub fn stats() Stats;                                        // /proc/pipes 用

pub const ReadResult = union(enum) {
    ok: usize,     // 实际读取字节数；0 表示 EOF（所有写端已关）
    would_block,   // 需要 block 当前任务
    bad_pipe,
};

pub const WriteResult = union(enum) {
    ok: usize,     // 实际写入字节数
    would_block,   // 读端还在但缓冲满
    broken,        // 所有读端已关 → EPIPE
    bad_pipe,
};
```

### 4.2 read / write 详细逻辑

```
fn read(pipe_id, dst):
    p = &pipes[pipe_id]
    if !p.active: return bad_pipe

    if p.len == 0:
        if p.writer_count == 0: return ok = 0        // EOF
        return would_block                            // 调用方把自己挂上 blocked_readers

    n = min(p.len, dst.len)
    for i in 0..n:
        dst[i] = p.buffer[(p.read_pos + i) % PIPE_BUFFER_SIZE]
    p.read_pos = (p.read_pos + n) % PIPE_BUFFER_SIZE
    p.len -= n

    // 写端可能在等缓冲腾出空间
    wakeAll(&p.blocked_writers, &p.blocked_writer_count)
    return ok = n

fn write(pipe_id, src):
    p = &pipes[pipe_id]
    if !p.active: return bad_pipe

    if p.reader_count == 0: return broken             // EPIPE
    if p.len == PIPE_BUFFER_SIZE: return would_block

    free = PIPE_BUFFER_SIZE - p.len
    n = min(src.len, free)
    for i in 0..n:
        p.buffer[(p.write_pos + i) % PIPE_BUFFER_SIZE] = src[i]
    p.write_pos = (p.write_pos + n) % PIPE_BUFFER_SIZE
    p.len += n

    wakeAll(&p.blocked_readers, &p.blocked_reader_count)
    return ok = n
```

> **原子性**：本项目是 single-CPU + 关中断调度。`pipe.read` / `pipe.write` 从进入到返回应全程关中断（复用现有的 `cpu.cli`/`cpu.sti`，参考 `scheduler.zig` 中锁约定）。Phase 18 SMP 时替换为 spinlock。

### 4.3 release 的收尾

```
fn release(pipe_id, kind):
    p = &pipes[pipe_id]
    if kind == .read_end:
        p.reader_count -= 1
        if p.reader_count == 0:
            // 写端阻塞的全部唤醒，让它们见到 broken
            wakeAll(&p.blocked_writers, ...)
    else:
        p.writer_count -= 1
        if p.writer_count == 0:
            // 读端阻塞的全部唤醒，让它们见到 EOF
            wakeAll(&p.blocked_readers, ...)

    if p.reader_count == 0 and p.writer_count == 0:
        p.active = false  // 连带 buffer 归零由下次 allocate 处理（惰性）
```

### 4.4 wakeAll / block 与 scheduler 的接口

Phase 12 的 waitpid 已经让 `task.zig` / `scheduler.zig` 支持通用 block/unblock。Phase 13 复用这套 API：

```zig
// scheduler.zig (Phase 12 已有)
pub fn blockCurrentOn(reason: BlockReason) void;
pub fn unblock(pid: u32) bool;

pub const BlockReason = union(enum) {
    wait_child: u32,   // Phase 12
    sleep,             // Phase 10
    pipe_read: u16,    // 新：pipe_id
    pipe_write: u16,   // 新
};
```

`pipe.allocate` / `read` / `write` 不直接 block 任务；它们只返回 `would_block`，由 syscall 层决定是否 block（见 §7）。这样 pipe 模块保持无依赖，可单测。

### 4.5 /proc/pipes（可选 stretch）

类似 `/proc/tasks`，列出每个活跃 pipe 的 `id`, `len`, `readers`, `writers`。`pipe.stats()` 返回数据，`procfs.zig` 渲染。

---

## 5. Phase 13b: SYS_PIPE

### 5.1 syscall 签名

```zig
fn sysPipe(fds_ptr: u64) u64;
// 成功：0；两个 fd 写入 user *[2]u64（fd[0]=read, fd[1]=write）
// 失败：-ENFILE（pipe 池满）/ -EMFILE（进程 fd 表连续两个空位不够）/ -EFAULT
```

> 若进程 fd 表只剩 1 个空位，返回 `-EMFILE` 并释放已分配的 pipe。

### 5.2 `process.zig` 新增

```zig
pub const CreatePipeResult = union(enum) {
    ok: struct { read_fd: u64, write_fd: u64 },
    no_pipe,     // ENFILE
    no_fd,       // EMFILE
    not_user,
};

pub fn createPipeCurrent() CreatePipeResult;
```

### 5.3 实现要点

```
1. 当前进程必须是用户进程
2. pid_slots = 扫描 fds 找两个空位；不足 2 → no_fd
3. pipe_id = pipe.allocate(); 失败 → no_pipe
4. pipe.acquire(pipe_id, .read_end); pipe.acquire(.write_end)   // refcount 1/1
5. fds[read_slot]  = .{ .pipe_read  = .{ .pipe_id = pipe_id } }
   fds[write_slot] = .{ .pipe_write = .{ .pipe_id = pipe_id } }
6. return { read_fd = FIRST_USER_FD + read_slot? 或直接 slot index 作 fd 号? }
```

**fd 编号约定（保持与 Phase 11 一致）**：fd 号 == 槽位索引。0/1/2 为 stdin/stdout/stderr 的约定由 shell+exec 初始化（见 §9），内核不再硬编码。

### 5.4 用户内存写回

```
const pair = [2]u64{ read_fd, write_fd };
if !copyToUser(fds_ptr, std.mem.asBytes(&pair)): return -EFAULT
return 0
```

EFAULT 时必须回滚：关掉两个 fd 槽、`pipe.release` 两次。

---

## 6. Phase 13c: SYS_DUP / SYS_DUP2

### 6.1 签名

```zig
fn sysDup(old_fd: u64) u64;
// 成功：new_fd（最小空位）；失败：-EBADF（old 不存在）/ -EMFILE

fn sysDup2(old_fd: u64, new_fd: u64) u64;
// 成功：new_fd
// 若 old == new 且 old 合法：直接返回 new_fd
// 否则若 new_fd 已打开：先 close(new_fd) 再复制
// 失败：-EBADF / -EINVAL（fd 号越界）
```

### 6.2 `process.zig` 新增

```zig
pub const DupResult = union(enum) {
    ok: u64,
    bad_fd,
    no_fd,
    invalid,
    not_user,
};

pub fn dupCurrent(old_fd: u64) DupResult;
pub fn dup2Current(old_fd: u64, new_fd: u64) DupResult;
```

### 6.3 fd 复制（`cloneFd`）语义

这是关键辅助函数。复制时对不同 kind 做不同事：

```
fn cloneFd(src: FileDescriptor) FileDescriptor:
    switch src:
        .none         => return .none
        .vfs_file |v| => return .{ .vfs_file = v }         // 按值复制，offset 独立
        .pipe_read  |p| => pipe.acquire(p.pipe_id, .read_end);
                            return .{ .pipe_read = p }
        .pipe_write |p| => pipe.acquire(p.pipe_id, .write_end);
                            return .{ .pipe_write = p }
        .char_dev   |c| => return .{ .char_dev = c }       // 字符设备无状态
```

> **注意 VFS fd 的 offset 语义**：POSIX 要求 `dup` 后的 fd 与原 fd **共享 offset**（通过 `open file description`）。当前 `FileDescriptor.vfs_file.offset` 内嵌在 fd 槽里，两份 fd 互相独立——这与 POSIX 不符。
> 
> **Phase 13 决定**：接受"按值复制 offset"的简化语义。本内核没有 file description 间接层，引入它跨 Phase 影响太大。
> **Phase 13 的 sh_mini 不依赖共享 offset**（它只对 pipe 做 dup，而 pipe 的状态在全局 pool，已共享）。
> 把"offset 共享需要 open file description 间接层"加入 Phase 13 的 "Known Limitations"，留给未来改造。

### 6.4 dup2 的 close-first 必须原子

伪代码：

```
fn dup2Current(old, new):
    if old == new and fds[old] != .none: return ok = new
    if fds[old] == .none: return bad_fd
    if new >= MAX_FILE_DESCRIPTORS: return invalid
    if fds[new] != .none: closeFd(&fds[new])     // 走 release 路径
    fds[new] = cloneFd(fds[old])
    return ok = new
```

`closeFd` 是内部 helper，根据 kind 决定是否调用 `pipe.release`。

---

## 7. Phase 13d: SYS_READ / SYS_WRITE 泛化

### 7.1 现状回顾

Phase 11 的 `sysRead` / `sysWrite`：
- `sysWrite(fd=1|2, ...)` → 直接 `log.writeBytes`
- `sysRead(fd=0, ...)` → 直接读键盘
- `sysRead(fd>=3, ...)` → VFS 文件读取

Phase 13 把这一切统一到 fd 表：**只要 fd 表有条目，就按 kind 分发**；fd 0/1/2 的"默认"行为由 §9 在 exec 时预填 fd 表实现。

### 7.2 新路径

```
fn sysWrite(fd, buf_ptr, count):
    // 快速失败
    if count == 0: return 0
    // 从用户读数据（限 MAX_WRITE_BYTES）
    capped = min(count, MAX_WRITE_BYTES)
    copyFromUser(buffer[0..capped], buf_ptr) or return -EFAULT

    // 通过 process 层分发
    return process.writeFd(fd, buffer[0..capped])

fn sysRead(fd, buf_ptr, count):
    if count == 0: return 0
    capped = min(count, MAX_READ_BYTES)
    validateUserBuffer(buf_ptr, capped) or return -EFAULT

    return process.readFd(fd, buf_ptr, capped)
    // 注意 readFd 内部完成 copyToUser
```

### 7.3 `process.zig` 新增分发

```zig
pub fn writeFd(fd: u64, src: []const u8) u64;    // 返回 u64 形式 errno 或字节数
pub fn readFd(fd: u64, user_buf: u64, count: usize) u64;
```

实现：

```
fn writeFd(fd, src):
    info = currentUserInfo() or return -EINVAL
    if fd >= MAX_FILE_DESCRIPTORS: return -EBADF
    switch info.fds[fd]:
        .none          => return -EBADF
        .char_dev |c|  => return charWrite(c.inode, src)
        .pipe_write|p| => return pipeWriteBlocking(p.pipe_id, src)
        .pipe_read     => return -EBADF
        .vfs_file |v|  => return vfsWrite(&info.fds[fd].vfs_file, src)
                           // Phase 15 持久化；Phase 13 可返回 -EINVAL 或做 in-memory 写

fn pipeWriteBlocking(pipe_id, src):
    loop:
        match pipe.write(pipe_id, src):
            .ok |n|       => return n
            .broken       => return -EPIPE
            .bad_pipe     => return -EBADF
            .would_block  =>
                // 把当前任务挂到 pipe.blocked_writers
                pipe.addBlockedWriter(pipe_id, currentTid())
                scheduler.blockCurrentOn(.{ .pipe_write = pipe_id })
                // 被 wake 时回到 loop
```

`readFd` 同构。读端阻塞时挂 `blocked_readers`。

### 7.4 字符设备（char_dev）

Phase 13 引入两个字符设备：`/dev/tty`（双向）和 `/dev/null`（空洞；已存在，补写接口）。

`char_dev` 的读写通过 devfs 路由：

```zig
// devfs.zig
pub fn charRead(inode: u16, dst: []u8) CharResult;
pub fn charWrite(inode: u16, src: []const u8) CharResult;

pub const CharResult = union(enum) {
    ok: usize,
    would_block,
    bad_dev,
};
```

内部表：`inode → 驱动函数对`。`/dev/tty` 的读路由到 keyboard 模块（Phase 11 已有队列）；写路由到 `log.writeBytes`。

### 7.5 键盘输入的"前台进程"概念

Phase 14 才引入前台进程组。Phase 13 为过渡期：

- 单用户进程模型下，sh_mini 是唯一"前台"——和当前 Phase 11 的 keyboard owner 一致。
- 执行 fork + pipeline 时（`a | b`），sh_mini 把 keyboard owner 交给 pipeline 最左端（`a`）。pipeline 结束后交还。

上述"owner 交接"在 Phase 13 只需要 sh_mini 自己做（通过 `SYS_PRCTL` 之类暂未引入的 API 还是直接配合内核特例？）。**Phase 13 的决定**：延迟到 Phase 14 随信号 + pgid 一起正规化。Phase 13 的 sh_mini 不支持 "pipeline 读键盘"——pipeline 左端必须显式 `< /proc/xxx` 或 `< /dev/null` 重定向。

---

## 8. Phase 13e: fork / exec 的 fd 语义

### 8.1 fork 复制 fd 表

Phase 12 `forkCurrent` 的步骤里加一步：

```
for i in 0..MAX_FILE_DESCRIPTORS:
    child.fds[i] = cloneFd(parent.fds[i])   // §6.3，pipe 会自动 acquire
```

`cloneAddressSpace` 已负责页内容；`cloneFd` 负责 fd 引用计数。

### 8.2 exec 保留 fd

Phase 12 `execCurrent` 只替换地址空间；fd 表不动。Phase 13 保持这一行为，因此：

- sh_mini fork 后，子关掉不用的管道端 → exec 新程序 → 新程序看到 fd 0/1/2 仍然正确。

### 8.3 进程退出 / 杀死时 release 所有 fd

`process.exitCurrent` / `killUser` 的清理路径里：

```
for fd in info.fds:
    closeFd(&fd)   // pipe 引用计数 -1；全关时释放 pipe_id
```

waitpid 回收 zombie 时，fd 表已经在 exit 时清空——这避免了 zombie 持有 pipe 引用导致的挂起。

---

## 9. Phase 13f: /dev/tty 与 stdin/stdout/stderr 初始化

### 9.1 devfs 增量

`src/devfs.zig` 的 `init` 新增：

```zig
if (vfs.createDevice(dev_dir, "tty")) |idx| {
    registerCharDev(idx, .{
        .read = ttyRead,
        .write = ttyWrite,
    });
}
// /dev/null 已存在，补充：
registerCharDev(null_idx, .{
    .read = nullRead,
    .write = nullWrite,
});
```

`ttyRead` = `keyboard.readUser(buf)`（Phase 11 已有的非阻塞读；若无数据返回 `would_block` 让 syscall 层 block）。
`ttyWrite` = `log.writeBytes(src); return ok = src.len`。

### 9.2 进程初始 fd 表

目前 `spawn_user` 类路径创建进程时 fd 表全 `.none`。Phase 13 改为：

```zig
// process.zig: 创建用户进程时
pub fn initStdio(info: *ProcessInfo) bool {
    const tty_idx = vfs.resolve("/dev/tty") orelse return false;
    info.fds[0] = .{ .char_dev = .{ .inode = tty_idx } };
    info.fds[1] = .{ .char_dev = .{ .inode = tty_idx } };
    info.fds[2] = .{ .char_dev = .{ .inode = tty_idx } };
    return true;
}
```

由 `runuser` / `runelf` / `fork+exec` 的父进程调用；fork 时子进程从父继承（通过 §8.1 的 cloneFd）。

### 9.3 从 "fd=1 硬编码" 迁移

Phase 11 `sysWrite(fd=1)` 硬编码到 `log.writeBytes`，不查 fd 表。Phase 13 删除这条特例——`fd=1` 必须在 fd 表里有 `.char_dev` 条目才工作。

**迁移验收**：Phase 11 的 `hello_user`（内嵌 flat binary，fd=1 写）仍然工作，因为 `initStdio` 在 spawn 时填了 fd 1。

---

## 10. Phase 13g: sh_mini 升级

### 10.1 语法

在 Phase 12 `sh_mini.elf` 基础上，新增词法与执行：

```
command    := simple_cmd (PIPE simple_cmd)*
simple_cmd := word+ (REDIR_IN word)? (REDIR_OUT word)?
word       := [^ \t<>|]+    // 不含空白或控制符
```

支持：
- `cmd > file` 和 `cmd < file`（只覆盖写；`>>` 追加留给后续）
- `cmd1 | cmd2`（任意长度链）
- `cmd arg1 arg2 ...`

不支持（明确拒绝报错）：
- 引号、转义、变量、通配符
- 后台 `&`、分号 `;`
- `2>&1` 之类 fd 操作

### 10.2 pipeline 执行算法

对 `c1 | c2 | c3`：

```
// 生成 N-1 个 pipe
pipes[N-1]
for i in 0..N-1: pipes[i] = sys_pipe()

for i in 0..N:
    pid = sys_fork()
    if pid == 0:
        // 子：设置 stdin/stdout，关所有管道
        if i > 0:    sys_dup2(pipes[i-1].read, 0)
        if i < N-1:  sys_dup2(pipes[i].write, 1)
        for p in pipes: sys_close(p.read); sys_close(p.write)
        // 重定向文件
        if i == 0 and redir_in:  fd = sys_open(redir_in); sys_dup2(fd, 0); sys_close(fd)
        if i == N-1 and redir_out: fd = sys_open(redir_out, CREATE); sys_dup2(fd, 1); sys_close(fd)
        sys_exec(command[i].path)
        exit(127)   // exec 失败路径
    // 父：继续
pids[i] = pid

// 父关掉所有 pipe 端（否则 pipeline 永远等不到 EOF）
for p in pipes: sys_close(p.read); sys_close(p.write)

// 依次 waitpid
for pid in pids: sys_waitpid(pid, &status)
```

> Phase 13 用的 SYS_OPEN 目前 flags==0；需要扩展支持 `O_CREAT | O_TRUNC | O_WRONLY`（定义 3 个常量位）。
> **Phase 13 决定**：在 `syscall.zig` 的 `sysOpen` 中接受 flags 的新位：
>
> ```
> pub const O_RDONLY: u64 = 0x0000;
> pub const O_WRONLY: u64 = 0x0001;
> pub const O_RDWR:   u64 = 0x0002;
> pub const O_CREAT:  u64 = 0x0040;
> pub const O_TRUNC:  u64 = 0x0200;
> ```
>
> 其余 flags 忽略。Phase 13 的 VFS 仍为内存型，写入只在进程生命周期内有效；Phase 15 引入持久化后自然生效。

### 10.3 需要打进 /bin 的新用户程序

| 路径 | 作用 |
|------|------|
| `/bin/cat.elf` | 从 stdin 读直到 EOF，写到 stdout（已存在可复用） |
| `/bin/echo.elf` | argv[1..] join ' '，写 stdout，换行 |
| `/bin/grep.elf` | 从 stdin 读按行；包含 argv[1] 的行写 stdout |
| `/bin/wc.elf` | 从 stdin 读；打印行数/字数/字节数 |
| `/bin/true.elf`, `/bin/false.elf` | 仅测试 exit code |
| `/bin/sh_mini.elf` | Phase 13 升级版 |

argv/envp：Phase 13 顺带引入最简化的 argv 传递——`execCurrent(path, argv)` 把 argv 字符串数组打包到用户栈顶（`argc` 在 rdi，`argv` 在 rsi，或更地道地按 System V 把它们压在 rsp 上供 `_start` 解析）。

> **Phase 13 决定**：argv 通过**用户栈**传递。执行 `sys_exec(path, argv)` 时：
> - syscall 签名扩展：`exec(path_ptr, argv_ptr)`；`argv_ptr` 是用户空间 `null`-terminated `char* []`。
> - 内核把 argv 字符串内容复制到新地址空间的栈顶下方，指针数组放在栈上，`rsp` 指向 `argc, argv[0]..argv[argc], NULL`。
> - 用户 `_start` 规约：`rsp -> [argc][argv0][argv1]...[NULL]`；`_start` 读 argc/argv 后调用 `main(argc, argv)`。
>
> 这相当于给 Phase 12 的 `sysExec` 打个补丁：原来 `sysExec(path_ptr)` → `sysExec(path_ptr, argv_ptr)`。`argv_ptr == 0` 时按 argc=1, argv={path} 处理（保持 Phase 12 单参数调用兼容）。

---

## 11. QEMU 验收

### 11.1 主序列

```
merlion> runelf /bin/sh_mini.elf
[sh_mini] pid=7 ppid=1
$ echo hello
hello
[pid=8] exited 0
$ echo hello | /bin/wc.elf
      1       1       6
[pid=9] exited 0
$ /bin/cat.elf < /proc/version
MerlionOS-Zig 0.X.Y (Zig 0.15.x)
[pid=11] exited 0
$ /bin/cat.elf /proc/version | /bin/grep.elf Zig
MerlionOS-Zig 0.X.Y (Zig 0.15.x)
[pid=14] exited 0
$ /bin/echo.elf bye > /tmp/bye.txt
[pid=15] exited 0
$ /bin/cat.elf /tmp/bye.txt
bye
[pid=16] exited 0
$ exit
merlion>
```

### 11.2 边界测试

1. **Pipe buffer 压力**：`/bin/yes.elf | /bin/head.elf -c 8192` —— head 读够后退出，yes 写端触发 EPIPE → yes 正常 exit（非 panic）。
2. **反向关闭**：读端先关，写端继续写 → 得到 `-EPIPE`。
3. **fd 耗尽**：在一个进程里 `sys_pipe` 到 EMFILE，观察错误码。
4. **pipe 池耗尽**：同时持有 >16 个 pipe → ENFILE。
5. **dup2 相同 fd**：`dup2(5, 5)` 返回 5，不改状态。
6. **孤立 pipe**：`sys_pipe` 后 exit 而不关 → exitCurrent 的清理路径自动 release，pipe 可被再 allocate。
7. **阻塞 + 唤醒**：一个进程 read 空 pipe 进入 blocked；另一进程写入 → 第一个进程 wake，返回数据。可以用 `/bin/cat.elf </dev/tty` + 键盘输入验证（keyboard → /dev/tty 读也走 block/wake）。

### 11.3 回归覆盖

每次修改运行（作为冒烟）：
- Phase 11 `runelf /bin/hello.elf` 仍工作。
- Phase 12 `runelf /bin/fork_demo.elf` 仍工作。

如果任一回归失败，先查 fd 表初始化（§9.2）和 fork 的 cloneFd（§8.1）。

---

## 12. 实现顺序检查清单

```
Phase 13a: Pipe 模块（单测可通过）
- [ ] pipe.zig: Pipe / AllocResult / ReadResult / WriteResult
- [ ] pipe.zig: allocate / acquire / release / read / write / stats
- [ ] pipe.zig: addBlockedReader / addBlockedWriter / wakeAll
- [ ] shell_cmds.zig: pipetest 命令（分配/写/读/关闭走一遍）
- [ ] 验证: pipetest 打印环形写入读出匹配

Phase 13b: FD 表重构
- [ ] process.zig: FileDescriptor 改为 tagged union
- [ ] process.zig: closeFd / cloneFd 辅助
- [ ] process.zig: clearFileDescriptors 兼容
- [ ] syscall.zig: openCurrentFile / closeCurrentFile / readCurrentFile 改写到新 union
- [ ] 验证: Phase 11 所有 runuser/runelf/ps/runelf file 回归通过

Phase 13c: SYS_PIPE
- [ ] syscall.zig: SYS.PIPE=15, ENFILE/EMFILE/EPIPE 常量
- [ ] process.zig: createPipeCurrent
- [ ] syscall.zig: sysPipe + copyToUser 回写 fds
- [ ] 验证: 内核 shell 命令 pipepairtest 创建+读写+关闭全部 ok

Phase 13d: SYS_DUP / SYS_DUP2
- [ ] syscall.zig: SYS.DUP=16, SYS.DUP2=17
- [ ] process.zig: dupCurrent, dup2Current
- [ ] 验证: duptest 命令覆盖 dup/dup2 六种场景

Phase 13e: SYS_READ / SYS_WRITE 泛化
- [ ] process.zig: readFd / writeFd 分发
- [ ] process.zig: pipeReadBlocking / pipeWriteBlocking（含 blockCurrentOn）
- [ ] syscall.zig: sysRead/sysWrite 改走新分发；删除 fd=0/1/2 特例
- [ ] devfs.zig: registerCharDev + /dev/tty 注册
- [ ] keyboard.zig: readUser 的非阻塞/would_block 协议
- [ ] 验证: sysReadKeyboard 原路径走 /dev/tty 仍然工作

Phase 13f: fork / exec / 初始 fd
- [ ] process.zig: initStdio（新进程预填 fd 0/1/2 为 /dev/tty）
- [ ] process.zig: forkCurrent 里 cloneFd 所有 16 槽
- [ ] process.zig: execCurrent 保留 fd
- [ ] process.zig: exitCurrent/killUser 遍历 fd 做 closeFd
- [ ] 验证: fork+exec 的子进程 fd 0/1/2 自动可用

Phase 13g: execCurrent 的 argv 支持
- [ ] syscall.zig: sysExec(path_ptr, argv_ptr=0 兼容)
- [ ] process.zig: execCurrent(path, argv)
- [ ] user_mem.zig: 在新栈顶构造 [argc][argv]...[NULL]
- [ ] 用户 _start 规约：读 rsp 得 argc/argv
- [ ] 验证: /bin/echo.elf arg1 arg2 打印 "arg1 arg2"

Phase 13h: sh_mini 升级
- [ ] user_src/sh_mini.zig: 增加 pipeline 解析 + < > 重定向
- [ ] user_src/echo.zig / cat.zig / grep.zig / wc.zig / true.zig / false.zig
- [ ] build.zig: user-programs step 批量编译并塞入 initfs
- [ ] syscall.zig: O_CREAT / O_TRUNC / O_WRONLY 常量 + sysOpen 支持
- [ ] 验证: §11.1 全序列通过

Phase 13i（可选）: /proc/pipes
- [ ] procfs.zig: /proc/pipes 节点 + pipe.stats() 渲染
- [ ] 验证: 执行期间 cat /proc/pipes 显示每个活跃 pipe 的 reader/writer/len
```
