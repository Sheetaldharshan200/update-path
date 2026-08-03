"""Configure must scope a per-client failure to that client.

Field report behind these tests: a pre-existing, EMPTY (0-byte)
``~/Library/Application Support/Code/User/mcp.json``, left behind by a VS Code
update and unrelated to Exasol. An empty file is not valid JSON, so the VS Code
adapter correctly refused to overwrite it — and Claude, Claude Code, Codex and
Cursor, all four healthy, got no ``exasol`` entry either.

Two failure modes are pinned here:

* one client's blocking finding must not decide the whole operation, and
* the outcome must not depend on the ORDER the clients are processed in. The
  render-stage skip check used to test the shared cross-client findings list,
  so every client after the broken one was silently dropped.
"""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest import mock

from mcp.core.models import OperationStatus, Severity
from mcp.runtime.environment import ExecutionEnvironment
from mcp.service import MCPAccessSubsystem

# The 0-byte file from the field report. json.loads("") raises, so this is the
# exact input that produced the blocking invalid_client_config finding.
EMPTY_FILE = ""

CONFIG_ENV_NAMES = {
    "claude_desktop": "CLAUDE_DESKTOP_CONFIG_PATH",
    "claude_code": "CLAUDE_CODE_CONFIG_PATH",
    "cursor": "CURSOR_MCP_CONFIG_PATH",
    "codex": "CODEX_MCP_CONFIG_PATH",
    "vscode_copilot": "VSCODE_MCP_CONFIG_PATH",
}

CONFIG_FILE_NAMES = {
    "claude_desktop": ("claude", "claude_desktop_config.json"),
    "claude_code": ("claude-code", ".claude.json"),
    "cursor": ("cursor", "mcp.json"),
    "codex": ("codex", "config.toml"),
    "vscode_copilot": ("Code/User", "mcp.json"),
}


class PerClientScopingTests(unittest.TestCase):
    def setUp(self) -> None:
        self._sandboxes: list[Path] = []
        self._new_sandbox()

    def tearDown(self) -> None:
        for sandbox in self._sandboxes:
            shutil.rmtree(sandbox, ignore_errors=True)

    def _new_sandbox(self) -> None:
        """Fresh client config files and runtime root, for one configure run."""

        self._temp_dir = Path(tempfile.mkdtemp(prefix="mcp-client-scoping-"))
        self._sandboxes.append(self._temp_dir)
        self.runtime_root = self._temp_dir / "runtime"
        self.paths: dict[str, Path] = {}
        env: dict[str, str] = {}
        for client, (directory, file_name) in CONFIG_FILE_NAMES.items():
            path = self._temp_dir / directory / file_name
            path.parent.mkdir(parents=True, exist_ok=True)
            self.paths[client] = path
            env[CONFIG_ENV_NAMES[client]] = str(path)
        self.env = env
        self.environment = ExecutionEnvironment(
            os_name="darwin", home=self._temp_dir, env=env, cwd=self._temp_dir
        )

    # ---------------------------------------------------------------- helpers

    def _subsystem(self, environment: ExecutionEnvironment | None = None) -> MCPAccessSubsystem:
        return MCPAccessSubsystem(environment=environment or self.environment)

    def _request(self, clients: list[str], **overrides) -> dict:
        request = {
            "operation": "configure",
            "target_clients": clients,
            "deployment_mode": "stdio",
            "runtime_root": str(self.runtime_root),
            "server_definition": {
                "name": "exasol",
                "transport": "stdio",
                "command": "exasol-mcp-server",
                "args": ["--profile", "starter-kit"],
                "env": {"EXA_DSN": "127.0.0.1:8563", "EXA_USER": "mcp_readonly"},
            },
            "credential_reference": {"kind": "inline_env", "name": "EXA_PASSWORD"},
            "dsn_reference": {"kind": "literal", "value": "127.0.0.1:8563"},
            "create_snapshot": True,
            "validate_after_apply": True,
        }
        request.update(overrides)
        return request

    def _mock_connectivity(self):
        connection = mock.MagicMock()
        connection.__enter__.return_value = connection
        connection.__exit__.return_value = False
        return mock.patch(
            "mcp.validator.service.socket.create_connection", return_value=connection
        )

    def _clients_carrying_entry(self, clients: list[str]) -> set[str]:
        """The clients whose real config file on disk now names the server."""

        carrying = set()
        for client in clients:
            path = self.paths.get(client)
            if path is None or not path.exists():
                continue
            if "exasol" in path.read_text(encoding="utf-8"):
                carrying.add(client)
        return carrying

    @staticmethod
    def _skipped_ids(result) -> set[str]:
        return {item["client"] for item in result.details.get("skipped_clients", [])}

    # ------------------------------------------------------------------ tests

    def test_broken_client_does_not_stop_the_healthy_clients(self) -> None:
        """Bug A: the reported symptom."""

        self.paths["vscode_copilot"].write_text(EMPTY_FILE, encoding="utf-8")
        healthy = ["claude_desktop", "claude_code", "cursor", "codex"]
        clients = healthy + ["vscode_copilot"]
        with self._mock_connectivity():
            result = self._subsystem().execute(self._request(clients))

        self.assertEqual(result.status, OperationStatus.SUCCESS_WITH_WARNINGS)
        self.assertEqual(self._clients_carrying_entry(clients), set(healthy))
        self.assertEqual({artifact.client for artifact in result.artifacts}, set(healthy))

        # the broken client is reported as skipped, with the reason
        self.assertEqual(self._skipped_ids(result), {"vscode_copilot"})
        skipped = result.details["skipped_clients"][0]
        self.assertEqual(skipped["reason_code"], "invalid_client_config")
        self.assertEqual(skipped["display_name"], "GitHub Copilot")
        self.assertIn("not valid JSON", skipped["reason"])

        # and its file is still exactly as we found it: refusing to overwrite
        # an unparseable config is the adapter's job and stays untouched.
        self.assertEqual(self.paths["vscode_copilot"].read_text(encoding="utf-8"), EMPTY_FILE)
        codes = {finding.code for finding in result.findings}
        self.assertIn("invalid_client_config", codes)

    def test_healthy_clients_are_identical_whatever_the_broken_position(self) -> None:
        """Bug B: order-dependence.

        The render-stage skip check used to consult the shared findings list, so
        clients processed AFTER the broken one were dropped while clients before
        it survived. With the broken client first, last and in the middle, the
        configured set must be the same.
        """

        healthy = ["claude_desktop", "claude_code", "cursor", "codex"]
        orders = {
            "broken_first": ["vscode_copilot"] + healthy,
            "broken_last": healthy + ["vscode_copilot"],
            "broken_middle": healthy[:2] + ["vscode_copilot"] + healthy[2:],
        }
        outcomes = {}
        for name, order in orders.items():
            self._new_sandbox()  # a clean sandbox per order
            self.paths["vscode_copilot"].write_text(EMPTY_FILE, encoding="utf-8")
            with self._mock_connectivity():
                result = self._subsystem().execute(self._request(order))
            outcomes[name] = {
                "status": result.status,
                "configured": self._clients_carrying_entry(order),
                "artifacts": {artifact.client for artifact in result.artifacts},
                "skipped": self._skipped_ids(result),
            }

        for name, outcome in outcomes.items():
            self.assertEqual(outcome["configured"], set(healthy), f"order={name}")
            self.assertEqual(outcome["artifacts"], set(healthy), f"order={name}")
            self.assertEqual(outcome["skipped"], {"vscode_copilot"}, f"order={name}")
            self.assertEqual(
                outcome["status"], OperationStatus.SUCCESS_WITH_WARNINGS, f"order={name}"
            )
        self.assertEqual(
            outcomes["broken_first"]["configured"], outcomes["broken_last"]["configured"]
        )

    def test_all_clients_blocking_is_still_blocked(self) -> None:
        """Nothing rendered at all stays an honest, total failure."""

        clients = ["cursor", "vscode_copilot", "claude_desktop"]
        for client in clients:
            self.paths[client].write_text("{ this is not json", encoding="utf-8")
        with self._mock_connectivity():
            result = self._subsystem().execute(self._request(clients))

        self.assertEqual(result.status, OperationStatus.BLOCKED)
        self.assertEqual(result.artifacts, [])
        self.assertEqual(self._clients_carrying_entry(clients), set())
        self.assertEqual(self._skipped_ids(result), set(clients))
        for client in clients:
            self.assertEqual(
                self.paths[client].read_text(encoding="utf-8"), "{ this is not json"
            )

    def test_unsupported_client_does_not_block_supported_clients(self) -> None:
        """Bug C: client_not_supported is a fact about one client."""

        # Claude Desktop has no documented Linux location, so on linux its
        # locate() reports unavailable — as long as no override is set for it.
        env = {key: value for key, value in self.env.items() if key != "CLAUDE_DESKTOP_CONFIG_PATH"}
        environment = ExecutionEnvironment(
            os_name="linux", home=self._temp_dir, env=env, cwd=self._temp_dir
        )
        clients = ["claude_desktop", "cursor", "codex"]
        with self._mock_connectivity():
            result = self._subsystem(environment).execute(self._request(clients))

        self.assertEqual(result.status, OperationStatus.SUCCESS_WITH_WARNINGS)
        self.assertEqual(self._clients_carrying_entry(clients), {"cursor", "codex"})
        self.assertEqual(self._skipped_ids(result), {"claude_desktop"})
        self.assertEqual(
            result.details["skipped_clients"][0]["reason_code"], "client_not_supported"
        )
        unsupported = [
            finding for finding in result.findings if finding.code == "client_not_supported"
        ]
        self.assertEqual(len(unsupported), 1)
        # it must not be able to block, on its own or in company
        self.assertFalse(unsupported[0].blocking)
        self.assertEqual(unsupported[0].severity, Severity.WARNING)

    def test_unsupported_client_alone_is_blocked(self) -> None:
        """Demoting the finding must not turn "nothing happened" into success."""

        env = {key: value for key, value in self.env.items() if key != "CLAUDE_DESKTOP_CONFIG_PATH"}
        environment = ExecutionEnvironment(
            os_name="linux", home=self._temp_dir, env=env, cwd=self._temp_dir
        )
        with self._mock_connectivity():
            result = self._subsystem(environment).execute(self._request(["claude_desktop"]))
        self.assertEqual(result.status, OperationStatus.BLOCKED)
        self.assertEqual(result.artifacts, [])

    def test_dry_run_reports_the_same_per_client_picture(self) -> None:
        self.paths["vscode_copilot"].write_text(EMPTY_FILE, encoding="utf-8")
        clients = ["cursor", "vscode_copilot", "codex"]
        with self._mock_connectivity():
            result = self._subsystem().execute(self._request(clients, dry_run=True))

        self.assertEqual(result.status, OperationStatus.NO_CHANGE)
        self.assertEqual({artifact.client for artifact in result.artifacts}, {"cursor", "codex"})
        self.assertEqual(self._skipped_ids(result), {"vscode_copilot"})
        self.assertFalse(any(change.applied for change in result.changes))
        # a dry run writes nothing at all
        self.assertEqual(self._clients_carrying_entry(clients), set())
        self.assertFalse(self.paths["cursor"].exists())

    def test_snapshot_covers_only_the_clients_that_were_applied(self) -> None:
        """Partial application must leave a coherent rollback point."""

        existing = {
            "mcpServers": {
                "filesystem": {"command": "npx", "args": ["-y", "server-filesystem"]}
            }
        }
        self.paths["cursor"].write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
        self.paths["vscode_copilot"].write_text(EMPTY_FILE, encoding="utf-8")
        clients = ["cursor", "vscode_copilot", "codex"]
        with self._mock_connectivity():
            configure = self._subsystem().execute(self._request(clients))
        self.assertEqual(configure.status, OperationStatus.SUCCESS_WITH_WARNINGS)

        snapshot_id = configure.backup_reference
        self.assertIsNotNone(snapshot_id)
        snapshot = json.loads(
            (self.runtime_root / "backups" / str(snapshot_id) / "snapshot.json").read_text(
                encoding="utf-8"
            )
        )
        # only the pre-existing file of an APPLIED client is in the snapshot:
        # the skipped client's file was never touched, so it needs no backup.
        self.assertEqual(
            [record["path"] for record in snapshot["files"]], [str(self.paths["cursor"])]
        )

        with self._mock_connectivity():
            restore = self._subsystem().execute(
                {
                    "operation": "restore",
                    "runtime_root": str(self.runtime_root),
                    "snapshot_id": snapshot_id,
                    "snapshot_current_state_first": False,
                    "dsn_reference": {"kind": "literal", "value": "127.0.0.1:8563"},
                }
            )
        self.assertEqual(restore.status, OperationStatus.SUCCESS)
        restored = json.loads(self.paths["cursor"].read_text(encoding="utf-8"))
        self.assertIn("filesystem", restored["mcpServers"])
        self.assertNotIn("exasol", restored["mcpServers"])
        # rollback leaves the skipped client exactly as it was found
        self.assertEqual(self.paths["vscode_copilot"].read_text(encoding="utf-8"), EMPTY_FILE)


if __name__ == "__main__":
    unittest.main()
