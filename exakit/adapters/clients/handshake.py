"""The MCP stdio handshake: start the server the way a client would and wait for its initialize answer."""

from __future__ import annotations

import json
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass

REQUEST = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
           "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "starter-kit-validator", "version": "1.0"}}}


@dataclass(frozen=True, slots=True)
class Handshake:
    ok: bool
    detail: str


def stdio_handshake(command: str, spec: str, env: Mapping[str, str], *, timeout: float = 120) -> Handshake:
    """Run ``<command> <spec>`` with the connection in the environment; ok when an initialize result comes back."""
    try:
        proc = subprocess.Popen([command, spec], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, env=dict(env))
    except OSError as err:
        return Handshake(False, f"could not start {command}: {err}")
    try:
        out, err = proc.communicate(json.dumps(REQUEST) + "\n", timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        return Handshake(False, "handshake timed out")
    for line in out.splitlines():
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == 1 and "result" in msg:
            info = msg["result"].get("serverInfo", {})
            return Handshake(True, f"handshake ok: {info.get('name')} {info.get('version')}")
    return Handshake(False, (err.strip() or "no initialize result in server output")[-600:])
