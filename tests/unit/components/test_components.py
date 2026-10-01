"""The component lifecycles over fakes: naming, digests, keep-or-replace decisions, records, and the self-update swap."""

from __future__ import annotations

import hashlib
import io
import os
import json
import tarfile
import unittest
from pathlib import Path
from unittest import mock

from exakit.adapters.process.runner import Completed
from exakit.components import for_component
from exakit.components.personal import major
from exakit.domain.errors import Failed
from exakit.domain.platform import Platform
from tests.unit.app.harness import MANIFEST, FakeVersions, Sandbox
from tests.unit.fakes import FakeRunner, FakeRuntime, mode_of


def versions_doc(**components) -> dict:
    return {"schema_version": 1, "updated": "2026-09-30", "kit": {"version": "0.3.0"},
            "components": {cid: {"version": ver, "severity": "normal", **extra} for cid, (ver, extra) in components.items()}}


def tarball(files: dict[str, str], prefix: str = "repo-main") -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(f"{prefix}/{name}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class ExapumpTest(unittest.TestCase):
    def test_asset_name_and_digest_sources(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            lc = for_component(box.ctx, "exapump")
            self.assertEqual(lc.asset_name("0.13.0"), "exapump-0.13.0-macos-aarch64")
            self.assertEqual(lc.digest_for("0.11.2", "exapump-0.11.2-macos-aarch64"), "e1438c69f26cdcca69ad1b7211aa9495524c53ff1badebee91d5a631c503616b")
            box.ctx.versions = FakeVersions(versions_doc(exapump=("0.13.0", {"sha256": {"macos-aarch64": "ab" * 32}})))
            self.assertEqual(lc.digest_for("0.13.0", "exapump-0.13.0-macos-aarch64"), "ab" * 32)
            self.assertIsNone(lc.digest_for("0.12.0", "exapump-0.12.0-macos-aarch64"))
        finally:
            box.close()

    def test_a_glibc_mismatch_installs_the_container_shim_and_proves_it_runs(self):
        """The release binary needs glibc 2.38; on an older distro it runs inside a container, through the same path and CLI."""
        from exakit.adapters.process.runner import Completed

        class OnceOld(FakeRunner):
            def __init__(self):
                super().__init__(which={"podman": "/usr/bin/podman"})
                self.old = True
            def run(self, cmd, **kw):
                self.calls.append(tuple(cmd))
                if cmd[-1] == "--version" and str(cmd[0]).replace("\\", "/").endswith("/exapump") and self.old:
                    self.old = False
                    return Completed(1, "", "exapump: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found")
                if cmd[:2] == ["ldd", "--version"]:
                    return Completed(0, "ldd (Ubuntu GLIBC 2.35-0ubuntu3) 2.35\n", "")
                return Completed(0, "exapump 0.13.0\n", "")

        runner = OnceOld()
        box = Sandbox(manifest=MANIFEST, runner=runner, platform=Platform("linux", "x86_64"))
        try:
            lc = for_component(box.ctx, "exapump")
            lc.bin.parent.mkdir(parents=True, exist_ok=True)
            lc.bin.write_bytes(b"ELF exapump")
            lc.verify_runs()
            real = box.ctx.paths.home / "libexec" / "exapump-real"
            self.assertEqual(real.read_bytes(), b"ELF exapump")
            shim = lc.bin.read_text(encoding="utf-8")
            self.assertIn("/usr/bin/podman", shim)
            self.assertIn("ubuntu:24.04", shim)
            self.assertIn(str(real), shim)
            self.assertIn(("/usr/bin/podman", "pull", "ubuntu:24.04"), runner.calls)
            self.assertEqual(box.manifest().get("components.exapump.shim_image"), "ubuntu:24.04")
            self.assertIn("runs through the ubuntu:24.04 container", box.screen())
        finally:
            box.close()

    def test_a_glibc_mismatch_without_podman_is_a_clear_failure(self):
        from exakit.adapters.process.runner import Completed
        runner = FakeRunner()
        box = Sandbox(manifest=MANIFEST, runner=runner, platform=Platform("linux", "x86_64"))
        try:
            lc = for_component(box.ctx, "exapump")
            lc.bin.parent.mkdir(parents=True, exist_ok=True)
            lc.bin.write_bytes(b"ELF")
            runner.responses[(str(lc.bin), "--version")] = Completed(1, "", "version `GLIBC_2.38' not found")
            with self.assertRaises(Failed) as caught:
                lc.verify_runs()
            self.assertIn("Podman is not available", caught.exception.message)
            self.assertEqual(caught.exception.remedy, "exakit update exapump")
        finally:
            box.close()

    def test_install_downloads_verifies_and_records(self):
        body = b"#!/bin/sh\necho exapump 0.13.0\n"
        digest = hashlib.sha256(body).hexdigest()
        runner = FakeRunner()
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            box.ctx.versions = FakeVersions(versions_doc(exapump=("0.13.0", {"sha256": {"macos-aarch64": digest}})))
            lc = for_component(box.ctx, "exapump")
            box.downloader.pages["https://github.com/exasol-labs/exapump/releases/download/v0.13.0/exapump-0.13.0-macos-aarch64"] = body
            runner.responses[(str(lc.bin), "--version")] = Completed(0, "exapump 0.13.0\n", "")
            lc.install("0.13.0")
            self.assertTrue(lc.bin.exists())
            self.assertTrue(os.access(lc.bin, os.X_OK))
            self.assertEqual(box.manifest().get("components.exapump.version"), "0.13.0")
            self.assertEqual(box.manifest().get("components.exapump.path"), str(lc.bin))
            self.assertIn("exapump v0.13.0 installed", box.screen())
        finally:
            box.close()

    def test_a_tampered_download_is_refused_and_nothing_is_installed(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            box.ctx.versions = FakeVersions(versions_doc(exapump=("0.13.0", {"sha256": {"macos-aarch64": "00" * 32}})))
            lc = for_component(box.ctx, "exapump")
            box.downloader.pages["https://github.com/exasol-labs/exapump/releases/download/v0.13.0/exapump-0.13.0-macos-aarch64"] = b"bad"
            with self.assertRaises(Failed) as caught:
                lc.install("0.13.0")
            self.assertIn("checksum", caught.exception.message)
            self.assertFalse(lc.bin.exists())
        finally:
            box.close()

    def test_an_existing_binary_of_the_right_version_is_kept_and_a_wrong_one_replaced(self):
        runner = FakeRunner()
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            lc = for_component(box.ctx, "exapump")
            lc.bin.parent.mkdir(parents=True, exist_ok=True)
            lc.bin.write_text("old")
            runner.responses[(str(lc.bin), "--version")] = Completed(0, "exapump 0.13.0\n", "")
            lc.install("0.13.0")
            self.assertEqual(lc.bin.read_text(), "old")
            self.assertIn("already installed", box.screen())
            runner.responses[(str(lc.bin), "--version")] = Completed(0, "exapump 0.12.0\n", "")
            box.ctx.versions = FakeVersions(versions_doc(exapump=("0.13.0", {"sha256": {"macos-aarch64": hashlib.sha256(b"new").hexdigest()}})))
            box.downloader.pages["https://github.com/exasol-labs/exapump/releases/download/v0.13.0/exapump-0.13.0-macos-aarch64"] = b"new"
            with mock.patch.object(lc, "verify_runs", lambda: None):
                lc.install("0.13.0")
            self.assertEqual(lc.bin.read_bytes(), b"new")
            self.assertIn("replacing it", box.screen())
        finally:
            box.close()

    def test_profile_is_written_from_the_record_without_printing_the_password(self):
        box = Sandbox(manifest=MANIFEST)
        try:
            pw = box.home / "credentials" / "personal_sys_password"
            pw.parent.mkdir(parents=True)
            pw.write_text("s3cret\n")
            box.ctx.manifest_store.update(lambda m: m.set("runtime.password_file", str(pw)))
            lc = for_component(box.ctx, "exapump")
            lc.create_profile()
            text = lc.config_path.read_text()
            self.assertIn("[starter-kit]", text)
            self.assertIn('password = "s3cret"', text)
            self.assertIn(mode_of(lc.config_path), (0o600, None))
            self.assertNotIn("s3cret", box.screen())
            self.assertEqual(box.manifest().get("components.exapump.profile"), "starter-kit")
        finally:
            box.close()

    def test_update_reconciles_the_record_when_already_current(self):
        runner = FakeRunner()
        box = Sandbox(manifest={**MANIFEST, "components": {**MANIFEST["components"], "exapump": {"version": "0.12.0"}}}, runner=runner)
        try:
            box.ctx.versions = FakeVersions(versions_doc(exapump=("0.13.0", {})))
            lc = for_component(box.ctx, "exapump")
            lc.bin.parent.mkdir(parents=True, exist_ok=True)
            lc.bin.write_text("")
            runner.responses[(str(lc.bin), "--version")] = Completed(0, "exapump 0.13.0\n", "")
            lc.update()
            self.assertEqual(box.manifest().get("components.exapump.version"), "0.13.0")
            self.assertIn("Reconciling the recorded exapump version (0.12.0)", box.screen())
            self.assertIn("exapump is already current (0.13.0)", box.screen())
        finally:
            box.close()


class McpServerTest(unittest.TestCase):
    def test_uvx_comes_from_the_record_then_beside_uv_then_path(self):
        runner = FakeRunner(which={"uvx": "/usr/local/bin/uvx"})
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            lc = for_component(box.ctx, "mcp")
            self.assertEqual(lc.uvx(), "/usr/local/bin/uvx")
            tools = box.home / "tools" / "uv"
            tools.mkdir(parents=True)
            (tools / "uv").write_text("")
            (tools / "uvx").write_text("")
            self.assertEqual(lc.uvx(), str(tools / "uvx"))
        finally:
            box.close()

    def test_install_primes_and_records(self):
        runner = FakeRunner(which={"uv": "/u/uv", "uvx": "/u/uvx"})
        runner.responses[("/u/uvx", "exasol-mcp-server@2.2.0", "--help")] = Completed(0, "usage: exasol-mcp-server", "")
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            lc = for_component(box.ctx, "mcp")
            lc.install("2.2.0")
            self.assertIn("MCP server package cached", box.screen())
            self.assertEqual(box.manifest().get("components.mcp_server.command"), "/u/uvx")
            self.assertEqual(box.manifest().get("components.mcp_server.package"), "exasol-mcp-server")
        finally:
            box.close()

    def test_validate_records_the_handshake_outcome(self):
        runner = FakeRunner(which={"uv": "/u/uv", "uvx": "/u/uvx"})
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            lc = for_component(box.ctx, "mcp")
            from exakit.adapters.clients.handshake import Handshake
            with mock.patch("exakit.components.mcp_server.stdio_handshake", lambda cmd, spec, env, timeout=120: Handshake(True, "handshake ok: x 2.2.0")):
                lc.validate()
            self.assertIs(box.manifest().get("components.mcp_server.validated"), True)
            self.assertEqual(box.manifest().get("components.mcp_server.mode"), "stdio")
            with mock.patch("exakit.components.mcp_server.stdio_handshake", lambda cmd, spec, env, timeout=120: Handshake(False, "boom")), \
                 mock.patch("exakit.components.mcp_server.time.sleep", lambda s: None):
                lc.validate()
            self.assertIs(box.manifest().get("components.mcp_server.validated"), False)
            self.assertIn("| boom", box.screen())
        finally:
            box.close()


class PyexasolTest(unittest.TestCase):
    def test_install_uses_uv_and_records_then_validate_imports(self):
        runner = FakeRunner(which={"uv": "/u/uv"})
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            lc = for_component(box.ctx, "pyexasol")
            runner.responses[(str(lc.python), "-c", "import pyexasol; print(pyexasol.__version__)")] = Completed(1, "", "no module")
            lc.install("2.4.1")
            self.assertIn(("/u/uv", "venv", "--seed", "--python", "3.12", str(lc.venv)), runner.calls)
            self.assertIn(("/u/uv", "pip", "install", "--python", str(lc.python), "pyexasol==2.4.1"), runner.calls)
            self.assertEqual(box.manifest().get("components.pyexasol.version"), "2.4.1")
            lc.python.parent.mkdir(parents=True, exist_ok=True)
            lc.python.write_text("")
            runner.responses[(str(lc.python), "-c", "import pyexasol")] = Completed(1, "", "ImportError")
            lc.validate()
            self.assertIs(box.manifest().get("components.pyexasol.validated"), False)
        finally:
            box.close()

    def test_live_check_needs_the_connection_details(self):
        runner = FakeRunner(which={"uv": "/u/uv"})
        box = Sandbox(manifest=MANIFEST, runner=runner)
        try:
            lc = for_component(box.ctx, "pyexasol")
            lc.python.parent.mkdir(parents=True, exist_ok=True)
            lc.python.write_text("")
            lc.validate()
            self.assertIs(box.manifest().get("components.pyexasol.validated"), False)
            pw = box.home / "pw"
            pw.write_text("x")
            box.ctx.manifest_store.update(lambda m: m.set("runtime.password_file", str(pw)))
            lc.validate()
            self.assertIs(box.manifest().get("components.pyexasol.validated"), True)
            self.assertIn("pyexasol works", box.screen())
        finally:
            box.close()


class PersonalTest(unittest.TestCase):
    def test_asset_names_and_major(self):
        for platform, asset in ((Platform("macos", "aarch64"), "exasol-personal_macOS_arm64.tar.gz"), (Platform("linux", "x86_64"), "exasol-personal_Linux_x86_64.tar.gz")):
            box = Sandbox(manifest=MANIFEST, platform=platform)
            try:
                self.assertEqual(for_component(box.ctx, "personal").asset_name("2.3.0"), asset)
            finally:
                box.close()
        self.assertEqual((major("2.3.0"), major("v3.0.1"), major(None)), ("2", "3", ""))

    def test_install_verifies_against_the_checksums_file(self):
        body = tarball({"exasol": "#!/bin/sh\n"}, prefix="exasol-personal")
        digest = hashlib.sha256(body).hexdigest()
        runner = FakeRunner()
        box = Sandbox(manifest=MANIFEST, runner=runner)
        box.ctx.runtime = FakeRuntime("stopped")
        try:
            base = "https://github.com/exasol/exasol-personal/releases/download/v2.3.0"
            box.downloader.pages[f"{base}/exasol-personal_macOS_arm64.tar.gz"] = body
            box.downloader.pages[f"{base}/exasol-personal_2.3.0_checksums.txt"] = f"{digest}  exasol-personal_macOS_arm64.tar.gz\n"
            lc = for_component(box.ctx, "personal")
            lc.install("2.3.0")
            self.assertTrue(lc.bin.exists())
            box.downloader.pages[f"{base}/exasol-personal_2.3.0_checksums.txt"] = f"{'0' * 64}  exasol-personal_macOS_arm64.tar.gz\n"
            box.ctx.env["EXAKIT_FORCE_COMPONENT_INSTALL"] = "1"
            with self.assertRaises(Failed):
                lc.install("2.3.0")
        finally:
            box.close()

    def test_a_newer_deployment_refuses_the_launcher(self):
        box = Sandbox(manifest=MANIFEST)
        box.ctx.runtime = FakeRuntime("stopped")
        box.ctx.runtime.deployed = "2.4.0"
        try:
            with self.assertRaises(Failed) as caught:
                for_component(box.ctx, "personal").install("2.3.0")
            self.assertIn("newer 2.4.0 deployment", caught.exception.message)
        finally:
            box.close()

    def test_update_modes(self):
        box = Sandbox(manifest=MANIFEST)
        box.ctx.runtime = FakeRuntime("stopped")
        try:
            box.ctx.versions = FakeVersions(versions_doc(personal=("2.3.0", {})))
            for_component(box.ctx, "personal").update()
            self.assertIn("already current (2.3.0)", box.screen())
            box.ctx.versions = FakeVersions(versions_doc(personal=("2.4.0", {})))
            for_component(box.ctx, "personal").update(["--plan"])
            self.assertIn("2.3.0 -> 2.4.0", box.screen())
            box.ctx.versions = FakeVersions(versions_doc(personal=("3.0.0", {})))
            with self.assertRaises(Failed) as caught:
                for_component(box.ctx, "personal").update()
            self.assertEqual(caught.exception.remedy, "exakit update runtime --backup")
            with self.assertRaises(Failed):
                for_component(box.ctx, "personal").update(["--apply"])
        finally:
            box.close()


class KitSelfUpdateTest(unittest.TestCase):
    def _installed_kit(self, box: Sandbox) -> Path:
        kit = box.ctx.paths.kit
        (kit / "exakit").mkdir(parents=True)
        (kit / "versions.json").write_text(json.dumps({"schema_version": 1, "kit": {"version": "0.2.0"}, "components": {}}))
        (kit / "setup").mkdir()
        (kit / "setup" / "exakit").write_text("old launcher")
        return kit

    def test_swap_installs_the_new_tree_and_the_launcher_and_records(self):
        box = Sandbox(manifest={**MANIFEST, "kit": {"version": "0.2.0"}})
        try:
            self._installed_kit(box)
            new_tree = {"setup/exakit": "new launcher", "setup/exakit.ps1": "ps1", "setup/exakit.cmd": "cmd", "catalog/kit.json": "{}",
                        "bootstrap/exakit": "new launcher", "exakit/__main__.py": "",
                        "versions.json": json.dumps({"schema_version": 1, "kit": {"version": "0.3.0"}, "components": {}}),
                        "help/whats-new.json": json.dumps({"0.3.0": ["Python kit"]}), "help/exakit.json": "{}"}
            box.downloader.pages["https://github.com/krishna-exasol/update-path/archive/refs/heads/main.tar.gz"] = tarball(new_tree)
            with mock.patch("exakit.app.skills.install", lambda ctx: 0):
                for_component(box.ctx, "exakit").update()
            self.assertEqual((box.ctx.paths.kit / "setup" / "exakit").read_text(), "new launcher")
            self.assertEqual((box.ctx.paths.bin_dir / "exakit").read_text(), "new launcher")
            self.assertEqual(box.manifest().get("kit.version"), "0.3.0")
            self.assertEqual(box.manifest().get("kit.source"), "krishna-exasol/update-path@main")
            self.assertTrue(any(p.name.startswith("kit.backup-") for p in box.home.iterdir()))
            self.assertFalse(box.ctx.paths.update_in_progress.exists())
            self.assertIn("exakit updated to 0.3.0", box.screen())
            self.assertIn("Python kit", box.screen())
        finally:
            box.close()

    def test_an_incomplete_download_leaves_the_kit_untouched(self):
        box = Sandbox(manifest={**MANIFEST, "kit": {"version": "0.2.0"}})
        try:
            kit = self._installed_kit(box)
            box.downloader.pages["https://github.com/krishna-exasol/update-path/archive/refs/heads/main.tar.gz"] = tarball({"versions.json": "{}"})
            with self.assertRaises(Failed) as caught:
                for_component(box.ctx, "exakit").update()
            self.assertIn("incomplete", caught.exception.message)
            self.assertEqual((kit / "setup" / "exakit").read_text(), "old launcher")
            self.assertEqual(box.manifest().get("kit.version"), "0.2.0")
        finally:
            box.close()

    def test_a_source_checkout_is_not_self_updated(self):
        box = Sandbox(manifest={**MANIFEST, "kit": {"version": "0.2.0"}})
        try:
            for_component(box.ctx, "exakit").update()
            self.assertIn("source checkout", box.screen())
            self.assertEqual(box.downloader.calls, [])
        finally:
            box.close()


class SkillSetTest(unittest.TestCase):
    def test_source_checkout_places_what_it_carries(self):
        box = Sandbox(manifest={**MANIFEST, "components": {**MANIFEST["components"], "skills": {"version": "0.0.1"}}})
        try:
            with mock.patch("exakit.app.skills.install", lambda ctx: 3):
                for_component(box.ctx, "skills").update()
            self.assertIn("source checkout", box.screen())
        finally:
            box.close()

    def test_installed_kit_swaps_the_skills_folder(self):
        box = Sandbox(manifest={**MANIFEST, "components": {**MANIFEST["components"], "skills": {"version": "0.0.1"}}})
        try:
            kit = box.ctx.paths.kit
            (kit / "exakit").mkdir(parents=True)
            (kit / "skills" / "old").mkdir(parents=True)
            (kit / "skills" / "old" / "SKILL.md").write_text("old")
            tree = {"skills/new/SKILL.md": "---\nname: new\ndescription: x. Triggers — y\n---\n",
                    "versions.json": json.dumps({"schema_version": 1, "kit": {"version": "0.3.0"}, "components": {"skills": {"version": "1.12.2"}}})}
            box.downloader.pages["https://github.com/krishna-exasol/update-path/archive/refs/heads/main.tar.gz"] = tarball(tree)
            def place(ctx):
                ctx.manifest_store.update(lambda m: m.set("components.skills.version", "1.12.2"))
                return 1
            with mock.patch("exakit.app.skills.install", place):
                for_component(box.ctx, "skills").update()
            self.assertTrue((kit / "skills" / "new" / "SKILL.md").exists())
            self.assertFalse((kit / "skills" / "old").exists())
            self.assertEqual((kit / "skills" / ".version").read_text().strip(), "1.12.2")
            self.assertFalse(any(p.name.startswith("skills.backup-") for p in kit.iterdir()))
            self.assertIn("AI skills updated to 1.12.2", box.screen())
        finally:
            box.close()
