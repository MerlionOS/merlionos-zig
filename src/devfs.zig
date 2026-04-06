const vfs = @import("vfs.zig");

pub fn init() void {
    const dev_dir = vfs.resolve("/dev") orelse return;

    _ = vfs.createDevice(dev_dir, "null");

    if (vfs.createDevice(dev_dir, "zero")) |idx| {
        var zeros: [256]u8 = [_]u8{0} ** 256;
        _ = vfs.writeFile(idx, zeros[0..]);
    }
}
