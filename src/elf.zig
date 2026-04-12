const cpu = @import("cpu.zig");
const pmm = @import("pmm.zig");
const user_mem = @import("user_mem.zig");

pub const MAX_LOAD_SEGMENTS: usize = 8;

const ELF_MAGIC = [4]u8{ 0x7F, 'E', 'L', 'F' };
const ELFCLASS64: u8 = 2;
const ELFDATA2LSB: u8 = 1;
const ET_EXEC: u16 = 2;
const EM_X86_64: u16 = 62;
const PT_LOAD: u32 = 1;
const PF_X: u32 = 1;
const PF_W: u32 = 2;

const ELF_HEADER_SIZE: usize = 64;
const PHDR_ENTRY_SIZE: usize = 56;
const PAGE_SIZE: u64 = pmm.PAGE_SIZE;
const PAGE_FRAME_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const PAGE_MASK: u64 = PAGE_SIZE - 1;
const MAX_U64: u64 = ~@as(u64, 0);

const OFF_MAGIC: usize = 0;
const OFF_CLASS: usize = 4;
const OFF_DATA: usize = 5;
const OFF_TYPE: usize = 16;
const OFF_MACHINE: usize = 18;
const OFF_ENTRY: usize = 24;
const OFF_PHOFF: usize = 32;
const OFF_PHENTSIZE: usize = 54;
const OFF_PHNUM: usize = 56;

const PH_OFF_TYPE: usize = 0;
const PH_OFF_FLAGS: usize = 4;
const PH_OFF_OFFSET: usize = 8;
const PH_OFF_VADDR: usize = 16;
const PH_OFF_FILESZ: usize = 32;
const PH_OFF_MEMSZ: usize = 40;

pub const LoadSegment = struct {
    vaddr: u64,
    file_offset: u64,
    file_size: u64,
    mem_size: u64,
    writable: bool,
    executable: bool,
};

pub const ParseResult = struct {
    entry_point: u64,
    segments: [MAX_LOAD_SEGMENTS]LoadSegment,
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

pub const sample_exec = [_]u8{
    0x7F, 'E',  'L',  'F',  0x02, 0x01, 0x01, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x02, 0x00, 0x3E, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x40, 0x00, 0x38, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00,
    0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x40, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,

    0xC3,
};

pub fn parse(data: []const u8, result: *ParseResult) ParseError {
    result.* = emptyResult();

    if (data.len < ELF_HEADER_SIZE) return .too_small;
    if (!hasMagic(data)) return .bad_magic;
    if (data[OFF_CLASS] != ELFCLASS64) return .not_64bit;
    if (data[OFF_DATA] != ELFDATA2LSB) return .not_little_endian;
    if (readLe16(data, OFF_TYPE) != ET_EXEC) return .not_executable;
    if (readLe16(data, OFF_MACHINE) != EM_X86_64) return .not_x86_64;

    const entry = readLe64(data, OFF_ENTRY);
    if (!validUserRange(entry, 1)) return .invalid_segment;

    const phoff = readLe64(data, OFF_PHOFF);
    const phentsize = readLe16(data, OFF_PHENTSIZE);
    const phnum = readLe16(data, OFF_PHNUM);
    if (phentsize < PHDR_ENTRY_SIZE) return .invalid_segment;

    result.entry_point = entry;

    var index: u16 = 0;
    while (index < phnum) : (index += 1) {
        const ph_offset_u64 = checkedAddU64(phoff, @as(u64, index) * @as(u64, phentsize)) orelse return .invalid_segment;
        const ph_offset = toUsize(ph_offset_u64) orelse return .invalid_segment;
        if (!rangeInSlice(data, ph_offset, PHDR_ENTRY_SIZE)) return .invalid_segment;

        const p_type = readLe32(data, ph_offset + PH_OFF_TYPE);
        if (p_type != PT_LOAD) continue;
        if (result.segment_count >= MAX_LOAD_SEGMENTS) return .too_many_segments;

        const segment = LoadSegment{
            .vaddr = readLe64(data, ph_offset + PH_OFF_VADDR),
            .file_offset = readLe64(data, ph_offset + PH_OFF_OFFSET),
            .file_size = readLe64(data, ph_offset + PH_OFF_FILESZ),
            .mem_size = readLe64(data, ph_offset + PH_OFF_MEMSZ),
            .writable = (readLe32(data, ph_offset + PH_OFF_FLAGS) & PF_W) != 0,
            .executable = (readLe32(data, ph_offset + PH_OFF_FLAGS) & PF_X) != 0,
        };
        if (!validSegment(data, segment)) return .invalid_segment;

        result.segments[result.segment_count] = segment;
        result.segment_count += 1;
    }

    return .ok;
}

pub fn load(data: []const u8, result: *const ParseResult, addr_space: *user_mem.AddressSpace) bool {
    var segment_index: usize = 0;
    while (segment_index < result.segment_count) : (segment_index += 1) {
        const segment = result.segments[segment_index];
        if (!mapSegment(addr_space, segment)) return false;
        if (!copySegment(data, segment, addr_space)) return false;
    }

    return true;
}

fn mapSegment(addr_space: *user_mem.AddressSpace, segment: LoadSegment) bool {
    if (segment.mem_size == 0) return true;

    const start_page = alignDown(segment.vaddr);
    const end_addr = checkedAddU64(segment.vaddr, segment.mem_size) orelse return false;
    const end_page = alignUp(end_addr) orelse return false;

    var page = start_page;
    while (page < end_page) : (page += PAGE_SIZE) {
        // The current user memory API has no permission-tightening pass yet;
        // flat user programs are also loaded into writable text pages.
        if (!user_mem.mapUserPage(addr_space, page, true)) return false;
    }

    return true;
}

fn copySegment(data: []const u8, segment: LoadSegment, addr_space: *user_mem.AddressSpace) bool {
    const file_offset = toUsize(segment.file_offset) orelse return false;
    const file_size = toUsize(segment.file_size) orelse return false;
    const mem_size = toUsize(segment.mem_size) orelse return false;
    if (!rangeInSlice(data, file_offset, file_size)) return false;

    const saved_cr3 = cpu.readCr3() & PAGE_FRAME_MASK;
    user_mem.activate(addr_space);
    defer cpu.writeCr3(saved_cr3);

    const dest: [*]volatile u8 = @ptrFromInt(segment.vaddr);
    const src = data[file_offset .. file_offset + file_size];
    for (src, 0..) |byte, offset| {
        dest[offset] = byte;
    }

    var offset = file_size;
    while (offset < mem_size) : (offset += 1) {
        dest[offset] = 0;
    }

    return true;
}

fn validSegment(data: []const u8, segment: LoadSegment) bool {
    if (segment.mem_size < segment.file_size) return false;
    if (segment.mem_size == 0) return segment.file_size == 0;
    if (!validUserRange(segment.vaddr, segment.mem_size)) return false;

    const file_offset = toUsize(segment.file_offset) orelse return false;
    const file_size = toUsize(segment.file_size) orelse return false;
    if (!rangeInSlice(data, file_offset, file_size)) return false;

    return true;
}

fn validUserRange(vaddr: u64, len: u64) bool {
    if (vaddr == 0 or len == 0) return false;
    const end = checkedAddU64(vaddr, len - 1) orelse return false;
    return end <= user_mem.USER_ADDR_MAX;
}

fn rangeInSlice(data: []const u8, offset: usize, len: usize) bool {
    if (offset > data.len) return false;
    return len <= data.len - offset;
}

fn hasMagic(data: []const u8) bool {
    return data[OFF_MAGIC] == ELF_MAGIC[0] and
        data[OFF_MAGIC + 1] == ELF_MAGIC[1] and
        data[OFF_MAGIC + 2] == ELF_MAGIC[2] and
        data[OFF_MAGIC + 3] == ELF_MAGIC[3];
}

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

fn alignDown(value: u64) u64 {
    return value & ~PAGE_MASK;
}

fn alignUp(value: u64) ?u64 {
    return (checkedAddU64(value, PAGE_MASK) orelse return null) & ~PAGE_MASK;
}

fn checkedAddU64(a: u64, b: u64) ?u64 {
    if (a > MAX_U64 - b) return null;
    return a + b;
}

fn toUsize(value: u64) ?usize {
    if (@sizeOf(usize) >= 8) return @intCast(value);
    if (value > 0xFFFF_FFFF) return null;
    return @intCast(value);
}

fn emptyResult() ParseResult {
    return .{
        .entry_point = 0,
        .segments = [_]LoadSegment{emptySegment()} ** MAX_LOAD_SEGMENTS,
        .segment_count = 0,
    };
}

fn emptySegment() LoadSegment {
    return .{
        .vaddr = 0,
        .file_offset = 0,
        .file_size = 0,
        .mem_size = 0,
        .writable = false,
        .executable = false,
    };
}
