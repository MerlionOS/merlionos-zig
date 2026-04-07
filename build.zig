const std = @import("std");

pub fn build(b: *std.Build) void {
    // Use shell script for full build pipeline (workaround for Zig 0.15 SIGBUS on macOS ARM cross-compile)
    const build_cmd = b.addSystemCommand(&.{
        "/bin/sh", "tools/build.sh",
    });
    const build_step = b.step("kernel", "Build the kernel ELF");
    build_step.dependOn(&build_cmd.step);
    b.default_step = build_step;

    // --- ISO build step ---
    const iso_cmd = b.addSystemCommand(&.{
        "/bin/sh", "tools/mkiso.sh",
    });
    iso_cmd.step.dependOn(build_step);
    const iso_step = b.step("iso", "Build bootable ISO");
    iso_step.dependOn(&iso_cmd.step);

    // --- QEMU run step ---
    const qemu_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-cdrom",
        "zig-out/merlionos.iso",
        "-m",
        "128M",
        "-serial",
        "stdio",
        "-no-reboot",
        "-no-shutdown",
    });
    qemu_cmd.step.dependOn(&iso_cmd.step);
    const run_step = b.step("run", "Build ISO and run in QEMU");
    run_step.dependOn(&qemu_cmd.step);

    // --- Serial-only QEMU run step ---
    const qemu_serial_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-cdrom",
        "zig-out/merlionos.iso",
        "-m",
        "128M",
        "-serial",
        "stdio",
        "-display",
        "none",
        "-no-reboot",
    });
    qemu_serial_cmd.step.dependOn(&iso_cmd.step);
    const run_serial_step = b.step("run-serial", "Build ISO and run headless in QEMU (serial only)");
    run_serial_step.dependOn(&qemu_serial_cmd.step);

    // --- QEMU run step with COM2 wired to the host-side AI proxy socket ---
    const qemu_ai_cmd = b.addSystemCommand(&.{
        "qemu-system-x86_64",
        "-cdrom",
        "zig-out/merlionos.iso",
        "-m",
        "128M",
        "-serial",
        "stdio",
        "-chardev",
        "socket,id=ai,path=/tmp/merlionos-ai.sock,server=on,wait=off",
        "-serial",
        "chardev:ai",
        "-no-reboot",
        "-no-shutdown",
    });
    qemu_ai_cmd.step.dependOn(&iso_cmd.step);
    const run_ai_step = b.step("run-ai", "Build ISO and run QEMU with COM2 AI proxy socket");
    run_ai_step.dependOn(&qemu_ai_cmd.step);
}
