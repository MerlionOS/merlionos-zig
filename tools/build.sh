#!/bin/sh
# Build the MerlionOS-Zig kernel ELF.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"
mkdir -p zig-out/bin

# Step 1: Compile to object file with kernel code model for higher-half addressing
zig build-obj \
    -mno-red-zone \
    -OReleaseSmall \
    -mcpu x86_64+soft_float \
    -mcmodel=kernel \
    -target x86_64-freestanding-none \
    -Mroot=src/main.zig \
    --name kernel

# Step 2: Link with custom linker script using LLD
zig ld.lld \
    -T linker.ld \
    -z max-page-size=4096 \
    -o zig-out/bin/kernel.elf \
    kernel.o

rm -f kernel.o
echo "[build] Kernel built: zig-out/bin/kernel.elf"
