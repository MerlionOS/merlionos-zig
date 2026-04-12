# MerlionOS-Zig 内核漫游 (Phase 1-6)

> 本文是一次带读者走进代码的导览。如果你希望看到权威的实现规格 (spec-level) 描述，请先阅读
> [`docs/spec/DESIGN.md`](../spec/DESIGN.md)；网络栈的细节在
> [`docs/spec/DESIGN-TCPIP.md`](../spec/DESIGN-TCPIP.md)。
>
> 本文则换一种语气：我们不试图穷举字段，而是牵着你的手，沿着 `src/` 的文件顺着读一遍，
> 告诉你"为什么这样写"，以及每一层藏着的那些容易被忽略的小坑。

---

## 1. 引言：这是个什么东西？

MerlionOS-Zig 是一个 **x86_64 的裸机内核**，用 Zig 0.15 写的，通过 Limine
bootloader 启动。它的灵感来源是 Rust 版本的
[MerlionOS](https://github.com/lai3d/merlionos)，但这不是一行一行的翻译——
它是一次重新实现，目的是让 Zig 的 comptime、显式 allocator 和 error union
这些特性自然融入到内核代码里。

它**是**什么：

- 一个能在 QEMU 里跑起来、可以交互的小 OS
- 有 GDT/IDT、PIC/PIT、分页、堆、调度器、VFS、PCI、e1000、基本 ARP/ICMP
- 一个给学习者翻阅的"合格示例"

它**不是**什么：

- 不是 POSIX 兼容的 OS
- 没有用户态进程（目前调度器只跑内核线程）
- 没有磁盘 / 块设备 / 真文件系统（VFS 全在内存里）
- 不是生产级代码——它被刻意写得"够用且好读"

当前完工的阶段：**Phase 1-6**。往后的 PCI / e1000 / ARP / ICMP / UDP 是额外
追加的网络栈骨架。接下来我们就按阶段走。

---

## 2. Phase 1 — 启动：从 UEFI 到 `_start`

**关键文件：`src/limine.zig`、`src/main.zig`、`linker.ld`、`limine.conf`**

传统的 x86 启动有三段苦日子：实模式 16 位 → 保护模式 32 位 → 长模式 64 位。
我们不想自己写这套 trampoline，因此选了 **Limine** 协议：
Limine 会替我们从 UEFI/BIOS 一路走到长模式，把内核 ELF 加载进去，
然后**直接**跳进我们的 `_start`，此时 CPU 已经在 64-bit long mode 里。

### 2.1 高半内核 (Higher-Half Kernel)

看 `linker.ld`，你会看到内核被链接在 `0xffffffff80000000`——x86_64 虚拟地址
空间最上面那 2 GiB。这叫 "higher-half"。为什么？

- 未来支持用户态时，低地址空间可以完全交给用户
- 内核代码地址永远在一个固定、与进程无关的位置
- 让内核页表"共享的上半"和"每进程私有的下半"天然分开

Limine 会给我们建好初始页表，把物理内存也以一段恒等式映射暴露在所谓 HHDM
(Higher Half Direct Map) 区域——内核可以通过
`phys + hhdm_offset` 直接访问任意物理页。

### 2.2 与 Limine 握手

`src/limine.zig` 就是一堆 extern struct：请求结构体 (`FramebufferRequest`、
`MemmapRequest`、`HhdmRequest`) 带着魔数 ID；回应结构体里放着 Limine 填给我们的
数据。关键点：

```zig
pub export var memmap_request: MemmapRequest linksection(".limine_requests") = .{...};
```

`linksection(".limine_requests")` 把这些结构放进 linker script 里定义的专门
section，夹在 `requests_start_marker` 和 `requests_end_marker` 之间。Limine
扫描这一段就能找到我们的请求，把回应指针写回。

### 2.3 `_start` 的开场白

打开 `src/main.zig`，`_start` 的开头几行几乎就是教科书里"最小可验证启动"的
样子：先把串口 COM1 拉起来，在串口打一行"我活着"，再读一下 HHDM offset，
再初始化 VGA 文本模式。只要这两个输出通道能刷出字符，就意味着：

1. Limine 确实把我们扔到了 64 位
2. 我们的 linker 脚本没写错
3. 端口 I/O 和基本 MMIO 能工作

从这里开始，每完成一个子系统都会 `log.kprintln` 一行，串口和 VGA
"双路广播"——这也是 `src/log.zig` 只有 17 行的原因：它就是把同一段格式化
文本喂给两个 writer。

---

## 3. Phase 2 — CPU 初始化：GDT / TSS / IDT / PIC / PIT

**关键文件：`src/gdt.zig`、`src/idt.zig`、`src/cpu.zig`、`src/pic.zig`、`src/pit.zig`**

Limine 已经帮我们做过一次 GDT/IDT 设置——**但那是 Limine 的**，随时可能被回收
(bootloader-reclaimable 区域)，我们必须拿回控制权。

### 3.1 为什么要重建 GDT？

`src/gdt.zig` 里有 7 条描述符：

```
[0] null
[1] kernel code   (selector 0x08)
[2] kernel data   (0x10)
[3] user   data   (0x18)
[4] user   code   (0x20)
[5..6] TSS (占两条，因为 64 位 TSS 描述符是 16 字节)
```

加载完之后用一段内联汇编重新刷 `ds/es/fs/gs/ss`，然后通过一条"假装的远跳"
(`pushq $0x08; leaq 1f(%rip); pushq %rax; lretq; 1:`) 重新载入 CS——
x86_64 不支持直接 `mov` 给 CS，只能靠 far return / iret 这种"从栈上吃"指令。

### 3.2 为什么要 TSS？

64 位模式下 TSS 不再承担上下文切换，但**仍然有用**：

- `rsp0`：当 ring 3→ring 0 切换时 CPU 自动切到这个栈（我们未来做用户态时要用）
- `ist1..ist7`：中断栈表。我们把 **double fault** (向量 8) 放到 IST1，
  用一块单独的 4 KiB 栈接住它——哪怕普通内核栈坏掉了，double fault
  handler 依然有一块干净栈可用。看 `gdt.init()` 里 `tss.ist1 = ...` 和
  `idt.zig` 里 `makeGate(..., 1, 0x8E)` 的那个 `ist=1` 就是这回事。

### 3.3 IDT 与中断 stub

`src/idt.zig` 填 256 条门描述符，大多数指向一个"未处理中断"默认 stub。
关心的几个：

- `0/1/3/6/8/13/14`：CPU 异常（除零、调试、断点、非法指令、double fault、#GP、#PF）
- `32` (IRQ0) → PIT 时钟
- `33` (IRQ1) → 键盘
- `0x80` → 占位的系统调用门 (DPL=3)
- `0x81` → 用户可用的"内核 yield" 软中断 (稍后细说)

每个 stub 都是 `callconv(.naked)` 的裸函数，内部是手写汇编。为什么？因为
中断入口必须：

1. 立刻保存寄存器
2. 不让编译器塞 prologue/epilogue
3. 最后用 `iretq` 而不是 `ret` 返回

`pushRegsAndCall` 是通用流程，`pushFullRegsAndSwitch` 是**调度专用**：
它保存**全部 15 个 GPR**，把当前 `rsp` 传给 Zig 一侧的 `irq0Inner`
或 `yieldInner`，后者可以决定返回**另一个任务**的 rsp——于是 `movq %rax, %rsp`
就完成了上下文切换（栈一换，pop 出来的全是另一个任务的寄存器）。

### 3.4 PIC 为什么要重映射？

老式 8259 PIC 上电默认把 IRQ0..7 映射到中断向量 **0x08..0x0F**——
这和 CPU 自己的异常向量 (0..31) **严重冲突**。一旦发生 timer 中断，
CPU 会以为是 double fault。

所以 `src/pic.zig` 做的第一件事就是把 PIC1 偏移改成 32，PIC2 改成 40：

```
ICW1_INIT → 开始初始化
ICW2      → 新的向量偏移
ICW3      → 告诉 PIC1 slave 挂在 IRQ2；告诉 PIC2 它自己是 IRQ2 上挂的
ICW4      → 走 8086 模式
```

最后 `outb(PIC1_DATA, 0xFC)` 解除 IRQ0 (timer) 和 IRQ1 (keyboard) 的屏蔽，
其他全部禁用。简单粗暴但够用。

### 3.5 PIT = 心跳

`src/pit.zig` 非常简短：往命令口写 `0x36` (channel 0, rate generator)，
然后写入分频值 `1_193_182 / hz`。我们传入 100 Hz，于是每 10 ms 进一次 IRQ0。
这颗心跳后面会被调度器抢占、`sleep` 命令、`uptime` 一起共用。

---

## 4. Phase 3 — 内存：三层抽象

**关键文件：`src/pmm.zig`、`src/vmm.zig`、`src/heap.zig`**

内存管理是 OS 里最容易被写成"一锅乱炖"的子系统。我们把它老老实实拆成三层：

```
             heap (std.mem.Allocator)         ← 任意字节、用完 free
                     │ 需要 4 KiB 页时向下要
                     ▼
             vmm (虚拟→物理，4 级页表)         ← 以页为单位映射/解除映射
                     │ 需要一个物理页时向下要
                     ▼
             pmm (位图)                       ← 管理物理页帧
                     │
                     ▼
             Limine memory map
```

### 4.1 PMM：位图 + HHDM

`src/pmm.zig` 的实现故意朴素：一个 `[MAX_PAGES/8]u8` 位图，1 表示"已用/不可用"。
`init()` 把整个位图先填成 0xFF（全部不可用），然后遍历 Limine memmap 的
`USABLE` 段，把对应位清 0 (= 可用)。

`physToVirt(phys) = phys + hhdm_offset` 让我们可以直接读写任意物理地址，
这一点在 VMM 里尤其好使——操纵页表本质上是"操纵一块物理内存"。

### 4.2 VMM：x86_64 的 4 级页表

看 `src/vmm.zig::mapPage`。x86_64 的虚拟地址布局：

```
  63       48 47   39 38   30 29   21 20   12 11   0
  |  sign   | PML4 | PDPT | PD  | PT  | offset |
           \__9__/\__9__/\__9__/\__9__/\__12__/
```

`mapPageWithFlags` 把这 4 个 9-bit 字段切出来，按级下钻。`getOrCreateTable`
如果发现下一级不存在，就 `pmm.allocFrame()` 分一页物理内存、通过 HHDM 清零、
写回上一级条目。最后：

```zig
pt[pt_idx] = (phys & ...) | flags;
asm volatile ("invlpg (%[addr])" ...);
```

`invlpg` 是必须的——TLB 会缓存旧的映射，不刷一下，你刚做的 map 可能对
CPU "暂时透明"。

注意我们**从来没有自己建过顶层 PML4**。CR3 里指向的是 Limine 给我们留下的
那张表。我们只是在它上面增量地挂新条目。这是 higher-half 设计的又一个好处：
Limine 已经把内核本体和 HHDM 都在顶半区映射好了，我们要做的只是追加堆、
外设 MMIO 等少量新映射。

### 4.3 Heap：First-fit Free-list

`src/heap.zig` 是一块典型的"教学型堆分配器"：

- 预分配 4 MiB 虚拟空间起点 `0xFFFF_C000_0000_0000`
- `init()` 里用 `pmm.allocFrame + vmm.mapPage` 把这 4 MiB 填实
- 一条 `FreeBlock` 自由链表，first-fit 策略
- 切分时剩余太小就整块拿走，避免产生过于零碎的 free block
- 暴露成标准 `std.mem.Allocator`，内核代码可以直接 `try allocator.alloc(T, n)`

这里有一个 Zig 特有的漂亮之处：`std.mem.Allocator` 是运行时多态的 vtable，
所以我们只要提供 `alloc` / `free`，整个 std 的容器都能白嫖——比如
`std.ArrayList` 之类的东西就可以在内核里直接用。

---

## 5. Phase 4 — 键盘与 Shell

**关键文件：`src/keyboard.zig`、`src/shell.zig`、`src/shell_cmds.zig`**

### 5.1 PS/2 扫描码的三种坑

键盘控制器在 `0x60` 口吐 scancode，流程是这样：

1. `0xE0` 前缀 → 接下来是"扩展键" (方向键、Home、End...)
2. bit 7 = 1 → 这是一个 "release"（松开），否则是 "make"（按下）
3. 某些键 (Shift `0x2A/0x36`、Ctrl `0x1D`) 是 modifier，只更新状态不产生事件

`src/keyboard.zig::handleInterrupt` 用三个 `var` (`shift_pressed`、
`ctrl_pressed`、`extended`) 跟踪状态机，把可打印键翻译成 ASCII、功能键翻译成
`KeyEvent` 枚举，推进一个 128 项的环形缓冲区。

这个 ISR **不阻塞、不分配**。它只做"读口、查表、入队、EOI"——复杂的
行编辑都在用户上下文里 (shell) 完成。这是个通用模式：ISR 要短，消费者自己来拉。

### 5.2 Shell：行编辑 + 历史

`src/shell.zig` 就是一个 `while (true)`：

```
读一个 KeyEvent →
  enter    → 把 input_buf 丢给 executeCommand
  backspace / delete / arrows → 编辑 buffer、重绘这一行
  char     → 插入字符、重绘
```

支持上下方向键翻历史、左右方向键移光标——不复杂，但对"它是个真交互式 shell"
这种感受很关键。具体命令 (`help`、`ls`、`cat`、`ps`、`ping` 等) 都在
`src/shell_cmds.zig` 里，那是本项目最长的一个文件 (1200+ 行)，更多地是"调度
命令 + 格式化输出"。

---

## 6. Phase 5 — 多任务：合作式 + 抢占式

**关键文件：`src/task.zig`、`src/scheduler.zig`、`src/context_switch.S`、
`src/idt.zig` 里的 `irq0Stub`/`yieldStub`**

这是整个内核最"魔法"的部分。仔细走一遍。

### 6.1 Task 结构

`src/task.zig` 里 `Task` 是一个 POD：pid、name、state (`ready/running/blocked/finished`)、
**rsp**、栈范围、统计计数。MAX_TASKS = 32，每个任务有一块 16 KiB 的内核栈
(从静态 `stack_pool` 中分配)。栈底写入一个 canary `0xDEAD_BEEF_CAFE_BABE`
——任何人踩穿栈底都会被发现。

### 6.2 初始栈怎么铺 (最微妙的一步)

当你 `spawn` 一个任务时，它从未运行过。但**上下文切换**那段汇编只会做一件事：
把栈切过去、pop 一堆寄存器、iretq。那 pop 出来的东西从哪来？
答案是：我们**在 `buildInitialStack` 里用代码"伪造"了一份它刚被中断的样子**。

从栈顶往下依次压入：

```
  ss = KERNEL_DATA
  rsp = stack_top          ┐ iretq 会消耗这 5 项
  rflags = 0x202 (IF=1)    │
  cs = KERNEL_CODE         │
  rip = &taskBootstrap     ┘  ← iretq 跳这里
  ---------------------------
  rax..r11 = 0              ┐
  r12 = entry_fn            │ 15 个 GPR 会被 pop 出来
  r13 = stack_top           │
  r14 = 0, r15 = 0          ┘
```

注意 `r12 = entry_fn`、`r13 = stack_top`——这两条是"走私参数"。
去看 `src/context_switch.S` 里的 `taskBootstrap`：

```asm
taskBootstrap:
    mov %r13, %rsp      # 重置到干净栈顶
    call *%r12          # 调用真正的入口
```

于是任务第一次"恢复执行"时，伪造的栈帧让它觉得自己是"刚从中断返回"，
跳到 `taskBootstrap`，再间接调用真正的 entry function。漂亮。

### 6.3 合作式 yield

用户态代码想主动让出时调用 `scheduler.yield()` → `task.yieldCurrent()`
→ `src/context_switch.S` 里的：

```asm
yieldCurrent:
    int $0x81
    ret
```

一条软中断。好处是：**所有寄存器保存/恢复走完全相同的 IRQ 入口路径**。
不需要为合作式切换单独写一份"保存寄存器"的代码。

`yieldStub` → `yieldInner(current_rsp)` → `switchFromContext(current_rsp)`：

```
1. 选下一个 ready 的任务 (round-robin)
2. 把旧 task.rsp = current_rsp   (当前栈位置存回)
3. 返回 new_task.rsp              (stub 拿到后用 movq %rax, %rsp)
4. stub 从新栈上 pop 寄存器、iretq
```

### 6.4 抢占式

打开抢占只需要做一件事：在 IRQ0 (PIT) 的处理路径里复用同样的
`switchFromContext`。看 `src/scheduler.zig::timerTickFromContext`：

```zig
tick_count += 1;
if (quantum != 0 and tick_count % quantum == 0 and runnableCount() > 1) {
    return switchFromContext(current_rsp);
}
return current_rsp;
```

默认 quantum = 10 tick，即 100 Hz * 10 = **100 ms 一个时间片**。
`irq0Stub` 用的是 `pushFullRegsAndSwitch`，和 yield 走的是完全同一条汇编路径——
关键是它也**保存全部 15 个 GPR** 而不是只保存 caller-saved。否则切回去时
callee-saved 寄存器会错。

这就是为什么 `idt.zig` 里同时有 `pushRegsAndCall` 和 `pushFullRegsAndSwitch`
两套：前者给普通中断 (只保存 caller-saved 省点栈)，后者给**可能触发切换**
的中断 (必须保存全套)。

---

## 7. Phase 6 — 内存 VFS

**关键文件：`src/vfs.zig`、`src/devfs.zig`、`src/procfs.zig`**

没有磁盘，我们只造一个**内存 VFS**，让 shell 的 `ls / cat / mkdir / touch`
能有"文件"可操作。

### 7.1 数据模型

一切就是一个 `Inode` 的大数组 (`MAX_INODES = 128`)，每个 inode 包含：

```
name, name_len          // 短名字
node_type               // directory / regular_file / device / proc_node
parent                  // 指向父目录 inode 的索引
data, data_len          // 4 KiB 内联数据
active                  // 该槽是否在用
```

没有分离的 dentry、没有 block allocator、没有链接计数——对一个教学内核
已经足够表达"层级命名空间"的概念。

### 7.2 路径解析 `resolve("/etc/hostname")`

看 `vfs.resolve`：从根 (`inode[0]`) 开始，把路径按 `/` 切片，每段去遍历当前目录
下所有 `active && parent == current` 的 inode，找名字相等的，把 `current`
推进去。拒绝非绝对路径。没有 `..`、没有符号链接——故意不做。

### 7.3 伪代码速览

```
open(path)           → idx = resolve(path); 如果是文件返回 idx
read(idx)            → readFile(idx) 直接返回 inode.data[0..data_len] 的切片
write(idx, buf)      → writeFile(idx, buf) memcpy 进 inode，截断到 4 KiB
mkdir(parent, name)  → createDir → 分一个 inode 槽、挂到 parent 下
rm(idx)              → remove 检查是否空目录，清零整个槽
```

### 7.4 特殊挂载点

- **`/tmp`**：普通目录，随便写
- **`/dev`**：`src/devfs.zig` 在这里造 `device` 节点 (当前很小)
- **`/proc`**：`src/procfs.zig` 造 `proc_node`，由 shell 命令动态生成内容
  (例如 `/proc/uptime`、`/proc/meminfo`、`/proc/tasks`)
- **`/etc`**：普通目录，目前空着留给配置文件

区分它们的只有 `node_type`——具体的 read/write 语义由上层决定。这是一个
**"极简 VFS 能走多远"**的练习。

---

## 8. 后续扩展：PCI、e1000、ARP/ICMP

Phase 1-6 之后，项目继续长出了一块**网络栈骨架**。不要指望它像 lwIP 那么
完备，但把一帧 ARP/ICMP 请求真的从 QEMU 的虚拟网卡发出去、收回来——
整条链路已经可运行。

### 8.1 PCI 枚举 — `src/pci.zig`

老式 x86 PCI 配置空间通过端口 `0xCF8/0xCFC` 两只"地址/数据"寄存器访问。
`pci.init()` 暴力扫描 bus 0..255、device 0..31、function 0..7，
读 vendor/device/class 塞进一张表，之后 e1000 和其他驱动按 vendor:device
匹配查找。

### 8.2 e1000 驱动 — `src/e1000.zig`

Intel 82540/82545 系列网卡。关键点：

- 通过 PCI BAR0 拿到 MMIO 基址
- 建立 TX ring 和 RX ring (物理连续的描述符数组)
- 把 RX 缓冲区写进描述符，告诉网卡"可以往这里 DMA"
- IRQ 触发时处理 RX/TX 完成
- 发送 = 填 TX 描述符 + 敲 TDT 寄存器

代码不小 (~600 行)，但职责都是这套经典 DMA + 环形描述符的套路。

### 8.3 ARP / ICMP / UDP — `src/arp*.zig`、`src/icmp.zig`、`src/udp.zig`

- `src/eth.zig`：以太网帧的 pack/unpack
- `src/arp.zig` + `src/arp_cache.zig`：ARP 请求/应答，+ 一个按 IP→MAC 的小缓存
- `src/ipv4.zig`：IP 头、校验和、简单路由
- `src/icmp.zig`：只实现了 echo request/reply → shell 的 `ping` 可以工作
- `src/udp.zig`：UDP 基本骨架

设计上遵循"每一层只认下一层给它的 buffer"。细节请看
[`docs/spec/DESIGN-TCPIP.md`](../spec/DESIGN-TCPIP.md)。

---

## 9. 如何阅读这份代码

如果你是第一次打开这个 repo，建议的阅读顺序：

```
1. docs/spec/DESIGN.md       ← 先看 spec，知道整个系统拼图
2. src/main.zig              ← 从 _start 开始，一行一行往下读
                               每遇到一个 init() 就跳到对应文件
3. src/limine.zig            ← 理解启动协议
4. src/gdt.zig → idt.zig → pic.zig → pit.zig
                             ← CPU 初始化链
5. src/pmm.zig → vmm.zig → heap.zig
                             ← 内存三层
6. src/keyboard.zig → shell.zig
                             ← 第一次能"交互"
7. src/task.zig + context_switch.S + scheduler.zig
                             ← 这一段必须三份一起读
8. src/vfs.zig → devfs.zig → procfs.zig
                             ← 命名空间
9. src/pci.zig → e1000.zig → net.zig + eth/arp/ipv4/icmp/udp
                             ← 网络栈
10. src/shell_cmds.zig       ← 把上面所有子系统串起来的 glue
```

几条读码建议：

- **遇到汇编先别慌。** 本项目的手写汇编几乎都集中在 `context_switch.S` 和
  `idt.zig` 的中断 stub。把栈当成一个列表，字面地画出 push/pop 前后的状态，
  就能看穿。
- **追踪一次 IRQ 的完整路径。** 比如键盘：从 `irq1Stub` (naked) → 保存寄存器 →
  `irq1Inner` → `keyboard.handleInterrupt` → `cpu.inb(0x60)` → 推缓冲 →
  `pic.sendEoi(1)` → 回到 stub → pop 寄存器 → `iretq`。把这整条路径默画一遍，
  你就懂中断模型了。
- **追踪一次 yield 的完整路径。** 同理，从 `scheduler.yield()` 开始，
  一路到"真的已经在另一个任务里跑"。
- **用 `zig build run-serial` 配合 `log.kprintln` 当调试器。** 这个内核没有
  GDB stub，串口日志是你的朋友。

---

祝你玩得开心。这是一个**可以完整读完**的内核，全部 6000 行左右——
把每个文件打开、把每个函数读一遍，一个周末就够。读完之后你会对
"为什么现代操作系统做某件事要那么复杂"有非常具体的感觉，
因为你刚刚见过它的最小可运行版本。
