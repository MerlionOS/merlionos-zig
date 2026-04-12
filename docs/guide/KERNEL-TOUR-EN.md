# MerlionOS-Zig Kernel Tour (Phase 1-6)

> This document is a guided walkthrough of the code. If you're looking for
> an authoritative, spec-level description of the implementation, start with
> [`docs/spec/DESIGN.md`](../spec/DESIGN.md); the networking stack is
> covered in [`docs/spec/DESIGN-TCPIP.md`](../spec/DESIGN-TCPIP.md).
>
> This tour takes a different tone: instead of enumerating every field,
> we'll walk you through the files under `src/` in order, explaining
> "why it's written this way" and pointing out the small pitfalls each
> layer hides.

---

## 1. Introduction: What is this thing?

MerlionOS-Zig is an **x86_64 bare-metal kernel** written in Zig 0.15,
booted via the Limine bootloader. It was inspired by the Rust version of
[MerlionOS](https://github.com/lai3d/merlionos), but this is not a
line-by-line port — it's a reimplementation whose goal is to let Zig's
comptime, explicit allocators, and error unions flow naturally into the
kernel code.

What it **is**:

- A small OS you can boot in QEMU and interact with
- It has GDT/IDT, PIC/PIT, paging, a heap, a scheduler, a VFS, PCI, e1000,
  and basic ARP/ICMP
- A "good-enough example" for learners to browse

What it is **not**:

- Not a POSIX-compatible OS
- No userspace processes (the scheduler currently only runs kernel threads)
- No disks / block devices / real filesystem (the VFS lives entirely in memory)
- Not production code — it's deliberately written to be "just enough and
  easy to read"

Stages completed so far: **Phase 1-6**. The PCI / e1000 / ARP / ICMP / UDP
networking-stack skeleton that follows is an additional bolt-on. We'll
go through it phase by phase.

---

## 2. Phase 1 — Boot: from UEFI to `_start`

**Key files: `src/limine.zig`, `src/main.zig`, `linker.ld`, `limine.conf`**

Traditional x86 boot has three painful stages: 16-bit real mode →
32-bit protected mode → 64-bit long mode. We didn't want to write that
trampoline ourselves, so we picked the **Limine** protocol: Limine takes
us from UEFI/BIOS all the way into long mode, loads the kernel ELF, and
then jumps **directly** into our `_start` with the CPU already in 64-bit
long mode.

### 2.1 Higher-Half Kernel

Take a look at `linker.ld`: the kernel is linked at `0xffffffff80000000`
— the top 2 GiB of the x86_64 virtual address space. This is called
"higher-half". Why?

- When we eventually support userspace, the low half can be handed
  over entirely to user code
- The kernel code always lives at a fixed, process-independent location
- The kernel page tables naturally split into "shared upper half" and
  "per-process private lower half"

Limine builds an initial page table for us and also exposes physical
memory as an identity-mapped region called HHDM (Higher Half Direct
Map) — the kernel can access any physical page directly via
`phys + hhdm_offset`.

### 2.2 Handshaking with Limine

`src/limine.zig` is just a collection of extern structs: request
structures (`FramebufferRequest`, `MemmapRequest`, `HhdmRequest`) carry
magic IDs, and response structures hold the data Limine fills in for
us. The key line:

```zig
pub export var memmap_request: MemmapRequest linksection(".limine_requests") = .{...};
```

`linksection(".limine_requests")` drops these structures into a
dedicated section defined by the linker script, sandwiched between
`requests_start_marker` and `requests_end_marker`. Limine scans that
region to find our requests and writes back response pointers.

### 2.3 The opening lines of `_start`

Open `src/main.zig`: the first few lines of `_start` are almost a
textbook "minimum verifiable boot": bring up the serial COM1, print an
"I'm alive" line to serial, read the HHDM offset, then initialize VGA
text mode. As long as these two output channels can flush characters,
we know:

1. Limine really did drop us into 64-bit mode
2. Our linker script isn't broken
3. Port I/O and basic MMIO work

From here on, each completed subsystem calls `log.kprintln` to announce
itself — serial and VGA "dual-broadcast". That's why `src/log.zig` is
only 17 lines: all it does is feed the same formatted text to two
writers.

---

## 3. Phase 2 — CPU initialization: GDT / TSS / IDT / PIC / PIT

**Key files: `src/gdt.zig`, `src/idt.zig`, `src/cpu.zig`, `src/pic.zig`, `src/pit.zig`**

Limine has already set up GDT/IDT for us — **but those are Limine's**,
and may be reclaimed at any time (bootloader-reclaimable region), so we
have to take control back.

### 3.1 Why rebuild the GDT?

`src/gdt.zig` has 7 descriptors:

```
[0] null
[1] kernel code   (selector 0x08)
[2] kernel data   (0x10)
[3] user   data   (0x18)
[4] user   code   (0x20)
[5..6] TSS (takes two slots, because a 64-bit TSS descriptor is 16 bytes)
```

After loading, a bit of inline assembly reloads `ds/es/fs/gs/ss`, and
then a "fake far jump"
(`pushq $0x08; leaq 1f(%rip); pushq %rax; lretq; 1:`) reloads CS —
x86_64 doesn't allow you to `mov` into CS directly; you have to use
far-return / iret-style "pop from stack" instructions.

### 3.2 Why a TSS?

In 64-bit mode the TSS no longer drives context switching, but it's
**still useful**:

- `rsp0`: on a ring 3→ring 0 switch, the CPU automatically switches
  to this stack (we'll need it when we do userspace)
- `ist1..ist7`: the Interrupt Stack Table. We place the **double
  fault** (vector 8) on IST1, with a dedicated 4 KiB stack to catch
  it — even if the normal kernel stack is trashed, the double fault
  handler still has a clean stack. That's what `tss.ist1 = ...` in
  `gdt.init()` and the `ist=1` argument in `makeGate(..., 1, 0x8E)`
  in `idt.zig` are about.

### 3.3 The IDT and interrupt stubs

`src/idt.zig` populates 256 gate descriptors, most of which point to a
default "unhandled interrupt" stub. The ones we care about:

- `0/1/3/6/8/13/14`: CPU exceptions (divide-by-zero, debug, breakpoint,
  invalid opcode, double fault, #GP, #PF)
- `32` (IRQ0) → PIT timer
- `33` (IRQ1) → keyboard
- `0x80` → placeholder syscall gate (DPL=3)
- `0x81` → a user-usable "kernel yield" software interrupt (more
  on this later)

Each stub is a `callconv(.naked)` naked function with hand-written
assembly inside. Why? Because an interrupt entry has to:

1. Save registers immediately
2. Prevent the compiler from inserting a prologue/epilogue
3. Return with `iretq`, not `ret`

`pushRegsAndCall` is the generic path; `pushFullRegsAndSwitch` is
**scheduler-specific**: it saves **all 15 GPRs**, hands the current
`rsp` to `irq0Inner` or `yieldInner` on the Zig side, and those
functions can decide to return **another task's** rsp — after which
`movq %rax, %rsp` completes the context switch (swap stacks, and every
register that gets popped belongs to the other task).

### 3.4 Why remap the PIC?

An old-school 8259 PIC powers up with IRQ0..7 mapped to interrupt
vectors **0x08..0x0F** — which **collides badly** with the CPU's own
exception vectors (0..31). Once a timer interrupt fires, the CPU
would think it's a double fault.

So the first thing `src/pic.zig` does is change PIC1's offset to 32
and PIC2's to 40:

```
ICW1_INIT → begin initialization
ICW2      → new vector offset
ICW3      → tell PIC1 the slave is on IRQ2; tell PIC2 it is that slave
ICW4      → use 8086 mode
```

Finally, `outb(PIC1_DATA, 0xFC)` unmasks IRQ0 (timer) and IRQ1
(keyboard); everything else is masked. Crude but sufficient.

### 3.5 PIT = heartbeat

`src/pit.zig` is very short: write `0x36` (channel 0, rate generator)
to the command port, then write the divisor `1_193_182 / hz`. We pass
100 Hz, so IRQ0 fires every 10 ms. That heartbeat is later shared by
the scheduler's preemption, the `sleep` command, and `uptime`.

---

## 4. Phase 3 — Memory: three layers of abstraction

**Key files: `src/pmm.zig`, `src/vmm.zig`, `src/heap.zig`**

Memory management is the subsystem in an OS most easily written as a
giant tangled mess. We honestly split it into three layers:

```
             heap (std.mem.Allocator)         ← arbitrary bytes, free when done
                     │ asks the layer below when it needs a 4 KiB page
                     ▼
             vmm (virtual→physical, 4-level page tables)  ← maps/unmaps by page
                     │ asks the layer below when it needs one physical page
                     ▼
             pmm (bitmap)                     ← manages physical page frames
                     │
                     ▼
             Limine memory map
```

### 4.1 PMM: bitmap + HHDM

`src/pmm.zig` is deliberately plain: a `[MAX_PAGES/8]u8` bitmap, where
1 means "used/unavailable". `init()` first fills the whole bitmap with
0xFF (everything unavailable), then walks the `USABLE` entries of the
Limine memmap and clears the corresponding bits to 0 (= available).

`physToVirt(phys) = phys + hhdm_offset` lets us read and write any
physical address directly — especially handy in the VMM, since
manipulating page tables is essentially "manipulating a chunk of
physical memory".

### 4.2 VMM: the x86_64 4-level page tables

Look at `src/vmm.zig::mapPage`. The x86_64 virtual address layout:

```
  63       48 47   39 38   30 29   21 20   12 11   0
  |  sign   | PML4 | PDPT | PD  | PT  | offset |
           \__9__/\__9__/\__9__/\__9__/\__12__/
```

`mapPageWithFlags` extracts these four 9-bit fields and descends level
by level. `getOrCreateTable` notices when the next level doesn't
exist, allocates a physical page via `pmm.allocFrame()`, zeroes it
through HHDM, and writes it back to the upper-level entry. At the end:

```zig
pt[pt_idx] = (phys & ...) | flags;
asm volatile ("invlpg (%[addr])" ...);
```

`invlpg` is mandatory — the TLB caches the old mapping, and without
the flush, the map you just created may be "temporarily invisible" to
the CPU.

Note that we **never build the top-level PML4 ourselves**. The table
CR3 points to is the one Limine left for us. We just incrementally
hang new entries off it. That's another benefit of the higher-half
design: Limine has already mapped the kernel image and HHDM into the
upper half, and all we have to do is add a few new mappings for the
heap, device MMIO, etc.

### 4.3 Heap: first-fit free list

`src/heap.zig` is a classic "teaching-style heap allocator":

- Pre-allocates a 4 MiB virtual region starting at `0xFFFF_C000_0000_0000`
- `init()` populates all 4 MiB using `pmm.allocFrame + vmm.mapPage`
- A single `FreeBlock` free list, first-fit strategy
- On split, if the remainder is too small, the whole block is handed
  out to avoid producing overly fragmented free blocks
- Exposed as a standard `std.mem.Allocator`, so kernel code can just
  do `try allocator.alloc(T, n)`

There's a lovely Zig-specific twist here: `std.mem.Allocator` is a
runtime-polymorphic vtable, so as long as we provide `alloc` / `free`,
every std container comes along for the ride — `std.ArrayList` and
friends work directly inside the kernel.

---

## 5. Phase 4 — Keyboard and shell

**Key files: `src/keyboard.zig`, `src/shell.zig`, `src/shell_cmds.zig`**

### 5.1 Three kinds of PS/2 scancode traps

The keyboard controller coughs up scancodes on port `0x60`. The flow
looks like this:

1. `0xE0` prefix → the next byte is an "extended key" (arrows, Home, End...)
2. bit 7 = 1 → this is a "release" (key up); otherwise it's a "make" (key down)
3. Certain keys (Shift `0x2A/0x36`, Ctrl `0x1D`) are modifiers, so they
   only update state and don't produce events

`src/keyboard.zig::handleInterrupt` uses three `var`s (`shift_pressed`,
`ctrl_pressed`, `extended`) to track the state machine, translates
printable keys to ASCII and function keys to a `KeyEvent` enum, and
pushes into a 128-entry ring buffer.

This ISR **doesn't block and doesn't allocate**. It only does "read the
port, table lookup, enqueue, EOI" — the complex line editing happens
later in user context (the shell). This is a general pattern: ISRs
should be short, and the consumer pulls from them.

### 5.2 Shell: line editing + history

`src/shell.zig` is just a `while (true)`:

```
read a KeyEvent →
  enter    → hand input_buf to executeCommand
  backspace / delete / arrows → edit buffer, repaint line
  char     → insert character, repaint
```

Up/down arrows walk history, left/right move the cursor — nothing
fancy, but crucial to the feel of "this is a real interactive shell".
The actual commands (`help`, `ls`, `cat`, `ps`, `ping`, etc.) live in
`src/shell_cmds.zig`, which is the longest file in the project
(1200+ lines) and is mostly "command dispatch + output formatting".

---

## 6. Phase 5 — Multitasking: cooperative + preemptive

**Key files: `src/task.zig`, `src/scheduler.zig`, `src/context_switch.S`,
and `irq0Stub`/`yieldStub` in `src/idt.zig`**

This is the most "magical" part of the whole kernel. Let's go through it
carefully.

### 6.1 The Task struct

In `src/task.zig`, `Task` is a POD: pid, name, state (`ready/running/blocked/finished`),
**rsp**, stack range, stat counters. MAX_TASKS = 32, and each task has a
16 KiB kernel stack (allocated from a static `stack_pool`). The bottom
of each stack is stamped with a canary `0xDEAD_BEEF_CAFE_BABE` — anyone
who tramples the bottom of the stack gets caught.

### 6.2 How to lay out the initial stack (the trickiest step)

When you `spawn` a task, it has never run. But the context-switch
assembly only does one thing: swap stacks, pop a bunch of registers,
iretq. Where do the popped values come from? The answer:
**`buildInitialStack` fakes up what the stack would look like if the
task had just been interrupted**.

From the top of the stack down:

```
  ss = KERNEL_DATA
  rsp = stack_top          ┐ iretq consumes these 5 entries
  rflags = 0x202 (IF=1)    │
  cs = KERNEL_CODE         │
  rip = &taskBootstrap     ┘  ← iretq jumps here
  ---------------------------
  rax..r11 = 0              ┐
  r12 = entry_fn            │ 15 GPRs get popped
  r13 = stack_top           │
  r14 = 0, r15 = 0          ┘
```

Note `r12 = entry_fn`, `r13 = stack_top` — these two are "smuggled
arguments". Look at `taskBootstrap` in `src/context_switch.S`:

```asm
taskBootstrap:
    mov %r13, %rsp      # reset to a clean stack top
    call *%r12          # call the real entry point
```

So the first time the task "resumes", the fake stack frame makes it
think it has "just returned from an interrupt", it jumps to
`taskBootstrap`, which then indirectly calls the actual entry
function. Elegant.

### 6.3 Cooperative yield

When code wants to yield voluntarily, it calls `scheduler.yield()` →
`task.yieldCurrent()` → this in `src/context_switch.S`:

```asm
yieldCurrent:
    int $0x81
    ret
```

A single software interrupt. The benefit: **register save/restore
reuses the exact same IRQ entry path**. We don't need a separate
"save registers" routine just for cooperative switches.

`yieldStub` → `yieldInner(current_rsp)` → `switchFromContext(current_rsp)`:

```
1. Pick the next ready task (round-robin)
2. Save old task.rsp = current_rsp   (stash current stack position)
3. Return new_task.rsp                (the stub uses movq %rax, %rsp)
4. Stub pops registers off the new stack and iretqs
```

### 6.4 Preemption

Turning on preemption only takes one thing: reuse the same
`switchFromContext` in the IRQ0 (PIT) handler path. See
`src/scheduler.zig::timerTickFromContext`:

```zig
tick_count += 1;
if (quantum != 0 and tick_count % quantum == 0 and runnableCount() > 1) {
    return switchFromContext(current_rsp);
}
return current_rsp;
```

The default quantum is 10 ticks — at 100 Hz, that's a **100 ms time
slice**. `irq0Stub` uses `pushFullRegsAndSwitch`, taking the same
assembly path as yield — crucially, it also **saves all 15 GPRs**,
not just caller-saved ones. Otherwise callee-saved registers would be
wrong when we switch back.

That's why `idt.zig` has both `pushRegsAndCall` and
`pushFullRegsAndSwitch`: the former is for ordinary interrupts (saves
only caller-saved, to save stack), the latter is for interrupts that
**might trigger a switch** (must save the full set).

---

## 7. Phase 6 — In-memory VFS

**Key files: `src/vfs.zig`, `src/devfs.zig`, `src/procfs.zig`**

We have no disk, so we build an **in-memory VFS** just so the shell's
`ls / cat / mkdir / touch` have "files" to operate on.

### 7.1 The data model

Everything lives in one big array of `Inode`s (`MAX_INODES = 128`).
Each inode has:

```
name, name_len          // short name
node_type               // directory / regular_file / device / proc_node
parent                  // index of the parent directory inode
data, data_len          // 4 KiB inline data
active                  // whether this slot is in use
```

No separate dentries, no block allocator, no link counts — plenty for
a teaching kernel to express the concept of a "hierarchical namespace".

### 7.2 Path resolution: `resolve("/etc/hostname")`

Look at `vfs.resolve`: starting from the root (`inode[0]`), it splits
the path on `/`, then for each component scans all inodes with
`active && parent == current` and matches by name, advancing
`current`. Non-absolute paths are rejected. No `..`, no symlinks —
left out on purpose.

### 7.3 Pseudocode cheat sheet

```
open(path)           → idx = resolve(path); if file, return idx
read(idx)            → readFile(idx) returns a slice into inode.data[0..data_len]
write(idx, buf)      → writeFile(idx, buf) memcpy's into the inode, truncating to 4 KiB
mkdir(parent, name)  → createDir → grab an inode slot, hang it under parent
rm(idx)              → remove checks whether the directory is empty, zeroes the slot
```

### 7.4 Special mount points

- **`/tmp`**: ordinary directory, write whatever you want
- **`/dev`**: `src/devfs.zig` creates `device` nodes here (currently tiny)
- **`/proc`**: `src/procfs.zig` creates `proc_node` entries whose
  contents are generated on the fly by shell commands (for example
  `/proc/uptime`, `/proc/meminfo`, `/proc/tasks`)
- **`/etc`**: ordinary directory, currently empty, reserved for
  config files

The only thing distinguishing them is `node_type` — the specific
read/write semantics are decided by the layer above. This is an
exercise in **"how far can a minimalist VFS go"**.

---

## 8. Going further: PCI, e1000, ARP/ICMP

After Phase 1-6, the project grew a **networking-stack skeleton**.
Don't expect it to be as complete as lwIP, but sending an ARP/ICMP
frame out through QEMU's virtual NIC and getting a reply back — the
full pipeline works.

### 8.1 PCI enumeration — `src/pci.zig`

On old-school x86, PCI config space is accessed through the two
"address/data" registers at ports `0xCF8/0xCFC`. `pci.init()` brute-
force scans bus 0..255, device 0..31, function 0..7, reads
vendor/device/class into a table, and later drivers like e1000 look
themselves up by vendor:device.

### 8.2 e1000 driver — `src/e1000.zig`

Intel 82540/82545 family NICs. Key points:

- Get the MMIO base from PCI BAR0
- Set up a TX ring and an RX ring (physically contiguous descriptor arrays)
- Write RX buffers into descriptors to tell the NIC "you can DMA into here"
- On IRQ, handle RX/TX completion
- Send = fill a TX descriptor + kick the TDT register

The code isn't small (~600 lines), but every responsibility follows
the classic DMA + ring-descriptor playbook.

### 8.3 ARP / ICMP / UDP — `src/arp*.zig`, `src/icmp.zig`, `src/udp.zig`

- `src/eth.zig`: pack/unpack Ethernet frames
- `src/arp.zig` + `src/arp_cache.zig`: ARP request/reply, plus a small
  IP→MAC cache
- `src/ipv4.zig`: IP header, checksum, simple routing
- `src/icmp.zig`: only echo request/reply is implemented → the shell's
  `ping` works
- `src/udp.zig`: basic UDP skeleton

The design follows "each layer only knows the buffer handed to it by
the next layer down". For details, see
[`docs/spec/DESIGN-TCPIP.md`](../spec/DESIGN-TCPIP.md).

---

## 9. How to read this code

If this is your first time opening the repo, a suggested reading order:

```
1. docs/spec/DESIGN.md       ← read the spec first, to see the big picture
2. src/main.zig              ← start at _start and read linearly;
                               whenever you hit an init(), jump to that file
3. src/limine.zig            ← understand the boot protocol
4. src/gdt.zig → idt.zig → pic.zig → pit.zig
                             ← the CPU init chain
5. src/pmm.zig → vmm.zig → heap.zig
                             ← the three memory layers
6. src/keyboard.zig → shell.zig
                             ← the first time you can "interact"
7. src/task.zig + context_switch.S + scheduler.zig
                             ← these three must be read together
8. src/vfs.zig → devfs.zig → procfs.zig
                             ← namespace
9. src/pci.zig → e1000.zig → net.zig + eth/arp/ipv4/icmp/udp
                             ← networking stack
10. src/shell_cmds.zig       ← the glue that ties all the subsystems together
```

A few tips for reading:

- **Don't panic when you hit assembly.** Almost all hand-written
  assembly in this project is concentrated in `context_switch.S` and
  the interrupt stubs in `idt.zig`. Think of the stack as a list and
  literally draw out the state before and after each push/pop — and
  it becomes transparent.
- **Trace a complete IRQ path.** For example, the keyboard: from
  `irq1Stub` (naked) → save registers → `irq1Inner` →
  `keyboard.handleInterrupt` → `cpu.inb(0x60)` → push into the buffer
  → `pic.sendEoi(1)` → back to the stub → pop registers → `iretq`.
  Once you've drawn that whole path from memory, you understand the
  interrupt model.
- **Trace a complete yield.** Same exercise: from `scheduler.yield()`
  all the way to "we're actually running inside another task now".
- **Use `zig build run-serial` together with `log.kprintln` as your
  debugger.** This kernel has no GDB stub; the serial log is your
  friend.

---

Have fun. This is a kernel you can **read cover to cover** — about
6000 lines total. Open every file, read every function, and a weekend
is enough. Afterwards, you'll have a very concrete sense of "why
modern operating systems have to do X in such a complicated way",
because you've just seen the minimum-runnable version of it.
