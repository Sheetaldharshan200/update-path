"""Where everything lives, computed once from the environment.

Nothing else in the kit builds a path under the kit home by hand.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class Paths:
    home: Path            # EXAKIT_HOME, default ~/.exasol-starter-kit
    bin_dir: Path         # EXAKIT_BIN_DIR, default ~/.local/bin (the launcher and add-on launchers)

    @classmethod
    def from_env(cls, env: Mapping[str, str], user_home: Path) -> Paths:
        """The kit's paths from EXAKIT_HOME and EXAKIT_BIN_DIR, defaulting under the user's home."""
        home = Path(env.get("EXAKIT_HOME") or user_home / ".exasol-starter-kit")
        bin_dir = Path(env.get("EXAKIT_BIN_DIR") or user_home / ".local" / "bin")
        return cls(home=home.expanduser(), bin_dir=bin_dir.expanduser())

    @property
    def kit(self) -> Path:
        """The kit copy the launcher runs."""
        return self.home / "kit"

    @property
    def manifest(self) -> Path:
        """The install record."""
        return self.home / "manifest.json"

    @property
    def manifest_lock(self) -> Path:
        """The lock taken while the record is written."""
        return self.home / "manifest.json.lock"

    @property
    def logs(self) -> Path:
        """Log files, one per run."""
        return self.home / "logs"

    @property
    def credentials(self) -> Path:
        """Password files, owner-only."""
        return self.home / "credentials"

    @property
    def cache(self) -> Path:
        """Cached answers: versions, About texts, release API."""
        return self.home / "cache"

    @property
    def versions_cache(self) -> Path:
        """The cached versions manifest."""
        return self.cache / "versions.json"

    @property
    def about_cache(self) -> Path:
        """Cached GitHub About texts."""
        return self.cache / "about"

    @property
    def releases_cache(self) -> Path:
        """Cached release API answers."""
        return self.cache / "releases"

    @property
    def tools(self) -> Path:
        """Tools the kit downloads for itself (uv)."""
        return self.home / "tools"

    @property
    def python(self) -> Path:
        """The kit's managed Python."""
        return self.home / "python"

    @property
    def python_interpreter_record(self) -> Path:
        """The file naming the interpreter the bootstrap set up."""
        return self.python / "interpreter"

    @property
    def personas_user(self) -> Path:
        """The user's own persona files."""
        return self.home / "personas"

    @property
    def workflows(self) -> Path:
        """Scheduled workflow definitions."""
        return self.home / "workflows"

    @property
    def failure_note(self) -> Path:
        """The note the last failed run left for status to show."""
        return self.home / ".last-failure"

    @property
    def update_in_progress(self) -> Path:
        """The marker a kit self-update leaves until it completes."""
        return self.home / ".update-in-progress"

    @property
    def install_lock(self) -> Path:
        """The lock the installer holds while it runs."""
        return self.home / ".install.lock"
