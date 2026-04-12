# MerlionOS-Zig User Mode: Concepts and Explanations

> This is the **conceptual guide** for user mode, intended to help readers understand the core concepts of x86_64 user mode.
> The companion implementation spec is at [../spec/DESIGN-USERMODE-EN.md](../spec/DESIGN-USERMODE-EN.md).
>
> This document is not a "how to write the code" manual; it is the "why it's written this way" background.
> Good to read before the Spec, or whenever you hit an implementation detail you don't understand.

## Table of Contents

1. [What Is User Mode](#1-what-is-user-mode)
2. [Privilege Level Switching Mechanisms](#2-privilege-level-switching-mechanisms)
3. [Key Hardware Mechanisms (GDT / TSS / Page Tables)](#3-key-hardware-mechanisms-gdt--tss--page-tables)
4. [What Is a System Call](#4-what-is-a-system-call)
5. [Virtual Address Space Layout](#5-virtual-address-space-layout)
6. [syscall Dispatch: From int 0x80 to a C Function](#6-syscall-dispatch-from-int-0x80-to-a-c-function)
7. [Safe Handling of User-Space Pointers](#7-safe-handling-of-user-space-pointers)
8. [How syscallStub's Stack Offsets Are Calculated](#8-how-syscallstubs-stack-offsets-are-calculated)
9. [Per-Process Page Tables: Why Isolate Address Spaces](#9-per-process-page-tables-why-isolate-address-spaces)
10. [The Semantics of Copying the PML4 Upper Half](#10-the-semantics-of-copying-the-pml4-upper-half)
11. [Why mapUserPage Temporarily Switches CR3](#11-why-mapuserpage-temporarily-switches-cr3)
12. [Jumping from Kernel to User Mode: The iretq Trick](#12-jumping-from-kernel-to-user-mode-the-iretq-trick)
13. [Why Each Process Needs Its Own Kernel Stack](#13-why-each-process-needs-its-own-kernel-stack)
14. [What ELF Is, and Why the Loader Only Looks at Program Headers](#14-what-elf-is-and-why-the-loader-only-looks-at-program-headers)
15. [Process Lifecycle](#15-process-lifecycle)
16. [Why We Use Hand-Written Machine Code for Test Programs](#16-why-we-use-hand-written-machine-code-for-test-programs)
17. [Security Model Summary](#17-security-model-summary)

---

## 1. What Is User Mode

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

---

## 2. Privilege Level Switching Mechanisms

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

---

## 3. Key Hardware Mechanisms (GDT / TSS / Page Tables)

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

---

## 4. What Is a System Call

User programs cannot directly operate hardware, but they need to do I/O (printing, reading files, sending network packets, etc.). How? Through system calls — they "request" the kernel to do it on their behalf:

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

---

## 5. Virtual Address Space Layout

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

## 6. syscall Dispatch: From int 0x80 to a C Function

When a user program executes `int 0x80`, the CPU jumps to the handler pointed to by IDT[0x80]. We need to:

1. **Save all registers** (the user program's state must not be lost)
2. **Read rax** (syscall number)
3. **Dispatch to the corresponding handler**
4. **Place the return value in rax**
5. **Restore registers, iretq back to user mode**

The register convention follows Linux: rax carries the syscall number and return value; rdi/rsi/rdx/r10/r8/r9 carry up to 6 arguments. Note that the 4th argument uses r10 rather than rcx — because the `syscall` instruction clobbers rcx. We use `int 0x80` so this doesn't strictly matter, but keeping the same convention makes future migration easier.

---

## 7. Safe Handling of User-Space Pointers

**Why can't we just use the user-provided pointer directly?**

Although our kernel can access all memory, the `buf_ptr` from the user might:
- Point to kernel code/data → leaking kernel information
- Point to an unmapped page → triggering a kernel page fault (if the kernel doesn't handle it, it crashes)
- Point to another process's memory (if we later support multiple address spaces)

Therefore we must first verify that the address falls within the user space range, then verify that the page table actually has a mapping. After validation passes, copy user data to a kernel buffer first, and pass the **kernel buffer** to kernel internal functions — this also defends against TOCTOU (time-of-check to time-of-use) races.

---

## 8. How syscallStub's Stack Offsets Are Calculated

The assembly stub performs 15 consecutive `pushq` operations in this order:

```
rax, rbx, rcx, rdx, rbp, rsi, rdi, r8, r9, r10, r11, r12, r13, r14, r15
```

The stack grows downward, so the last push (r15) is at the lowest address (rsp+0). Each value takes 8 bytes, giving:

```
RSP+112: rax  (1st push)
RSP+104: rbx  (2nd push)
RSP+96:  rcx  (3rd push)
RSP+88:  rdx  (4th push)
RSP+80:  rbp  (5th push)
RSP+72:  rsi  (6th push)
RSP+64:  rdi  (7th push)
RSP+56:  r8   (8th push)
RSP+48:  r9   (9th push)
RSP+40:  r10  (10th push)
RSP+32:  r11  (11th push)
RSP+24:  r12  (12th push)
RSP+16:  r13  (13th push)
RSP+8:   r14  (14th push)
RSP+0:   r15  (15th push)
```

When calling `syscallDispatch(number, arg1, arg2, arg3, arg4, arg5)`, we read the argument values from the stack (not from live registers, because some registers are already committed by the calling convention). The System V AMD64 ABI uses rdi/rsi/rdx/rcx/r8/r9 for the first six arguments, so a register-remapping step is needed.

---

## 9. Per-Process Page Tables: Why Isolate Address Spaces

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

---

## 10. The Semantics of Copying the PML4 Upper Half

**Why is copying the PML4 upper half sufficient?**

PML4 entries point to PDPTs. The kernel's PDPT/PD/PT are globally shared — we only copied the pointers in the PML4, not a deep copy of the entire page table tree. This means:

- All processes see the exact same kernel memory mappings (because they point to the same PDPT)
- If the kernel later adds mappings (modifying PDPT/PD/PT), all processes automatically see them
- But if the kernel adds new PML4 entries (new 512GB regions), they need to be synced to all processes' PML4s
  (for the MVP this won't happen — the kernel only uses PML4 entry [511])

---

## 11. Why mapUserPage Temporarily Switches CR3

`vmm.mapPage` reads and writes page tables using the PML4 address obtained via `cpu.readCr3()`. If we don't switch CR3, `mapPage` would modify the currently active page table (the kernel's), not the new process's. Switch CR3 → map → switch back ensures we are operating on the target address space's page table.

An alternative approach would be to modify vmm to accept an explicit PML4 address, but that requires larger changes. Temporarily switching CR3 is sufficient for the MVP.

---

## 12. Jumping from Kernel to User Mode: The iretq Trick

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

**Key detail**: The lower 2 bits of CS and SS are the RPL (Requested Privilege Level).
`USER_CODE_SEL = 0x20`, plus RPL=3 → `0x23`.
`USER_DATA_SEL = 0x18`, plus RPL=3 → `0x1B`.
The CPU uses the RPL to determine privilege level switching.

**This is an elegant trick**: We don't have a dedicated "enter user mode" instruction. Instead, we reuse the interrupt return mechanism — `iretq` doesn't know whether it's actually "returning"; it simply pops RIP/CS/RFLAGS/RSP/SS from the stack and jumps. If we set CS to a user-mode selector, iretq will "return" to a user-mode program that was never "interrupted" in the first place. All operating systems use this trick.

---

## 13. Why Each Process Needs Its Own Kernel Stack

When a user program is executing in Ring 3 and an interrupt occurs (e.g., the PIT timer), the CPU needs to switch to Ring 0. The CPU gets the kernel stack pointer from TSS.rsp0 and saves the user's register state there.

If two user processes shared a kernel stack, the state saved on the kernel stack when process A is interrupted could be overwritten by process B's interrupt. So each user process must have its own kernel stack, and TSS.rsp0 must be updated on every context switch.

---

## 14. What ELF Is, and Why the Loader Only Looks at Program Headers

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

**The loader only cares about Program Headers (not Section Headers)**. Section Headers (.text, .data, .bss names, etc.) are used by linkers and debuggers; they are irrelevant at runtime. Each PT_LOAD type Program Header tells us: which segment of the file to load, and at what virtual address to place it.

> ELF files use little-endian byte order, which is the same as our x86_64 CPU's byte order.
> This is the opposite of network protocols (big-endian). That's why the code uses readLe16 rather than readBe16.

---

## 15. Process Lifecycle

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

---

## 16. Why We Use Hand-Written Machine Code for Test Programs

User programs run in Ring 3, in a completely different address space. They cannot call kernel Zig functions; the only way to communicate is through system calls (int 0x80). The simplest way to test is to hand-write a few instructions.

Later, we can cross-compile user-mode programs with Zig (target: x86_64-freestanding-none), link them at a fixed address, and output flat binary or ELF. But for the MVP, a few dozen bytes of hand-written machine code is enough to validate the whole Ring 0 → Ring 3 → syscall → Ring 0 path.

---

## 17. Security Model Summary

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

Together these four layers form the user-mode security boundary: hardware mechanisms (Ring / page tables) provide mandatory isolation, while software mechanisms (parameter validation / TSS switching) ensure that the kernel itself will not be brought down by malicious or buggy user-mode input.
