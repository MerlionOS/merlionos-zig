# MerlionOS-Zig Phase 12+ Roadmap

> This document plans the evolution path after Phase 11 (userland file ABI, with `SYS_MMAP` wrapping up).
> Each Phase states its **motivation / deliverables / dependencies / files touched / acceptance criteria**.
> A detailed implementation spec lives alongside this file at `DESIGN-PROCESS.md` (Phase 12 is fully expanded).
> For each subsequent Phase, a matching `DESIGN-*.md` should be written when work starts, keeping phase specs and implementations one-to-one.

## Table of Contents

1. [Current Kernel State (Starting Line)](#1-current-kernel-state-starting-line)
2. [Roadmap Overview](#2-roadmap-overview)
3. [Phase 12: Process Creation (fork / exec / waitpid)](#3-phase-12-process-creation-fork--exec--waitpid)
4. [Phase 13: Pipes and I/O Redirection](#4-phase-13-pipes-and-io-redirection)
5. [Phase 14: Signals and Job Control](#5-phase-14-signals-and-job-control)
6. [Phase 15: Block Device and Persistent Filesystem](#6-phase-15-block-device-and-persistent-filesystem)
7. [Phase 16: Userland Network ABI](#7-phase-16-userland-network-abi)
8. [Phase 17: Framebuffer and Character Terminal](#8-phase-17-framebuffer-and-character-terminal)
9. [Phase 18: SMP and Multi-Core Scheduling](#9-phase-18-smp-and-multi-core-scheduling)
10. [Phase 19: Userland AI ABI](#10-phase-19-userland-ai-abi)
11. [Design Principles (Shared Across Phases)](#11-design-principles-shared-across-phases)

---

## 1. Current Kernel State (Starting Line)

When Phase 11 closes, the kernel should have the capabilities below. This roadmap takes them as preconditions:

| Capability | Modules | Notes |
|-----------|---------|-------|
| Boot / logging / panic | limine / serial / vga / log | — |
| GDT / IDT / PIC / PIT 100 Hz | gdt / idt / pic / pit | TSS.rsp0 updated on context switch |
| Physical / virtual memory, kernel heap | pmm / vmm / heap | `mapPage(user=true, writable=?)` stable |
| Keyboard, shell, history, cd/pwd | keyboard / shell / shell_cmds | |
| Cooperative + preemptive scheduling, ps/spawn/kill | task / scheduler | `wake_tick`, `sleepCurrent` already exist |
| In-memory VFS, /proc, /dev, redirection | vfs / procfs / devfs | |
| PCI, e1000, ARP, IPv4, UDP, TCP, DNS | pci / e1000 / net / eth / arp_cache / ipv4 / udp / tcp / dns / socket | |
| COM2 AI proxy, aiask/aipoll | ai | Host-side `tools/ai_proxy.py` |
| User-mode syscall dispatch (int 0x80) | syscall / idt | SYS numbers 0..10 occupied |
| User address space, mmap region | user_mem | `USER_MMAP_BASE=0x4000_0000`, `mmap_next` field |
| Process table / fd table (VFS) | process | `MAX_FILE_DESCRIPTORS=16`, `FIRST_USER_FD=3` |
| Flat + ELF user programs | elf / user_programs / `/bin/hello.elf` | `runuser`, `runelf` |
| SYS_EXIT/WRITE/READ/YIELD/GETPID/SLEEP/BRK/OPEN/CLOSE/STAT/MMAP | syscall | The final `SYS_MMAP` was completed by codex in parallel |

---

## 2. Roadmap Overview

```
Phase 11 ──► 12 ──► 13 ──► 14 ──► 15 ──► 16 ──► 17 ──► 18 ──► 19
userland   process  pipes   signals  block    user     framebuffer SMP   user
file ABI   creation I/O     /job     /persist network  /terminal  multi-  AI
(mmap)    (fork)   (pipe)   control  FS       ABI                 core   ABI
                                     (virtblk)
```

Three reasons for this ordering:

1. **fork/exec is what lets the shell actually run in user space.** After Phase 11, user-mode code can only be entered through the kernel's built-in `runuser` or `runelf`. The eventual goal is to turn the shell itself into a ring-3 ELF, but that requires `fork + exec` first.
2. **Pipes and signals are hard requirements for a real shell.** Pipelines need fork; Ctrl+C needs signals. With both, the shell feels complete.
3. **Persistence comes after interactivity; the network ABI comes after persistence.** AI demos and tests run fine without persistence; polish the execution and interaction model first.

Rough scale estimate for each phase (used for calendar planning):

| Phase | New files | Main files touched | Est. LoC | Est. time |
|-------|-----------|--------------------|---------|-----------|
| 12 fork/exec/waitpid | 0 (extend process/user_mem) | syscall, process, user_mem, task, scheduler, shell_cmds | ~800 lines | medium |
| 13 pipes + dup + redirection | `pipe.zig` | syscall, process, shell | ~500 lines | medium |
| 14 signals | `signal.zig` | syscall, process, task, idt, keyboard, shell | ~800 lines | large |
| 15 virtio-blk + FS | `virtio_blk.zig`, `merfs.zig` | vfs, main, shell_cmds | ~1500 lines | large |
| 16 socket syscalls | — | syscall, process, socket, shell_cmds | ~500 lines | medium |
| 17 framebuffer + console | `fb.zig`, `console.zig`, `font.zig` | main, log, vga (kept for compatibility) | ~900 lines | large |
| 18 SMP | `acpi.zig`, `apic.zig`, `smp.zig`, `spinlock.zig` | idt, scheduler, pit→hpet?, heap (locked) | ~1500 lines | very large |
| 19 AI ABI | `ai_dev.zig` | syscall, vfs, devfs, ai | ~400 lines | small |

---

## 3. Phase 12: Process Creation (fork / exec / waitpid)

**Motivation:** turn "every user program is a kernel-preset entry point" into "any ELF can fork a child at runtime, replace its image, and wait for exit." This is the prerequisite for self-hosting the shell (moving it into ring 3), running `/bin/sh -c 'a | b'`, and generally any POSIX-style user program.

**New system calls (numbering continues 11..14):**

| # | Name | Prototype | Semantics |
|---|------|-----------|-----------|
| 11 | `SYS_FORK` | `fork() -> pid` | Duplicates the current process; parent gets child pid, child gets 0 |
| 12 | `SYS_EXEC` | `exec(path_ptr) -> no return / -errno` | Replaces the current image with an ELF from the VFS |
| 13 | `SYS_WAITPID` | `waitpid(pid, status_ptr) -> pid` | Blocks until the target child exits; reaps the zombie |
| 14 | `SYS_GETPPID` | `getppid() -> ppid` | Returns the parent pid |

**Core changes:**

- `user_mem.zig`: new `cloneAddressSpace(src: *const AddressSpace) ?AddressSpace`. No COW for now — copy each page directly (`MAX_USER_PAGES=256`, cost is bounded). COW is deferred to a possible future Phase 12g.
- `task.zig`: `Task` gains `parent_pid: u32 = 0`; `state` extended with `.zombie`.
- `process.zig`: adds `forkCurrent()`, `execCurrent(path)`, `waitpidCurrent(pid)`, `reapZombie(pid)`, and changes `exitCurrent` so it no longer immediately frees the slot — it transitions to `.zombie` first and `waitpidCurrent` does the reaping.
- `scheduler.zig`: generalizes `sleepCurrent` into a broader `block_on_exit(pid)` (and related block/unblock primitives).
- `shell_cmds.zig`: stops using kernel-path preallocated `runuser` / `runelf` entries (keeps them as examples); adds an `exec` shell command (single-line shell `$ /bin/hello.elf`).

**Deliverables:**

- `/bin/fork_demo.elf`: forks, parent and child each print a line and exit, parent calls `waitpid(child)`.
- `/bin/sh_mini.elf`: a ≤200-line ELF shell that supports `echo`, running `/bin/X.elf`, and `exit`. **This is the Phase 12 milestone** — the kernel shell and the ring-3 shell coexist, and the latter is launched via `exec` from the former.

**Acceptance (QEMU head-screen):**

```
merlion> runelf /bin/sh_mini.elf
[sh_mini] pid=7 ppid=1 ready
$ /bin/hello.elf
Hello from Ring 3!
$ exit
[pid=7] exited 0
merlion>
```

- `ps` can show the full lifecycle: child briefly alive → zombie → reaped by `waitpid`.
- `runelf /bin/bad_exec.elf` (intentionally exec'ing a nonexistent path) returns `-ENOENT` and does not panic.

See `DESIGN-PROCESS.md` for the full specification.

---

## 4. Phase 13: Pipes and I/O Redirection

**Motivation:** enable the user-mode shell to run `cmd1 | cmd2`, `cmd > file`, and `cmd < file`. Also decouple the current kernel hard-coding of writes to `fd=1` and reads from `fd=0` onto the fd table.

**New system calls:**

| # | Name | Prototype | Semantics |
|---|------|-----------|-----------|
| 15 | `SYS_PIPE` | `pipe(fds_ptr: *[2]u64) -> 0 / -errno` | Allocates a read/write pair |
| 16 | `SYS_DUP` | `dup(fd) -> new_fd` | Copies to the lowest free slot |
| 17 | `SYS_DUP2` | `dup2(old, new) -> new / -errno` | Overwrites the specified slot |

**New module:** `src/pipe.zig`. Each pipe is a 4 KB ring buffer with read/write fd pointers. Reading an empty pipe blocks; writing a full pipe blocks (tasks are parked on a wait queue managed by the scheduler). When all write ends are closed, the read end gets EOF (returns 0).

**fd kind differentiation:** the current `FileDescriptor { active, inode, offset }` becomes a `tagged union`:

```zig
pub const FdKind = enum { vfs_file, pipe_read, pipe_write, socket /* Phase 16 */ };
pub const FileDescriptor = union(FdKind) {
    vfs_file: struct { inode: u16, offset: usize },
    pipe_read: struct { pipe_id: u16 },
    pipe_write: struct { pipe_id: u16 },
    socket: struct { socket_id: u16 },
};
```

**SYS_WRITE / SYS_READ changes:** stop special-casing fd=0/1/2 for character devices. Instead, `/dev/stdin`, `/dev/stdout`, and `/dev/stderr` are pre-opened on fd 0/1/2 when exec sets up a new user process (via `sh_mini`).

**Deliverables:**

- `/bin/sh_mini.elf` (the Phase 12 version) extended with `|`, `>`, and `<`.
- Verification sequence:

```
$ /bin/cat.elf < /proc/version | /bin/grep.elf Zig
MerlionOS-Zig ... Zig 0.15 ...
```

**Dependency:** Phase 12's fork/exec. The pipe is allocated first, then fork splits the parent and child, each of which closes the end it does not use.

---

## 5. Phase 14: Signals and Job Control

**Motivation:** Ctrl+C kills the foreground process, parents receive `SIGCHLD`, user programs install custom handlers. Without this, an interactive shell always feels one step short.

**New system calls:**

| # | Name | Notes |
|---|------|-------|
| 18 | `SYS_KILL(pid, sig)` | Default behavior: TERM/KILL/INT → kill; CHLD → ignore |
| 19 | `SYS_SIGACTION(sig, new_ptr, old_ptr)` | Installs a user handler |
| 20 | `SYS_SIGRETURN` | Returns from trampoline (the trampoline inlines `int 0x80`) |
| 21 | `SYS_SIGPROCMASK` | Blocks/unblocks signal sets |

**New module:** `src/signal.zig`.

**Signal set:** only a subset of the first 16 Unix signals: `SIGINT=2, SIGKILL=9, SIGSEGV=11, SIGTERM=15, SIGCHLD=17, SIGSTOP=19, SIGCONT=18`.

**Delivery path:**
- Kernel-side pending: `task.pending_signals: u64` bitmap + `signal_mask: u64`.
- On every return-to-user path (from a syscall or IRQ), check `pending & ~mask`; if non-zero, build a `ucontext` frame on the user stack and adjust rip to the user handler and the return address to a kernel-installed user-space trampoline at a fixed virtual address near `USER_TEXT_BASE`.
- The trampoline calls the handler, then invokes `SYS_SIGRETURN`, which restores the ucontext.

**Keyboard → SIGINT:** introduce the concept of a "foreground process group (pgid)". The shell's fork+exec sets the child's pgid = child_pid; the shell sets the foreground pgid to child_pid. When the keyboard driver sees Ctrl+C (scancode 0x2E with Ctrl held), it delivers `SIGINT` to every member of the foreground pgid.

**Process table change:** `Task` gains `pgid: u32` and `sid: u32`.

**Deliverables:**

- `/bin/sig_demo.elf`: installs a SIGINT handler that prints a line; without a handler, the default is termination.
- QEMU acceptance: `$ /bin/loop.elf` followed by Ctrl+C → process exits, shell re-prompts; with a handler installed → the handler runs.
- `waitpid` can observe the child's `WIFSIGNALED` state (`status` high 16 bits encode the signal number).

---

## 6. Phase 15: Block Device and Persistent Filesystem

**Motivation:** after Phases 1–14, the VFS is still entirely in memory. A reboot zeroes it. With a persistent disk, `/bin/*.elf`, logs, and shell history can survive reboots, and AI conversations can be archived.

**Choice:**

- Block device driver: **virtio-blk** (legacy PCI, QEMU `-drive if=virtio,...`). More modern and easier to write than ATA PIO. Start with polling mode and a single virtqueue.
- Filesystem: **MerFS** — a native 32 MB minimal FS. No FAT, because FAT's long filenames and directory entry overhead drift from the "clean reimplementation" ethos.

**MerFS on-disk layout:**

```
+--------+---------+-------------+-----------+---------+
| Super  | Inode   | Block       | Reserved  | Data    |
| block  | table   | bitmap      |           | blocks  |
| 1 blk  | 1024    | 1 blk       | ..        | ..      |
|        | inodes  |             |           |         |
+--------+---------+-------------+-----------+---------+
block size = 4096, 64 B per inode, single-level direct block pointers (12 each).
```

Superblock magic `"MERLION1"`; on first boot, if the magic is missing, `mkfs` runs.

**New files:** `src/virtio_blk.zig`, `src/merfs.zig`, `src/blkdev.zig` (abstract block read/write interface).

**VFS integration:** new `mount(path, fs_type)`. Default is `mount("/mnt", "merfs")`. MerFS directories and files work transparently through the VFS interface — `cat`, `ls`, `write`, `rm` all reuse existing paths.

**Deliverables:**

- Shell commands: `mount`, `umount`, `sync`, `df`.
- Cold-boot script: detect empty disk and `mkfs` automatically; copy `/bin/*.elf` from kernel initramfs to `/mnt/bin`.
- On the next boot, `/mnt/bin/hello.elf` is still present.
- QEMU command: `qemu-system-x86_64 ... -drive file=merlionos.img,if=virtio,format=raw` (add a `-with-disk` option to `build.zig`'s `run` step).

---

## 7. Phase 16: Userland Network ABI

**Motivation:** the TCP/IP stack (Phase 9) is already reasonably complete, but can only be driven from shell commands or kernel code. This phase promotes `socket.zig` to a userland ABI, so `/bin/httpget.elf` and `/bin/dns.elf` can exist as real ELFs.

**New system calls (Linux-style subset):**

| # | Name | Notes |
|---|------|-------|
| 22 | `SYS_SOCKET(domain, type, proto)` | Only `AF_INET + SOCK_DGRAM / SOCK_STREAM` |
| 23 | `SYS_BIND(fd, addr_ptr, addr_len)` | |
| 24 | `SYS_CONNECT(fd, addr_ptr, addr_len)` | TCP blocks until ESTABLISHED or timeout |
| 25 | `SYS_LISTEN(fd, backlog)` | |
| 26 | `SYS_ACCEPT(fd, addr_out, len_out)` | Blocks |
| 27 | `SYS_SEND(fd, buf, len, flags)` | |
| 28 | `SYS_RECV(fd, buf, len, flags)` | |
| 29 | `SYS_SENDTO(fd, buf, len, flags, addr, addr_len)` | UDP |
| 30 | `SYS_RECVFROM(fd, buf, len, flags, addr_out, len_out)` | UDP |

`SYS_CLOSE` is not added — it reuses the existing Phase 11 `SYS_CLOSE` (the fd table is already a tagged union by Phase 13).

**Deliverables:**

- `/bin/httpget.elf`: fetch a page from the shell (`/bin/httpget.elf example.com /`).
- `/bin/ncat.elf`: acts as an `nc -l -p 4444`-style service.

**Dependency:** the fd tagged union from Phase 13.

---

## 8. Phase 17: Framebuffer and Character Terminal

**Motivation:** move past VGA text mode, preparing for GUI / bitmap work. Limine already hands the kernel a linear framebuffer at boot; it just isn't used yet.

**Scope:**

- `src/fb.zig`: wraps the Limine framebuffer request, exposing `pixel(x,y,rgba)`, `rect`, `blit`.
- `src/font.zig`: embeds a PSF v2 font (8×16), parsed at comptime into a bitmap array.
- `src/console.zig`: a bitmap-based 80×25 terminal emulator; takes over `log.writeBytes`. Supports an ANSI SGR color subset (30–37, 40–47, 1, 0).
- Changes to `log.zig`: output simultaneously to serial + console (replacing the old serial + VGA path). VGA is kept as a `--no-fb` fallback.

**Deliverables:**

- After boot, the terminal is a bitmap console with colored kernel logs.
- New shell command `fbtest`: draws a gradient rectangle and a small lion logo.
- Reserves hooks for future multi-tty and window system work (`console.zig` exposes `createViewport(rect)` returning `*Viewport`).

**Dependency:** only Phase 1. Independent of other phases; can be done in parallel.

---

## 9. Phase 18: SMP and Multi-Core Scheduling

**Motivation:** single-core scheduling is easy to write, but real AI workloads (Phase 19 later) want at least the LLM-proxy polling and the user shell on separate cores. QEMU `-smp 4` also makes a nice demo.

**Scope:**

- `src/acpi.zig`: minimum viable ACPI — locate the RSDP (via Limine's `LIMINE_RSDP_REQUEST`), parse the XSDT, find the MADT, enumerate local APICs and IO APICs.
- `src/apic.zig`: xAPIC MMIO access, EOI, IPI send, Timer mode init (each core's local timer replaces PIT preemption).
- `src/smp.zig`: AP trampoline (16-bit real-mode code relocated to 0x8000), INIT-SIPI-SIPI sequence, per-core stack allocation, `per_cpu_data`.
- `src/spinlock.zig`: TAS spinlock; replace the interrupt-disable protection in heap / scheduler / process / vfs etc.
- `scheduler.zig` rewrite: per-CPU ready queue + global load balance (periodic migration each tick).
- `idt.zig` rewrite: the IDT stays shared across cores, but each core initializes its own TSS and kernel stack.
- PIT is retained but demoted to a wall-clock fallback; the main time source becomes HPET or the APIC timer.

**Deliverables:**

- `zig build run-smp` boots 4 cores.
- `cpuinfo` shell command lists every core and the task currently on it.
- `ps` shows a `CPU` column.
- Stress test: four `/bin/loop.elf` instances show load balanced across four cores.

**Dependency:** Phase 18 is the biggest single change. Best to defer until 12–17 are done, and give it a dedicated `docs/spec/DESIGN-SMP.md`.

---

## 10. Phase 19: Userland AI ABI

**Motivation:** MerlionOS's manifesto is "Born for AI, Built by AI." Right now the AI proxy can only be triggered via kernel shell commands `aiask` / `aipoll`. Exposing it to user space opens the door to `/bin/chat.elf`, `/bin/codegen.elf`, even a user-space `agent.elf`.

**Design choice (two routes):**

| Option | Pros | Cons |
|--------|------|------|
| A: `SYS_AI(op, arg_ptr)` | Direct, fewer files | Needs a new protocol; pollutes the syscall table |
| B: `/dev/ai` char device | Uses VFS + fd naturally | Needs devfs non-blocking read/write and poll |

**Option B is recommended.** The protocol is simple:

- `write(fd, "hello", 5)` submits a prompt to the AI proxy.
- `read(fd, buf, n)` reads the reply (blocks until the proxy responds).
- `ioctl(fd, AI_STATUS, status_ptr)` reports connection status (Phase 19 introduces the first `SYS_IOCTL=31` alongside).

**New modules:**
- `src/ai_dev.zig`: devfs node `/dev/ai`, wrapping `ai.zig`'s COM2 queue as a VFS read/write.
- `src/syscall.zig`: add `SYS_IOCTL` (generic ioctl — future tty / socket will use it).

**Deliverables:**

- `/bin/chat.elf`: command-line loop → `write /dev/ai` → `read /dev/ai` → print.
- `/bin/agent.elf` (stretch): feeds the results of `ps`, `cat`, `ls` into the AI to answer "is the kernel healthy right now?"
- Final demo: in the shell, run `/bin/chat.elf`, and the user talks to the model entirely through ring 3.

---

## 11. Design Principles (Shared Across Phases)

1. **Zero external dependencies.** No new phase pulls in a third-party crate or zig package.
2. **Explicit allocators.** Every dynamic structure (pipe, socket, signal queue, blockdev cache) accepts an allocator argument; kernel-internal uses go through `heap.allocator()`.
3. **Errors as `-errno`.** Consistent with the `ENOSYS/EFAULT/EINVAL/ENOMEM/EBADF/ENOENT` set established in Phase 11. New numbers are declared at the top of `syscall.zig`.
4. **Every phase requires a QEMU head-screen regression.** The corresponding `DESIGN-*.md` ends with a "QEMU test methods" section, and the expected output is locked into the PR description.
5. **User test programs go through the VFS; no more kernel-embedded byte arrays.** After Phase 12, `runuser hello` should be equivalent to `runelf /bin/hello.elf`.
6. **Phases are decoupled but PRs can merge concurrently.** For example, Phase 13 cannot start before Phase 12 is done (it depends on fork), but Phase 17 framebuffer is entirely independent and can interleave with 12–16 freely.
7. **Docs before code.** Before any phase starts, write its `DESIGN-*.md`, review it, and only then let codex implement. This roadmap is the index; each phase's standalone spec lives alongside it.

---

## Appendix A: Alignment with the Original Rust MerlionOS

The original Rust MerlionOS project currently sits around Phase 9 (TCP). This Zig reimplementation started at Phase 10 (user mode) and is already ahead. Phases 12–19 are expected to evolve independently on each side; if the original project ships an on-disk FS design at Phase 15, it's worth reviewing for UX alignment (not implementation).

## Appendix B: Recommended Implementation-Order Adjustments

- **Phase 13 and Phase 14 can be swapped.** If the "Ctrl+C interrupts a loop" demo is more impactful than the pipeline demo for your audience, do 14 first. Fork/exec must already be in place.
- **Phase 15 can move up in front of Phase 12.** If the team wants to see "files survive reboot" first, insert Phase 15 ahead of Phase 13. Phase 15 does not depend on fork.
- **Phase 19 can cut in line at any time.** It only depends on Phase 11 (VFS fd + open/read/write), not on fork/exec or the network ABI. Under demo pressure, jump from Phase 12 straight to Phase 19 for a headline, then circle back for 13–18.
