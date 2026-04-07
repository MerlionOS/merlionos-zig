const e1000 = @import("e1000.zig");
const log = @import("log.zig");
const pci = @import("pci.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const procfs = @import("procfs.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const vfs = @import("vfs.zig");
const vga = @import("vga.zig");

const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn ([]const u8) void,
};

const commands = [_]Command{
    .{ .name = "cat", .description = "Print a file from the virtual filesystem", .handler = cmdCat },
    .{ .name = "cd", .description = "Change the current directory", .handler = cmdCd },
    .{ .name = "help", .description = "Show available commands", .handler = cmdHelp },
    .{ .name = "clear", .description = "Clear the screen", .handler = cmdClear },
    .{ .name = "echo", .description = "Print text or write with > redirection", .handler = cmdEcho },
    .{ .name = "info", .description = "System information", .handler = cmdInfo },
    .{ .name = "kill", .description = "Kill a background task by pid", .handler = cmdKill },
    .{ .name = "ls", .description = "List a directory in the virtual filesystem", .handler = cmdLs },
    .{ .name = "lspci", .description = "List discovered PCI devices", .handler = cmdLspci },
    .{ .name = "mem", .description = "Memory statistics", .handler = cmdMem },
    .{ .name = "mkdir", .description = "Create a directory in the virtual filesystem", .handler = cmdMkdir },
    .{ .name = "netinfo", .description = "Show detected network device details", .handler = cmdNetinfo },
    .{ .name = "nettest", .description = "Transmit one raw Ethernet test frame", .handler = cmdNettest },
    .{ .name = "pwd", .description = "Print the current directory", .handler = cmdPwd },
    .{ .name = "ps", .description = "List tasks", .handler = cmdPs },
    .{ .name = "rm", .description = "Remove a file or empty directory", .handler = cmdRm },
    .{ .name = "spawn", .description = "Spawn a cooperative worker task", .handler = cmdSpawn },
    .{ .name = "touch", .description = "Create an empty file", .handler = cmdTouch },
    .{ .name = "tree", .description = "Show a directory tree", .handler = cmdTree },
    .{ .name = "uptime", .description = "Time since boot", .handler = cmdUptime },
    .{ .name = "yield", .description = "Yield the CPU cooperatively", .handler = cmdYield },
    .{ .name = "write", .description = "Write text to a virtual file", .handler = cmdWrite },
    .{ .name = "version", .description = "Kernel version", .handler = cmdVersion },
};

var current_dir_buf: [MAX_PATH]u8 = [_]u8{'/'} ++ [_]u8{0} ** (MAX_PATH - 1);
var current_dir_len: usize = 1;

pub fn dispatch(cmd: []const u8, args: []const u8) void {
    for (commands) |command| {
        if (strEql(cmd, command.name)) {
            command.handler(args);
            return;
        }
    }

    log.kprintln("Unknown command: {s}. Type 'help' for commands.", .{cmd});
}

fn cmdHelp(_: []const u8) void {
    log.kprintln("Available commands:", .{});
    for (commands) |command| {
        log.kprintln("  {s: <12} {s}", .{ command.name, command.description });
    }
}

fn cmdClear(_: []const u8) void {
    vga.vga_writer.clear();
}

fn cmdCat(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePath(args, false, &path_buf) orelse {
        log.kprintln("Usage: cat <path>", .{});
        return;
    };

    procfs.prepareRead(path);

    const idx = vfs.resolve(path) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    const inode = vfs.getInode(idx) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    if (inode.node_type == .directory) {
        log.kprintln("{s}: is a directory", .{path});
        return;
    }

    const data = vfs.readFile(idx) orelse {
        log.kprintln("{s}: cannot read", .{path});
        return;
    };
    if (data.len == 0) return;

    log.kprint("{s}", .{data});
    if (data[data.len - 1] != '\n') {
        log.kprint("\n", .{});
    }
}

fn cmdCd(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePathOrRoot(args, &path_buf);
    const idx = vfs.resolve(path) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    const inode = vfs.getInode(idx) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    if (inode.node_type != .directory) {
        log.kprintln("{s}: not a directory", .{path});
        return;
    }

    setCurrentDir(path);
}

fn cmdEcho(args: []const u8) void {
    if (parseEchoRedirect(args)) |redirect| {
        switch (writePath(redirect.path, redirect.text)) {
            .ok => log.kprintln("Wrote {d} bytes to {s}.", .{ redirect.text.len, redirect.path }),
            .invalid_path => log.kprintln("echo: invalid path", .{}),
            .parent_missing => log.kprintln("echo: parent directory missing", .{}),
            .parent_not_dir => log.kprintln("echo: parent is not a directory", .{}),
            .name_invalid => log.kprintln("echo: invalid file name", .{}),
            .write_failed => log.kprintln("echo: failed to write file", .{}),
        }
        return;
    }

    log.kprintln("{s}", .{args});
}

fn cmdInfo(_: []const u8) void {
    log.kprintln("MerlionOS-Zig v0.1.0", .{});
    log.kprintln("Architecture: x86_64", .{});
    log.kprintln("Boot: Limine", .{});
    log.kprintln("Uptime: {d}s", .{pit.uptimeSeconds()});
    log.kprintln("Memory: {d}/{d} MB free", .{
        pmm.freeMemory() / 1048576,
        pmm.totalMemory() / 1048576,
    });
    log.kprintln("PCI devices: {d}", .{pci.deviceCount()});
    log.kprintln("Tasks: {d} total ({d} runnable)", .{
        task.taskCount(),
        task.runnableCount(),
    });
    log.kprintln("Scheduler: IRQ-time round-robin, quantum={d}, switches={d}", .{
        scheduler.getQuantum(),
        scheduler.getContextSwitches(),
    });
    log.kprintln("Preemption: pending={s} requests={d}", .{
        if (scheduler.hasPreemptPending()) "yes" else "no",
        scheduler.getPreemptRequests(),
    });
}

fn cmdKill(args: []const u8) void {
    const trimmed = trimSpaces(args);
    const pid = parsePid(trimmed) orelse {
        log.kprintln("Usage: kill <pid>", .{});
        return;
    };

    switch (task.kill(pid)) {
        .killed => log.kprintln("Killed task {d}.", .{pid}),
        .not_found => log.kprintln("Task {d} not found.", .{pid}),
        .busy_current => log.kprintln("Cannot kill the currently running task {d}.", .{pid}),
    }
}

fn cmdMem(_: []const u8) void {
    log.kprintln("Physical memory:", .{});
    log.kprintln("  Total: {d} MB", .{pmm.totalMemory() / 1048576});
    log.kprintln("  Used:  {d} MB", .{pmm.usedMemory() / 1048576});
    log.kprintln("  Free:  {d} MB", .{pmm.freeMemory() / 1048576});
}

fn cmdMkdir(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePath(args, false, &path_buf) orelse {
        log.kprintln("Usage: mkdir <path>", .{});
        return;
    };

    switch (createDirectory(path)) {
        .ok => log.kprintln("Created directory {s}.", .{path}),
        .already_exists => log.kprintln("{s}: already exists", .{path}),
        .invalid_path => log.kprintln("mkdir: invalid path", .{}),
        .parent_missing => log.kprintln("mkdir: parent directory missing", .{}),
        .parent_not_dir => log.kprintln("mkdir: parent is not a directory", .{}),
        .name_invalid => log.kprintln("mkdir: invalid directory name", .{}),
        .create_failed => log.kprintln("mkdir: failed to create directory", .{}),
    }
}

fn cmdNetinfo(_: []const u8) void {
    e1000.refresh();

    const nic = e1000.detected() orelse {
        log.kprintln("No supported Intel e1000-family NIC detected.", .{});
        return;
    };
    const rings = e1000.ringInfo();

    log.kprintln("Driver: e1000-family detection only", .{});
    log.kprintln("Model:  {s}", .{nic.model});
    log.kprintln("PCI:    {x:0>2}:{x:0>2}.{d} vendor={x:0>4} device={x:0>4}", .{
        nic.device.bus,
        nic.device.slot,
        nic.device.function,
        nic.device.vendor_id,
        nic.device.device_id,
    });
    log.kprintln("BAR0:   raw=0x{x:0>8} base=0x{x:0>8} kind={s} prefetch={s}", .{
        nic.bar0.raw,
        nic.bar0.base,
        @tagName(nic.bar0.kind),
        if (nic.bar0.prefetchable) "yes" else "no",
    });
    log.kprintln("MMIO:   mapped={s} cache={s} virt=0x{x:0>16} CTRL=0x{x:0>8} STATUS=0x{x:0>8}", .{
        if (nic.mmio_mapped) "yes" else "no",
        if (nic.mmio_uncached) "uncached" else "default",
        nic.mmio_virt,
        nic.ctrl,
        nic.status,
    });
    log.kprintln("RX ring: ready={s} descs={d} phys=0x{x:0>8} head={d} tail={d}", .{
        if (rings.initialized) "yes" else "no",
        rings.rx_count,
        rings.rx_desc_phys,
        rings.rx_head,
        rings.rx_tail,
    });
    log.kprintln("TX ring: ready={s} descs={d} phys=0x{x:0>8} head={d} tail={d}", .{
        if (rings.initialized) "yes" else "no",
        rings.tx_count,
        rings.tx_desc_phys,
        rings.tx_head,
        rings.tx_tail,
    });
    log.kprintln("TX stats: frames={d} last={s}", .{
        nic.tx_frames_sent,
        @tagName(nic.tx_last_status),
    });
    log.kprintln("IRQ:    line={d} pin={d}", .{
        nic.device.interrupt_line,
        nic.device.interrupt_pin,
    });
}

fn cmdNettest(_: []const u8) void {
    const status = e1000.transmitTestFrame();
    e1000.refresh();

    const rings = e1000.ringInfo();
    log.kprintln("nettest: {s}", .{@tagName(status)});
    log.kprintln("TX ring: head={d} tail={d}", .{ rings.tx_head, rings.tx_tail });
}

fn cmdLs(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePathOrRoot(args, &path_buf);
    const idx = vfs.resolve(path) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    const inode = vfs.getInode(idx) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    if (inode.node_type != .directory) {
        log.kprintln("{s}: not a directory", .{path});
        return;
    }

    vfs.listDir(idx, printDirEntry);
}

fn cmdLspci(_: []const u8) void {
    if (pci.deviceCount() == 0) {
        log.kprintln("No PCI devices discovered.", .{});
        return;
    }

    log.kprintln("BUS  DEV  FN  VENDOR DEVICE CLASS SUB PROG  TYPE", .{});
    pci.forEach(printPciDevice);
}

fn cmdPwd(_: []const u8) void {
    log.kprintln("{s}", .{currentDir()});
}

fn cmdPs(_: []const u8) void {
    if (task.taskCount() == 0) {
        log.kprintln("No tasks registered.", .{});
        return;
    }

    log.kprintln("PID  STATE    TICKS  RUNS   YIELDS PRIO  NAME", .{});
    task.forEach(printTaskRow);
    log.kprintln("Scheduler: tick={d} quantum={d} yields={d} slices={d} switches={d}", .{
        scheduler.getTickCount(),
        scheduler.getQuantum(),
        scheduler.getYieldRequests(),
        scheduler.getTimeSliceExpirations(),
        scheduler.getContextSwitches(),
    });
    log.kprintln("Preemption: pending={s} requests={d}", .{
        if (scheduler.hasPreemptPending()) "yes" else "no",
        scheduler.getPreemptRequests(),
    });
}

fn cmdSpawn(args: []const u8) void {
    const trimmed = trimSpaces(args);
    const task_name = if (trimmed.len == 0) "worker" else trimmed;
    if (scheduler.spawnWorker(task_name)) |pid| {
        log.kprintln("Spawned task {d}: {s}", .{ pid, task_name });
        return;
    }

    log.kprintln("Failed to spawn task. Task table or stack pool is full.", .{});
}

fn cmdRm(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePath(args, false, &path_buf) orelse {
        log.kprintln("Usage: rm <path>", .{});
        return;
    };

    const idx = vfs.resolve(path) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };

    if (strEql(path, currentDir())) {
        log.kprintln("rm: cannot remove the current directory", .{});
        return;
    }

    switch (vfs.remove(idx)) {
        .ok => log.kprintln("Removed {s}.", .{path}),
        .not_found => log.kprintln("{s}: not found", .{path}),
        .busy => log.kprintln("rm: cannot remove {s}", .{path}),
        .not_empty => log.kprintln("rm: directory not empty: {s}", .{path}),
    }
}

fn cmdTouch(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePath(args, false, &path_buf) orelse {
        log.kprintln("Usage: touch <path>", .{});
        return;
    };

    switch (touchPath(path)) {
        .ok => log.kprintln("Touched {s}.", .{path}),
        .already_exists => log.kprintln("{s}: already exists", .{path}),
        .invalid_path => log.kprintln("touch: invalid path", .{}),
        .parent_missing => log.kprintln("touch: parent directory missing", .{}),
        .parent_not_dir => log.kprintln("touch: parent is not a directory", .{}),
        .name_invalid => log.kprintln("touch: invalid file name", .{}),
        .create_failed => log.kprintln("touch: failed to create file", .{}),
    }
}

fn cmdTree(args: []const u8) void {
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = normalizePathOrRoot(args, &path_buf);
    const idx = vfs.resolve(path) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };
    const inode = vfs.getInode(idx) orelse {
        log.kprintln("{s}: not found", .{path});
        return;
    };

    if (inode.node_type != .directory) {
        log.kprintln("{s}", .{path});
        return;
    }

    log.kprintln("{s}", .{path});
    treeDir(idx, 0);
}

fn cmdUptime(_: []const u8) void {
    const secs = pit.uptimeSeconds();
    const mins = secs / 60;
    const hours = mins / 60;
    log.kprintln("Uptime: {d}h {d}m {d}s ({d} ticks)", .{
        hours,
        mins % 60,
        secs % 60,
        pit.getTicks(),
    });
}

fn cmdYield(_: []const u8) void {
    if (scheduler.yield()) {
        log.kprintln("Yielded to another runnable task and returned.", .{});
        return;
    }

    if (task.currentPid()) |pid| {
        log.kprintln("No alternate runnable task; still on PID {d}.", .{pid});
    } else {
        log.kprintln("Tasking is not initialized.", .{});
    }
}

fn cmdWrite(args: []const u8) void {
    const trimmed = trimSpaces(args);
    if (trimmed.len == 0) {
        log.kprintln("Usage: write <path> <text>", .{});
        return;
    }

    var split: usize = 0;
    while (split < trimmed.len and trimmed[split] != ' ') : (split += 1) {}
    if (split == trimmed.len) {
        log.kprintln("Usage: write <path> <text>", .{});
        return;
    }

    const path = trimSpaces(trimmed[0..split]);
    const text = trimSpaces(trimmed[split + 1 ..]);
    if (path.len == 0) {
        log.kprintln("write: invalid path", .{});
        return;
    }

    switch (writePath(path, text)) {
        .ok => log.kprintln("Wrote {d} bytes to {s}.", .{ text.len, path }),
        .invalid_path => log.kprintln("write: invalid path", .{}),
        .parent_missing => log.kprintln("write: parent directory missing", .{}),
        .parent_not_dir => log.kprintln("write: parent is not a directory", .{}),
        .name_invalid => log.kprintln("write: invalid file name", .{}),
        .write_failed => log.kprintln("write: failed to write file", .{}),
    }
}

fn cmdVersion(_: []const u8) void {
    log.kprintln("MerlionOS-Zig v0.1.0", .{});
    log.kprintln("Built with Zig 0.15", .{});
}

fn printTaskRow(task_entry: *const task.Task, is_current: bool) void {
    log.kprintln("{d: <4} {s: <8} {d: <6} {d: <6} {d: <6} {d: <5} {s}{s}", .{
        task_entry.pid,
        @tagName(task_entry.state),
        task_entry.ticks,
        task_entry.run_count,
        task_entry.yield_count,
        task_entry.priority,
        task.nameSlice(task_entry),
        if (is_current) " *" else "",
    });
}

fn printPciDevice(device: *const pci.Device) void {
    log.kprintln("{x:0>2}   {x:0>2}   {d}   {x:0>4}   {x:0>4}   {x:0>2}    {x:0>2}  {x:0>2}    {s}", .{
        device.bus,
        device.slot,
        device.function,
        device.vendor_id,
        device.device_id,
        device.class_code,
        device.subclass,
        device.prog_if,
        pci.className(device),
    });
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn trimSpaces(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;

    while (start < end and value[start] == ' ') : (start += 1) {}
    while (end > start and value[end - 1] == ' ') : (end -= 1) {}

    return value[start..end];
}

const MAX_PATH = 256;

fn normalizePathOrRoot(input: []const u8, buffer: *[MAX_PATH]u8) []const u8 {
    return normalizePath(input, true, buffer) orelse "/";
}

fn normalizePath(input: []const u8, allow_root_default: bool, buffer: *[MAX_PATH]u8) ?[]const u8 {
    const trimmed = trimSpaces(input);
    if (trimmed.len == 0) {
        if (!allow_root_default) return null;
        @memcpy(buffer[0..current_dir_len], current_dir_buf[0..current_dir_len]);
        return buffer[0..current_dir_len];
    }
    return canonicalizePath(trimmed, buffer);
}

fn parsePid(value: []const u8) ?u32 {
    if (value.len == 0) return null;

    var pid: u32 = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        pid = pid * 10 + (ch - '0');
    }
    return pid;
}

fn printDirEntry(_: u16, inode: *const vfs.Inode) void {
    log.kprintln("{s}{s}", .{
        vfs.getName(inode),
        if (inode.node_type == .directory) "/" else "",
    });
}

fn treeDir(dir_idx: u16, depth: usize) void {
    vfs.listDir(dir_idx, treeEntryCallback(depth));
}

fn treeEntryCallback(depth: usize) *const fn (u16, *const vfs.Inode) void {
    return switch (depth) {
        0 => treeEntryDepth0,
        1 => treeEntryDepth1,
        2 => treeEntryDepth2,
        3 => treeEntryDepth3,
        else => treeEntryDepth4,
    };
}

fn treeEntryDepth0(idx: u16, inode: *const vfs.Inode) void {
    treeEntry(idx, inode, 0);
}

fn treeEntryDepth1(idx: u16, inode: *const vfs.Inode) void {
    treeEntry(idx, inode, 1);
}

fn treeEntryDepth2(idx: u16, inode: *const vfs.Inode) void {
    treeEntry(idx, inode, 2);
}

fn treeEntryDepth3(idx: u16, inode: *const vfs.Inode) void {
    treeEntry(idx, inode, 3);
}

fn treeEntryDepth4(idx: u16, inode: *const vfs.Inode) void {
    treeEntry(idx, inode, 4);
}

fn treeEntry(idx: u16, inode: *const vfs.Inode, depth: usize) void {
    for (0..depth) |_| {
        log.kprint("  ", .{});
    }
    log.kprintln("{s}{s}", .{
        vfs.getName(inode),
        if (inode.node_type == .directory) "/" else "",
    });

    if (inode.node_type == .directory) {
        treeDir(idx, depth + 1);
    }
}

const CreateStatus = enum {
    ok,
    already_exists,
    invalid_path,
    parent_missing,
    parent_not_dir,
    name_invalid,
    create_failed,
};

const TouchStatus = enum {
    ok,
    already_exists,
    invalid_path,
    parent_missing,
    parent_not_dir,
    name_invalid,
    create_failed,
};

const WriteStatus = enum {
    ok,
    invalid_path,
    parent_missing,
    parent_not_dir,
    name_invalid,
    write_failed,
};

const EchoRedirect = struct {
    text: []const u8,
    path: []const u8,
};

fn createDirectory(path: []const u8) CreateStatus {
    if (path.len <= 1) return .invalid_path;
    if (vfs.resolve(path) != null) return .already_exists;

    var parent_buf: [MAX_PATH]u8 = undefined;
    const target = splitParent(path, &parent_buf) orelse return .invalid_path;
    if (target.name.len == 0) return .name_invalid;

    const parent_idx = vfs.resolve(target.parent) orelse return .parent_missing;
    const parent_inode = vfs.getInode(parent_idx) orelse return .parent_missing;
    if (parent_inode.node_type != .directory) return .parent_not_dir;

    if (vfs.createDir(parent_idx, target.name) == null) return .create_failed;
    return .ok;
}

fn touchPath(path: []const u8) TouchStatus {
    if (path.len <= 1) return .invalid_path;
    if (vfs.resolve(path) != null) return .already_exists;

    var parent_buf: [MAX_PATH]u8 = undefined;
    const target = splitParent(path, &parent_buf) orelse return .invalid_path;
    if (target.name.len == 0) return .name_invalid;

    const parent_idx = vfs.resolve(target.parent) orelse return .parent_missing;
    const parent_inode = vfs.getInode(parent_idx) orelse return .parent_missing;
    if (parent_inode.node_type != .directory) return .parent_not_dir;

    const file_idx = vfs.createFile(parent_idx, target.name) orelse return .create_failed;
    if (!vfs.writeFile(file_idx, "")) return .create_failed;
    return .ok;
}

fn writePath(path: []const u8, text: []const u8) WriteStatus {
    if (path.len <= 1) return .invalid_path;

    if (vfs.resolve(path)) |idx| {
        if (!vfs.writeFile(idx, text)) return .write_failed;
        return .ok;
    }

    var parent_buf: [MAX_PATH]u8 = undefined;
    const target = splitParent(path, &parent_buf) orelse return .invalid_path;
    if (target.name.len == 0) return .name_invalid;

    const parent_idx = vfs.resolve(target.parent) orelse return .parent_missing;
    const parent_inode = vfs.getInode(parent_idx) orelse return .parent_missing;
    if (parent_inode.node_type != .directory) return .parent_not_dir;

    const file_idx = vfs.createFile(parent_idx, target.name) orelse return .write_failed;
    if (!vfs.writeFile(file_idx, text)) return .write_failed;
    return .ok;
}

const ParentSplit = struct {
    parent: []const u8,
    name: []const u8,
};

fn splitParent(path: []const u8, buffer: *[MAX_PATH]u8) ?ParentSplit {
    if (path.len == 0 or path[0] != '/') return null;

    var last_slash = path.len;
    while (last_slash > 0) : (last_slash -= 1) {
        if (path[last_slash - 1] == '/') break;
    }

    if (last_slash == 0 or last_slash > path.len) return null;
    const name = trimSpaces(path[last_slash..]);
    if (name.len == 0) return null;

    const parent = if (last_slash == 1) "/" else blk: {
        const parent_len = last_slash - 1;
        if (parent_len >= buffer.len) return null;
        @memcpy(buffer[0..parent_len], path[0..parent_len]);
        break :blk buffer[0..parent_len];
    };

    return .{ .parent = parent, .name = name };
}

fn parseEchoRedirect(args: []const u8) ?EchoRedirect {
    const trimmed = trimSpaces(args);
    var i: usize = 0;
    while (i + 1 < trimmed.len) : (i += 1) {
        if (trimmed[i] == '>' and trimmed[i + 1] != '>') {
            const left = trimSpaces(trimmed[0..i]);
            const right = trimSpaces(trimmed[i + 1 ..]);
            if (right.len == 0) return null;
            return .{ .text = left, .path = right };
        }
    }
    return null;
}

fn currentDir() []const u8 {
    return current_dir_buf[0..current_dir_len];
}

fn setCurrentDir(path: []const u8) void {
    current_dir_len = path.len;
    @memcpy(current_dir_buf[0..path.len], path);
}

fn canonicalizePath(input: []const u8, buffer: *[MAX_PATH]u8) ?[]const u8 {
    var out_len: usize = 0;
    if (input[0] == '/') {
        buffer[0] = '/';
        out_len = 1;
    } else {
        @memcpy(buffer[0..current_dir_len], current_dir_buf[0..current_dir_len]);
        out_len = current_dir_len;
    }

    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and input[i] == '/') : (i += 1) {}
        if (i >= input.len) break;

        var end = i;
        while (end < input.len and input[end] != '/') : (end += 1) {}
        const part = input[i..end];

        if (strEql(part, ".")) {
            i = end;
            continue;
        }
        if (strEql(part, "..")) {
            out_len = parentPathLen(buffer[0..out_len]);
            i = end;
            continue;
        }

        if (out_len > 1) {
            if (out_len + 1 >= buffer.len) return null;
            buffer[out_len] = '/';
            out_len += 1;
        }
        if (out_len + part.len >= buffer.len) return null;
        @memcpy(buffer[out_len .. out_len + part.len], part);
        out_len += part.len;
        i = end;
    }

    if (out_len == 0) {
        buffer[0] = '/';
        out_len = 1;
    }
    return buffer[0..out_len];
}

fn parentPathLen(path: []const u8) usize {
    if (path.len <= 1) return 1;

    var idx = path.len;
    while (idx > 1 and path[idx - 1] != '/') : (idx -= 1) {}
    if (idx <= 1) return 1;
    return idx - 1;
}
