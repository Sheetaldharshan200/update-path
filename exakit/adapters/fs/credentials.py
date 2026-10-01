"""Credential files under ``$EXAKIT_HOME/credentials``: mode 0600 in a 0700 directory, never echoed.

A credential is stored by name (``personal_sys_password``,
``mcp_readonly_password``, ``exasol_scheduler_password``) and read back as
a value that callers pass to tools through the environment or stdin, never
on a command line and never into a log.
"""

from __future__ import annotations

import os
import secrets
import string
from pathlib import Path

from exakit.domain.errors import Failed

from .atomic import atomic_write_text
import contextlib

_TOKEN_ALPHABET = string.ascii_uppercase + string.digits


class CredentialStore:
    def __init__(self, directory: Path) -> None:
        self.directory = directory

    def path(self, name: str) -> Path:
        """The file for a credential name."""
        return self.directory / name

    def exists(self, name: str) -> bool:
        """True when the credential is stored."""
        return self.path(name).is_file()

    def read(self, name: str) -> str | None:
        """The value, or None when the file is missing. Unreadable files raise Failed."""
        path = self.path(name)
        if not path.is_file():
            return None
        try:
            return path.read_text(encoding="utf-8")
        except OSError as err:
            raise Failed(f"The credential file {path} exists but cannot be read.", hint=str(err)) from err

    def store(self, name: str, value: str) -> Path:
        """Write the value (no trailing newline) with owner-only modes; atomic."""
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            os.chmod(self.directory, 0o700)
        except OSError as err:
            raise Failed(f"Could not create the credentials directory {self.directory}.", hint=str(err)) from err
        path = self.path(name)
        if path.is_dir():
            raise Failed(f"{path} is a directory, not a credential file; move it aside and retry.")
        atomic_write_text(path, value, mode=0o600)
        return path

    def remove(self, name: str) -> None:
        """Delete the credential."""
        with contextlib.suppress(FileNotFoundError):
            self.path(name).unlink()

    @staticmethod
    def new_token() -> str:
        """A database-safe generated password: ``A`` then 23 characters from ``[A-Z0-9]``."""
        return "A" + "".join(secrets.choice(_TOKEN_ALPHABET) for _ in range(23))

    @staticmethod
    def is_token(value: str | None) -> bool:
        """True when the value is a single ASCII token."""
        return bool(value) and value[0].isascii() and value[0].isalpha() and value.isupper() and all(
            c in _TOKEN_ALPHABET for c in value)
