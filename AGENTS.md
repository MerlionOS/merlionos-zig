# Repository Guidelines

## Project Structure & Module Organization
`src/` contains the kernel source. `main.zig` is the entry point and boot sequence. Low-level platform modules live alongside it, for example `limine.zig`, `serial.zig`, `cpu.zig`, `gdt.zig`, `idt.zig`, `pmm.zig`, and `heap.zig`. Boot and link configuration lives at the repo root in `linker.ld` and `limine.conf`. Build helpers are in `tools/`, and design notes live in `docs/`, especially `docs/DESIGN.md`.

## Build, Test, and Development Commands
Use the Zig build wrapper for normal development:

- `zig build kernel` builds `zig-out/bin/kernel.elf`
- `zig build iso` builds the bootable ISO at `zig-out/merlionos.iso`
- `zig build run` boots the ISO in QEMU with display output
- `zig build run-serial` boots headless and prints kernel logs to serial

The project uses `tools/build.sh` because macOS ARM cross-compiling with Zig 0.15 requires a two-step build (`zig build-obj` then `zig ld.lld`).

## Coding Style & Naming Conventions
Write Zig 0.15-compatible code. Follow existing formatting: 4-space indentation, no tabs, ASCII unless the file already uses Unicode. Use `zig fmt` on edited Zig files. Prefer short, direct comments only where the code is not obvious.

Naming follows current conventions:
- files: lowercase, e.g. `serial.zig`, `pmm.zig`
- types: `PascalCase`
- functions/vars: `camelCase`
- constants: `UPPER_SNAKE_CASE`

## Testing Guidelines
There is no dedicated unit test suite yet. Validate changes with:

- `zig build kernel` for compile verification
- `zig build run-serial` for runtime boot validation

When changing boot, memory, or interrupt code, include the relevant serial output in your PR notes. Avoid merging changes that have not at least booted to the expected log milestone.

## Commit & Pull Request Guidelines
Keep commit messages imperative and concise, matching recent history, for example: `Implement CPU and memory init boot path`.

When Codex prepares a commit, keep the human developer as the Git author and append this trailer to the commit message:
`Co-authored-by: Codex <codex@openai.com>`

Pull requests should include:
- a short summary of behavior changes
- the commands used to verify the change
- any QEMU serial output relevant to boot or fault handling
- linked issues if applicable

## Configuration & Safety Notes
This is a freestanding x86_64 kernel. Do not assume libc, host OS services, SSE, or mapped VGA text memory. Prefer serial logging for early boot diagnostics, and check `docs/DESIGN.md` before changing boot protocol or memory initialization behavior.
