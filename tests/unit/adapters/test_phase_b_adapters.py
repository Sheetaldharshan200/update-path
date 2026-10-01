import json
import tempfile
import unittest
from pathlib import Path

from exakit.adapters.clients import ClientCall, client_states, managed_clients
from exakit.adapters.exapump import Profile, failure_reason, looks_not_runnable_yet, table_listing, temp_config, write_profile
from exakit.adapters.fs.credentials import CredentialStore
from exakit.adapters.net.github import asset_digest, download_url, release_assets
from exakit.adapters.process.ports import process_age_seconds
from exakit.adapters.process.runner import Completed
from exakit.adapters.process.services import LaunchdServices, ServiceSpec, SystemdUserServices, WindowsStartupServices
from tests.support import kit_settings
from tests.unit.fakes import FakeDownloader, FakeRunner, mode_of


ENDPOINTS = kit_settings().endpoints


class CredentialsTest(unittest.TestCase):
    def test_store_read_remove_with_private_modes(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = CredentialStore(Path(tmp) / "credentials")
            path = store.store("personal_sys_password", "s3cret")
            self.assertIn(mode_of(store.directory), (0o700, None))
            self.assertIn(mode_of(path), (0o600, None))
            self.assertEqual(path.read_bytes(), b"s3cret")
            self.assertEqual(store.read("personal_sys_password"), "s3cret")
            self.assertIsNone(store.read("nothing"))
            store.remove("personal_sys_password")
            self.assertFalse(store.exists("personal_sys_password"))

    def test_generated_tokens_are_database_safe(self):
        token = CredentialStore.new_token()
        self.assertEqual(len(token), 24)
        self.assertTrue(CredentialStore.is_token(token))
        self.assertFalse(CredentialStore.is_token("lower1"))
        self.assertFalse(CredentialStore.is_token(""))


class ExapumpTest(unittest.TestCase):
    def test_profile_toml_and_atomic_replace(self):
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "config.toml"
            cfg.write_text("[other]\nhost = \"x\"\n")
            write_profile(cfg, Profile("starter-kit", "127.0.0.1", 8563, "sys", 'p"w'))
            text = cfg.read_text()
            self.assertIn("[other]", text)
            self.assertIn('[starter-kit]\nhost = "127.0.0.1"\nport = 8563\nuser = "sys"\npassword = "p\\"w"\ntls = true\nvalidate_certificate = false', text)
            write_profile(cfg, Profile("starter-kit", "127.0.0.1", 9999, "sys", "new"))
            self.assertEqual(cfg.read_text().count("[starter-kit]"), 1)
            self.assertIn("port = 9999", cfg.read_text())
            self.assertIn(mode_of(cfg), (0o600, None))

    def test_temp_config_holds_extra_profiles_and_is_removed(self):
        with tempfile.TemporaryDirectory() as tmp:
            with temp_config(Path(tmp), [Profile("admin", "h", 1, "u", "p"), Profile("mcp_readonly", "h", 1, "r", "q", schema="STARTER_KIT")]) as path:
                text = path.read_text()
                self.assertIn("[admin]", text)
                self.assertIn('schema = "STARTER_KIT"', text)
            self.assertFalse(path.exists())

    def test_table_listing_parses_rows_and_needs_the_sentinel(self):
        done = Completed(0, "QUALIFIED\nEXAKIT.LISTING_ANSWERED|1\nTPCH.CUSTOMER|1500\nweird line\nSTARTER_KIT.T|0\n", "")
        self.assertEqual(table_listing(done), {"TPCH.CUSTOMER": 1500, "STARTER_KIT.T": 0})
        self.assertIsNone(table_listing(Completed(0, "TPCH.CUSTOMER|1500\n", "")))
        self.assertIsNone(table_listing(Completed(1, "", "boom")))

    def test_failure_reasons(self):
        self.assertIn("row 412 has a line break", failure_reason("Error: ETL-2105: not enclosed field row=412", delimiter_name="comma"))
        self.assertIn("Windows line endings", failure_reason("Error: bad <CR> here"))
        self.assertEqual(failure_reason("Error: ETL-9999: something odd (Session: 12)"), "ETL-9999: something odd")
        self.assertIn("did not say why", failure_reason("no errors here"))

    def test_not_runnable_yet_patterns(self):
        self.assertTrue(looks_not_runnable_yet("Access is denied"))
        self.assertFalse(looks_not_runnable_yet("segmentation fault"))


class GithubTest(unittest.TestCase):
    def test_release_assets_and_digest(self):
        page = json.dumps({"assets": [{"name": "exapump-0.13.0-macos-aarch64", "browser_download_url": "https://x/a", "digest": "sha256:" + "a" * 64},
                                      {"name": "other", "browser_download_url": "https://x/b"}]})
        dl = FakeDownloader({"https://api.github.com/repos/o/r/releases/tags/v0.13.0": page})
        assets = release_assets("o/r", "v0.13.0", dl, endpoints=ENDPOINTS)
        self.assertEqual(len(assets), 2)
        self.assertEqual(asset_digest("o/r", "v0.13.0", "exapump-0.13.0-macos-aarch64", dl, endpoints=ENDPOINTS), "a" * 64)
        self.assertIsNone(asset_digest("o/r", "v0.13.0", "other", dl, endpoints=ENDPOINTS))
        self.assertIsNone(release_assets("o/r", "v9", dl, endpoints=ENDPOINTS))
        self.assertEqual(download_url("o/r", "v1", "f", endpoints=ENDPOINTS), "https://github.com/o/r/releases/download/v1/f")


class ClientsFacadeTest(unittest.TestCase):
    def test_states_and_managed_clients_from_documents(self):
        discover = ClientCall(0, {"clients": [{"id": "claude_code", "detected": True, "configured": True},
                                              {"id": "cursor", "detected": True, "configured": False},
                                              {"id": "codex", "detected": False, "configured": False},
                                              {"id": "bogus", "detected": True}]}, "")
        self.assertEqual(client_states(discover), {"claude_code": "connected", "cursor": "pending", "codex": "missing"})
        self.assertIsNone(client_states(ClientCall(1, None, "x")))
        status = ClientCall(0, {"artifacts": [{"client": "cursor"}, {"client": "claude_code"}, {"client": "cursor"}]}, "")
        self.assertEqual(managed_clients(status), ["claude_code", "cursor"])


class ServicesTest(unittest.TestCase):
    def test_launchd_writes_a_plist_and_loads_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner = FakeRunner()
            svc = LaunchdServices(Path(tmp) / "agents", Path(tmp) / "logs", runner)
            out = svc.register(ServiceSpec("dash-server", ("/bin/dash-server", "--port", "5100")))
            self.assertTrue(out.ok)
            plist = (Path(tmp) / "agents" / "com.exasol.exakit.dash-server.plist").read_text()
            self.assertIn("<string>com.exasol.exakit.dash-server</string>", plist)
            self.assertIn("<string>--port</string>", plist)
            self.assertIn("autostart-dash-server.log", plist)
            self.assertTrue(svc.registered("dash-server"))
            self.assertIn(["launchctl", "load", str(Path(tmp) / "agents" / "com.exasol.exakit.dash-server.plist")], [list(c) for c in runner.calls])
            self.assertTrue(svc.unregister("dash-server"))
            self.assertFalse(svc.registered("dash-server"))
            self.assertFalse(svc.unregister("dash-server"))

    def test_launchd_load_failure_is_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner = FakeRunner(responses={("launchctl", "load"): Completed(1, "", "refused")})
            out = LaunchdServices(Path(tmp), Path(tmp) / "logs", runner).register(ServiceSpec("x", ("/x",)))
            self.assertFalse(out.ok)
            self.assertIn("launchd refused", out.notes[0])

    def test_systemd_unit_kinds_and_missing_user_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            runner = FakeRunner(which={"systemctl": "/bin/systemctl"})
            svc = SystemdUserServices(Path(tmp) / "units", runner)
            out = svc.register(ServiceSpec("database", ("/x/exasol", "start"), kind="handoff"))
            self.assertTrue(out.ok, out.notes)
            unit = (Path(tmp) / "units" / "com.exasol.exakit.database.service").read_text()
            self.assertIn("Type=oneshot\nRemainAfterExit=yes", unit)
            self.assertIn("ExecStart=/x/exasol start", unit)
            svc.register(ServiceSpec("dash-server", ("/x/dash server", "--port", "5100")))
            unit = (Path(tmp) / "units" / "com.exasol.exakit.dash-server.service").read_text()
            self.assertIn("Restart=on-failure", unit)
            self.assertIn("ExecStart='/x/dash server' --port 5100", unit)
            self.assertTrue(svc.registered("dash-server"))
            self.assertTrue(svc.unregister("dash-server"))
            no_systemd = SystemdUserServices(Path(tmp) / "u2", FakeRunner(), wsl=True)
            out = no_systemd.register(ServiceSpec("x", ("/x",)))
            self.assertFalse(out.ok)
            self.assertTrue(any("wsl.conf" in n for n in out.notes))

    def test_windows_startup_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            svc = WindowsStartupServices(Path(tmp) / "Startup")
            self.assertTrue(svc.register(ServiceSpec("dash-server", ("C:\\p\\dash-server.cmd", "--port", "5100"))).ok)
            entry = (Path(tmp) / "Startup" / "com.exasol.exakit.dash-server.cmd").read_bytes().decode()
            self.assertIn('start "" /min C:\\p\\dash-server.cmd --port 5100', entry)
            self.assertIn("\r\n", entry)
            self.assertTrue(svc.registered("dash-server"))
            self.assertTrue(svc.unregister("dash-server"))


class PortsTest(unittest.TestCase):
    def test_etime_parsing(self):
        runner = FakeRunner(responses={("ps", "-o", "etime="): Completed(0, "   02:03:04\n", "")})
        self.assertEqual(process_age_seconds(1, runner), 2 * 3600 + 3 * 60 + 4)
        runner = FakeRunner(responses={("ps", "-o", "etime="): Completed(0, "1-00:00:10\n", "")})
        self.assertEqual(process_age_seconds(1, runner), 86400 + 10)
        runner = FakeRunner(responses={("ps", "-o", "etime="): Completed(1, "", "")})
        self.assertIsNone(process_age_seconds(1, runner))


if __name__ == "__main__":
    unittest.main()
