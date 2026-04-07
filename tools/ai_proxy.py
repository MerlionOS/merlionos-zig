#!/usr/bin/env python3
"""Host-side COM2 proxy for MerlionOS-Zig.

The kernel sends line-oriented requests on COM2:

    ASK <prompt>

By default this bridge replies with one deterministic line so QEMU tests can
validate the serial round trip without network access or API credentials. Use
`--backend command --command ...` to delegate prompts to an external LLM CLI or
script; prompts are passed on stdin and stdout is returned to the kernel.
"""

from __future__ import annotations

import argparse
import socket
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass


DEFAULT_SOCKET = "/tmp/merlionos-ai.sock"


@dataclass(frozen=True)
class Config:
    backend: str
    command: str | None
    command_timeout: float
    max_response_bytes: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge MerlionOS COM2 AI proxy requests.")
    parser.add_argument("--socket", default=DEFAULT_SOCKET, help=f"QEMU UNIX socket path (default: {DEFAULT_SOCKET})")
    parser.add_argument("--connect-timeout", type=float, default=10.0, help="Seconds to wait for QEMU socket")
    parser.add_argument("--once", action="store_true", help="Exit after replying to one ASK line")
    parser.add_argument("--backend", choices=("echo", "command"), default="echo", help="Response backend (default: echo)")
    parser.add_argument("--command", help="External command for --backend command; prompt is passed on stdin")
    parser.add_argument("--command-timeout", type=float, default=30.0, help="Seconds to wait for command backend")
    parser.add_argument("--max-response-bytes", type=int, default=480, help="Maximum response bytes returned to the kernel")
    return parser.parse_args()


def connect(path: str, timeout: float) -> socket.socket:
    deadline = time.monotonic() + timeout
    last_error: OSError | None = None

    while time.monotonic() < deadline:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(path)
            return sock
        except OSError as exc:
            last_error = exc
            sock.close()
            time.sleep(0.05)

    raise RuntimeError(f"timed out connecting to {path}: {last_error}")


def response_for(line: str, config: Config) -> str:
    if line.startswith("ASK "):
        prompt = line[4:].strip()
        if config.backend == "command":
            return command_response(prompt, config)
        return f"AI echo: {prompt}\n"
    return f"ERR unknown command: {line}\n"


def command_response(prompt: str, config: Config) -> str:
    if not config.command:
        return "ERR command backend requires --command\n"

    try:
        argv = shlex.split(config.command)
        if not argv:
            return "ERR command backend requires --command\n"
        result = subprocess.run(
            argv,
            input=prompt,
            text=True,
            capture_output=True,
            timeout=config.command_timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return f"ERR command timed out after {config.command_timeout:.1f}s\n"
    except OSError as exc:
        return f"ERR command failed: {exc}\n"
    except ValueError as exc:
        return f"ERR command parse failed: {exc}\n"

    if result.returncode != 0:
        detail = normalize_line(result.stderr or result.stdout or "no output", config.max_response_bytes)
        return f"ERR command exited {result.returncode}: {detail}\n"

    return normalize_line(result.stdout, config.max_response_bytes) + "\n"


def normalize_line(text: str, max_bytes: int) -> str:
    line = " ".join(text.split())
    if not line:
        line = "(empty response)"

    encoded = line.encode("utf-8")[:max_bytes]
    return encoded.decode("utf-8", errors="ignore")


def run(sock: socket.socket, once: bool, config: Config) -> None:
    buffer = bytearray()
    responses = 0

    while True:
        chunk = sock.recv(1)
        if not chunk:
            return

        byte = chunk[0]
        if byte == ord("\r"):
            continue
        if byte != ord("\n"):
            buffer.append(byte)
            continue

        line = buffer.decode("utf-8", errors="replace")
        buffer.clear()
        response = response_for(line, config)
        sock.sendall(response.encode("utf-8"))
        responses += 1
        print(f"{line} -> {response.strip()}", flush=True)

        if once and responses >= 1:
            return


def main() -> int:
    args = parse_args()
    config = Config(
        backend=args.backend,
        command=args.command,
        command_timeout=args.command_timeout,
        max_response_bytes=args.max_response_bytes,
    )
    try:
        with connect(args.socket, args.connect_timeout) as sock:
            run(sock, args.once, config)
    except Exception as exc:
        print(f"ai_proxy: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
