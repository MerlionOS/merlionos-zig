# Phase 12 Implementation Spec: Process Creation (fork / exec / waitpid)

> This document is the **implementation spec**, intended for direct use by AI code generation tools (Codex, Claude, etc.).
> Depends on Phase 11 being complete (including `SYS_MMAP`).
> The companion roadmap is `ROADMAP-PHASE12-PLUS-EN.md`.

## Table of Contents

1. [Motivation and Scope](#1-motivation-and-scope)
2. [System Calls and Numbering](#2-system-calls-and-numbering)
3. [Data Structure Changes](#3-data-structure-changes)
4. [Phase 12a: Address-Space Cloning](#4-phase-12a-address-space-cloning)
5. [Phase 12b: SYS_FORK](#5-phase-12b-sys_fork)
6. [Phase 12c: SYS_EXEC](#6-phase-12c-sys_exec)
7. [Phase 12d: Zombie Processes and SYS_WAITPID](#7-phase-12d-zombie-processes-and-sys_waitpid)
8. [Phase 12e: SYS_GETPPID](#8-phase-12e-sys_getppid)
9. [Phase 12f: Shell Integration and Demo Programs](#9-phase-12f-shell-integration-and-demo-programs)
10. [QEMU Acceptance](#10-qemu-acceptance)
11. [Implementation Order Checklist](#11-implementation-order-checklist)

---

## 1. Motivation and Scope

After Phase 11, the only way into user mode is via `runuser <name>` (embedded flat binary) or `runelf <path>` (ELF on the VFS). Both are kernel-initiated. A user program itself cannot fork a new process or replace itself with a different image.

Phase 12 makes the following three lines legal and working:

```c
pid_t p = fork();
if (p == 0) exec("/bin/hello.elf");
else        waitpid(p, &status);
```

**Out of scope for this phase:**

- Copy-on-write (COW). This phase copies physical pages directly. Each fork copies at most `MAX_USER_PAGES * 4KB = 1MB`; we accept this cost. COW is deferred to a possible Phase 12g.
- Multithreading. `SYS_CLONE` flag semantics are not implemented.
- `vfork`.
- File descriptor reference counting (fds are copied by value into the child's fd table on fork; refcounting for pipes/sockets comes in with their respective phases).

---

## 2. System Calls and Numbering

Continuing from the end of Phase 11 (`SYS_MMAP=10`), append to the `SYS` enum in `src/syscall.zig`:

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

New error codes (following the negative-value convention):

```zig
pub const ECHILD: i64 = -7;   // waitpid: no child
pub const ENOEXEC: i64 = -8;  // exec: ELF parse / segment load failed
```

Extend `syscallName(n)` accordingly; add four arms to `dispatch`:

```zig
.FORK => sysFork(),
.EXEC => sysExec(ctx.arg1),
.WAITPID => sysWaitpid(ctx.arg1, ctx.arg2),
.GETPPID => sysGetppid(),
```

---

## 3. Data Structure Changes

### 3.1 `src/task.zig`

```zig
pub const TaskState = enum {
    ready,
    running,
    blocked,
    finished,
    zombie,    // New: exited, waiting for parent waitpid
};

pub const Task = struct {
    // Existing fields unchanged
    parent_pid: u32 = 0,       // New: 0 means no parent (boot / kernel task)
    wait_on_pid: u32 = 0,      // New: while blocked in waitpid, the target pid; 0 means "any"
    exit_status: u32 = 0,      // New: encoded like POSIX wstatus (low 8 bits are exit code or signal number)
};
```

The existing `finished` state is kept: it denotes "exited with no parent to reap." A process whose `parent_pid == 0` at exit goes directly to `finished`, skipping the zombie stage.

### 3.2 `src/process.zig`

`ProcessInfo` gains:

```zig
pub const ProcessInfo = struct {
    // Existing fields
    parent_pid: u32 = 0,      // New
};
```

`process.zig` gains four new public functions (see §5–§8).

### 3.3 `src/user_mem.zig`

New public function:

```zig
pub fn cloneAddressSpace(src: *const AddressSpace, dst: *AddressSpace) bool;
```

See §4.

---

## 4. Phase 12a: Address-Space Cloning

### 4.1 Goal

Given an already-activated or inactive source `src`, construct an independent copy in the caller-provided `dst`:

- New PML4 (shares the kernel half; the user half is fresh).
- For every `src.pages[i].active`, allocate a new physical frame, copy 4 KB from the source, and map it at the same `virt` with the same writable permission in `dst`.
- Copy `brk` and `mmap_next`.
- All intermediate page tables (PDPT / PD / PT) are allocated independently.

On failure, roll back every allocated frame and page table.

### 4.2 Function Signature

```zig
pub fn cloneAddressSpace(src: *const AddressSpace, dst: *AddressSpace) bool;
```

### 4.3 Implementation Notes (pseudocode)

```
1. Initialize base:
   if !createInto(dst) return false      // reuse existing PML4 + kernel-half sharing + initial user stack
   // createInto already allocates a new user stack here; if src already has user stack mappings,
   // that conflicts with the clone logic — we need to clear them first.
   for each record in dst.pages: unmap if active
   dst.page_count = 0
   dst.brk = src.brk
   dst.mmap_next = src.mmap_next

2. Copy page-by-page:
   saved_cr3 = cpu.readCr3() & PAGE_FRAME_MASK
   for each src.pages[i] where active:
       new_phys = pmm.allocFrame() or goto rollback
       // Copy source content into the new frame (both sides go through the physToVirt direct-map
       // window; we do not go through the user address space)
       src_bytes = @ptrFromInt(pmm.physToVirt(record.phys))
       dst_bytes = @ptrFromInt(pmm.physToVirt(new_phys))
       @memcpy(dst_bytes[0..PAGE_SIZE], src_bytes[0..PAGE_SIZE])
       // Map into dst (use mapUserPagePhys; writable matches source — simplified to true here
       // because all user pages are writable today; extend when we introduce read-only segments)
       if !mapUserPagePhys(dst, record.virt, new_phys, /* writable */ true):
           pmm.freeFrame(new_phys); goto rollback

3. Restore cr3 and return:
   cpu.writeCr3(saved_cr3)
   return true

rollback:
   cpu.writeCr3(saved_cr3)
   destroy(dst)
   return false
```

> **Note:** `createInto` pre-allocates a user stack for dst. If `src`'s user stack is already mapped (99% of the time), the clone will fail in step 2 with "has mapping." Step 1 must first free the stack pages that `createInto` allocated so step 2 can allocate them uniformly.
> Simpler: add a new `createBlank(dst)` — identical to `createInto` but **without pre-allocating the user stack** — and use it for clone. `create` / `createInto` stay for `spawnFlat` / `execCurrent`, which keep the current path.

### 4.4 Self-Test Extension

On top of the existing `selfTest()`, add `cloneSelfTest()`:

1. Create `src`, map two pages, write unique byte patterns.
2. `cloneAddressSpace(src, dst)`.
3. Activate `dst`; the bytes at the corresponding virtual addresses should equal the original patterns.
4. Write a different byte pattern into the second page of `dst`.
5. Switch back to `src`; confirm the second page is **unchanged** (verifies physical isolation).
6. Destroy both.

Expose `shell_cmds` command `clonememtest` to trigger this check.

---

## 5. Phase 12b: SYS_FORK

### 5.1 Syscall Signature

```zig
fn sysFork() u64;
// Return: parent gets child_pid; child gets 0; failure returns -ENOMEM / -errno
```

### 5.2 New in `process.zig`

```zig
pub const ForkResult = union(enum) {
    parent: u32,   // child pid
    child,         // child's view
    no_memory,
    no_slot,
};

pub fn forkCurrent() ForkResult;
```

### 5.3 Implementation Notes

The current process must be a user process (otherwise fork from a kernel task is meaningless — `sysFork` guards this at the top and returns an `ENOSYS`-like error).

```
1. parent_pid = task.currentPid()
2. Find the current process.ProcessInfo slot
3. Allocate a child slot: process.reserveSlot() → child index
4. Allocate the child address space: cloneAddressSpace(parent.as, &child.as); on failure → ENOMEM
5. Allocate a child kernel stack (reuse task.zig's stack_pool mechanism; the new task slot gets an independent stack)
6. On the child's kernel stack, construct the "return to user" initial frame:
   Copy the parent's user-context register snapshot captured at syscall entry (see §5.4),
   but set rax = 0 (child return value).
7. child.state = .ready, child.parent_pid = parent.pid
8. scheduler.enqueue(child)
9. The parent returns child.pid immediately.
```

### 5.4 Capturing the User Context

Phase 11's `syscallStub` saves 15 GPRs and the 5-tuple for iretq (ss, rsp, rflags, cs, rip) on the kernel stack. fork needs to know that stack address. Plan:

- In `syscall.zig`, add a **thread-local-ish** global `current_syscall_frame: ?u64 = null`.
- `syscallStub` records the current rsp after pushing registers (either via an extra `mov rsp, (saved_frame_addr)` before calling `syscallDispatch`, or by capturing rsp at the top of `syscallDispatch` on the Zig side via `asm("mov %rsp, %0"…)`), storing it into the global.
- `sysFork` reads the address, `@memcpy`s the 15 regs + 5 iretq = 160-byte region into the corresponding slot of the child kernel stack, and rewrites the "rax" slot to 0.
- When the child is scheduled, `switchFromContext` loads its rsp, `popq` the 15 regs, `iretq`, returning to user mode — with rip at the parent's syscall return point and rax=0.

> **Note:** Zig 0.15 has no real TLS, and this kernel is still single-core, so a plain global is safe; Phase 18 SMP upgrades this to a per-CPU field.

### 5.5 Failure Paths

- `cloneAddressSpace` fails → release the already-reserved child slot, return `-ENOMEM`.
- Kernel stack allocation fails → same.
- Process table full → return `-ENOMEM` (reuse; or add `-EAGAIN`, but not required now).

---

## 6. Phase 12c: SYS_EXEC

### 6.1 Syscall Signature

```zig
fn sysExec(path_ptr: u64) u64;
// Success: no return (the current process's user context is replaced and resumes from a new entry).
// Failure: -ENOENT / -ENOEXEC / -ENOMEM / -EFAULT; caller continues with the original image.
```

### 6.2 New in `process.zig`

```zig
pub const ExecResult = union(enum) {
    ok,               // syscallDispatch then arranges the jump
    not_found,
    not_user,
    bad_elf,
    no_memory,
    bad_path,
};

pub fn execCurrent(path: []const u8) ExecResult;
```

### 6.3 Implementation Notes

```
1. Copy path from user memory (reuse copyUserString; on failure return EFAULT → caller).
2. vfs.resolve(path) → inode_idx; not found → not_found.
3. inode = vfs.getInode(inode_idx); non-regular-file → bad_path.
4. Read file contents into a temporary heap buffer elf_buf (cap 1 MB); on failure → no_memory.
5. elf.parse(elf_buf); if not ELF64 x86_64 → bad_elf.
6. Build a new temporary AddressSpace new_as:
   createInto(&new_as)  // this path allocates the user stack already
7. For each segment in elf.segments: mapUserPage + write file_data + zero-fill bss.
   On failure → destroy(&new_as); no_memory.
8. Atomic swap:
   old_as = current_process.address_space
   current_process.address_space = new_as
   user_mem.activate(&new_as)
   destroy(&old_as)
9. Rebuild the user initial stack frame (process.buildUserInitialStack, entry=elf.entry,
   user_stack_top=USER_STACK_TOP)
   current_task.rsp = new_rsp
10. Clear FD_CLOEXEC-flagged entries in the fd table (Phase 12 keeps everything;
    Phase 13/14 introduce cloexec).
11. When exec is successful, syscallDispatch does not return normally — either it writes rax=0
    into the saved slot and replaces the iretq stack with the output of buildUserInitialStack,
    or sysExec returns a special sentinel and syscallStub jumps into scheduler.yield()
    (see §6.4).
```

### 6.4 Return Protocol

The "no return on success" behavior of exec is tricky because `syscallDispatch`'s caller (`syscallStub`) expects rax to carry a return value. Two viable implementations:

**Option A (recommended):** when `sysExec` succeeds:
- Overwrite the iretq frame on the kernel stack directly with the new program's initial frame (ss/rsp/rflags/cs/rip + 15 zeroed GPRs).
- Write 0 into the saved rax slot (a conventional "successful return").
- `syscallDispatch` returns 0; `syscallStub` `popq`s the registers and `iretq`s. The CPU starts executing at the new rip.

**Option B:** on success, `sysExec` calls `scheduler.yield()`, and the current task restarts from the new stack frame when it's next chosen. This adds unnecessary scheduling overhead; not recommended.

`sysExec` must finish all the potentially-failing steps (read ELF, parse, pre-allocate new AS) **before** overwriting the current address space, so failure never leaves the process in a half-replaced state.

### 6.5 Side Effects

- fd table is preserved (simplified version).
- Signal handlers (Phase 14) reset to defaults on exec.
- Process name (`ProcessInfo.name`? doesn't exist today; add `name: [32]u8` and set it to path basename on exec, so `ps` has something useful to show).

---

## 7. Phase 12d: Zombie Processes and SYS_WAITPID

### 7.1 Zombification Trigger

`process.exitCurrent(code)` currently behaves as:

```
task.finishCurrent(code) → scheduler picks the next task
```

Change to:

```
if (current.parent_pid != 0 and parent_exists):
    current.exit_status = encodeExit(code)
    current.state = .zombie
    // Keep the address space, process slot, and kernel stack until parent waitpid
    maybeWakeParentWaitingOn(current.pid)
else:
    // No parent, or parent already exited: reap directly (preserves the existing "finished" semantics)
    destroyProcess(current)
```

`encodeExit(code)` convention: low 8 bits = exit code; bit 8 = signaled flag (Phase 14); high 8 bits = signal number.

### 7.2 Syscall Signature

```zig
fn sysWaitpid(pid: u64, status_ptr: u64) u64;
// Success: returns the reaped child's pid
// pid == u64(-1) (casted from i64(-1)) means "any child"
// No matching child → ECHILD
// Current process has no children at all → ECHILD
// If status_ptr != 0, write exit_status back to user memory (4 bytes u32)
```

### 7.3 New in `process.zig`

```zig
pub const WaitResult = union(enum) {
    ok: struct { pid: u32, status: u32 },
    no_child,
    bad_pid,
    interrupted,   // reserved for Phase 14
};

pub fn waitpidCurrent(target_pid: u32) WaitResult;
// target_pid == 0 means "any child"
```

### 7.4 Implementation Notes

```
1. Count the current process's children (walk process_table where parent_pid == me.pid && active).
   Count == 0 → no_child.
2. Scan children for zombies:
   for child in children:
       if child.state == .zombie and (target_pid == 0 or child.pid == target_pid):
           result = { pid: child.pid, status: child.exit_status }
           reapZombie(child)
           return .ok = result
3. If target_pid was specified but isn't one of my children → bad_pid.
4. No zombie matched → block:
   current.wait_on_pid = target_pid
   task.block(current)   // new: scheduler.blockCurrent()
5. On wake-up, return to step 2.
```

When a child exits (`exitCurrent`), check every waiting parent of its own: if `parent.state == .blocked and parent.wait_on_pid in (0, me.pid)`, call `scheduler.unblock(parent)`.

### 7.5 reapZombie

```
fn reapZombie(child: *ProcessInfo) void:
    user_mem.destroy(&child.address_space)
    task.freeSlot(child.task_slot)
    process_table[child.slot] = empty
```

### 7.6 User Copy

When `status_ptr != 0`, use `copyToUser(status_ptr, std.mem.asBytes(&status_u32))`. On failure → `-EFAULT`.

---

## 8. Phase 12e: SYS_GETPPID

The simplest call:

```zig
fn sysGetppid() u64 {
    const me = process.currentInfo() orelse return 0;
    return me.parent_pid;
}
```

Kernel tasks / init return 0.

---

## 9. Phase 12f: Shell Integration and Demo Programs

### 9.1 New VFS-Resident Programs

Add the following ELFs to initfs / kernel-embedded resources (compiled by `build.zig`'s `user-programs` step, target `x86_64-freestanding-none`, two-step `build-obj + ld.lld`):

| Path | Description |
|------|-------------|
| `/bin/hello.elf` | Already present in Phase 11; only SYS_WRITE + SYS_EXIT. |
| `/bin/fork_demo.elf` | New: forks once, parent and child each print a line, parent waitpids. |
| `/bin/exec_demo.elf` | New: `exec("/bin/hello.elf")`, no wait. |
| `/bin/sh_mini.elf` | New: the Phase 12 milestone — a small user-mode shell. |
| `/bin/bad_exec.elf` | New: exec a nonexistent path, print errno, and exit. |

### 9.2 Scope of `/bin/sh_mini.elf`

- Prompt `$ `
- Builtins: `exit`, `pwd` (needs SYS_GETCWD? not in this phase — hardcode "/"), `help`.
- External commands: `<path>` → direct fork + exec + waitpid.
- Exit code display: `[pid=X] exited N`.
- No pipes, no redirection, no signals (those are Phase 13 / 14).

Suggested source file: `user_src/sh_mini.zig`, around 200 lines. Key points:
- Built-in minimal readline (via SYS_READ fd=0).
- Built-in SYS_WRITE `print` / `println` helpers.
- Decode errno from syscall return values (`if rax as i64 < 0 → -rax as errno`).

### 9.3 New Shell Commands (Kernel Shell)

Keep the kernel shell, but let it launch `/bin/sh_mini.elf`:

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

New in `shell_cmds.zig`:
- `fork_demo` (alias for `runelf /bin/fork_demo.elf`, for convenience).
- `ps` columns extended: "S" (state: R/r/B/Z/F) and "PPID".

### 9.4 Deprecated Paths

Kernel-embedded `hello_user` / `loop_user` / `bad_cli` / `bad_read` / `file_user` byte arrays can **stay but should not grow** once Phase 12 lands. All new test programs go through ELF + VFS.

---

## 10. QEMU Acceptance

### 10.1 Standard Regression Sequence

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

### 10.2 Stress and Edge Cases

1. **100× fork/exec/wait loop**: `/bin/stress.elf` (optional stretch) confirms no memory leak (`meminfo` matches before/after).
2. **Process slot exhaustion**: keep forking until the limit; observe `-ENOMEM`; after waitpid reclaims, forking continues to work.
3. **Process survives failed exec**: `bad_exec.elf` after an exec failure still prints and exits cleanly — no panic.
4. **Orphan process**: parent exits first, child exits later. The child should go straight to "finished" (we do not introduce a pid=1 init reaper in this phase; by "parent-exits-first → child has no one to wait on," the child's exit destroys itself immediately).
5. **waitpid ECHILD**: a process that never forked calls waitpid → `-7`.

### 10.3 Reporting Format

When each sub-phase (12a–12f) lands, the PR attaches:

- A serial snippet of the `runelf <path>` output.
- A `ps` snapshot at the key moment in that phase.
- Before/after `meminfo` (confirms no leak).

---

## 11. Implementation Order Checklist

```
Phase 12a: Address-space cloning
- [x] user_mem.zig: createBlank (variant without the user stack)
- [x] user_mem.zig: cloneAddressSpace
- [x] user_mem.zig: cloneSelfTest
- [x] shell_cmds.zig: clonememtest command
- [x] Verify: clonememtest ok, and the two address spaces at the same virtual address are physically isolated

Phase 12b: SYS_FORK
- [ ] syscall.zig: SYS.FORK=11, MAX_SYSCALL updated
- [ ] syscall.zig: current_syscall_frame capture (asm side in idt.syscallStub + Zig side)
- [ ] task.zig: parent_pid, exit_status, wait_on_pid fields
- [ ] process.zig: forkCurrent, ForkResult, reserveSlot
- [ ] syscall.zig: sysFork wiring
- [ ] Verify: /bin/fork_demo.elf parent/child output, rax=0/child_pid split

Phase 12c: SYS_EXEC
- [ ] process.zig: execCurrent, ExecResult
- [ ] syscall.zig: sysExec + overwrite iretq frame on success
- [ ] process.zig: ProcessInfo.name field + basename extraction
- [ ] shell_cmds.zig: ps displays NAME
- [ ] Verify: /bin/exec_demo.elf prints "Hello from Ring 3!" with pid unchanged

Phase 12d: SYS_WAITPID
- [ ] task.zig: TaskState.zombie
- [ ] process.zig: waitpidCurrent, WaitResult, reapZombie, maybeWakeParentWaitingOn
- [ ] process.zig: rework exitCurrent (zombie vs destroy branch)
- [ ] scheduler.zig: blockCurrent / unblock (reuse/extend the sleep mechanism if not already present)
- [ ] syscall.zig: sysWaitpid
- [ ] Verify: fork_demo's waitpid returns child.pid with the correct status

Phase 12e: SYS_GETPPID
- [ ] syscall.zig: sysGetppid
- [ ] Verify: fork_demo's child prints ppid == parent.pid

Phase 12f: Shell integration
- [ ] build.zig: user-programs step (compile multiple user_src/*.zig → /bin/*.elf into initfs)
- [ ] user_src/fork_demo.zig
- [ ] user_src/exec_demo.zig
- [ ] user_src/bad_exec.elf
- [ ] user_src/sh_mini.zig (milestone)
- [ ] shell_cmds.zig: ps extended with PPID / STATE columns
- [ ] Verify: full QEMU head-screen §10.1

Phase 12g (optional): COW
- [ ] vmm.zig: copy-on-write markers on page-table entries (use available bits 9/10/11)
- [ ] idt.zig: #PF handler recognizes COW and dups the page
- [ ] user_mem.zig: cloneAddressSpace switches to shared + read-only mapping
- [ ] Verify: fork followed immediately by exec copies zero pages (meminfo shows the expected savings)
```
