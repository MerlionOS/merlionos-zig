// Limine boot protocol structures and requests for MerlionOS-Zig.
// See: https://github.com/limine-bootloader/limine/blob/trunk/PROTOCOL.md

// --- Common ---

const LIMINE_COMMON_MAGIC = [2]u64{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b };

// --- Framebuffer ---

pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    _unused: [7]u8,
    edid_size: u64,
    edid: [*]u8,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: [*]const *const Framebuffer,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const FramebufferResponse,
};

// --- Memory Map ---

pub const MEMMAP_USABLE: u64 = 0;
pub const MEMMAP_RESERVED: u64 = 1;
pub const MEMMAP_ACPI_RECLAIMABLE: u64 = 2;
pub const MEMMAP_ACPI_NVS: u64 = 3;
pub const MEMMAP_BAD_MEMORY: u64 = 4;
pub const MEMMAP_BOOTLOADER_RECLAIMABLE: u64 = 5;
pub const MEMMAP_KERNEL_AND_MODULES: u64 = 6;
pub const MEMMAP_FRAMEBUFFER: u64 = 7;

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    entry_type: u64,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]const *const MemmapEntry,
};

pub const MemmapRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const MemmapResponse,
};

// --- HHDM (Higher Half Direct Map) ---

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64,
    revision: u64,
    response: ?*const HhdmResponse,
};

// --- Request Instances ---
// Placed in special linker sections so Limine can find them.

// Start marker (MUST be first in .limine_requests section)
pub export var requests_start_marker: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
    0x785c6ed015d3e316, 0x181e920a7852b9d9,
};

// Base revision
pub export var base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 2,
};

// Framebuffer request
pub export var framebuffer_request: FramebufferRequest linksection(".limine_requests") = .{
    .id = .{ LIMINE_COMMON_MAGIC[0], LIMINE_COMMON_MAGIC[1], 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    .revision = 0,
    .response = null,
};

// Memory map request
pub export var memmap_request: MemmapRequest linksection(".limine_requests") = .{
    .id = .{ LIMINE_COMMON_MAGIC[0], LIMINE_COMMON_MAGIC[1], 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    .revision = 0,
    .response = null,
};

// HHDM request
pub export var hhdm_request: HhdmRequest linksection(".limine_requests") = .{
    .id = .{ LIMINE_COMMON_MAGIC[0], LIMINE_COMMON_MAGIC[1], 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    .revision = 0,
    .response = null,
};

// End marker (MUST be last in .limine_requests section)
pub export var requests_end_marker: [2]u64 linksection(".limine_requests_end") = .{
    0xadc0e0531bb10d03, 0x9572709f31764c62,
};
