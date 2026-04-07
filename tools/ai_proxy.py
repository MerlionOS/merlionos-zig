#!/usr/bin/env python3
"""Host-side COM2 proxy for MerlionOS-Zig.

The kernel sends line-oriented requests on COM2:

    ASK <prompt>

This bridge replies with one deterministic line so QEMU tests can validate
the serial round trip without requiring network access or API credentials.
"""

from __future__ import annotations

import argparse
import socket
import sys
import time


DEFAULT_SOCKET = "/tmp/merlionos-ai.sock"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge MerlionOS COM2 AI proxy requests.")
    parser.add_argument("--socket", default=DEFAULT_SOCKET, help=f"QEMU UNIX socket path (default: {DEFAULT_SOCKET})")
    parser.add_argument("--connect-timeout", type=float, default=10.0, help="Seconds to wait for QEMU socket")
    parser.add_argument("--once", action="store_true", help="Exit after replying to one ASK line")
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


def response_for(line: str) -> str:
    if line.startswith("ASK "):
        prompt = line[4:].strip()
        return f"AI echo: {prompt}\n"
    return f"ERR unknown command: {line}\n"


def run(sock: socket.socket, once: bool) -> None:
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
        response = response_for(line)
        sock.sendall(response.encode("utf-8"))
        responses += 1
        print(f"{line} -> {response.strip()}", flush=True)

        if once and responses >= 1:
            return


def main() -> int:
    args = parse_args()
    try:
        with connect(args.socket, args.connect_timeout) as sock:
            run(sock, args.once)
    except Exception as exc:
        print(f"ai_proxy: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
