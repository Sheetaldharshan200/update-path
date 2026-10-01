"""SHA-256 of files, and the one verification message every download shares."""

from __future__ import annotations

import hashlib
from pathlib import Path

from exakit.domain.errors import Failed


def sha256_of(path: Path) -> str:
    """The hex sha256 of a file."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class ChecksumMismatch(Failed):
    """The file's digest is not the published one: the download is corrupt or tampered with, and nothing retries it."""


def verify_sha256(path: Path, expected: str, *, what: str) -> None:
    """Raise ChecksumMismatch, naming the artifact, when the file's digest is not the expected one."""
    actual = sha256_of(path)
    if actual.lower() != expected.lower():
        raise ChecksumMismatch(
            f"The downloaded {what} did not match its published checksum.",
            hint=f"expected sha256 {expected}, got {actual}; the download may be corrupt or tampered with",
        )


def digest_from_checksums(text: str, asset: str) -> str | None:
    """The sha256 for one asset out of a ``<digest>  <name>`` checksums file (a ``dist/`` prefix or a leading ``*`` is ignored); None when it is not listed."""
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[-1].lstrip("*").rsplit("/", 1)[-1] == asset and len(parts[0]) == 64:
            return parts[0].lower()
    return None
