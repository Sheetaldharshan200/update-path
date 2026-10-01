"""The machine states the scenario matrix runs every command against.

Each state is an install record (or its absence) in the hermetic sandbox of
``tests.support``: no launcher, no exapump, no client on the PATH, a throwaway
user home. What a command answers in each state is the frozen contract that
``test_state_matrix`` pins, one test per (state, command).
"""

from __future__ import annotations

from tests.support import MANIFEST, Sandbox

SECRET = "s3cret-pa55word-never-printed"  # noqa: S105 - the sentinel the outputs must never contain

STATES: dict[str, dict | str | None] = {
    "fresh": None,
    "recorded_running": MANIFEST,
    "stopped": {**MANIFEST, "runtime": {**MANIFEST["runtime"], "status": "stopped"}},
    "no_database": {**MANIFEST, "runtime": {"type": None, "status": "not installed"}, "steps_completed": ["launcher"],
                    "data": {"loaded": False, "datasets": {}}},
    "interrupted_install": {**MANIFEST, "install": {"current_step": "mcp"}, "steps_completed": ["launcher", "runtime", "exapump"]},
    "persona_recorded": {**MANIFEST, "persona": {"id": "analyst", "source": "install", "requested_at": "2026-09-30T00:00:00Z"}},
    "corrupt_record": "{not json",
}


def sandbox_for(state: str) -> Sandbox:
    """A sandbox in that state, with a password file the outputs must never quote."""
    box = Sandbox(manifest=STATES[state])
    creds = box.home / "credentials"
    creds.mkdir()
    (creds / "personal_sys_password").write_text(SECRET + "\n", encoding="utf-8")
    manifest = box.home / "manifest.json"
    if manifest.exists() and STATES[state] is not None and not isinstance(STATES[state], str):
        import json
        doc = json.loads(manifest.read_text(encoding="utf-8"))
        doc.setdefault("runtime", {})["password_file"] = str(creds / "personal_sys_password")
        manifest.write_text(json.dumps(doc), encoding="utf-8")
    return box


# Every command the matrix runs. Only read-only commands and the refusal paths
# of the mutating ones: nothing here may start, load, configure or remove
# anything, even in a sandbox (the launcher and the clients live outside it).
COMMANDS: dict[str, list[str]] = {
    "status": ["status"], "info": ["info"], "version": ["version"], "guide": ["guide"],
    "preflight": ["preflight"], "catalog": ["catalog"], "help": ["help"], "help-topic": ["help", "mcp"],
    "help-unknown-topic": ["help", "nope"], "whats-new": ["whats-new"],
    "persona-list": ["persona", "list"], "persona-plan": ["persona", "plan", "analyst"],
    "persona-show": ["persona", "show", "minimal"], "persona-show-unknown": ["persona", "show", "nope"],
    "persona-bad-subcommand": ["persona", "bogus"], "persona-apply-no-yes": ["persona", "apply", "minimal"],
    "marketplace-list": ["marketplace", "--list"], "marketplace-list-with-id": ["marketplace", "--list", "dash-server"],
    "skills": ["skills"], "logs": ["logs"], "logs-bad-target": ["logs", "nope"], "mcp-status": ["mcp-status"],
    "mcp-doctor": ["mcp-doctor"], "mcp-remove-no-client": ["mcp-remove"],
    "sql-no-statement": ["sql"], "sql-select": ["sql", "SELECT 1"], "sql-write-rejected": ["sql", "DELETE FROM T"],
    "data-load-bad-option": ["data-load", "--nope"], "update-dry-run": ["update", "--dry-run"],
    "update-unknown-target": ["update", "nope"], "install-dry-run": ["install", "--dry-run"],
    "install-with-argument": ["install", "extra"], "uninstall-dry-run": ["uninstall", "--dry-run"],
    "uninstall-addon-dry-run": ["uninstall", "dash-server", "--dry-run"], "repair-runtime-no-yes": ["repair-runtime"],
    "migrate-no-args": ["migrate"], "autostart-with-argument": ["autostart", "on"],
    "status-bad-option": ["status", "--nope"], "unknown-command": ["bogus"],
    "start-fresh-only": ["start"], "stop-fresh-only": ["stop"], "mcp-setup-fresh-only": ["mcp-setup"],
}
# The three mutating commands above run only where they cannot act: without an install record.
FRESH_ONLY = {"start-fresh-only", "stop-fresh-only", "mcp-setup-fresh-only"}
