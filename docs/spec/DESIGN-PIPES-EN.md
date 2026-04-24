# Phase 13 Implementation Spec: Pipes and I/O Redirection (pipe / dup / redirection)

> This document is the **implementation spec**, intended for direct use by AI code generation tools (Codex, Claude, etc.).
> **Depends on** Phase 12 being complete (fork / exec / waitpid / getppid). Syscall numbers 0..14 are taken.
> **Companions**: roadmap at `ROADMAP-PHASE12-PLUS-EN.md`, Phase 12 spec at `DESIGN-PROCESS-EN.md`.

## Table of Contents

1. [Motivation and Scope](#1-motivation-and-scope)
2. [System Calls and Numbering](#2-system-calls-and-numbering)
3. [FD Table Restructure](#3-fd-table-restructure)
4. [Phase 13a: Pipe Module](#4-phase-13a-pipe-module)
5. [Phase 13b: SYS_PIPE](#5-phase-13b-sys_pipe)
6. [Phase 13c: SYS_DUP / SYS_DUP2](#6-phase-13c-sys_dup--sys_dup2)
7. [Phase 13d: Generalized SYS_READ / SYS_WRITE](#7-phase-13d-generalized-sys_read--sys_write)
8. [Phase 13e: fork / exec fd Semantics](#8-phase-13e-fork--exec-fd-semantics)
9. [Phase 13f: /dev/tty and stdin/stdout/stderr Init](#9-phase-13f-devtty-and-stdinstdoutstderr-init)
10. [Phase 13g: sh_mini Upgrade](#10-phase-13g-sh_mini-upgrade)
11. [QEMU Acceptance](#11-qemu-acceptance)
12. [Implementation Order Checklist](#12-implementation-order-checklist)

---

## 1. Motivation and Scope

After Phase 12, `/bin/sh_mini.elf` can run single commands. Phase 13 lets it run:

```sh
$ cat < /proc/version
$ echo hello > /mnt/tmp.txt    # writes to VFS; persistence comes in Phase 15
$ cat /proc/version | grep Zig
$ ls | wc
```

Three things: **fds can point to pipes**, **fds can be duped to a specific slot**, and **fork inherits fds / exec preserves fds**.

**Out of scope:**

- `FD_CLOEXEC`. Exec keeps all fds (introduced with `SYS_FCNTL` in Phase 14).
- `select` / `poll` (Phase 16 or later).
- Non-blocking fds (`O_NONBLOCK`).
- Named pipes (FIFOs). This phase only covers anonymous pipes (the two fds returned by `SYS_PIPE`).
- `SIGPIPE`. Writing when all readers are closed returns `-EPIPE`; no signal is delivered (`SIGPIPE` waits for Phase 14).

---

## 2. System Calls and Numbering

Continuing from the end of Phase 12 (`SYS_GETPPID=14`), append:

```zig
pub const SYS = enum(u64) {
    // ... 0..14 same as Phase 12 ...
    PIPE = 15,
    DUP = 16,
    DUP2 = 17,
};

pub const MAX_SYSCALL = 17;
```

Error codes extend Phase 12 with:

```zig
pub const EPIPE: i64 = -9;       // write when all read ends are closed
pub const EMFILE: i64 = -10;     // per-process fd table full
pub const ENFILE: i64 = -11;     // global pipe pool full
pub const EINTR: i64 = -12;      // reserved for Phase 14 (blocking call interrupted by signal)
```

Extend `syscallName(n)` and `dispatch` arms accordingly.

---

## 3. FD Table Restructure

### 3.1 Today (Phase 11)

```zig
pub const FileDescriptor = struct {
    active: bool = false,
    inode: u16 = 0,
    offset: usize = 0,
};
```

Supports VFS files only. Phase 13 needs fd to additionally carry pipes and tty (char devices); Phase 16 will add sockets. Restructure once and let later phases only extend the enum.

### 3.2 New Structure

```zig
pub const FdKind = enum(u8) {
    none = 0,
    vfs_file,
    pipe_read,
    pipe_write,
    char_dev,   // /dev/tty and friends; initial support in Phase 13
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
        inode: u16,     // devfs node
    };

    pub fn isActive(self: FileDescriptor) bool {
        return self.kind != .none;
    }
};
```

> Zig 0.15 note: the tag type on `union(FdKind)` must match the `kind` field; if we keep both, setters must sync them manually. Cleaner is to only use `payload` (the tagged union carries its own tag) and drop the outer `kind` field. Code below in later sections uses this simplified form:

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

### 3.3 Migration Checklist

Every place in existing code that uses `fd.active` / `fd.inode` / `fd.offset` must change:

| File | Function | Old | New |
|------|----------|-----|-----|
| `process.zig` | `openCurrentFile` | `for (&info.fds) if (!fd.active)` | `for (&info.fds) if (fd.* == .none)` |
| `process.zig` | `closeCurrentFile` | `fds[i].active = false` → `.{}` | `fds[i] = .none` |
| `process.zig` | `readCurrentFile` | `if (!fd.active) return .bad_fd` | Route via `dispatchRead` in §7 |
| `process.zig` | `clearFileDescriptors` | `fds = EMPTY_FILE_DESCRIPTORS` | `fds = [_]FileDescriptor{.none} ** MAX_FILE_DESCRIPTORS` |
| `process.zig` | `EMPTY_FILE_DESCRIPTORS` constant | old value | `[_]FileDescriptor{.none} ** N` |
| `syscall.zig` | `sysReadFile` | direct `offset` access | route via `process.readFd(fd_num, dest)` |

Phase 12 already introduced fork (which must copy the fd table). In the `cloneAddressSpace` path inside fork, also copy `fds`; for pipe ends, the copy must call `pipe.acquireEnd(pipe_id, .read_or_write)` to bump the reference count (see §4.4).

---

## 4. Phase 13a: Pipe Module

### 4.1 New File `src/pipe.zig`

```zig
pub const MAX_PIPES: usize = 16;
pub const PIPE_BUFFER_SIZE: usize = 4096;
pub const MAX_WAITERS_PER_END: usize = 4;  // at most 4 blocked tasks per end

pub const Pipe = struct {
    active: bool = false,
    buffer: [PIPE_BUFFER_SIZE]u8 = [_]u8{0} ** PIPE_BUFFER_SIZE,
    read_pos: usize = 0,
    write_pos: usize = 0,
    len: usize = 0,
    reader_count: u16 = 0,
    writer_count: u16 = 0,
    // Blocked wait queues (hold task indices; Phase 18 SMP switches to per-CPU queues)
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
pub fn acquire(pipe_id: u16, kind: AcquireKind) bool;       // refcount +1
pub fn release(pipe_id: u16, kind: AcquireKind) void;       // refcount -1, cleanup when it hits 0
pub fn read(pipe_id: u16, dst: []u8) ReadResult;
pub fn write(pipe_id: u16, src: []const u8) WriteResult;
pub fn stats() Stats;                                        // used by /proc/pipes

pub const ReadResult = union(enum) {
    ok: usize,     // bytes actually read; 0 means EOF (all write ends closed)
    would_block,   // caller should block the current task
    bad_pipe,
};

pub const WriteResult = union(enum) {
    ok: usize,     // bytes actually written
    would_block,   // readers still open but buffer full
    broken,        // all read ends closed → EPIPE
    bad_pipe,
};
```

### 4.2 read / write Details

```
fn read(pipe_id, dst):
    p = &pipes[pipe_id]
    if !p.active: return bad_pipe

    if p.len == 0:
        if p.writer_count == 0: return ok = 0        // EOF
        return would_block                            // caller parks itself on blocked_readers

    n = min(p.len, dst.len)
    for i in 0..n:
        dst[i] = p.buffer[(p.read_pos + i) % PIPE_BUFFER_SIZE]
    p.read_pos = (p.read_pos + n) % PIPE_BUFFER_SIZE
    p.len -= n

    // Writers may be waiting for buffer space
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

> **Atomicity:** this project is single-CPU + interrupt-disable scheduling. `pipe.read` / `pipe.write` must run with interrupts disabled from entry to return (reuse the existing `cpu.cli` / `cpu.sti` convention from `scheduler.zig`). Phase 18 SMP replaces this with spinlocks.

### 4.3 release Cleanup

```
fn release(pipe_id, kind):
    p = &pipes[pipe_id]
    if kind == .read_end:
        p.reader_count -= 1
        if p.reader_count == 0:
            // Wake all writers so they see .broken
            wakeAll(&p.blocked_writers, ...)
    else:
        p.writer_count -= 1
        if p.writer_count == 0:
            // Wake all readers so they see EOF
            wakeAll(&p.blocked_readers, ...)

    if p.reader_count == 0 and p.writer_count == 0:
        p.active = false  // buffer zeroing is lazy; next allocate handles it
```

### 4.4 wakeAll / block Interface with the Scheduler

Phase 12 already extended `task.zig` / `scheduler.zig` with generic block / unblock for waitpid. Phase 13 reuses that API:

```zig
// scheduler.zig (already in Phase 12)
pub fn blockCurrentOn(reason: BlockReason) void;
pub fn unblock(pid: u32) bool;

pub const BlockReason = union(enum) {
    wait_child: u32,   // Phase 12
    sleep,             // Phase 10
    pipe_read: u16,    // new: pipe_id
    pipe_write: u16,   // new
};
```

`pipe.allocate` / `read` / `write` never block the task directly; they only return `would_block`, letting the syscall layer decide whether to block (see §7). This keeps the pipe module dependency-free and unit-testable.

### 4.5 /proc/pipes (Optional Stretch)

Similar to `/proc/tasks`, list each active pipe's `id`, `len`, `readers`, `writers`. `pipe.stats()` returns the data; `procfs.zig` renders it.

---

## 5. Phase 13b: SYS_PIPE

### 5.1 Syscall Signature

```zig
fn sysPipe(fds_ptr: u64) u64;
// Success: 0; writes two fds into user *[2]u64 (fd[0]=read, fd[1]=write)
// Failure: -ENFILE (pipe pool full) / -EMFILE (process fd table does not have two free slots) / -EFAULT
```

> If the process fd table only has one free slot, return `-EMFILE` and release the already-allocated pipe.

### 5.2 New in `process.zig`

```zig
pub const CreatePipeResult = union(enum) {
    ok: struct { read_fd: u64, write_fd: u64 },
    no_pipe,     // ENFILE
    no_fd,       // EMFILE
    not_user,
};

pub fn createPipeCurrent() CreatePipeResult;
```

### 5.3 Implementation Notes

```
1. Current process must be a user process.
2. pid_slots = scan fds for two free slots; fewer than 2 → no_fd.
3. pipe_id = pipe.allocate(); on failure → no_pipe.
4. pipe.acquire(pipe_id, .read_end); pipe.acquire(.write_end)   // refcount 1/1
5. fds[read_slot]  = .{ .pipe_read  = .{ .pipe_id = pipe_id } }
   fds[write_slot] = .{ .pipe_write = .{ .pipe_id = pipe_id } }
6. return { read_fd = FIRST_USER_FD + read_slot? or just use the slot index as the fd number? }
```

**fd numbering convention (consistent with Phase 11):** fd number == slot index. The "0/1/2 are stdin/stdout/stderr" convention is set up by the shell + exec (see §9); the kernel no longer hard-codes it.

### 5.4 User Write-Back

```
const pair = [2]u64{ read_fd, write_fd };
if !copyToUser(fds_ptr, std.mem.asBytes(&pair)): return -EFAULT
return 0
```

On EFAULT we must roll back: close the two fd slots and call `pipe.release` twice.

---

## 6. Phase 13c: SYS_DUP / SYS_DUP2

### 6.1 Signatures

```zig
fn sysDup(old_fd: u64) u64;
// Success: new_fd (lowest free slot); failure: -EBADF (old doesn't exist) / -EMFILE

fn sysDup2(old_fd: u64, new_fd: u64) u64;
// Success: new_fd
// If old == new and old is valid: return new_fd directly.
// Otherwise, if new_fd is already open: close(new_fd) first, then copy.
// Failure: -EBADF / -EINVAL (fd out of range)
```

### 6.2 New in `process.zig`

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

### 6.3 FD Copy (`cloneFd`) Semantics

The key helper. Different kinds need different handling:

```
fn cloneFd(src: FileDescriptor) FileDescriptor:
    switch src:
        .none         => return .none
        .vfs_file |v| => return .{ .vfs_file = v }         // copied by value; offset is independent
        .pipe_read  |p| => pipe.acquire(p.pipe_id, .read_end);
                            return .{ .pipe_read = p }
        .pipe_write |p| => pipe.acquire(p.pipe_id, .write_end);
                            return .{ .pipe_write = p }
        .char_dev   |c| => return .{ .char_dev = c }       // char devices are stateless
```

> **Note about VFS fd offset semantics:** POSIX says `dup`'d fds **share** offset (through the "open file description"). In our design, `FileDescriptor.vfs_file.offset` is embedded in the fd slot, so duped fds are independent — which is not POSIX-conforming.
>
> **Phase 13 decision:** accept the "copy-by-value offset" simplification. This kernel has no file-description indirection layer, and introducing one has cross-phase impact.
> **Phase 13's sh_mini does not depend on shared offset** (it only dups pipes, and pipe state lives in the global pool, already shared).
> "Offset sharing requires the open-file-description indirection" is added to Phase 13's "Known Limitations" for future cleanup.

### 6.4 dup2 close-first Must Be Atomic

Pseudocode:

```
fn dup2Current(old, new):
    if old == new and fds[old] != .none: return ok = new
    if fds[old] == .none: return bad_fd
    if new >= MAX_FILE_DESCRIPTORS: return invalid
    if fds[new] != .none: closeFd(&fds[new])     // go through release path
    fds[new] = cloneFd(fds[old])
    return ok = new
```

`closeFd` is an internal helper that calls `pipe.release` based on kind.

---

## 7. Phase 13d: Generalized SYS_READ / SYS_WRITE

### 7.1 Current State

Phase 11's `sysRead` / `sysWrite`:
- `sysWrite(fd=1|2, ...)` → direct `log.writeBytes`.
- `sysRead(fd=0, ...)` → direct keyboard read.
- `sysRead(fd>=3, ...)` → VFS file read.

Phase 13 unifies everything through the fd table: **if there's an entry, dispatch by kind**; the "default" behavior for fd 0/1/2 is established by §9 pre-populating the fd table at exec time.

### 7.2 New Path

```
fn sysWrite(fd, buf_ptr, count):
    // Fast fail
    if count == 0: return 0
    // Copy from user (capped at MAX_WRITE_BYTES)
    capped = min(count, MAX_WRITE_BYTES)
    copyFromUser(buffer[0..capped], buf_ptr) or return -EFAULT

    // Dispatch via the process layer
    return process.writeFd(fd, buffer[0..capped])

fn sysRead(fd, buf_ptr, count):
    if count == 0: return 0
    capped = min(count, MAX_READ_BYTES)
    validateUserBuffer(buf_ptr, capped) or return -EFAULT

    return process.readFd(fd, buf_ptr, capped)
    // readFd handles copyToUser internally
```

### 7.3 New Dispatch in `process.zig`

```zig
pub fn writeFd(fd: u64, src: []const u8) u64;    // returns either a byte count or a u64-encoded errno
pub fn readFd(fd: u64, user_buf: u64, count: usize) u64;
```

Implementation:

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
                           // Phase 15 for persistence; Phase 13 may return -EINVAL or do in-memory writes

fn pipeWriteBlocking(pipe_id, src):
    loop:
        match pipe.write(pipe_id, src):
            .ok |n|       => return n
            .broken       => return -EPIPE
            .bad_pipe     => return -EBADF
            .would_block  =>
                // Park the current task on pipe.blocked_writers
                pipe.addBlockedWriter(pipe_id, currentTid())
                scheduler.blockCurrentOn(.{ .pipe_write = pipe_id })
                // When woken, loop again
```

`readFd` is structurally identical. On read-block, park on `blocked_readers`.

### 7.4 Character Devices (char_dev)

Phase 13 introduces two char devices: `/dev/tty` (bidirectional) and `/dev/null` (already present; we just add the write interface).

Char-device read/write is routed through devfs:

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

Internal table: `inode → driver fn pair`. `/dev/tty`'s read routes to the keyboard module (Phase 11 already has a queue); its write routes to `log.writeBytes`.

### 7.5 Keyboard "Foreground Process" Concept

Phase 14 brings in the foreground process group. Phase 13 bridges the gap:

- In single-user-process mode, sh_mini is the only "foreground," which matches the current Phase 11 keyboard owner.
- When running a fork + pipeline (`a | b`), sh_mini hands keyboard ownership to the leftmost pipeline stage (`a`). Ownership returns when the pipeline ends.

This owner handoff is done entirely by sh_mini itself in Phase 13 (either via some `SYS_PRCTL`-style API that doesn't exist yet, or with the kernel special-casing it). **Phase 13 decision**: defer this to Phase 14, which formalizes it together with signals + pgid. Phase 13's sh_mini does **not** support "pipeline reading the keyboard" — the leftmost pipeline stage must explicitly redirect `< /proc/xxx` or `< /dev/null`.

---

## 8. Phase 13e: fork / exec fd Semantics

### 8.1 fork Copies the fd Table

Add one step inside Phase 12's `forkCurrent`:

```
for i in 0..MAX_FILE_DESCRIPTORS:
    child.fds[i] = cloneFd(parent.fds[i])   // §6.3, pipe acquires automatically
```

`cloneAddressSpace` handles page content; `cloneFd` handles fd refcounts.

### 8.2 exec Preserves fds

Phase 12's `execCurrent` only swaps the address space; it does not touch fds. Phase 13 keeps this:

- After sh_mini forks, the child closes unused pipe ends → execs a new program → the new program sees fds 0/1/2 still correct.

### 8.3 Process Exit / Kill Releases All fds

In `process.exitCurrent` / `killUser` cleanup:

```
for fd in info.fds:
    closeFd(&fd)   // pipe refcount -1; free the pipe_id when both hit 0
```

When waitpid reaps a zombie, the fd table is already cleared at exit time — this avoids a zombie holding a pipe reference and causing hangs.

---

## 9. Phase 13f: /dev/tty and stdin/stdout/stderr Init

### 9.1 devfs Increment

`src/devfs.zig`'s `init` adds:

```zig
if (vfs.createDevice(dev_dir, "tty")) |idx| {
    registerCharDev(idx, .{
        .read = ttyRead,
        .write = ttyWrite,
    });
}
// /dev/null already exists; add:
registerCharDev(null_idx, .{
    .read = nullRead,
    .write = nullWrite,
});
```

`ttyRead` = `keyboard.readUser(buf)` (the non-blocking read already in Phase 11; if no data, return `would_block` so the syscall layer blocks).
`ttyWrite` = `log.writeBytes(src); return ok = src.len`.

### 9.2 Process Initial fd Table

Today `spawn_user`-style paths create a process with an all-`.none` fd table. Phase 13 changes that:

```zig
// process.zig: when creating a user process
pub fn initStdio(info: *ProcessInfo) bool {
    const tty_idx = vfs.resolve("/dev/tty") orelse return false;
    info.fds[0] = .{ .char_dev = .{ .inode = tty_idx } };
    info.fds[1] = .{ .char_dev = .{ .inode = tty_idx } };
    info.fds[2] = .{ .char_dev = .{ .inode = tty_idx } };
    return true;
}
```

Called by the parent's `runuser` / `runelf` / `fork+exec`; on fork, the child inherits from the parent (via §8.1's cloneFd).

### 9.3 Migrating Away from the "fd=1 Hardcode"

Phase 11's `sysWrite(fd=1)` hard-codes to `log.writeBytes`, not consulting the fd table. Phase 13 removes this special case — `fd=1` must have a `.char_dev` entry in the fd table to work.

**Migration acceptance:** Phase 11's `hello_user` (embedded flat binary, writes fd=1) still works because `initStdio` fills fd 1 at spawn time.

---

## 10. Phase 13g: sh_mini Upgrade

### 10.1 Syntax

On top of Phase 12's `sh_mini.elf`, add lexing and execution:

```
command    := simple_cmd (PIPE simple_cmd)*
simple_cmd := word+ (REDIR_IN word)? (REDIR_OUT word)?
word       := [^ \t<>|]+    // no whitespace or control chars
```

Supports:
- `cmd > file` and `cmd < file` (overwrite only; `>>` append is future).
- `cmd1 | cmd2` (chains of arbitrary length).
- `cmd arg1 arg2 ...`.

Explicitly rejected (with an error):
- Quotes, escapes, variables, globs.
- Background `&`, sequencing `;`.
- `2>&1`-style fd manipulation.

### 10.2 Pipeline Execution Algorithm

For `c1 | c2 | c3`:

```
// Create N-1 pipes
pipes[N-1]
for i in 0..N-1: pipes[i] = sys_pipe()

for i in 0..N:
    pid = sys_fork()
    if pid == 0:
        // Child: set up stdin/stdout, close everything else
        if i > 0:    sys_dup2(pipes[i-1].read, 0)
        if i < N-1:  sys_dup2(pipes[i].write, 1)
        for p in pipes: sys_close(p.read); sys_close(p.write)
        // File redirection
        if i == 0 and redir_in:  fd = sys_open(redir_in); sys_dup2(fd, 0); sys_close(fd)
        if i == N-1 and redir_out: fd = sys_open(redir_out, CREATE); sys_dup2(fd, 1); sys_close(fd)
        sys_exec(command[i].path)
        exit(127)   // exec failure path
    // Parent continues
pids[i] = pid

// Parent closes all pipe ends (otherwise the pipeline never sees EOF)
for p in pipes: sys_close(p.read); sys_close(p.write)

// waitpid for each
for pid in pids: sys_waitpid(pid, &status)
```

> Phase 13's SYS_OPEN currently accepts only flags=0; it must be extended with `O_CREAT | O_TRUNC | O_WRONLY` (three new bits).
> **Phase 13 decision:** add the new flag bits to `sysOpen` in `syscall.zig`:
>
> ```
> pub const O_RDONLY: u64 = 0x0000;
> pub const O_WRONLY: u64 = 0x0001;
> pub const O_RDWR:   u64 = 0x0002;
> pub const O_CREAT:  u64 = 0x0040;
> pub const O_TRUNC:  u64 = 0x0200;
> ```
>
> Other flags are ignored. Phase 13's VFS is still in-memory, so writes only persist within the process lifecycle; Phase 15 brings persistence and makes writes stick.

### 10.3 New User Programs to Ship in /bin

| Path | Purpose |
|------|---------|
| `/bin/cat.elf` | Read stdin until EOF, write to stdout (may already exist; reuse) |
| `/bin/echo.elf` | argv[1..] joined by ' ', written to stdout with a newline |
| `/bin/grep.elf` | Read stdin line-by-line; write lines containing argv[1] to stdout |
| `/bin/wc.elf` | Read stdin; print line/word/byte counts |
| `/bin/true.elf`, `/bin/false.elf` | Only test exit codes |
| `/bin/sh_mini.elf` | Phase 13 upgraded version |

argv/envp: Phase 13 also introduces the most minimal argv-passing — `execCurrent(path, argv)` packs the argv string array onto the new user-stack top (`argc` in rdi, `argv` in rsi, or, idiomatically per System V, pushed onto rsp for `_start` to parse).

> **Phase 13 decision:** argv is passed via the **user stack**. When executing `sys_exec(path, argv)`:
> - The syscall signature is extended: `exec(path_ptr, argv_ptr)`; `argv_ptr` is a user-space `null`-terminated `char* []`.
> - The kernel copies argv string content into the bottom of the new address space's stack, places the pointer array above it, and sets `rsp` pointing to `argc, argv[0]..argv[argc], NULL`.
> - User `_start` contract: `rsp -> [argc][argv0][argv1]...[NULL]`; `_start` reads argc/argv and calls `main(argc, argv)`.
>
> This is a patch to Phase 12's `sysExec`: the old `sysExec(path_ptr)` → `sysExec(path_ptr, argv_ptr)`. When `argv_ptr == 0`, the kernel defaults to argc=1, argv={path} (preserving the Phase 12 single-arg calling convention).

---

## 11. QEMU Acceptance

### 11.1 Main Sequence

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

### 11.2 Boundary Tests

1. **Pipe buffer pressure**: `/bin/yes.elf | /bin/head.elf -c 8192` — head exits when it has what it needs; yes sees EPIPE on write → exits cleanly (no panic).
2. **Reverse close**: reader closes first; writer still writes → gets `-EPIPE`.
3. **fd exhaustion**: `sys_pipe` until EMFILE in a single process; observe the error code.
4. **Pipe pool exhaustion**: hold >16 pipes simultaneously → ENFILE.
5. **dup2 same fd**: `dup2(5, 5)` returns 5, no state change.
6. **Orphan pipe**: `sys_pipe` then exit without close → `exitCurrent` cleanup path auto-releases, pipe_id can be reallocated.
7. **Block + wake**: one process reads an empty pipe and enters blocked; another writes → the first wakes, returns data. Can verify with `/bin/cat.elf </dev/tty` + keyboard input (keyboard → /dev/tty read also goes through block/wake).

### 11.3 Regression Coverage

Every modification run (as a smoke check):
- Phase 11 `runelf /bin/hello.elf` still works.
- Phase 12 `runelf /bin/fork_demo.elf` still works.

If either regression fails, investigate fd-table initialization (§9.2) and fork's cloneFd (§8.1) first.

---

## 12. Implementation Order Checklist

```
Phase 13a: Pipe module (unit-testable)
- [ ] pipe.zig: Pipe / AllocResult / ReadResult / WriteResult
- [ ] pipe.zig: allocate / acquire / release / read / write / stats
- [ ] pipe.zig: addBlockedReader / addBlockedWriter / wakeAll
- [ ] shell_cmds.zig: pipetest command (allocate → write → read → close)
- [ ] Verify: pipetest prints a ring-buffer write/read roundtrip match

Phase 13b: FD-table restructure
- [ ] process.zig: FileDescriptor becomes a tagged union
- [ ] process.zig: closeFd / cloneFd helpers
- [ ] process.zig: clearFileDescriptors compatibility
- [ ] syscall.zig: openCurrentFile / closeCurrentFile / readCurrentFile rewritten for the new union
- [ ] Verify: all Phase 11 runuser / runelf / ps / runelf file regressions pass

Phase 13c: SYS_PIPE
- [ ] syscall.zig: SYS.PIPE=15, ENFILE/EMFILE/EPIPE constants
- [ ] process.zig: createPipeCurrent
- [ ] syscall.zig: sysPipe + copyToUser writes fds back
- [ ] Verify: a kernel shell command pipepairtest handles allocate + read/write + close end-to-end

Phase 13d: SYS_DUP / SYS_DUP2
- [ ] syscall.zig: SYS.DUP=16, SYS.DUP2=17
- [ ] process.zig: dupCurrent, dup2Current
- [ ] Verify: a duptest command covers the six dup/dup2 scenarios

Phase 13e: Generalized SYS_READ / SYS_WRITE
- [ ] process.zig: readFd / writeFd dispatch
- [ ] process.zig: pipeReadBlocking / pipeWriteBlocking (incl. blockCurrentOn)
- [ ] syscall.zig: sysRead/sysWrite on the new dispatch; remove the fd=0/1/2 special cases
- [ ] devfs.zig: registerCharDev + /dev/tty registration
- [ ] keyboard.zig: readUser non-blocking / would_block protocol
- [ ] Verify: the original sysReadKeyboard path via /dev/tty still works

Phase 13f: fork / exec / initial fds
- [ ] process.zig: initStdio (new process pre-populates fd 0/1/2 to /dev/tty)
- [ ] process.zig: forkCurrent calls cloneFd across all 16 slots
- [ ] process.zig: execCurrent preserves fds
- [ ] process.zig: exitCurrent/killUser walk fds and call closeFd
- [ ] Verify: fork+exec child's fd 0/1/2 usable without ceremony

Phase 13g: execCurrent argv support
- [ ] syscall.zig: sysExec(path_ptr, argv_ptr=0 compatibility)
- [ ] process.zig: execCurrent(path, argv)
- [ ] user_mem.zig: build [argc][argv]...[NULL] on the new stack top
- [ ] User _start convention: read rsp for argc/argv
- [ ] Verify: /bin/echo.elf arg1 arg2 prints "arg1 arg2"

Phase 13h: sh_mini upgrade
- [ ] user_src/sh_mini.zig: add pipeline parsing + < > redirection
- [ ] user_src/echo.zig / cat.zig / grep.zig / wc.zig / true.zig / false.zig
- [ ] build.zig: user-programs step batch compiles and packs into initfs
- [ ] syscall.zig: O_CREAT / O_TRUNC / O_WRONLY constants + sysOpen support
- [ ] Verify: full §11.1 sequence passes

Phase 13i (optional): /proc/pipes
- [ ] procfs.zig: /proc/pipes node + render via pipe.stats()
- [ ] Verify: while running, cat /proc/pipes shows each active pipe's reader/writer/len
```
