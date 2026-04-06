#!/bin/sh
# Build a bootable ISO using Limine bootloader.
# Requires: xorriso, git (for cloning limine if not cached)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ISO_ROOT="$PROJECT_DIR/zig-out/iso_root"
LIMINE_DIR="$PROJECT_DIR/tools/limine"
KERNEL_ELF="$PROJECT_DIR/zig-out/bin/kernel.elf"
OUTPUT_ISO="$PROJECT_DIR/zig-out/merlionos.iso"

# Check kernel exists
if [ ! -f "$KERNEL_ELF" ]; then
    echo "ERROR: kernel.elf not found at $KERNEL_ELF"
    echo "Run 'zig build' first."
    exit 1
fi

# Clone/update limine if needed
if [ ! -d "$LIMINE_DIR" ]; then
    echo "[mkiso] Cloning Limine bootloader..."
    git clone --depth=1 --branch=v8.x-binary https://github.com/limine-bootloader/limine.git "$LIMINE_DIR"
    make -C "$LIMINE_DIR"
fi

# Prepare ISO root
rm -rf "$ISO_ROOT"
mkdir -p "$ISO_ROOT/boot/limine"
mkdir -p "$ISO_ROOT/EFI/BOOT"

# Copy kernel
cp "$KERNEL_ELF" "$ISO_ROOT/boot/kernel.elf"

# Copy limine config
cp "$PROJECT_DIR/limine.conf" "$ISO_ROOT/boot/limine/limine.conf"

# Copy limine binaries
cp "$LIMINE_DIR/limine-bios.sys" "$ISO_ROOT/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/limine-bios-cd.bin" "$ISO_ROOT/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/limine-uefi-cd.bin" "$ISO_ROOT/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/BOOTX64.EFI" "$ISO_ROOT/EFI/BOOT/" 2>/dev/null || true
cp "$LIMINE_DIR/BOOTIA32.EFI" "$ISO_ROOT/EFI/BOOT/" 2>/dev/null || true

# Build ISO
xorriso -as mkisofs \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$ISO_ROOT" -o "$OUTPUT_ISO" 2>/dev/null

# Install limine (BIOS boot sector)
"$LIMINE_DIR/limine" bios-install "$OUTPUT_ISO" 2>/dev/null || true

echo "[mkiso] ISO created: $OUTPUT_ISO"
