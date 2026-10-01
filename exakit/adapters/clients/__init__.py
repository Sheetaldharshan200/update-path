"""AI client configuration: a facade over the kit's ``mcp`` package (``python -m mcp``).

The ``mcp`` package stays where it is until the legacy installer no longer
needs it (Phase C); this facade calls it in process and hands back the JSON
documents its CLI prints. Nothing else in the kit imports ``mcp`` directly.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

CLIENT_IDS = ("claude_desktop", "claude_code", "cursor", "codex", "vscode_copilot", "gemini_cli", "opencode", "continue")


@dataclass(frozen=True, slots=True)
class ClientCall:
    code: int
    doc: dict[str, Any] | None
    stderr: str


class ClientOps(Protocol):
    def discover(self, runtime_root: Path) -> ClientCall: ...
    def setup(self, runtime_root: Path, clients: list[str]) -> ClientCall: ...
    def operation(self, op: str, runtime_root: Path, clients: list[str], *, servers: list[str] | None = None) -> ClientCall: ...
    def register_addon_servers(self, runtime_root: Path, clients: list[str]) -> ClientCall: ...


class InProcessClientOps:
    """Runs ``mcp.cli.main`` in this interpreter with stdout captured."""

    def __init__(self, kit_root: Path) -> None:
        self.kit_root = kit_root

    def _call(self, argv: list[str]) -> ClientCall:
        if str(self.kit_root) not in sys.path:
            sys.path.insert(0, str(self.kit_root))
        try:
            from mcp.cli import main as mcp_main
        except ImportError as err:
            return ClientCall(1, None, f"the kit's mcp package could not be loaded: {err}")
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = int(mcp_main(argv) or 0)
            except SystemExit as exit_:  # argparse
                code = int(exit_.code or 0) if isinstance(exit_.code, int) else 1
            except Exception as failure:  # the operation itself blew up: report, never crash the kit
                return ClientCall(1, None, f"{type(failure).__name__}: {failure}")
        text = out.getvalue().strip()
        doc: dict[str, Any] | None = None
        if text:
            try:
                parsed = json.loads(text)
                doc = parsed if isinstance(parsed, dict) else None
            except ValueError:
                doc = None
        return ClientCall(code, doc, err.getvalue())

    def discover(self, runtime_root: Path) -> ClientCall:
        return self._call(["discover-clients", "--runtime-root", str(runtime_root)])

    def setup(self, runtime_root: Path, clients: list[str]) -> ClientCall:
        return self._call(["setup-runtime-clients", "--runtime-root", str(runtime_root), "--clients", *clients])

    def operation(self, op: str, runtime_root: Path, clients: list[str], *, servers: list[str] | None = None) -> ClientCall:
        argv = ["run-runtime-operation", op, "--runtime-root", str(runtime_root)]
        if clients:
            argv += ["--clients", *clients]
        if servers:
            argv += ["--servers", *servers]
        return self._call(argv)

    def register_addon_servers(self, runtime_root: Path, clients: list[str]) -> ClientCall:
        return self._call(["register-addon-servers", "--runtime-root", str(runtime_root), "--clients", *clients])


def client_states(call: ClientCall) -> dict[str, str] | None:
    """id -> connected | pending | missing from a discover call; None when it failed."""
    if call.code != 0 or not call.doc:
        return None
    states: dict[str, str] = {}
    for client in call.doc.get("clients", []):
        cid = client.get("id")
        if cid in CLIENT_IDS:
            states[cid] = "connected" if client.get("configured") else "pending" if client.get("detected") else "missing"
    return states


def managed_clients(call: ClientCall) -> list[str]:
    """The clients with any managed artifact, from a status call, in kit order."""
    if not call.doc:
        return []
    seen = {a.get("client") for a in call.doc.get("artifacts", []) if a.get("client")}
    return [cid for cid in CLIENT_IDS if cid in seen]
