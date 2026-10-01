"""The Exasol MCP server: a uvx-run package, primed once, validated over a stdio handshake, pinned in the client configs."""

from __future__ import annotations

import re
import time
from pathlib import Path

from exakit.adapters.clients.handshake import stdio_handshake
from exakit.adapters.uv import find_uv
from exakit.domain.errors import Failed

from .base import ComponentBase

PRIMED = re.compile(r"usage:|insufficient database connection|exasol[./]ai[./]mcp|site-packages/exasol", re.I)


class Lifecycle(ComponentBase):
    id = "mcp"
    key = "mcp_server"
    step = "mcp"

    @property
    def package(self) -> str:
        """The MCP server package uvx runs (EXAKIT_MCP_PACKAGE overrides the catalog's)."""
        return self.ctx.env.get("EXAKIT_MCP_PACKAGE") or str(self.ctx.catalog.component("mcp").source["package"])

    def installed_version(self) -> str | None:
        """The recorded version, or None."""
        return self.recorded("version") or None

    def uvx(self) -> str:
        """The recorded command, else uvx beside the uv the kit uses, else uvx on PATH."""
        recorded = self.recorded("command")
        if recorded and Path(recorded).exists():
            return recorded
        uv = find_uv(self.ctx.env, self.ctx.paths.home, self.ctx.runner, windows=self.ctx.platform.os == "windows")
        if uv:
            sibling = Path(uv).with_name("uvx.exe" if self.ctx.platform.os == "windows" else "uvx")
            if sibling.exists():
                return str(sibling)
        return self.ctx.runner.which("uvx") or "uvx"

    def ssl_cert_validation(self) -> str:
        """The TLS setting the server needs for the kit's certificate."""
        host, _, _, _ = self.runtime_connection()
        return "no" if host in ("127.0.0.1", "localhost", "[::1]") else "yes"

    def credentials(self) -> tuple[str, str | None]:
        """(user, password file): the read-only user when recorded, else the admin account as a fallback."""
        user, pw_file = self.recorded("connection.user"), self.recorded("connection.password_file")
        if user and pw_file:
            return user, pw_file
        _, _, admin, admin_file = self.runtime_connection()
        self.ctx.log.line("WARN", "No read-only MCP credential is recorded; falling back to the ADMIN account. Repair with: exakit mcp-setup")
        return admin, admin_file

    # --- install ------------------------------------------------------------------------

    def install(self, version: str) -> None:
        """Prime the package through uvx and record it."""
        uv = find_uv(self.ctx.env, self.ctx.paths.home, self.ctx.runner, windows=self.ctx.platform.os == "windows")
        if not uv:
            raise Failed("uv (the Python tool runner the MCP server runs through) is not available - install it from https://docs.astral.sh/uv/ and re-run",
                         remedy="exakit update mcp")
        started = time.monotonic()
        spec = f"{self.package}@{version}"
        self.ctx.ui.info(f"Priming {spec} (downloads on first use)")
        self.ctx.log.line("CMD", f"{self.uvx()} {spec} --help")
        done = self.ctx.runner.run([self.uvx(), spec, "--help"], timeout=900)
        if done.ok or PRIMED.search(done.out + done.err):
            self.ctx.ui.ok("MCP server package cached")
        else:
            self.ctx.ui.warn("Could not prime the MCP server package (it will download on first client start)")
        self.record(uv_path=uv, command=self.uvx(), package=self.package, version=version)
        self.ctx.log.line("OK", f"MCP server ready to run via uvx ({self.elapsed(started)})")

    # --- validate -----------------------------------------------------------------------------

    def _handshake_with_retries(self, spec: str, env: dict[str, str]):
        """Three attempts; after an import error the uvx environment is rebuilt once (a first run can leave it half built)."""
        outcome = None
        for attempt in (1, 2, 3):
            outcome = stdio_handshake(self.uvx(), spec, env)
            self.ctx.log.line("MCP", outcome.detail)
            if outcome.ok or attempt == 3:
                break
            if attempt == 1 and ("ImportError" in outcome.detail or "ModuleNotFoundError" in outcome.detail):
                self.ctx.ui.warn("The server's Python environment is incomplete - rebuilding it once")
                self.ctx.runner.run([self.uvx(), "--reinstall", spec, "--help"], timeout=900)
            else:
                self.ctx.ui.warn(f"Handshake attempt {attempt} failed - retrying")
                time.sleep(5)
        return outcome

    def validate(self) -> None:
        """The server answers the stdio handshake; records validated."""
        self.ctx.ui.info("Validating the MCP server (stdio handshake)")
        host, port, _, _ = self.runtime_connection()
        user, pw_file = self.credentials()
        env = {**dict(self.ctx.env), "EXA_DSN": f"{host}:{port}", "EXA_USER": user or "", "EXA_PASSWORD": self.password(pw_file) or "",
               "EXA_SSL_CERT_VALIDATION": self.ssl_cert_validation()}
        spec = f"{self.package}@{self.installed_version() or self.target_version()}"
        outcome = self._handshake_with_retries(spec, env)
        if outcome and not outcome.ok and self.ctx.platform.arch == "aarch64" and self.ctx.platform.os == "linux":
            self.ctx.ui.warn("Handshake failed on a guest that may advertise SVE its host CPU cannot execute - retrying with OPENSSL_armcap=0")
            outcome = stdio_handshake(self.uvx(), spec, {**env, "OPENSSL_armcap": "0"})
            if outcome.ok:
                self.record(openssl_armcap_workaround=True)
                self.ctx.ui.info("Client configs generated by mcp-setup will launch the MCP server with OPENSSL_armcap=0.")
        if outcome and outcome.ok:
            self.ctx.ui.ok(f"MCP server {spec} cached and answering over stdio")
            self.record(mode="stdio", validated=True)
            return
        self.ctx.ui.error("The MCP server did not answer the stdio handshake. What it said:")
        self.ctx.ui.text(f"      | {outcome.detail if outcome else 'nothing'}")
        self.ctx.ui.warn("Your database and the client configs are unchanged - clients will still start the server. For a deeper check, run: exakit mcp-doctor")
        self.record(validated=False)

    # --- update -----------------------------------------------------------------------------------

    def snapshot(self) -> None:
        """Snapshot the clients' configs before a change."""
        from exakit.app import mcp as mcp_app
        from exakit.domain.ids import CLIENT_IDS
        call = mcp_app._clients(self.ctx).operation("backup", self.ctx.paths.home, list(CLIENT_IDS))
        reference = (call.doc or {}).get("backup_reference") if call.code == 0 else None
        if reference:
            self.ctx.manifest_store.update(lambda m: m.set("backups.mcp_update.latest", reference))
        else:
            self.ctx.ui.warn("MCP pre-update snapshot was not created; generated configs will still be refreshed.")

    def update(self, options: list[str] | None = None) -> None:
        """Re-prime the advertised version and refresh the clients' pins."""
        from exakit.app import mcp as mcp_app
        latest = self.target_version()
        current = self.installed_version()
        if latest == current:
            self.ctx.ui.ok(f"MCP server is already current ({current})")
            return
        self.ctx.ui.info(f"Updating MCP server {current or 'unknown'} -> {latest}")
        self.snapshot()
        self.install(latest)
        try:
            mcp_app.refresh_client_pins(self.ctx, latest)
        except Failed as err:
            self.ctx.ui.warn(err.message)
        self.validate()
        self.record_desired(latest)
        self.ctx.ui.ok("MCP server updated; database data was not changed")

    def uninstall(self, *, dry_run: bool) -> list[str]:
        """Remove the kit's entries from the clients and forget the component."""
        from exakit.app import mcp as mcp_app
        if dry_run:
            self.ctx.ui.info("  will remove: the managed MCP configuration from the AI clients")
            return ["mcp configs"]
        self.ctx.ui.info("Removing the managed MCP configuration from the AI clients")
        clients = mcp_app.managed(self.ctx)
        if clients and mcp_app._clients(self.ctx).operation("uninstall", self.ctx.paths.home, clients).code != 0:
            self.ctx.ui.warn("Removing the managed AI client config reported issues")
        self.forget()
        return ["mcp configs"]
