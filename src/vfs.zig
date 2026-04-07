pub const MAX_INODES = 128;
pub const MAX_NAME = 64;
pub const MAX_DATA = 4096;

pub const NodeType = enum(u8) {
    directory,
    regular_file,
    device,
    proc_node,
};

pub const Inode = struct {
    name: [MAX_NAME]u8 = [_]u8{0} ** MAX_NAME,
    name_len: u8 = 0,
    node_type: NodeType = .regular_file,
    parent: u16 = 0,
    data: [MAX_DATA]u8 = [_]u8{0} ** MAX_DATA,
    data_len: u16 = 0,
    active: bool = false,
};

var inodes: [MAX_INODES]Inode = [_]Inode{.{}} ** MAX_INODES;

pub fn init() void {
    inodes = [_]Inode{.{}} ** MAX_INODES;

    var root = &inodes[0];
    root.active = true;
    root.node_type = .directory;
    root.parent = 0;
    setName(root, "/");

    _ = createDir(0, "tmp");
    _ = createDir(0, "dev");
    _ = createDir(0, "proc");
    _ = createDir(0, "etc");
}

pub fn createDir(parent: u16, name: []const u8) ?u16 {
    return createNode(parent, name, .directory);
}

pub fn createFile(parent: u16, name: []const u8) ?u16 {
    return createNode(parent, name, .regular_file);
}

pub fn createDevice(parent: u16, name: []const u8) ?u16 {
    return createNode(parent, name, .device);
}

pub fn createProcNode(parent: u16, name: []const u8) ?u16 {
    return createNode(parent, name, .proc_node);
}

pub fn writeFile(idx: u16, data: []const u8) bool {
    if (idx >= MAX_INODES) return false;

    var inode = &inodes[idx];
    if (!inode.active or inode.node_type == .directory) return false;

    const copy_len = @min(data.len, MAX_DATA);
    @memcpy(inode.data[0..copy_len], data[0..copy_len]);
    inode.data_len = @intCast(copy_len);
    return true;
}

pub fn readFile(idx: u16) ?[]const u8 {
    const inode = getInode(idx) orelse return null;
    if (inode.node_type == .directory) return null;
    return inode.data[0..inode.data_len];
}

pub fn resolve(path: []const u8) ?u16 {
    if (path.len == 0 or path[0] != '/') return null;
    if (path.len == 1) return 0;

    var current: u16 = 0;
    var start: usize = 1;

    while (start < path.len) {
        while (start < path.len and path[start] == '/') : (start += 1) {}
        if (start >= path.len) break;

        var end = start;
        while (end < path.len and path[end] != '/') : (end += 1) {}

        current = findChild(current, path[start..end]) orelse return null;
        start = end;
    }

    return current;
}

pub fn listDir(dir_idx: u16, callback: *const fn (u16, *const Inode) void) void {
    const dir = getInode(dir_idx) orelse return;
    if (dir.node_type != .directory) return;

    for (0..MAX_INODES) |i| {
        const inode = &inodes[i];
        if (inode.active and inode.parent == dir_idx and i != dir_idx) {
            callback(@intCast(i), inode);
        }
    }
}

pub const RemoveStatus = enum {
    ok,
    not_found,
    busy,
    not_empty,
};

pub fn remove(idx: u16) RemoveStatus {
    if (idx == 0) return .busy;

    const inode = getInode(idx) orelse return .not_found;
    if (inode.node_type == .directory and !isDirEmpty(idx)) return .not_empty;

    inodes[idx] = .{};
    return .ok;
}

pub fn getName(inode: *const Inode) []const u8 {
    return inode.name[0..inode.name_len];
}

pub fn getInode(idx: u16) ?*Inode {
    if (idx >= MAX_INODES) return null;
    if (!inodes[idx].active) return null;
    return &inodes[idx];
}

fn createNode(parent: u16, name: []const u8, node_type: NodeType) ?u16 {
    const parent_inode = getInode(parent) orelse return null;
    if (parent_inode.node_type != .directory) return null;
    if (findChild(parent, name) != null) return null;

    const idx = allocInode() orelse return null;
    var inode = &inodes[idx];
    inode.active = true;
    inode.node_type = node_type;
    inode.parent = parent;
    inode.data_len = 0;
    setName(inode, name);
    return idx;
}

fn allocInode() ?u16 {
    for (0..MAX_INODES) |i| {
        if (!inodes[i].active) return @intCast(i);
    }
    return null;
}

fn findChild(parent: u16, name: []const u8) ?u16 {
    for (0..MAX_INODES) |i| {
        const inode = &inodes[i];
        if (inode.active and inode.parent == parent and i != parent) {
            if (strEql(getName(inode), name)) return @intCast(i);
        }
    }
    return null;
}

fn isDirEmpty(dir_idx: u16) bool {
    for (0..MAX_INODES) |i| {
        const inode = &inodes[i];
        if (inode.active and inode.parent == dir_idx and i != dir_idx) return false;
    }
    return true;
}

fn setName(inode: *Inode, name: []const u8) void {
    const copy_len = @min(name.len, MAX_NAME - 1);
    @memcpy(inode.name[0..copy_len], name[0..copy_len]);
    inode.name[copy_len] = 0;
    inode.name_len = @intCast(copy_len);
}

fn strEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}
