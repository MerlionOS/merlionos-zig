const cpu = @import("cpu.zig");
const pmm = @import("pmm.zig");
const vmm = @import("vmm.zig");

pub const USER_TEXT_BASE: u64 = 0x0000_0000_0040_0000;
pub const USER_HEAP_BASE: u64 = 0x0000_0000_1000_0000;
pub const USER_STACK_TOP: u64 = 0x0000_7FFF_FFFF_0000;
pub const USER_STACK_SIZE: u64 = 16 * PAGE_SIZE;
pub const USER_MMAP_BASE: u64 = 0x0000_0000_4000_0000;
pub const USER_ADDR_MAX: u64 = 0x0000_7FFF_FFFF_FFFF;

const KERNEL_PML4_START: usize = 256;
const ENTRIES_PER_TABLE: usize = 512;
const PAGE_SIZE: u64 = pmm.PAGE_SIZE;
const MAX_USER_PAGES: usize = 256;
const PAGE_FRAME_MASK: u64 = 0x000F_FFFF_FFFF_F000;
const PAGE_MASK: u64 = PAGE_SIZE - 1;
const FLAG_PRESENT: u64 = 0x001;

const PageTable = [ENTRIES_PER_TABLE]u64;

pub const PageRecord = struct {
    virt: u64,
    phys: u64,
    active: bool,
};

pub const AddressSpace = struct {
    pml4_phys: u64,
    page_count: usize,
    pages: [MAX_USER_PAGES]PageRecord,
    brk: u64,
    mmap_next: u64,
};

pub const SelfTestResult = enum {
    ok,
    create_failed,
    map_failed,
    text_missing,
    stack_missing,
    restore_failed,
};

pub const BrkResult = enum {
    ok,
    invalid,
    no_memory,
};

var kernel_cr3: u64 = 0;

pub fn init() void {
    kernel_cr3 = cpu.readCr3() & PAGE_FRAME_MASK;
}

pub fn create() ?AddressSpace {
    var as: AddressSpace = undefined;
    if (!createInto(&as)) return null;
    return as;
}

pub fn createInto(as: *AddressSpace) bool {
    if (kernel_cr3 == 0) init();

    const pml4_phys = pmm.allocFrame() orelse return false;
    const pml4: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));
    @memset(pml4[0..], 0);

    const kernel_pml4: *PageTable = @ptrFromInt(pmm.physToVirt(kernel_cr3));
    for (KERNEL_PML4_START..ENTRIES_PER_TABLE) |i| {
        pml4[i] = kernel_pml4[i];
    }

    as.pml4_phys = pml4_phys;
    as.page_count = 0;
    as.brk = USER_HEAP_BASE;
    as.mmap_next = USER_MMAP_BASE;
    for (&as.pages) |*record| {
        record.* = emptyPageRecord();
    }

    var stack_page = USER_STACK_TOP - USER_STACK_SIZE;
    while (stack_page < USER_STACK_TOP) : (stack_page += PAGE_SIZE) {
        if (!mapUserPage(as, stack_page, true)) {
            destroy(as);
            return false;
        }
    }

    return true;
}

pub fn mapUserPage(as: *AddressSpace, virt: u64, writable: bool) bool {
    const phys = pmm.allocFrame() orelse return false;
    zeroFrame(phys);
    if (!mapUserPagePhys(as, virt, phys, writable)) {
        pmm.freeFrame(phys);
        return false;
    }
    return true;
}

pub fn mapUserPagePhys(as: *AddressSpace, virt: u64, phys: u64, writable: bool) bool {
    const page = alignDown(virt);
    if (!validUserPage(page) or (phys & PAGE_MASK) != 0) return false;
    if (as.page_count >= MAX_USER_PAGES or hasMapping(as, page)) return false;
    const record = freePageRecord(as) orelse return false;

    const saved_cr3 = cpu.readCr3() & PAGE_FRAME_MASK;
    cpu.writeCr3(as.pml4_phys);
    const mapped = vmm.mapPage(page, phys, writable, true);
    cpu.writeCr3(saved_cr3);
    if (!mapped) return false;

    record.* = .{
        .virt = page,
        .phys = phys,
        .active = true,
    };
    as.page_count += 1;
    return true;
}

pub fn activate(as: *const AddressSpace) void {
    cpu.writeCr3(as.pml4_phys);
}

pub fn activateKernel() void {
    if (kernel_cr3 != 0) {
        cpu.writeCr3(kernel_cr3);
    }
}

pub fn destroy(as: *AddressSpace) void {
    const was_active = (cpu.readCr3() & PAGE_FRAME_MASK) == as.pml4_phys;
    if (was_active) activateKernel();

    for (&as.pages) |*record| {
        if (!record.active) continue;
        pmm.freeFrame(record.phys);
        record.* = emptyPageRecord();
    }
    as.page_count = 0;

    freeUserPageTables(as.pml4_phys);
    pmm.freeFrame(as.pml4_phys);
    as.pml4_phys = 0;
}

pub fn expandBrk(as: *AddressSpace, new_brk: u64) bool {
    return setBrk(as, new_brk) == .ok;
}

pub fn setBrk(as: *AddressSpace, new_brk: u64) BrkResult {
    if (new_brk < USER_HEAP_BASE or new_brk > USER_MMAP_BASE) return .invalid;
    if (new_brk == as.brk) return .ok;
    if (new_brk < as.brk) {
        shrinkBrk(as, new_brk);
        return .ok;
    }

    return growBrk(as, new_brk);
}

fn growBrk(as: *AddressSpace, new_brk: u64) BrkResult {
    const old_brk = as.brk;

    var page = alignUp(as.brk);
    const end = alignUp(new_brk);
    while (page < end) : (page += PAGE_SIZE) {
        if (!mapUserPage(as, page, true)) {
            rollbackGrow(as, old_brk, page);
            return .no_memory;
        }
    }
    as.brk = new_brk;
    return .ok;
}

fn shrinkBrk(as: *AddressSpace, new_brk: u64) void {
    var page = alignUp(new_brk);
    const end = alignUp(as.brk);
    while (page < end) : (page += PAGE_SIZE) {
        unmapUserPage(as, page);
    }
    as.brk = new_brk;
}

fn rollbackGrow(as: *AddressSpace, old_brk: u64, failed_page: u64) void {
    var page = alignUp(old_brk);
    while (page < failed_page) : (page += PAGE_SIZE) {
        unmapUserPage(as, page);
    }
}

fn unmapUserPage(as: *AddressSpace, virt: u64) void {
    const page = alignDown(virt);
    const saved_cr3 = cpu.readCr3() & PAGE_FRAME_MASK;
    cpu.writeCr3(as.pml4_phys);
    const phys = vmm.unmapPage(page);
    cpu.writeCr3(saved_cr3);
    if (phys) |frame| {
        pmm.freeFrame(frame);
    }

    if (pageRecord(as, page)) |record| {
        record.* = emptyPageRecord();
        if (as.page_count > 0) as.page_count -= 1;
    }
}

pub fn selfTest() SelfTestResult {
    const saved_cr3 = cpu.readCr3() & PAGE_FRAME_MASK;
    var as = create() orelse return .create_failed;
    defer destroy(&as);

    if (!mapUserPage(&as, USER_TEXT_BASE, true)) return .map_failed;

    activate(&as);
    const text_mapped = vmm.translateAddr(USER_TEXT_BASE) != null;
    const stack_mapped = vmm.translateAddr(USER_STACK_TOP - 1) != null;
    cpu.writeCr3(saved_cr3);

    if (!text_mapped) return .text_missing;
    if (!stack_mapped) return .stack_missing;
    if ((cpu.readCr3() & PAGE_FRAME_MASK) != saved_cr3) return .restore_failed;
    return .ok;
}

fn validUserPage(virt: u64) bool {
    if ((virt & PAGE_MASK) != 0) return false;
    if (virt == 0 or virt > USER_ADDR_MAX) return false;
    return virt + PAGE_SIZE - 1 <= USER_ADDR_MAX;
}

fn hasMapping(as: *const AddressSpace, virt: u64) bool {
    for (as.pages) |record| {
        if (record.active and record.virt == virt) return true;
    }
    return false;
}

fn freePageRecord(as: *AddressSpace) ?*PageRecord {
    for (&as.pages) |*record| {
        if (!record.active) return record;
    }
    return null;
}

fn pageRecord(as: *AddressSpace, virt: u64) ?*PageRecord {
    for (&as.pages) |*record| {
        if (record.active and record.virt == virt) return record;
    }
    return null;
}

fn freeUserPageTables(pml4_phys: u64) void {
    const pml4: *PageTable = @ptrFromInt(pmm.physToVirt(pml4_phys));
    for (0..KERNEL_PML4_START) |pml4_idx| {
        const pdpt_entry = pml4[pml4_idx];
        if ((pdpt_entry & FLAG_PRESENT) == 0) continue;
        const pdpt_phys = pdpt_entry & PAGE_FRAME_MASK;
        const pdpt: *PageTable = @ptrFromInt(pmm.physToVirt(pdpt_phys));

        for (pdpt) |pd_entry| {
            if ((pd_entry & FLAG_PRESENT) == 0) continue;
            const pd_phys = pd_entry & PAGE_FRAME_MASK;
            const pd: *PageTable = @ptrFromInt(pmm.physToVirt(pd_phys));

            for (pd) |pt_entry| {
                if ((pt_entry & FLAG_PRESENT) == 0) continue;
                const pt_phys = pt_entry & PAGE_FRAME_MASK;
                pmm.freeFrame(pt_phys);
            }

            pmm.freeFrame(pd_phys);
        }

        pmm.freeFrame(pdpt_phys);
        pml4[pml4_idx] = 0;
    }
}

fn zeroFrame(phys: u64) void {
    const bytes: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
    @memset(bytes[0..PAGE_SIZE], 0);
}

fn alignDown(value: u64) u64 {
    return value & ~PAGE_MASK;
}

fn alignUp(value: u64) u64 {
    return (value + PAGE_MASK) & ~PAGE_MASK;
}

fn emptyPageRecord() PageRecord {
    return .{
        .virt = 0,
        .phys = 0,
        .active = false,
    };
}
