# MerlionOS-Zig User Mode Design Document

> This document is intended for direct use by AI code generation tools (Codex, etc.).
> It also includes detailed explanations to help readers understand the core concepts of x86_64 user mode.
> Implementation order strictly follows the Phase numbering.

## Table of Contents

1. [Background: What Is User Mode](#1-background-what-is-user-mode)
2. [Current Kernel State Analysis](#2-current-kernel-state-analysis)
3. [Phase 8a: syscall Infrastructure](#3-phase-8a-syscall-infrastructure)
4. [Phase 8b: User-Mode Address Space](#4-phase-8b-user-mode-address-space)
5. [Phase 8c: User Process Loading and Execution](#5-phase-8c-user-process-loading-and-execution)
6. [Phase 8d: ELF Loader](#6-phase-8d-elf-loader)
7. [Phase 8e: Process Lifecycle](#7-phase-8e-process-lifecycle)
8. [Phase 8f: Shell Integration](#8-phase-8f-shell-integration)
9. [Integration and Initialization Order](#9-integration-and-initialization-order)
10. [QEMU Testing Methods](#10-qemu-testing-methods)
11. [Security Model Summary](#11-security-model-summary)

---

## 1. Background: What Is User Mode

### 1.1 Protection Rings

The x86_64 CPU has 4 privilege levels (Ring 0-3), but modern operating systems only use two:

```
Ring 0 (Kernel/Supervisor)            Ring 3 (User)
┌─────────────────────────┐     ┌─────────────────────────┐
│ Can execute any instruc. │     │ Cannot execute privileged│
│ Can access any memory    │     │ Can only access User-    │
│ Can operate I/O ports    │     │   flagged pages          │
│ Can modify page tables   │     │ Cannot directly access HW│
│ Can disable/enable ints  │     │ Cannot modify page tables│
└─────────────────────────┘     │ Cannot execute CLI/STI   │
        ↑                       └─────────────────────────┘
    Our kernel is here now               ↑
                                  We want programs to run here
```

**Why have user mode?** Isolation. If all code runs in Ring 0, a buggy program could overwrite kernel memory, manipulate hardware, or corrupt other programs. User mode lets the CPU hardware enforce isolation — when a user program attempts a privileged operation, the CPU raises an exception (#GP or #PF), and the kernel can choose to kill that program without affecting the system.

### 1.2 Privilege Level Switching Mechanisms

Entering user mode from kernel mode ("landing" in Ring 3):

```
Kernel (Ring 0)                       User Program (Ring 3)
     │                                  ↑
     │  Prepare stack frame:            │
     │  push USER_DATA_SEL (ss)         │
     │  push user_rsp                   │
     │  push user_rflags                │
     │  push USER_CODE_SEL (cs)         │
     │  push user_rip (program entry)   │
     │                                  │
     └──── iretq ───────────────────────┘
           CPU sees CS RPL=3,
           automatically switches to Ring 3
```

Returning to kernel mode from user mode (system call):

```
User Program (Ring 3)                 Kernel (Ring 0)
     │                                  ↑
     │  int 0x80                        │
     │  or syscall instruction          │
     └──────────────────────────────────┘
           CPU automatically:
           1. Loads RSP0 from TSS (kernel stack)
           2. Saves user's RIP, CS, RFLAGS, RSP, SS
           3. Jumps to interrupt handler
           4. Privilege level becomes Ring 0
```

### 1.3 Key Hardware Mechanisms

**GDT (Global Descriptor Table)** — already in `gdt.zig`

Our GDT already defines 4 segments:

| Selector | Purpose | DPL | Description |
|----------|---------|-----|-------------|
| 0x08 | KERNEL_CODE_SEL | 0 | Kernel code segment |
| 0x10 | KERNEL_DATA_SEL | 0 | Kernel data segment |
| 0x18 | USER_DATA_SEL | 3 | User data segment (access=0xF2, DPL=3) |
| 0x20 | USER_CODE_SEL | 3 | User code segment (access=0xFA, DPL=3) |

> Note that USER_DATA_SEL comes **before** USER_CODE_SEL. This is the layout required by the `syscall`/`sysret` instructions. The `sysret` hardware requires SS = STAR[63:48] and CS = STAR[63:48] + 16. So data comes first, code comes second. Our GDT is already arranged in this order.

**TSS (Task State Segment)** — already in `gdt.zig`

The `rsp0` field in the TSS tells the CPU which kernel stack to switch to when an interrupt/exception occurs in user mode. Every time we switch to a different process, we must update `tss.rsp0` to that process's kernel stack top.

**Page Tables** — already in `vmm.zig`

The `user` parameter of `vmm.mapPage` corresponds to the U/S bit (bit 2) in the page table entry. Pages with the U/S bit set can be accessed by Ring 3 code; pages without it can only be accessed by Ring 0. This is the core of user-mode memory isolation.

### 1.4 What Is a System Call

User programs cannot directly operate hardware, but they need to do I/O (printing, reading files, sending network packets, etc.). How? Through system calls (syscall) — they "request" the kernel to do it on their behalf:

```
User program:                     Kernel:
  "I want to print Hello"          Receives syscall
  → rax = 1 (WRITE)               → Validate parameter legality
  → rdi = 1 (stdout)              → Copy data from user memory
  → rsi = buf_ptr                 → Output via serial/VGA
  → rdx = 5 (length)              → Return bytes written
  → int 0x80                      → iretq back to user mode
```

The key principle of this design: **the kernel does not trust any parameters passed by the user**. The pointer from the user might point to kernel memory, might be out of bounds, or might be NULL. The kernel must validate every parameter.

### 1.5 Virtual Address Space Layout

```
0xFFFF_FFFF_FFFF_FFFF ┐
                      │ Kernel space (upper half)
                      │ Kernel code, heap, VGA, MMIO...
                      │ Page table marked as Supervisor (U/S=0)
                      │ User-mode code cannot access
0xFFFF_FFFF_8000_0000 ┤ ← Kernel base address (0xffffffff80000000 in linker.ld)
         ...          │
0x0000_8000_0000_0000 ┤ ← Non-canonical address hole (CPU will #GP)
         ...          │
0x0000_7FFF_FFFF_FFFF ┤ ← User space upper limit
                      │
0x0000_0000_0080_0000 │ ← User program .text load address
         ...          │
0x0000_0000_0010_0000 │ ← User heap start
         ...          │
0x0000_7FFF_FFFF_0000 │ ← User stack top (grows downward)
                      │
0x0000_0000_0000_0000 ┘ ← NULL region (unmapped, access causes #PF)
```

---

## 2. Current Kernel State Analysis

### 2.1 Existing Infrastructure (Can Be Reused Directly)

| Component | File | Capability Needed for User Mode | Status |
|-----------|------|-------------------------------|--------|
| GDT + TSS | gdt.zig | Ring 3 segment selectors + rsp0 switching | **Ready** — USER_DATA_SEL(0x18) + USER_CODE_SEL(0x20) already defined, `setKernelStack()` already exists |
| IDT | idt.zig | int 0x80 syscall entry point | **Skeleton exists** — `syscallStub` at 0x80, type_attr=0xEE (DPL=3, user mode can trigger), but handler only prints a log |
| VMM | vmm.zig | User page mapping (user=true) | **Ready** — `mapPage` supports user parameter |
| PMM | pmm.zig | Allocate user page frames | **Ready** |
| Task Management | task.zig | Process concept | **Needs extension** — Currently only has kernel tasks, needs user-mode context |
| Scheduler | scheduler.zig | Unified scheduling for kernel/user tasks | **Needs minor changes** — Must update TSS.rsp0 on switch |

### 2.2 Parts That Need to Be Added/Modified

```
New files:
  src/syscall.zig      — syscall dispatch + individual system call implementations
  src/user_mem.zig     — User address space management (independent page tables, memory mapping)
  src/elf.zig          — ELF parser
  src/process.zig      — Process management (high-level wrapper over task.zig)
  user/                — User-mode test programs (assembly + Zig)

Files to modify:
  src/idt.zig          — Change syscallStub to full syscall dispatch
  src/task.zig         — Add user-mode fields to Task struct
  src/scheduler.zig    — Update TSS.rsp0 on switch
  src/gdt.zig          — No changes needed (already ready)
  src/vmm.zig          — Add createAddressSpace / cloneKernelMappings
  src/shell_cmds.zig   — Add exec / ps command enhancements
```

---

## 3. Phase 8a: syscall Infrastructure

### 3.1 Concept: syscall Dispatch

When a user program executes `int 0x80`, the CPU jumps to the handler pointed to by IDT[0x80]. We need to:

1. **Save all registers** (the user program's state must not be lost)
2. **Read rax** (syscall number)
3. **Dispatch to the corresponding handler**
4. **Place the return value in rax**
5. **Restore registers, iretq back to user mode**

Register convention (Linux-like):

| Register | Purpose |
|----------|---------|
| rax | System call number (input) / return value (output) |
| rdi | 1st argument |
| rsi | 2nd argument |
| rdx | 3rd argument |
| r10 | 4th argument (note: not rcx, because the `syscall` instruction clobbers rcx) |
| r8 | 5th argument |
| r9 | 6th argument |

### 3.2 src/syscall.zig — System Call Implementation

#### System Call Numbers

```zig
// System call number definitions
// Using comptime enum for easy sharing between both sides
pub const SYS = enum(u64) {
    EXIT = 0,        // Exit the current process
    WRITE = 1,       // Write output (serial + VGA)
    READ = 2,        // Read input (keyboard buffer)
    YIELD = 3,       // Voluntarily yield the CPU
    GETPID = 4,      // Get current process PID
    SLEEP = 5,       // Sleep for N ticks
    BRK = 6,         // Adjust heap top (simple memory allocation)
    OPEN = 7,        // Open file (VFS)
    CLOSE = 8,       // Close file descriptor
    STAT = 9,        // Get file information
    MMAP = 10,       // Map anonymous memory pages
};

pub const MAX_SYSCALL: u64 = 10;

// Error codes (negative values indicate errors, returned in rax)
pub const ENOSYS: i64 = -1;    // Unknown system call
pub const EFAULT: i64 = -2;    // Invalid address
pub const EINVAL: i64 = -3;    // Invalid argument
pub const ENOMEM: i64 = -4;    // Out of memory
pub const EBADF: i64 = -5;     // Invalid file descriptor
pub const ENOENT: i64 = -6;    // File not found
```

#### Types

```zig
/// System call context (extracted from saved registers)
pub const SyscallContext = struct {
    number: u64,    // rax
    arg1: u64,      // rdi
    arg2: u64,      // rsi
    arg3: u64,      // rdx
    arg4: u64,      // r10
    arg5: u64,      // r8
    arg6: u64,      // r9
};

/// Statistics
pub const Stats = struct {
    total_calls: u64,
    by_number: [MAX_SYSCALL + 1]u64,
    unknown_calls: u64,
    fault_returns: u64,
};
```

#### Global State

```zig
var stats: Stats = std.mem.zeroes(Stats);
```

#### Public Functions

```zig
/// System call dispatch entry point (called by syscallStub in idt.zig)
/// Arguments are obtained from registers saved on the stack
/// Return value is written to rax
pub export fn syscallDispatch(
    number: u64,    // rax
    arg1: u64,      // rdi
    arg2: u64,      // rsi
    arg3: u64,      // rdx
    arg4: u64,      // r10
    arg5: u64,      // r8
) callconv(.c) u64;

/// Get statistics
pub fn getStats() Stats;
```

#### syscallDispatch() Internal Logic

```
1. stats.total_calls += 1
2. If number > MAX_SYSCALL → stats.unknown_calls += 1, return ENOSYS
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

#### Individual System Call Implementations

```zig
/// SYS_EXIT: Terminate the current user process
/// arg1: exit code
/// Does not return
fn sysExit(exit_code: u64) noreturn;
```

```
1. Get the current task, record exit_code
2. Set task.state = .finished
3. Release all page frames in the user address space
4. Schedule the next task
5. If no other tasks → return to shell (idle task)
```

```zig
/// SYS_WRITE: Write data to output
/// fd: file descriptor (1=stdout/serial, 2=stderr/serial)
/// buf_ptr: user-mode buffer address
/// count: number of bytes to write
/// Returns: actual number of bytes written, or error code
fn sysWrite(fd: u64, buf_ptr: u64, count: u64) u64;
```

```
1. If fd != 1 and fd != 2 → return EBADF
2. If count == 0 → return 0
3. If count > 4096 → count = 4096 (limit single write size)
4. Validate user buffer:
   If buf_ptr >= 0x0000_8000_0000_0000 → return EFAULT (address is in kernel space)
   If buf_ptr + count overflows → return EFAULT
   For each page, call vmm.translateAddr() to confirm mapping exists → if not, return EFAULT
5. Copy from user memory to a kernel temporary buffer (do not pass user pointers directly to kernel functions)
6. Output byte by byte to serial + VGA (via log module)
7. return count
```

> **Security note**: Why can't we use the user-provided pointer directly?
> 
> Although our kernel can access all memory, the `buf_ptr` from the user might:
> - Point to kernel code/data → leaking kernel information
> - Point to an unmapped page → triggering a kernel page fault (if the kernel doesn't handle it, it crashes)
> - Point to another process's memory (if we later support multiple address spaces)
> 
> Therefore we must first verify that the address falls within the user space range, then verify that the page table actually has a mapping.

```zig
/// SYS_READ: Read data from input
/// fd: file descriptor (0=stdin/keyboard)
/// buf_ptr: user-mode buffer address
/// count: maximum number of bytes to read
/// Returns: actual number of bytes read
fn sysRead(fd: u64, buf_ptr: u64, count: u64) u64;
```

```
1. If fd != 0 → return EBADF
2. Validate user buffer (same as sysWrite)
3. Read at most count bytes from the keyboard buffer
4. Copy to user memory
5. return actual number of bytes read (may be 0, meaning no input available)
```

```zig
/// SYS_YIELD: Voluntarily yield the CPU
fn sysYield() u64;
```

```
1. scheduler.yield()
2. return 0
```

```zig
/// SYS_GETPID: Get current process PID
fn sysGetpid() u64;
```

```
1. return task.currentPid() or 0
```

```zig
/// SYS_SLEEP: Sleep
/// ticks: number of PIT ticks (at 100Hz, 100 = 1 second)
fn sysSleep(ticks: u64) u64;
```

```
1. Record current tick: start = pit.ticks()
2. Set task.state = .blocked, task.wake_tick = start + ticks
3. scheduler.yield()
4. return 0
(Need to check blocked tasks' wake_tick in scheduler.timerTick)
```

```zig
/// SYS_BRK: Adjust process heap top
/// new_brk: new heap top address (0 means query current value)
/// Returns: current heap top address
fn sysBrk(new_brk: u64) u64;
```

```
1. Get the current process's brk value
2. If new_brk == 0 → return current brk
3. Validate that new_brk is within user space range
4. If new_brk > current brk:
   Allocate physical frames for new pages, mapPage(virt, phys, writable=true, user=true)
5. If new_brk < current brk:
   Release excess pages
6. Update brk, return new brk
```

```zig
/// SYS_MMAP: Map anonymous memory pages
/// addr: desired virtual address (0 means kernel chooses automatically)
/// length: mapping length (rounded up to page boundary)
/// Returns: mapped virtual address, or ENOMEM
fn sysMmap(addr: u64, length: u64) u64;
```

```
1. pages = (length + PAGE_SIZE - 1) / PAGE_SIZE
2. If addr == 0 → allocate from the process's mmap region
3. For each page: allocFrame + mapPage(user=true, writable=true)
4. return the starting virtual address of the mapping
```

### 3.3 Modifying src/idt.zig — syscall Dispatch

The current `syscallStub` uses `pushRegsAndCall`, which only saves caller-saved registers. It needs to be changed to save the full context and pass arguments:

```zig
// Replace the existing syscallStub
fn syscallStub() callconv(.naked) void {
    // Save all general-purpose registers
    // Extract syscall arguments from registers, call syscallDispatch
    // Place return value into the saved rax position on the stack
    // Restore registers, iretq
    asm volatile (
        // Save registers
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
        // Call syscallDispatch(number=rax, arg1=rdi, arg2=rsi, arg3=rdx, arg4=r10, arg5=r8)
        // System V AMD64 calling convention: rdi, rsi, rdx, rcx, r8, r9
        // Note register remapping: we need rax→rdi, rdi→rsi, rsi→rdx, rdx→rcx, r10→r8, r8→r9
        // But these registers have already been pushed to the stack, so read from the stack to avoid conflicts
        \\movq 112(%%rsp), %%rdi   // number = saved rax (15th push, 14*8=112)
        \\movq 64(%%rsp), %%rsi    // arg1 = saved rdi (8th push, 8*8=64)
        \\movq 72(%%rsp), %%rdx    // arg2 = saved rsi (9th push, 9*8=72)
        \\movq 88(%%rsp), %%rcx    // arg3 = saved rdx (11th push, 11*8=88)
        \\movq 40(%%rsp), %%r8     // arg4 = saved r10 (5th push, 5*8=40)
        \\movq 56(%%rsp), %%r9     // arg5 = saved r8 (7th push, 7*8=56)
        \\call syscallDispatch
        //
        // Return value is in rax, need to write it to the saved rax position on the stack
        \\movq %%rax, 112(%%rsp)
        //
        // Restore registers
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

> **Explanation: How are the stack offsets calculated?**
>
> The push order is rax, rbx, rcx, rdx, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15.
> The stack grows downward, so the last push (r15) is at the lowest address (rsp+0).
>
> ```
> RSP+112: rax  (1st push)
> RSP+104: rbx  (2nd push)
> RSP+96:  rcx  (3rd push)
> RSP+88:  rdx  (4th push)
> RSP+80:  rbp  (5th push)
> RSP+72:  rsi  (6th push)
> RSP+64:  rdi  (7th push)
> RSP+56:  r8   (8th push)
> RSP+48:  r9   (9th push)
> RSP+40:  r10  (10th push)
> RSP+32:  r11  (11th push)
> RSP+24:  r12  (12th push)
> RSP+16:  r13  (13th push)
> RSP+8:   r14  (14th push)
> RSP+0:   r15  (15th push)
> ```

### 3.4 User Address Validation Utilities

```zig
// In syscall.zig

/// User space address upper limit (non-canonical address boundary)
const USER_ADDR_MAX: u64 = 0x0000_7FFF_FFFF_FFFF;

/// Validate user-mode buffer legality
/// Checks: address is within user space range, no overflow, every page has a mapping
fn validateUserBuffer(ptr: u64, len: u64) bool {
    if (ptr == 0) return false;
    if (ptr > USER_ADDR_MAX) return false;
    if (len > USER_ADDR_MAX) return false;
    if (ptr + len < ptr) return false;  // Overflow check
    if (ptr + len > USER_ADDR_MAX) return false;

    // Check that every page is mapped
    var page = ptr & ~@as(u64, 0xFFF);
    const end = ptr + len;
    while (page < end) : (page += 0x1000) {
        if (vmm.translateAddr(page) == null) return false;
    }
    return true;
}

/// Safely copy from user memory to a kernel buffer
fn copyFromUser(dest: []u8, user_src: u64, len: usize) bool {
    if (!validateUserBuffer(user_src, len)) return false;
    const src: [*]const u8 = @ptrFromInt(user_src);
    @memcpy(dest[0..len], src[0..len]);
    return true;
}

/// Safely copy from a kernel buffer to user memory
fn copyToUser(user_dest: u64, src: []const u8) bool {
    if (!validateUserBuffer(user_dest, src.len)) return false;
    const dest: [*]u8 = @ptrFromInt(user_dest);
    @memcpy(dest[0..src.len], src);
    return true;
}
```

---

## 4. Phase 8b: User-Mode Address Space

### 4.1 Concept: Per-Process Page Tables

Currently the entire system shares a single page table (the PML4 pointed to by CR3). All tasks see the exact same virtual address space. This is fine for kernel-mode tasks, but user processes need isolated address spaces.

Approach comparison:

| Approach | Pros | Cons | Choice |
|----------|------|------|--------|
| **A. Fully independent page tables** | True process isolation | Need to copy kernel mappings to each new page table | ✓ MVP |
| B. Shared upper half | Simpler | User processes can see each other's lower half | |

We choose Approach A: each user process has its own PML4. The upper half (kernel space) PML4 entries are copied from the kernel page table, while the lower half (user space) is unique to each process.

```
Process A's PML4                  Process B's PML4
┌─────────────────┐            ┌─────────────────┐
│ [256] kernel ... │ ←──────── │ [256] kernel ... │  Same kernel mappings
│ [257] kernel ... │            │ [257] kernel ... │
│ ...              │            │ ...              │
│ [511] kernel ... │            │ [511] kernel ... │
├─────────────────┤            ├─────────────────┤
│ [0] Process A code│           │ [0] Process B code│  Different user mappings
│ [1] Process A heap│           │ [1] Process B heap│
│ ...              │            │ ...              │
│ [255] Process A  │            │ [255] Process B  │
│       stack      │            │       stack      │
└─────────────────┘            └─────────────────┘
```

> The PML4 has 512 entries. Entries [256..511] cover the upper half (0xFFFF800000000000+),
> entries [0..255] cover the lower half (user space).

### 4.2 src/user_mem.zig — User Address Space Management

#### Constants

```zig
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");
const cpu = @import("cpu.zig");

/// User space layout
pub const USER_TEXT_BASE: u64 = 0x0000_0000_0040_0000;    // 4MB, program load address
pub const USER_HEAP_BASE: u64 = 0x0000_0000_1000_0000;    // 256MB, heap start
pub const USER_STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;    // User stack top
pub const USER_STACK_SIZE: u64 = 16 * 4096;               // 64KB user stack
pub const USER_MMAP_BASE: u64 = 0x0000_0000_4000_0000;    // 1GB, mmap region

pub const USER_ADDR_MAX: u64 = 0x0000_7FFF_FFFF_FFFF;
const KERNEL_PML4_START: usize = 256;  // PML4[256..511] = kernel space
const ENTRIES_PER_TABLE: usize = 512;
const PAGE_SIZE: u64 = 4096;

const MAX_USER_PAGES: usize = 256;  // Max 256 pages per process = 1MB (MVP limit)
```

#### Types

```zig
/// User address space descriptor
pub const AddressSpace = struct {
    pml4_phys: u64,         // PML4 physical address (for writing to CR3)
    page_count: usize,      // Number of allocated user pages
    pages: [MAX_USER_PAGES]PageRecord,  // Record of each mapped page (for deallocation)
    brk: u64,               // Current heap top
    mmap_next: u64,         // Next mmap allocation address
};

/// Page mapping record
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

#### Public Functions

```zig
/// Create a new user address space
/// 1. Allocate a new PML4 page frame
/// 2. Zero out the lower half [0..255]
/// 3. Copy the upper half [256..511] from the current kernel page table
/// 4. Allocate and map the user stack
/// Returns: AddressSpace or null
pub fn create() ?AddressSpace;

/// Map a page in the user address space
/// Must be called before activate() or while the address space is active
pub fn mapUserPage(as: *AddressSpace, virt: u64, writable: bool) bool;

/// Map an existing physical page in the user address space (used for ELF loading)
pub fn mapUserPagePhys(as: *AddressSpace, virt: u64, phys: u64, writable: bool) bool;

/// Activate the address space (write CR3)
pub fn activate(as: *const AddressSpace) void;

/// Activate the kernel address space (restore original CR3)
/// Used after returning from user mode to kernel mode, if kernel data structures need to be manipulated
pub fn activateKernel() void;

/// Release all page frames of the user address space
/// Includes the PML4 itself and all user pages
/// Does not release kernel-portion page tables (those are shared)
pub fn destroy(as: *AddressSpace) void;

/// Expand the heap (implements the brk system call)
pub fn expandBrk(as: *AddressSpace, new_brk: u64) bool;
```

#### create() Internal Logic

```
1. pml4_phys = pmm.allocFrame() or return null
2. pml4_virt: *[512]u64 = @ptrFromInt(pmm.physToVirt(pml4_phys))
3. Zero the entire PML4: @memset(pml4_virt[0..], 0)
4. Copy upper half from kernel page table:
   kernel_cr3 = saved kernel CR3 value
   kernel_pml4: *[512]u64 = @ptrFromInt(pmm.physToVirt(kernel_cr3))
   for (KERNEL_PML4_START..512) |i| {
       pml4_virt[i] = kernel_pml4[i];  // Copy entries (pointing to the same PDPT page frames)
   }
5. Initialize AddressSpace:
   .pml4_phys = pml4_phys
   .page_count = 0
   .pages = all inactive
   .brk = USER_HEAP_BASE
   .mmap_next = USER_MMAP_BASE
6. Allocate user stack:
   stack_bottom = USER_STACK_TOP - USER_STACK_SIZE
   for each page in [stack_bottom..USER_STACK_TOP]:
     if !mapUserPage(&as, page_addr, true) → destroy(&as), return null
7. return as
```

> **Explanation: Why is copying the PML4 upper half sufficient?**
>
> PML4 entries point to PDPTs. The kernel's PDPT/PD/PT are globally shared — we only copied the
> pointers in the PML4, not a deep copy of the entire page table tree. This means:
> - All processes see the exact same kernel memory mappings (because they point to the same PDPT)
> - If the kernel later adds mappings (modifying PDPT/PD/PT), all processes automatically see them
> - But if the kernel adds new PML4 entries (new 512GB regions), they need to be synced to all processes' PML4s
>   (for the MVP this won't happen — the kernel only uses PML4 entry [511])

#### activate() Internal Logic

```
1. cpu.writeCr3(as.pml4_phys)
   // Writing CR3 automatically flushes the TLB
   // After this, the CPU uses the new page table for address translation
```

#### mapUserPage() Internal Logic

```
1. If page_count >= MAX_USER_PAGES → return false
2. phys = pmm.allocFrame() or return false
3. Need to map in as's page table, not the currently active page table
   The issue here: vmm.mapPage operates on the page table pointed to by the current CR3
   Solution: temporarily switch CR3 → map → switch back
   a. saved_cr3 = cpu.readCr3()
   b. cpu.writeCr3(as.pml4_phys)
   c. vmm.mapPage(virt, phys, writable, user=true)
   d. cpu.writeCr3(saved_cr3)
4. Record in as.pages[page_count]
5. page_count += 1
6. return true
```

> **Explanation: Why do we need to temporarily switch CR3?**
>
> `vmm.mapPage` reads and writes page tables using the PML4 address obtained via `cpu.readCr3()`.
> If we don't switch CR3, `mapPage` would modify the currently active page table (the kernel's), not the new process's.
> Switch CR3 → map → switch back ensures we are operating on the target address space's page table.
>
> An alternative approach would be to modify vmm to accept an explicit PML4 address, but that requires larger changes. Temporarily switching CR3 is sufficient for the MVP.

#### destroy() Internal Logic

```
1. Iterate over as.pages:
   For each active record:
     pmm.freeFrame(record.phys)
     record.active = false
2. Release lower-half intermediate page tables (PDPT/PD/PT page frames):
   Iterate over pml4[0..256], recursively free sub-tables
   (Simplified: MVP can skip freeing intermediate tables, only free leaf pages. Leaking a few pages is acceptable at small scale)
3. pmm.freeFrame(as.pml4_phys)
```

---

## 5. Phase 8c: User Process Loading and Execution

### 5.1 Concept: Jumping from Kernel to User Mode

Getting a user program running requires these steps:

```
1. Prepare the address space (create page table, map code/data/stack)
2. Copy the program code into user space pages
3. Switch to the user address space (write CR3)
4. Set TSS.rsp0 = this process's kernel stack top
5. Jump to Ring 3 via iretq

Detailed look at step 5:

            Kernel Stack
     ┌──────────────────┐
     │ SS = USER_DATA_SEL│  0x18 | 3 = 0x1B (RPL=3)
     │ RSP = user_stack  │  User stack top
     │ RFLAGS = 0x202    │  IF=1 (interrupts enabled)
     │ CS = USER_CODE_SEL│  0x20 | 3 = 0x23 (RPL=3)
     │ RIP = entry_point │  Program entry address
     └──────────────────┘
              ↓
           iretq
              ↓
     CPU sees CS.RPL = 3
     Switches to Ring 3
     Loads SS:RSP as user stack
     Jumps to RIP and begins execution
```

> **Key detail**: The lower 2 bits of CS and SS are the RPL (Requested Privilege Level).
> `USER_CODE_SEL = 0x20`, plus RPL=3 → `0x23`.
> `USER_DATA_SEL = 0x18`, plus RPL=3 → `0x1B`.
> The CPU uses the RPL to determine privilege level switching.

### 5.2 src/process.zig — Process Management

This is a high-level wrapper over task.zig, adding user-mode support.

#### Constants

```zig
const task = @import("task.zig");
const gdt = @import("gdt.zig");
const user_mem = @import("user_mem.zig");
const pmm = @import("pmm.zig");

const KERNEL_STACK_SIZE: usize = 8192; // Kernel stack size per user process
```

#### Types

```zig
/// Process type
pub const ProcessType = enum {
    kernel,    // Kernel task (existing behavior)
    user,      // User-mode process
};

/// Additional information for user-mode processes
/// Stored outside of task.Task (Task struct unchanged, linked by pid)
pub const ProcessInfo = struct {
    pid: u32,
    proc_type: ProcessType,
    address_space: ?user_mem.AddressSpace,
    kernel_stack_phys: u64,          // This process's kernel stack physical page
    kernel_stack_top: u64,           // Kernel stack top virtual address
    entry_point: u64,                // User program entry point
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

#### Global State

```zig
var process_table: [MAX_PROCESSES]ProcessInfo = [_]ProcessInfo{emptyProcessInfo()} ** MAX_PROCESSES;
var kernel_cr3: u64 = 0;  // Save the kernel's original CR3
```

#### Public Functions

```zig
/// Initialize: save kernel CR3
pub fn init() void;

/// Create and start a user process
/// program: user program binary data (ELF or flat binary)
/// name: process name
/// Returns: pid or null
pub fn spawnUser(name: []const u8, program: []const u8) ?u32;

/// Create a user process (from flat binary)
/// entry: entry address
/// code: code data
/// code_vaddr: virtual address to load the code at
pub fn spawnFlat(name: []const u8, code: []const u8, code_vaddr: u64, entry: u64) ?u32;

/// Process exit (called from syscall EXIT)
pub fn exitCurrent(exit_code: i32) noreturn;

/// Get process information
pub fn getProcessInfo(pid: u32) ?*const ProcessInfo;

/// Called during context switch: update TSS.rsp0 and switch address space
pub fn onContextSwitch(new_task_index: usize) void;

/// Get kernel CR3
pub fn getKernelCr3() u64;
```

#### spawnFlat() Internal Logic

```
1. Create user address space: as = user_mem.create() or return null
2. Map code pages in the user address space:
   pages_needed = (code.len + PAGE_SIZE - 1) / PAGE_SIZE
   for 0..pages_needed:
     user_mem.mapUserPage(&as, code_vaddr + i * PAGE_SIZE, false)  // Code pages are read-only
3. Activate the user address space (temporarily) to copy code:
   saved_cr3 = cpu.readCr3()
   cpu.writeCr3(as.pml4_phys)
   @memcpy(user virtual address, code)  // Now the virtual address refers to the user page table
   cpu.writeCr3(saved_cr3)
4. Allocate kernel stack (each user process needs an independent kernel stack):
   kernel_stack_phys = pmm.allocFrame() or cleanup + return null
   kernel_stack_virt = pmm.physToVirt(kernel_stack_phys)
   kernel_stack_top = kernel_stack_virt + PAGE_SIZE
5. Create a task in the task system:
   Use a variant of task.spawn(), or directly manipulate task internals
   Key: the initial stack frame must emulate the iretq-to-Ring-3 format

   Build initial stack (pseudocode):
   push (USER_DATA_SEL | 3)          // ss = 0x1B
   push (USER_STACK_TOP - 8)         // rsp = user stack top
   push 0x202                        // rflags (IF=1)
   push (USER_CODE_SEL | 3)          // cs = 0x23
   push entry                        // rip = user entry point
   push 0 (rax, rbx, ... r15)       // 15 general-purpose registers = 0

6. Record in process_table
7. return pid
```

> **Explanation: Why does each user process need an independent kernel stack?**
>
> When a user program is executing in Ring 3 and an interrupt occurs (e.g., the PIT timer), the CPU needs to switch to Ring 0.
> The CPU gets the kernel stack pointer from TSS.rsp0 and saves the user's register state there.
>
> If two user processes shared a kernel stack, the state saved on the kernel stack when process A is interrupted
> could be overwritten by process B's interrupt. So each user process must have its own kernel stack,
> and TSS.rsp0 must be updated on every context switch.

#### onContextSwitch() Internal Logic

```
1. Find the corresponding ProcessInfo based on new_task_index
2. If it's a kernel task:
   gdt.setKernelStack(default kernel stack)
   cpu.writeCr3(kernel_cr3)
3. If it's a user process:
   gdt.setKernelStack(process_info.kernel_stack_top)
   cpu.writeCr3(process_info.address_space.pml4_phys)
```

### 5.3 Modifying src/task.zig — Adding User-Mode Fields

Minimal field changes to the Task struct:

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
    // New fields
    is_user: bool = false,        // Whether this is a user-mode process
    wake_tick: u64 = 0,           // SYS_SLEEP wake-up time
};
```

> Minimally invasive change. Detailed user-mode information (address space, kernel stack, etc.) is stored
> in process.zig's process_table, linked by pid. We avoid stuffing too much into Task to maintain
> existing code compatibility.

### 5.4 Modifying src/scheduler.zig — Updating TSS on Context Switch

```zig
// In switchFromContext, after switching to the new task:
fn switchFromContext(current_rsp: u64) u64 {
    // ... existing logic ...

    // New: notify the process module to update TSS and CR3
    process.onContextSwitch(next_index);

    return new_task.rsp;
}
```

Also add wake-up checking for blocked tasks in `timerTickFromContext`:

```zig
// New addition in timerTickFromContext:
// Check if blocked tasks should be woken up
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

## 6. Phase 8d: ELF Loader

### 6.1 Concept: What Is ELF

ELF (Executable and Linkable Format) is the standard executable file format in the Linux/Unix world. When you compile a C/Zig program, the output is an ELF file.

ELF file structure (simplified):

```
┌──────────────────────────┐
│ ELF Header (64 bytes)    │  "What is this file"
│   magic: 0x7F 'E' 'L' 'F'│
│   class: 64-bit          │
│   entry: program entry    │
│   phoff: Program Header   │
│          offset           │
│   phnum: Program Header   │
│          count            │
├──────────────────────────┤
│ Program Headers          │  "How to load into memory"
│   [0] LOAD: load code seg│   vaddr=0x400000, filesz=0x1000
│   [1] LOAD: load data seg│   vaddr=0x401000, filesz=0x100
│   ...                    │
├──────────────────────────┤
│ .text (code)             │  Actual machine instructions
├──────────────────────────┤
│ .rodata (read-only data) │  String constants, etc.
├──────────────────────────┤
│ .data (writable data)    │  Global variable initial values
├──────────────────────────┤
│ .bss (zero-initialized)  │  Global variables (no space in file)
└──────────────────────────┘
```

The loader only cares about **Program Headers** (not Section Headers). Each PT_LOAD type Program Header tells us: which segment of the file to load, and at what virtual address to place it.

### 6.2 src/elf.zig — ELF Parser

#### Constants

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

// ELF header size
const ELF_HEADER_SIZE: usize = 64;
const PHDR_ENTRY_SIZE: usize = 56;
```

#### ELF Header Field Offsets

```zig
// We parse using offset + read (not packed struct), consistent with the project style
const OFF_MAGIC: usize = 0;       // [4]u8
const OFF_CLASS: usize = 4;       // u8
const OFF_DATA: usize = 5;        // u8
const OFF_TYPE: usize = 16;       // u16 LE
const OFF_MACHINE: usize = 18;    // u16 LE
const OFF_ENTRY: usize = 24;      // u64 LE
const OFF_PHOFF: usize = 32;      // u64 LE (program header table offset)
const OFF_PHENTSIZE: usize = 54;  // u16 LE
const OFF_PHNUM: usize = 56;      // u16 LE

// Program Header field offsets (within each entry)
const PH_OFF_TYPE: usize = 0;     // u32 LE
const PH_OFF_FLAGS: usize = 4;    // u32 LE
const PH_OFF_OFFSET: usize = 8;   // u64 LE (offset within the file)
const PH_OFF_VADDR: usize = 16;   // u64 LE (virtual address to load at)
const PH_OFF_FILESZ: usize = 32;  // u64 LE (size in the file)
const PH_OFF_MEMSZ: usize = 40;   // u64 LE (size in memory, >= filesz)
```

#### Types

```zig
/// Parse result: a loadable segment
pub const LoadSegment = struct {
    vaddr: u64,        // Target virtual address for loading
    file_offset: u64,  // Offset within the file
    file_size: u64,    // Data size in the file
    mem_size: u64,     // Size in memory (>= file_size, excess is zero-filled = .bss)
    writable: bool,    // Whether writable
    executable: bool,  // Whether executable
};

pub const ParseResult = struct {
    entry_point: u64,
    segments: [8]LoadSegment,   // Up to 8 LOAD segments
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

#### Public Functions

```zig
/// Parse an ELF file, extracting load information
/// data: complete ELF file contents
/// result: output parse result
/// Returns: ParseError
pub fn parse(data: []const u8, result: *ParseResult) ParseError;

/// Load ELF into user address space
/// For each segment returned by parse():
///   1. Map the required pages in address_space (user=true)
///   2. Copy file data to the corresponding virtual address
///   3. Zero-fill the mem_size - file_size portion (.bss)
pub fn load(
    data: []const u8,
    result: *const ParseResult,
    addr_space: *user_mem.AddressSpace,
) bool;
```

#### parse() Internal Logic

```
1. If data.len < ELF_HEADER_SIZE → return .too_small
2. Verify magic: data[0..4] != ELF_MAGIC → return .bad_magic
3. Verify class: data[OFF_CLASS] != ELFCLASS64 → return .not_64bit
4. Verify data encoding: data[OFF_DATA] != ELFDATA2LSB → return .not_little_endian
5. Verify type: readLe16(data, OFF_TYPE) != ET_EXEC → return .not_executable
6. Verify machine: readLe16(data, OFF_MACHINE) != EM_X86_64 → return .not_x86_64
7. entry = readLe64(data, OFF_ENTRY)
8. phoff = readLe64(data, OFF_PHOFF)
9. phentsize = readLe16(data, OFF_PHENTSIZE)
10. phnum = readLe16(data, OFF_PHNUM)
11. result.entry_point = entry
12. result.segment_count = 0
13. Iterate over program headers:
    for 0..phnum:
      ph_offset = phoff + i * phentsize
      If ph_offset + PHDR_ENTRY_SIZE > data.len → return .invalid_segment
      p_type = readLe32(data, ph_offset + PH_OFF_TYPE)
      If p_type != PT_LOAD → continue
      If result.segment_count >= 8 → return .too_many_segments
      Fill LoadSegment:
        vaddr = readLe64(data, ph_offset + PH_OFF_VADDR)
        file_offset = readLe64(data, ph_offset + PH_OFF_OFFSET)
        file_size = readLe64(data, ph_offset + PH_OFF_FILESZ)
        mem_size = readLe64(data, ph_offset + PH_OFF_MEMSZ)
        flags = readLe32(data, ph_offset + PH_OFF_FLAGS)
        writable = (flags & PF_W) != 0
        executable = (flags & PF_X) != 0
      Validate:
        If file_offset + file_size > data.len → return .invalid_segment
        If vaddr > user_mem.USER_ADDR_MAX → return .invalid_segment
      result.segments[result.segment_count] = segment
      result.segment_count += 1
14. return .ok
```

#### load() Internal Logic

```
1. Iterate over result.segments[0..result.segment_count]:
   for each segment:
     a. Calculate required pages:
        start_page = segment.vaddr & ~0xFFF
        end_addr = segment.vaddr + segment.mem_size
        end_page = (end_addr + 0xFFF) & ~0xFFF
        pages = (end_page - start_page) / PAGE_SIZE
     b. Map pages:
        for 0..pages:
          user_mem.mapUserPage(addr_space, start_page + i * PAGE_SIZE, segment.writable)
     c. Activate address space and copy data:
        saved_cr3 = cpu.readCr3()
        cpu.writeCr3(addr_space.pml4_phys)
        dest: [*]u8 = @ptrFromInt(segment.vaddr)
        @memcpy(dest[0..segment.file_size], data[segment.file_offset..][0..segment.file_size])
        // Zero-fill .bss portion
        if (segment.mem_size > segment.file_size):
          @memset(dest[segment.file_size..segment.mem_size], 0)
        cpu.writeCr3(saved_cr3)
2. return true
```

#### LE Read Utilities

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

> **Note**: ELF files use little-endian byte order, which is the same as our x86_64 CPU's byte order.
> This is the opposite of network protocols (big-endian). That's why we use readLe16 rather than readBe16 here.

---

## 7. Phase 8e: Process Lifecycle

### 7.1 Concept: The Life of a Process

```
          spawnFlat / spawnUser
                  │
                  ↓
            ┌──────────┐
            │  READY   │ ←─── Created, waiting to be scheduled
            └────┬─────┘
                 │ Selected by the scheduler
                 ↓
            ┌──────────┐
            │ RUNNING  │ ←─── Executing on CPU (Ring 3)
            └─┬──┬──┬──┘
              │  │  │
   Interrupt/ │  │  │ SYS_SLEEP
   syscall    │  │  ↓
              │  │ ┌──────────┐
              │  │ │ BLOCKED  │ ←── Waiting on condition (sleep, I/O)
              │  │ └────┬─────┘
              │  │      │ Condition met (wake_tick reached)
              │  │      ↓
              │  │   Back to READY
              │  │
              │  │ SYS_EXIT
              │  ↓
              │ ┌──────────┐
              │ │ FINISHED │ ←── Process ended, awaiting cleanup
              │ └──────────┘
              │       │
              │       ↓ Reclaim resources
              │    (slot freed)
              │
              │ Time slice expired
              ↓
          Back to READY (preemption)
```

### 7.2 First Jump from Kernel Mode to User Mode

When a newly created user process is scheduled for the first time, it needs to "jump" from kernel mode to Ring 3. This is achieved by constructing a fake interrupt return frame on the kernel stack:

```zig
/// In process.zig
/// Build the initial stack frame for iretq to Ring 3
fn buildUserInitialStack(kernel_stack_top: u64, entry: u64, user_stack_top: u64) u64 {
    var sp = kernel_stack_top;

    // iretq will pop these 5 values
    pushStack(&sp, gdt.USER_DATA_SEL | 3);   // ss (RPL=3)
    pushStack(&sp, user_stack_top);            // rsp
    pushStack(&sp, 0x202);                     // rflags (IF=1)
    pushStack(&sp, gdt.USER_CODE_SEL | 3);    // cs (RPL=3)
    pushStack(&sp, entry);                     // rip

    // 15 general-purpose registers (all zeroed, clean initial state)
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

When the scheduler selects this task, `switchFromContext` returns this RSP. The interrupt return path pops 15 registers and then executes `iretq`. The CPU sees CS.RPL=3 and automatically switches to Ring 3 to execute user code.

> **Explanation: This is an elegant trick**
>
> We don't have a dedicated "enter user mode" instruction. Instead, we reuse the interrupt return mechanism —
> `iretq` doesn't know whether it's actually "returning"; it simply pops RIP/CS/RFLAGS/RSP/SS from the stack and jumps.
> If we set CS to a user-mode selector, iretq will "return" to a user-mode program that was never "interrupted" in the first place.
> All operating systems use this trick.

---

## 8. Phase 8f: Shell Integration

### 8.1 Embedded Test Programs

In the MVP phase, we don't load ELF files from disk. Instead, we embed a few simple user-mode test programs (written in assembly, as byte arrays) directly in the kernel.

#### Test Program 1: hello_user (minimal viable program)

```zig
// In shell_cmds.zig or a separate user_programs.zig

/// Simplest user-mode program: print "Hello from Ring 3!" then exit
/// Hand-written x86_64 machine code
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

> **Explanation: Why hand-written machine code?**
>
> User programs run in Ring 3, in a completely different address space. They cannot call kernel Zig functions;
> the only way to communicate is through system calls (int 0x80). The simplest way to test is to hand-write a few instructions.
>
> Later, we can cross-compile user-mode programs with Zig (target: x86_64-freestanding-none),
> link them at a fixed address, and output flat binary or ELF.

#### Test Program 2: loop_user (test preemption)

```zig
/// Infinite loop program: test whether user-mode preemption works
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
    // jmp -46              ; jump back to start (loop)
    0xeb, 0xd2,
    // msg: "tick\n"
    't', 'i', 'c', 'k', '\n',
};
```

### 8.2 New Shell Commands

```zig
// Add to the commands array in shell_cmds.zig
.{ .name = "runuser", .description = "Run a built-in user-mode test program", .handler = cmdRunuser },
.{ .name = "ps", .description = "Show process list with type info", .handler = cmdPs },
.{ .name = "killuser", .description = "Kill a user process by PID", .handler = cmdKilluser },
.{ .name = "syscallstat", .description = "Show syscall statistics", .handler = cmdSyscallstat },
```

#### cmdRunuser

```
Usage: runuser <program>
Options: runuser hello     — run hello_user
         runuser loop      — run loop_user
         runuser <addr>    — run ELF (future)

1. Select the embedded program based on the argument
2. process.spawnFlat(name, program_bytes, USER_TEXT_BASE, USER_TEXT_BASE)
3. Display: "Spawned user process 'hello' (pid N)"
4. Polling-style loop to wait (or return immediately and let the scheduler run the user process in the background)
```

#### cmdPs (enhanced existing ps command)

```
Usage: ps

PID  Name       Type    State       Ticks   Switches
1    shell      kernel  running     50000   300
2    worker     kernel  ready       12000   150
3    hello      user    finished    5       1
4    loop       user    ready       100     10
```

#### cmdKilluser

```
Usage: killuser <pid>

1. Get ProcessInfo, confirm it is of type user
2. process.exitCurrent or task.kill
3. Release address space
4. Display result
```

#### cmdSyscallstat

```
Usage: syscallstat

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

## 9. Integration and Initialization Order

### 9.1 src/main.zig Modifications

Add to the existing initialization sequence:

```zig
// Existing
gdt.init();
idt.init();

// New (after task.init)
const process = @import("process.zig");
process.init();
log.kprintln("[proc] Process subsystem initialized", .{});
```

### 9.2 Initialization Dependency Chain

```
gdt.init()      ← GDT + TSS (existing)
  ↓
idt.init()      ← IDT (existing, syscallStub changed to full dispatch)
  ↓
pmm.init()      ← Physical memory management (existing)
  ↓
vmm init        ← Virtual memory (existing, initial page table set up by Limine)
  ↓
heap.init()     ← Kernel heap (existing)
  ↓
task.init()     ← Task management (existing, minor changes)
  ↓
process.init()  ← New: save kernel CR3, initialize process_table
  ↓
scheduler.init() ← Scheduler (minor changes)
```

### 9.3 New Files List

```
src/
├── syscall.zig      # System call dispatch + implementation
├── user_mem.zig     # User address space management
├── elf.zig          # ELF parser
├── process.zig      # Process management
└── user_programs.zig # Embedded user-mode test programs (machine code)
```

### 9.4 Modified Files List

```
src/idt.zig          # syscallStub changed to full syscall dispatch
src/task.zig         # Task gets is_user and wake_tick fields
src/scheduler.zig    # switchFromContext calls process.onContextSwitch
                     # timerTick checks blocked task wake-up
src/shell_cmds.zig   # New commands: runuser, ps, killuser, syscallstat
src/main.zig         # Add process.init() call
```

---

## 10. QEMU Testing Methods

### 10.1 Testing hello_user

```
MerlionOS> runuser hello
Spawned user process 'hello' (pid 2)
Hello from Ring 3!
Process 'hello' exited with code 0
```

If you see "Hello from Ring 3!", it means:
- User address space creation succeeded
- Ring 0 → Ring 3 transition succeeded
- int 0x80 → syscall dispatch → SYS_WRITE succeeded
- SYS_EXIT correctly reclaimed the process

### 10.2 Testing loop_user + Preemption

```
MerlionOS> runuser loop &     # Run in background (if supported)
Spawned user process 'loop' (pid 3)
tick
tick
tick
MerlionOS> ps                  # Verify shell is still usable (preemption works)
MerlionOS> killuser 3
Killed process 3
```

### 10.3 Testing Protection Mechanisms

```
# User program attempts to execute a privileged instruction → should trigger #GP, kernel kills the process
# User program attempts to access a kernel address → should trigger #PF, kernel kills the process
```

Dedicated test programs can be created:

```zig
/// Attempt to execute CLI (privileged instruction), should be killed
pub const bad_cli = [_]u8{
    0xFA,       // cli — not allowed in Ring 3
    0xEB, 0xFE, // jmp $ (should never reach here)
};

/// Attempt to read kernel memory, should trigger Page Fault
pub const bad_read = [_]u8{
    // mov rax, 0xFFFFFFFF80000000  ; kernel address
    0x48, 0xB8, 0x00, 0x00, 0x00, 0x80, 0xFF, 0xFF, 0xFF, 0xFF,
    // mov al, [rax]               ; attempt to read
    0x8A, 0x00,
    0xEB, 0xFE, // jmp $
};
```

### 10.4 Test Case Checklist

```
- [ ] hello_user: prints and exits normally
- [ ] loop_user: prints in a loop + yield, verify scheduler works
- [ ] bad_cli: verify #GP is caught, process is killed without kernel crash
- [ ] bad_read: verify #PF is caught, process is killed
- [ ] Run multiple user processes + shell simultaneously, verify preemptive scheduling
- [ ] ps command shows correct process types and states
- [ ] syscallstat shows correct call counts
```

---

## 11. Security Model Summary

```
Protection layers:

1. CPU Hardware (Ring 0 vs Ring 3)
   - User code cannot execute CLI/STI/HLT/LGDT/LIDT/MOV CR*/IN/OUT and other privileged instructions
   - Violation → #GP exception → kernel catches it → kills the process

2. Page Tables (U/S bit)
   - User pages marked U/S=1, kernel pages U/S=0
   - Ring 3 code accessing a page with U/S=0 → #PF exception → kernel catches it → kills the process

3. System Call Parameter Validation
   - All user-provided pointers must be validated to be within the user address space
   - All user-provided lengths must be validated to not exceed bounds
   - The kernel does not directly dereference user pointers (copies to kernel buffer first)

4. TSS.rsp0 Switching
   - TSS.rsp0 is updated on every context switch
   - Ensures the correct process's kernel stack is used when an interrupt occurs
   - Prevents information leakage between processes via the kernel stack
```

---

## Appendix: Implementation Order Checklist

```
Phase 8a: syscall Infrastructure
- [ ] src/syscall.zig — syscall dispatch + SYS_WRITE + SYS_EXIT + SYS_GETPID
- [ ] Modify src/idt.zig — syscallStub changed to full dispatch

Phase 8b: User Address Space
- [ ] src/user_mem.zig — create / mapUserPage / activate / destroy
- [ ] Verify: create address space, map a page, switch CR3, no crash

Phase 8c: User Processes
- [ ] src/process.zig — init / spawnFlat / onContextSwitch / exitCurrent
- [ ] src/user_programs.zig — hello_user machine code
- [ ] Modify src/task.zig — add is_user, wake_tick
- [ ] Modify src/scheduler.zig — call process.onContextSwitch on switch
- [ ] Verify: runuser hello prints "Hello from Ring 3!"

Phase 8d: ELF Loader
- [ ] src/elf.zig — parse / load
- [ ] Verify: parse an ELF, print segment information

Phase 8e: Process Lifecycle
- [ ] syscall.zig additions: SYS_READ / SYS_YIELD / SYS_SLEEP / SYS_BRK
- [ ] scheduler.zig: blocked task wake-up
- [ ] Verify: loop_user + preemption + killuser

Phase 8f: Shell Integration
- [ ] shell_cmds.zig: runuser / ps / killuser / syscallstat
- [ ] user_programs.zig: loop_user / bad_cli / bad_read
- [ ] Verify: all test cases
- [ ] main.zig: add process.init()
```
