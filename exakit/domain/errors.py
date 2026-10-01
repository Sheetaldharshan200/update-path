"""The kit's error hierarchy and the ONLY place exit codes are defined.

Every code has the meaning AGENTS.md documents:

    0  ok
    1  a real failure (the step ran and did not finish)
    2  bad input (unknown command, option, id, or value)
    3  the database is not running, or the install has no runtime yet
    4  not installed (no install record)
    5  not confirmed (a question was declined, or needed --yes)

Errors are raised, never returned. Only ``app.run_plan`` and ``cli.main``
catch them: the first to mark a step failed and carry on, the second to map
the error to its exit code and the refusal object under ``--json``.
"""

from __future__ import annotations

from typing import Any

EXIT_OK = 0


class ExakitError(Exception):
    """A failure the user can act on.

    ``remedy`` is the one command that fixes it, runnable as written, or None.
    Prose that explains the remedy goes in ``hint``. ``data`` carries extra
    keys for the JSON answer (a plan that was not confirmed, for example).
    """

    code: int = 1

    def __init__(
        self,
        message: str,
        *,
        remedy: str | None = None,
        hint: str | None = None,
        data: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.remedy = remedy
        self.hint = hint
        self.data = dict(data or {})

    def refusal(self) -> dict[str, Any]:
        """The object a refused ``--json`` call prints: one shape for every code."""
        doc: dict[str, Any] = {
            "ok": False,
            "error": self.message,
            "remedy": self.remedy,
            "rejected": self.code == BadInput.code,
        }
        if self.hint:
            doc["remedy_hint"] = self.hint
        doc.update(self.data)
        return doc


class Failed(ExakitError):
    """A step ran and did not finish."""

    code = 1


class BadInput(ExakitError):
    """Unknown command, option, id or value. Nothing ran."""

    code = 2


class NotRunning(ExakitError):
    """The database is not running, or no runtime is recorded yet."""

    code = 3


class NotInstalled(ExakitError):
    """No install record on this machine."""

    code = 4

    def refusal(self) -> dict[str, Any]:
        """The state-query keys first (``installed``, ``status``, ``remedy``), then the refusal object."""
        return {"installed": False, "status": "not installed", "remedy": self.remedy, **super().refusal()}


class NotConfirmed(ExakitError):
    """A question was declined, or needed ``--yes`` without a terminal."""

    code = 5
