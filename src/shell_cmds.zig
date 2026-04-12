const std = @import("std");

const ai = @import("ai.zig");
const arp = @import("arp.zig");
const arp_cache = @import("arp_cache.zig");
const dns = @import("dns.zig");
const e1000 = @import("e1000.zig");
const eth = @import("eth.zig");
const icmp = @import("icmp.zig");
const ipv4 = @import("ipv4.zig");
const log = @import("log.zig");
const net = @import("net.zig");
const pci = @import("pci.zig");
const pit = @import("pit.zig");
const pmm = @import("pmm.zig");
const procfs = @import("procfs.zig");
const scheduler = @import("scheduler.zig");
const task = @import("task.zig");
const tcp = @import("tcp.zig");
const udp = @import("udp.zig");
const vfs = @import("vfs.zig");
const vga = @import("vga.zig");

const Command = struct {
    name: []const u8,
    description: []const u8,
    handler: *const fn ([]const u8) void,
};

const commands = [_]Command{
    .{ .name = "aiask", .description = "Send one prompt to the COM2 AI proxy", .handler = cmdAiask },
    .{ .name = "aipoll", .description = "Poll one response from the COM2 AI proxy", .handler = cmdAipoll },
    .{ .name = "aistatus", .description = "Show COM2 AI proxy status", .handler = cmdAistatus },
    .{ .name = "arp", .description = "Show the ARP cache table", .handler = cmdArp },
    .{ .name = "arpreq", .description = "Send an ARP request for an IPv4 address", .handler = cmdArpreq },
    .{ .name = "arppoll", .description = "Poll one ARP reply from RX", .handler = cmdArppoll },
    .{ .name = "cat", .description = "Print a file from the virtual filesystem", .handler = cmdCat },
    .{ .name = "cd", .description = "Change the current directory", .handler = cmdCd },
    .{ .name = "clear", .description = "Clear the screen", .handler = cmdClear },
    .{ .name = "dns", .description = "Resolve a domain name to IPv4", .handler = cmdDns },
    .{ .name = "echo", .description = "Print text or write with > redirection", .handler = cmdEcho },
    .{ .name = "help", .description = "Show available commands", .handler = cmdHelp },
    .{ .name = "httpget", .description = "Simple HTTP GET request", .handler = cmdHttpget },
    .{ .name = "info", .description = "System information", .handler = cmdInfo },
    .{ .name = "kill", .description = "Kill a background task by pid", .handler = cmdKill },
    .{ .name = "ls", .description = "List a directory in the virtual filesystem", .handler = cmdLs },
    .{ .name = "lspci", .description = "List discovered PCI devices", .handler = cmdLspci },
    .{ .name = "mem", .description = "Memory statistics", .handler = cmdMem },
    .{ .name = "mkdir", .description = "Create a directory in the virtual filesystem", .handler = cmdMkdir },
    .{ .name = "netinfo", .description = "Show detected network device details", .handler = cmdNetinfo },
    .{ .name = "netpoll", .description = "Poll the Ethernet dispatch layer", .handler = cmdNetpoll },
    .{ .name = "netrx", .description = "Poll one raw Ethernet RX descriptor", .handler = cmdNetrx },
    .{ .name = "nettest", .description = "Transmit one raw Ethernet test frame", .handler = cmdNettest },
    .{ .name = "pingpoll", .description = "Poll one ICMP echo reply", .handler = cmdPingpoll },
    .{ .name = "pingtest", .description = "Send one ICMP echo request if ARP is known", .handler = cmdPingtest },
    .{ .name = "pwd", .description = "Print the current directory", .handler = cmdPwd },
    .{ .name = "ps", .description = "List tasks", .handler = cmdPs },
    .{ .name = "rm", .description = "Remove a file or empty directory", .handler = cmdRm },
    .{ .name = "spawn", .description = "Spawn a cooperative worker task", .handler = cmdSpawn },
    .{ .name = "tcpclose", .description = "Close a TCP connection", .handler = cmdTcpclose },
    .{ .name = "tcpconnect", .description = "Open a TCP connection", .handler = cmdTcpconnect },
    .{ .name = "tcprecv", .description = "Read data from a TCP connection", .handler = cmdTcprecv },
    .{ .name = "tcpsend", .description = "Send data on a TCP connection", .handler = cmdTcpsend },
    .{ .name = "tcpstat", .description = "Show TCP connection states", .handler = cmdTcpstat },
    .{ .name = "touch", .description = "Create an empty file", .handler = cmdTouch },
    .{ .name = "tree", .description = "Show a directory tree", .handler = cmdTree },
    .{ .name = "udpsend", .description = "Send a UDP datagram", .handler = cmdUdpsend },
    .{ .name = "uptime", .description = "Time since boot", .handler = cmdUptime },
    .{ .name = "yield", .description = "Yield the CPU cooperatively", .handler = cmdYield },
    .{ .name = "write", .description = "Write text to a virtual file", .handler = cmdWrite },
    .{ .name = "version", .description = "Kernel version", .handler = cmdVersion },
};

var current_dir_buf: [MAX_PATH]u8 = [_]u8{'/'} ++ [_]u8{0} ** (MAX_PATH - 1);
var current_dir_len: usize = 1;

const UDP_SHELL_SOURCE_PORT: u16 = 12345;
const DNS_COMMAND_TIMEOUT_TICKS: u64 = 500;
const HTTP_CONNECT_TIMEOUT_TICKS: u64 = 500;
const HTTP_RESPONSE_TIMEOUT_TICKS: u64 = 1000;
const HTTP_REQUEST_BUFFER_SIZE: usize = 512;
const HTTP_RESPONSE_BUFFER_SIZE: usize = 4096;

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

fn cmdAistatus(_: []const u8) void {
    const state = ai.info();
    log.kprintln("AI proxy: initialized={s} available={s}", .{
        if (state.initialized) "yes" else "no",
        if (state.available) "yes" else "no",
    });
    log.kprintln("  prompts={d} responses={d} tx={s} rx={s} response_len={d}", .{
        state.prompts_sent,
        state.responses_received,
        @tagName(state.last_send_status),
        @tagName(state.last_poll_status),
        state.response_len,
    });
}

fn cmdAiask(args: []const u8) void {
    const prompt = trimSpaces(args);
    if (prompt.len == 0) {
        log.kprintln("Usage: aiask <prompt>", .{});
        return;
    }

    const status = ai.sendPrompt(prompt);
    log.kprintln("aiask: {s}", .{@tagName(status)});
    if (status == .sent) {
        log.kprintln("COM2 protocol: ASK <prompt>", .{});
    }
}

fn cmdAipoll(_: []const u8) void {
    const status = ai.pollResponse();
    log.kprintln("aipoll: {s}", .{@tagName(status)});

    const response = ai.lastResponse();
    if ((status == .response_received or status == .partial or status == .response_truncated) and response.len > 0) {
        log.kprintln("AI response: {s}", .{response});
    }
}

fn cmdArp(_: []const u8) void {
    const cache_stats = arp_cache.getStats();
    log.kprintln("ARP cache:", .{});
    log.kprintln("  STATE     IP               MAC                AGE  RETRIES", .{});

    var printed: usize = 0;
    for (arp_cache.getTable()) |entry| {
        if (entry.state == .free) continue;

        const age = pit.getTicks() -% entry.timestamp;
        log.kprintln("  {s: <8} {d}.{d}.{d}.{d} {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2} {d: >4} {d}", .{
            @tagName(entry.state),
            entry.ip[0],
            entry.ip[1],
            entry.ip[2],
            entry.ip[3],
            entry.mac[0],
            entry.mac[1],
            entry.mac[2],
            entry.mac[3],
            entry.mac[4],
            entry.mac[5],
            age,
            entry.retries,
        });
        printed += 1;
    }

    if (printed == 0) {
        log.kprintln("  <empty>", .{});
    }
    log.kprintln("ARP cache stats: lookups={d} misses={d} req_tx={d} req_rx={d} reply_tx={d} reply_rx={d} retries={d} expired={d}", .{
        cache_stats.lookups,
        cache_stats.misses,
        cache_stats.requests_sent,
        cache_stats.requests_received,
        cache_stats.replies_sent,
        cache_stats.replies_received,
        cache_stats.retries,
        cache_stats.expired,
    });
}

fn cmdArpreq(args: []const u8) void {
    const trimmed = trimSpaces(args);
    const target_ip = if (trimmed.len == 0) arp.DEFAULT_TARGET_IP else parseIpv4(trimmed) orelse {
        log.kprintln("Usage: arpreq [a.b.c.d]", .{});
        return;
    };

    const status = arp.sendRequest(target_ip, arp.DEFAULT_LOCAL_IP);
    const info = arp.info();
    log.kprintln("arpreq: {s}", .{@tagName(status)});
    log.kprintln("ARP who-has {d}.{d}.{d}.{d} tell {d}.{d}.{d}.{d}", .{
        info.last_target_ip[0],
        info.last_target_ip[1],
        info.last_target_ip[2],
        info.last_target_ip[3],
        info.last_sender_ip[0],
        info.last_sender_ip[1],
        info.last_sender_ip[2],
        info.last_sender_ip[3],
    });
    log.kprintln("ARP requests sent: {d}", .{info.requests_sent});
    if (status == .sent) {
        arp_cache.markPending(target_ip);
    }
}

fn cmdArppoll(_: []const u8) void {
    const status = arp.pollReply();
    const info = arp.info();
    log.kprintln("arppoll: {s}", .{@tagName(status)});
    if (status == .reply_received) {
        arp_cache.addStatic(info.last_reply_ip, info.last_reply_mac);
        log.kprintln("ARP reply: {d}.{d}.{d}.{d} is-at {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            info.last_reply_ip[0],
            info.last_reply_ip[1],
            info.last_reply_ip[2],
            info.last_reply_ip[3],
            info.last_reply_mac[0],
            info.last_reply_mac[1],
            info.last_reply_mac[2],
            info.last_reply_mac[3],
            info.last_reply_mac[4],
            info.last_reply_mac[5],
        });
    }
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
    const rx = e1000.receiveInfo();

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
    log.kprintln("MAC:    {s} {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        if (nic.mac_valid) "valid" else "unknown",
        nic.mac[0],
        nic.mac[1],
        nic.mac[2],
        nic.mac[3],
        nic.mac[4],
        nic.mac[5],
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
    log.kprintln("RX stats: frames={d} last={s} len={d} ethertype=0x{x:0>4}", .{
        rx.frames_received,
        @tagName(rx.last_status),
        rx.last_length,
        rx.last_ethertype,
    });
    const arp_info = arp.info();
    log.kprintln("ARP stats: requests={d} replies={d} tx={s} rx={s} target={d}.{d}.{d}.{d}", .{
        arp_info.requests_sent,
        arp_info.replies_received,
        @tagName(arp_info.last_status),
        @tagName(arp_info.last_poll_status),
        arp_info.last_target_ip[0],
        arp_info.last_target_ip[1],
        arp_info.last_target_ip[2],
        arp_info.last_target_ip[3],
    });
    const icmp_info = icmp.info();
    log.kprintln("ICMP stats: requests={d} replies={d} tx={s} rx={s} target={d}.{d}.{d}.{d}", .{
        icmp_info.requests_sent,
        icmp_info.replies_received,
        @tagName(icmp_info.last_status),
        @tagName(icmp_info.last_poll_status),
        icmp_info.last_target_ip[0],
        icmp_info.last_target_ip[1],
        icmp_info.last_target_ip[2],
        icmp_info.last_target_ip[3],
    });
    const eth_stats = eth.getStats();
    log.kprintln("ETH stats: rx={d} tx={d} arp={d} ipv4={d} unknown={d} errors={d} last_rx={s} last_tx={s}", .{
        eth_stats.frames_received,
        eth_stats.frames_sent,
        eth_stats.arp_received,
        eth_stats.ipv4_received,
        eth_stats.unknown_received,
        eth_stats.errors,
        @tagName(eth_stats.last_poll_result),
        @tagName(eth_stats.last_tx_status),
    });
    const ipv4_stats = ipv4.getStats();
    log.kprintln("IPv4 stats: rx={d} tx={d} bad_csum={d} bad_ver={d} frag_drop={d} no_handler={d} arp_pending={d} last_proto={d} last_tx={s}", .{
        ipv4_stats.packets_received,
        ipv4_stats.packets_sent,
        ipv4_stats.bad_checksum,
        ipv4_stats.bad_version,
        ipv4_stats.fragmented_dropped,
        ipv4_stats.no_handler,
        ipv4_stats.arp_pending,
        ipv4_stats.last_protocol,
        @tagName(ipv4_stats.last_send_status),
    });
    const udp_stats = udp.getStats();
    log.kprintln("UDP stats: rx={d} tx={d} bad_csum={d} malformed={d} no_binding={d} send_errors={d} last_tx={s} ports={d}->{d}", .{
        udp_stats.datagrams_received,
        udp_stats.datagrams_sent,
        udp_stats.bad_checksum,
        udp_stats.malformed,
        udp_stats.no_binding,
        udp_stats.send_errors,
        @tagName(udp_stats.last_send_status),
        udp_stats.last_src_port,
        udp_stats.last_dst_port,
    });
    const tcp_stats = tcp.getStats();
    log.kprintln("TCP stats: rx={d} tx={d} opened={d} closed={d} retrans={d} rst={d} bad_csum={d} send_errors={d} last_tx={s}", .{
        tcp_stats.segments_received,
        tcp_stats.segments_sent,
        tcp_stats.connections_opened,
        tcp_stats.connections_closed,
        tcp_stats.retransmits,
        tcp_stats.resets_sent,
        tcp_stats.bad_checksum,
        tcp_stats.send_errors,
        @tagName(tcp_stats.last_send_status),
    });
    const dns_stats = dns.getStats();
    log.kprintln("DNS stats: queries={d} responses={d} hits={d} misses={d} timeouts={d} malformed={d} send_errors={d} last_tx={s}", .{
        dns_stats.queries_sent,
        dns_stats.responses_received,
        dns_stats.cache_hits,
        dns_stats.cache_misses,
        dns_stats.timeouts,
        dns_stats.malformed,
        dns_stats.send_errors,
        @tagName(dns_stats.last_send_status),
    });
    const cache_stats = arp_cache.getStats();
    log.kprintln("ARP cache: lookups={d} misses={d} req_tx={d} req_rx={d} reply_tx={d} reply_rx={d} retries={d} expired={d}", .{
        cache_stats.lookups,
        cache_stats.misses,
        cache_stats.requests_sent,
        cache_stats.requests_received,
        cache_stats.replies_sent,
        cache_stats.replies_received,
        cache_stats.retries,
        cache_stats.expired,
    });
    log.kprintln("IRQ:    line={d} pin={d}", .{
        nic.device.interrupt_line,
        nic.device.interrupt_pin,
    });
}

fn cmdNetpoll(args: []const u8) void {
    const trimmed = trimSpaces(args);
    const count = if (trimmed.len == 0) 10 else parseUsize(trimmed, 1000) orelse {
        log.kprintln("Usage: netpoll [count]", .{});
        return;
    };

    const processed = serviceNetwork(count);
    const stats = eth.getStats();
    log.kprintln("netpoll: processed={d} requested={d} last={s}", .{
        processed,
        count,
        @tagName(stats.last_poll_result),
    });
    log.kprintln("ETH stats: rx={d} tx={d} arp={d} ipv4={d} unknown={d} errors={d} last_ethertype=0x{x:0>4}", .{
        stats.frames_received,
        stats.frames_sent,
        stats.arp_received,
        stats.ipv4_received,
        stats.unknown_received,
        stats.errors,
        stats.last_ethertype,
    });
    const ipv4_stats = ipv4.getStats();
    log.kprintln("IPv4 stats: rx={d} tx={d} bad_csum={d} malformed={d} no_handler={d} last_proto={d}", .{
        ipv4_stats.packets_received,
        ipv4_stats.packets_sent,
        ipv4_stats.bad_checksum,
        ipv4_stats.malformed,
        ipv4_stats.no_handler,
        ipv4_stats.last_protocol,
    });
    const udp_stats = udp.getStats();
    log.kprintln("UDP stats: rx={d} tx={d} bad_csum={d} malformed={d} no_binding={d} send_errors={d}", .{
        udp_stats.datagrams_received,
        udp_stats.datagrams_sent,
        udp_stats.bad_checksum,
        udp_stats.malformed,
        udp_stats.no_binding,
        udp_stats.send_errors,
    });
    const tcp_stats = tcp.getStats();
    log.kprintln("TCP stats: rx={d} tx={d} opened={d} closed={d} retrans={d} rst={d} bad_csum={d} send_errors={d}", .{
        tcp_stats.segments_received,
        tcp_stats.segments_sent,
        tcp_stats.connections_opened,
        tcp_stats.connections_closed,
        tcp_stats.retransmits,
        tcp_stats.resets_sent,
        tcp_stats.bad_checksum,
        tcp_stats.send_errors,
    });
    const dns_stats = dns.getStats();
    log.kprintln("DNS stats: queries={d} responses={d} hits={d} misses={d} timeouts={d} malformed={d} send_errors={d}", .{
        dns_stats.queries_sent,
        dns_stats.responses_received,
        dns_stats.cache_hits,
        dns_stats.cache_misses,
        dns_stats.timeouts,
        dns_stats.malformed,
        dns_stats.send_errors,
    });
}

fn cmdNetrx(_: []const u8) void {
    const status = e1000.pollReceive();
    const rx = e1000.receiveInfo();

    log.kprintln("netrx: {s}", .{@tagName(status)});
    if (status == .received) {
        log.kprintln("RX frame: len={d} ethertype=0x{x:0>4}", .{
            rx.last_length,
            rx.last_ethertype,
        });
        log.kprintln("  src={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            rx.last_src[0],
            rx.last_src[1],
            rx.last_src[2],
            rx.last_src[3],
            rx.last_src[4],
            rx.last_src[5],
        });
        log.kprintln("  dst={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            rx.last_dst[0],
            rx.last_dst[1],
            rx.last_dst[2],
            rx.last_dst[3],
            rx.last_dst[4],
            rx.last_dst[5],
        });
    }
}

fn cmdNettest(_: []const u8) void {
    const status = e1000.transmitTestFrame();
    e1000.refresh();

    const rings = e1000.ringInfo();
    log.kprintln("nettest: {s}", .{@tagName(status)});
    log.kprintln("TX ring: head={d} tail={d}", .{ rings.tx_head, rings.tx_tail });
}

fn cmdPingtest(args: []const u8) void {
    const trimmed = trimSpaces(args);
    const target_ip = if (trimmed.len == 0) arp.DEFAULT_TARGET_IP else parseIpv4(trimmed) orelse {
        log.kprintln("Usage: pingtest [a.b.c.d]", .{});
        return;
    };

    const status = icmp.sendEchoRequest(target_ip, arp.DEFAULT_LOCAL_IP);
    const info = icmp.info();
    log.kprintln("pingtest: {s}", .{@tagName(status)});
    log.kprintln("ICMP echo {d}.{d}.{d}.{d} -> {d}.{d}.{d}.{d}", .{
        info.last_source_ip[0],
        info.last_source_ip[1],
        info.last_source_ip[2],
        info.last_source_ip[3],
        info.last_target_ip[0],
        info.last_target_ip[1],
        info.last_target_ip[2],
        info.last_target_ip[3],
    });
    if (status == .no_arp_entry) {
        log.kprintln("Run arpreq/arppoll first to learn the target MAC.", .{});
    }
}

fn cmdPingpoll(_: []const u8) void {
    _ = eth.pollAll(10);
    arp_cache.tick();
    const status = icmp.pollEchoReply(arp.DEFAULT_LOCAL_IP);
    const info = icmp.info();

    log.kprintln("pingpoll: {s}", .{@tagName(status)});
    if (status == .echo_reply_received) {
        log.kprintln("ICMP reply from {d}.{d}.{d}.{d} seq={d}", .{
            info.last_reply_ip[0],
            info.last_reply_ip[1],
            info.last_reply_ip[2],
            info.last_reply_ip[3],
            info.last_reply_sequence,
        });
        log.kprintln("  mac={x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
            info.last_reply_mac[0],
            info.last_reply_mac[1],
            info.last_reply_mac[2],
            info.last_reply_mac[3],
            info.last_reply_mac[4],
            info.last_reply_mac[5],
        });
    }
}

fn cmdUdpsend(args: []const u8) void {
    var rest = trimSpaces(args);
    const ip_token = takeToken(&rest) orelse {
        log.kprintln("Usage: udpsend <ip> <port> <message>", .{});
        return;
    };
    const port_token = takeToken(&rest) orelse {
        log.kprintln("Usage: udpsend <ip> <port> <message>", .{});
        return;
    };

    const target_ip = parseIpv4(ip_token) orelse {
        log.kprintln("Usage: udpsend <ip> <port> <message>", .{});
        return;
    };
    const target_port = parseU16(port_token) orelse {
        log.kprintln("Usage: udpsend <ip> <port> <message>", .{});
        return;
    };
    const message = stripDoubleQuotes(trimSpaces(rest));
    if (message.len == 0) {
        log.kprintln("Usage: udpsend <ip> <port> <message>", .{});
        return;
    }

    const status = udp.send(UDP_SHELL_SOURCE_PORT, target_ip, target_port, message);
    log.kprintln("udpsend: {s}", .{@tagName(status)});
    log.kprintln("UDP {d} -> {d}.{d}.{d}.{d}:{d} bytes={d}", .{
        UDP_SHELL_SOURCE_PORT,
        target_ip[0],
        target_ip[1],
        target_ip[2],
        target_ip[3],
        target_port,
        message.len,
    });
    if (status == .arp_pending) {
        log.kprintln("Run netpoll and retry after ARP resolves.", .{});
    }
}

fn cmdDns(args: []const u8) void {
    const name = stripDoubleQuotes(trimSpaces(args));
    if (name.len == 0) {
        log.kprintln("Usage: dns <domain>", .{});
        return;
    }

    var resolved_ip: net.Ipv4Addr = undefined;
    const status = resolveDnsBlocking(name, &resolved_ip);
    switch (status) {
        .resolved => log.kprintln("dns: {s} -> {d}.{d}.{d}.{d}", .{
            name,
            resolved_ip[0],
            resolved_ip[1],
            resolved_ip[2],
            resolved_ip[3],
        }),
        .pending => log.kprintln("dns: pending for {s}; run netpoll and retry", .{name}),
        .not_found => log.kprintln("dns: {s} not found", .{name}),
        .timeout => log.kprintln("dns: timeout resolving {s}", .{name}),
        .server_error => log.kprintln("dns: server error resolving {s}", .{name}),
        .name_too_long => log.kprintln("dns: name too long", .{}),
        .invalid_name => log.kprintln("dns: invalid name", .{}),
        .no_dns_server => log.kprintln("dns: no DNS server configured", .{}),
        .send_error => log.kprintln("dns: send error", .{}),
    }
}

fn cmdHttpget(args: []const u8) void {
    var rest = trimSpaces(args);
    const host = stripDoubleQuotes(takeToken(&rest) orelse {
        log.kprintln("Usage: httpget <host-or-ip> <port> <path>", .{});
        return;
    });
    const port_token = takeToken(&rest) orelse {
        log.kprintln("Usage: httpget <host-or-ip> <port> <path>", .{});
        return;
    };
    const path = stripDoubleQuotes(trimSpaces(rest));
    if (path.len == 0 or path[0] != '/') {
        log.kprintln("Usage: httpget <host-or-ip> <port> <path>", .{});
        return;
    }

    const port = parseU16(port_token) orelse {
        log.kprintln("Usage: httpget <host-or-ip> <port> <path>", .{});
        return;
    };

    var target_ip: net.Ipv4Addr = undefined;
    const resolve_status = resolveHostBlocking(host, &target_ip);
    if (resolve_status != .resolved) {
        log.kprintln("httpget: resolve {s} failed: {s}", .{ host, @tagName(resolve_status) });
        return;
    }

    var conn_id: tcp.ConnId = 0;
    const connect_status = tcp.connect(target_ip, port, &conn_id);
    if (connect_status != .ok) {
        log.kprintln("httpget: connect failed: {s}", .{@tagName(connect_status)});
        return;
    }

    var state = tcp.State.syn_sent;
    const connect_start = pit.getTicks();
    while (pit.getTicks() -% connect_start < HTTP_CONNECT_TIMEOUT_TICKS) {
        if (tcp.getConnection(conn_id)) |conn| {
            state = conn.state;
            if (state == .established or state == .closed) break;
        } else {
            state = .closed;
            break;
        }
        _ = serviceNetwork(10);
    }

    if (state != .established) {
        log.kprintln("httpget: connect timeout conn={d} state={s}", .{ conn_id, @tagName(state) });
        tcp.close(conn_id);
        return;
    }

    var request_buf: [HTTP_REQUEST_BUFFER_SIZE]u8 = undefined;
    const request = std.fmt.bufPrint(
        &request_buf,
        "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n",
        .{ path, host },
    ) catch {
        log.kprintln("httpget: request too large", .{});
        tcp.close(conn_id);
        return;
    };

    const send_status = tcp.send(conn_id, request);
    if (send_status != .ok) {
        log.kprintln("httpget: send failed: {s}", .{@tagName(send_status)});
        tcp.close(conn_id);
        return;
    }

    var response_buf: [HTTP_RESPONSE_BUFFER_SIZE]u8 = undefined;
    var response_len: usize = 0;
    var response_truncated = false;
    const response_start = pit.getTicks();
    while (pit.getTicks() -% response_start < HTTP_RESPONSE_TIMEOUT_TICKS) {
        _ = serviceNetwork(20);
        response_truncated = drainTcpRecv(conn_id, &response_buf, &response_len) or response_truncated;

        if (tcp.getConnection(conn_id)) |conn| {
            state = conn.state;
            if (state == .closed or state == .time_wait) break;
        } else {
            state = .closed;
            break;
        }
    }

    if (response_len == 0) {
        log.kprintln("httpget: no response conn={d} state={s}", .{ conn_id, @tagName(state) });
    } else {
        log.kprintln("httpget: conn={d} state={s} bytes={d}{s}", .{
            conn_id,
            @tagName(state),
            response_len,
            if (response_truncated) " truncated" else "",
        });
        log.kprintln("{s}", .{response_buf[0..response_len]});
    }

    if (state == .established or state == .close_wait) {
        tcp.close(conn_id);
    }
}

fn cmdTcpconnect(args: []const u8) void {
    var rest = trimSpaces(args);
    const ip_token = takeToken(&rest) orelse {
        log.kprintln("Usage: tcpconnect <ip> <port>", .{});
        return;
    };
    const port_token = takeToken(&rest) orelse {
        log.kprintln("Usage: tcpconnect <ip> <port>", .{});
        return;
    };

    const target_ip = parseIpv4(ip_token) orelse {
        log.kprintln("Usage: tcpconnect <ip> <port>", .{});
        return;
    };
    const target_port = parseU16(port_token) orelse {
        log.kprintln("Usage: tcpconnect <ip> <port>", .{});
        return;
    };

    var conn_id: tcp.ConnId = 0;
    const result = tcp.connect(target_ip, target_port, &conn_id);
    log.kprintln("tcpconnect: {s}", .{@tagName(result)});
    if (result == .ok) {
        const stats = tcp.getStats();
        log.kprintln("TCP conn={d} -> {d}.{d}.{d}.{d}:{d} state=syn_sent tx={s}", .{
            conn_id,
            target_ip[0],
            target_ip[1],
            target_ip[2],
            target_ip[3],
            target_port,
            @tagName(stats.last_send_status),
        });
        if (stats.last_send_status == .arp_pending) {
            log.kprintln("Run netpoll and retry after ARP resolves.", .{});
        }
    }
}

fn cmdTcpsend(args: []const u8) void {
    var rest = trimSpaces(args);
    const conn_token = takeToken(&rest) orelse {
        log.kprintln("Usage: tcpsend <conn> <data>", .{});
        return;
    };
    const conn_id = parseConnId(conn_token) orelse {
        log.kprintln("Usage: tcpsend <conn> <data>", .{});
        return;
    };
    const data = stripDoubleQuotes(trimSpaces(rest));
    if (data.len == 0) {
        log.kprintln("Usage: tcpsend <conn> <data>", .{});
        return;
    }

    const result = tcp.send(conn_id, data);
    log.kprintln("tcpsend: {s} conn={d} bytes={d}", .{ @tagName(result), conn_id, data.len });
}

fn cmdTcprecv(args: []const u8) void {
    const conn_id = parseConnId(trimSpaces(args)) orelse {
        log.kprintln("Usage: tcprecv <conn>", .{});
        return;
    };

    const result = tcp.recv(conn_id);
    log.kprintln("tcprecv: conn={d} state={s} bytes={d}", .{ conn_id, @tagName(result.state), result.data.len });
    if (result.data.len > 0) {
        log.kprintln("{s}", .{result.data});
    }
}

fn cmdTcpclose(args: []const u8) void {
    const conn_id = parseConnId(trimSpaces(args)) orelse {
        log.kprintln("Usage: tcpclose <conn>", .{});
        return;
    };

    tcp.close(conn_id);
    const conn = tcp.getConnection(conn_id);
    log.kprintln("tcpclose: conn={d} state={s}", .{
        conn_id,
        if (conn) |entry| @tagName(entry.state) else "invalid",
    });
}

fn cmdTcpstat(_: []const u8) void {
    const stats = tcp.getStats();
    log.kprintln("TCP stats: rx={d} tx={d} opened={d} closed={d} retrans={d} rst={d} bad_csum={d} malformed={d} send_errors={d} last_tx={s}", .{
        stats.segments_received,
        stats.segments_sent,
        stats.connections_opened,
        stats.connections_closed,
        stats.retransmits,
        stats.resets_sent,
        stats.bad_checksum,
        stats.malformed,
        stats.send_errors,
        @tagName(stats.last_send_status),
    });
    log.kprintln("  ID STATE        LOCAL  REMOTE              SND_NXT    RCV_NXT    RX TX", .{});
    for (0..tcp.MAX_CONNECTIONS) |i| {
        const conn_id: tcp.ConnId = @intCast(i);
        const conn = tcp.getConnection(conn_id) orelse continue;
        if (conn.state == .closed) continue;
        log.kprintln("  {d}  {s: <12} {d: <6} {d}.{d}.{d}.{d}:{d: <6} {d: <10} {d: <10} {d: <2} {d}", .{
            i,
            @tagName(conn.state),
            conn.local_port,
            conn.remote_ip[0],
            conn.remote_ip[1],
            conn.remote_ip[2],
            conn.remote_ip[3],
            conn.remote_port,
            conn.snd_nxt,
            conn.rcv_nxt,
            conn.rx_len,
            conn.tx_len,
        });
    }
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

fn serviceNetwork(max_frames: usize) usize {
    const processed = eth.pollAll(max_frames);
    arp_cache.tick();
    tcp.tick();
    dns.tick();
    return processed;
}

fn resolveHostBlocking(host: []const u8, ip_out: *net.Ipv4Addr) dns.ResolveStatus {
    if (parseIpv4(host)) |ip| {
        ip_out.* = ip;
        return .resolved;
    }
    return resolveDnsBlocking(host, ip_out);
}

fn resolveDnsBlocking(name: []const u8, ip_out: *net.Ipv4Addr) dns.ResolveStatus {
    var status = dns.resolve(name, ip_out);
    const start_tick = pit.getTicks();
    while (status == .pending and pit.getTicks() -% start_tick < DNS_COMMAND_TIMEOUT_TICKS) {
        _ = serviceNetwork(10);
        status = dns.resolve(name, ip_out);
    }

    if (status == .pending) {
        dns.tick();
        status = dns.resolve(name, ip_out);
    }
    return status;
}

fn drainTcpRecv(conn_id: tcp.ConnId, buffer: *[HTTP_RESPONSE_BUFFER_SIZE]u8, len: *usize) bool {
    const result = tcp.recv(conn_id);
    if (result.data.len == 0) return false;

    const available = buffer.len - len.*;
    const copy_len = if (result.data.len < available) result.data.len else available;
    if (copy_len > 0) {
        @memcpy(buffer[len.* .. len.* + copy_len], result.data[0..copy_len]);
        len.* += copy_len;
    }
    return copy_len < result.data.len;
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

fn takeToken(rest: *[]const u8) ?[]const u8 {
    const trimmed = trimSpaces(rest.*);
    if (trimmed.len == 0) {
        rest.* = "";
        return null;
    }

    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ') : (end += 1) {}

    rest.* = trimSpaces(trimmed[end..]);
    return trimmed[0..end];
}

fn stripDoubleQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
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

fn parseIpv4(value: []const u8) ?arp.Ipv4 {
    var out: arp.Ipv4 = undefined;
    var octet_index: usize = 0;
    var start: usize = 0;

    while (octet_index < 4) : (octet_index += 1) {
        var end = start;
        while (end < value.len and value[end] != '.') : (end += 1) {}

        if (end == start) return null;
        out[octet_index] = parseU8(value[start..end]) orelse return null;

        if (octet_index == 3) {
            if (end != value.len) return null;
        } else {
            if (end >= value.len or value[end] != '.') return null;
            start = end + 1;
        }
    }

    return out;
}

fn parseU8(value: []const u8) ?u8 {
    var result: u16 = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        result = result * 10 + (ch - '0');
        if (result > 255) return null;
    }
    return @intCast(result);
}

fn parseU16(value: []const u8) ?u16 {
    var result: u32 = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        result = result * 10 + (ch - '0');
        if (result > 65535) return null;
    }
    return @intCast(result);
}

fn parseConnId(value: []const u8) ?tcp.ConnId {
    const id = parseUsize(value, tcp.MAX_CONNECTIONS - 1) orelse return null;
    return @intCast(id);
}

fn parseUsize(value: []const u8, max_value: usize) ?usize {
    var result: usize = 0;
    for (value) |ch| {
        if (ch < '0' or ch > '9') return null;
        result = result * 10 + (ch - '0');
        if (result > max_value) return null;
    }
    return result;
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
