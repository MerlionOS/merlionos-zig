const elf = @import("elf.zig");
const vfs = @import("vfs.zig");

pub fn init() void {
    const bin_dir = vfs.resolve("/bin") orelse vfs.createDir(0, "bin") orelse return;
    const file_idx = vfs.resolve("/bin/hello.elf") orelse vfs.createFile(bin_dir, "hello.elf") orelse return;
    _ = vfs.writeFile(file_idx, elf.hello_exec[0..]);
}
