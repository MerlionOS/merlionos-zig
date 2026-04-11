#!/usr/bin/env python3
"""Host-side COM2 proxy for MerlionOS-Zig.

The kernel sends line-oriented requests on COM2:

    ASK <prompt>

By default this bridge replies with one deterministic line so QEMU tests can
validate the serial round trip without network access or API credentials. Use
`--backend command --command ...` to delegate prompts to an external LLM CLI or
script; prompts are passed on stdin and stdout is returned to the kernel.
Use `--backend openai` for a direct OpenAI Responses API adapter.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any


DEFAULT_SOCKET = "/tmp/merlionos-ai.sock"
DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"
DEFAULT_OPENAI_MODEL = "gpt-5.4-mini"


@dataclass(frozen=True)
class Config:
    backend: str
    command: str | None
    command_timeout: float
    max_response_bytes: int
    openai_base_url: str
    openai_key_env: str
    openai_model: str
    openai_timeout: float
    openai_max_output_tokens: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bridge MerlionOS COM2 AI proxy requests.")
    parser.add_argument("--socket", default=DEFAULT_SOCKET, help=f"QEMU UNIX socket path (default: {DEFAULT_SOCKET})")
    parser.add_argument("--connect-timeout", type=float, default=10.0, help="Seconds to wait for QEMU socket")
    parser.add_argument("--once", action="store_true", help="Exit after replying to one ASK line")
    parser.add_argument("--backend", choices=("echo", "command", "openai"), default="echo", help="Response backend (default: echo)")
    parser.add_argument("--command", help="External command for --backend command; prompt is passed on stdin")
    parser.add_argument("--command-timeout", type=float, default=30.0, help="Seconds to wait for command backend")
    parser.add_argument("--max-response-bytes", type=int, default=480, help="Maximum response bytes returned to the kernel")
    parser.add_argument("--openai-base-url", default=DEFAULT_OPENAI_BASE_URL, help=f"OpenAI-compatible API base URL (default: {DEFAULT_OPENAI_BASE_URL})")
    parser.add_argument("--openai-key-env", default="OPENAI_API_KEY", help="Environment variable containing the OpenAI API key")
    parser.add_argument("--openai-model", default=os.environ.get("OPENAI_MODEL", DEFAULT_OPENAI_MODEL), help=f"OpenAI model for --backend openai (default: $OPENAI_MODEL or {DEFAULT_OPENAI_MODEL})")
    parser.add_argument("--openai-timeout", type=float, default=30.0, help="Seconds to wait for OpenAI API responses")
    parser.add_argument("--openai-max-output-tokens", type=int, default=128, help="OpenAI max_output_tokens value")
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
        if config.backend == "openai":
            return openai_response(prompt, config)
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


def openai_response(prompt: str, config: Config) -> str:
    api_key = os.environ.get(config.openai_key_env)
    if not api_key:
        return f"ERR missing ${config.openai_key_env}\n"

    url = config.openai_base_url.rstrip("/") + "/responses"
    payload = {
        "model": config.openai_model,
        "input": prompt,
        "max_output_tokens": config.openai_max_output_tokens,
    }
    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=config.openai_timeout) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        return f"ERR OpenAI HTTP {exc.code}: {normalize_line(detail, config.max_response_bytes)}\n"
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return f"ERR OpenAI request failed: {exc}\n"
    except json.JSONDecodeError as exc:
        return f"ERR OpenAI JSON decode failed: {exc}\n"

    text = extract_openai_text(data)
    return normalize_line(text, config.max_response_bytes) + "\n"


def extract_openai_text(data: dict[str, Any]) -> str:
    output_text = data.get("output_text")
    if isinstance(output_text, str) and output_text:
        return output_text

    parts: list[str] = []
    for item in data.get("output", []):
        if not isinstance(item, dict):
            continue
        for content in item.get("content", []):
            if not isinstance(content, dict):
                continue
            text = content.get("text")
            if content.get("type") == "output_text" and isinstance(text, str):
                parts.append(text)
            elif isinstance(text, str):
                parts.append(text)

    if parts:
        return " ".join(parts)

    error = data.get("error")
    if isinstance(error, dict) and isinstance(error.get("message"), str):
        return f"ERR OpenAI response error: {error['message']}"
    return "ERR OpenAI response had no text output"


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
        openai_base_url=args.openai_base_url,
        openai_key_env=args.openai_key_env,
        openai_model=args.openai_model,
        openai_timeout=args.openai_timeout,
        openai_max_output_tokens=args.openai_max_output_tokens,
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
