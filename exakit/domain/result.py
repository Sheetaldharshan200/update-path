"""The one answer shape every command returns.

Every ``--json`` answer carries ``installed``, ``status`` and ``remedy`` first
(the three keys AGENTS.md promises a parser can read without knowing which
command answered), then the command's own keys. The human renderer draws the
same object.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from .errors import EXIT_OK


@dataclass(slots=True)
class Result:
    """What a command found or did.

    ``remedy`` is a runnable command or None, never a sentence; the sentence,
    when one is needed, is ``remedy_hint``. ``data`` holds the command-specific
    keys and is merged flat into the JSON object.
    """

    installed: bool
    status: str
    remedy: str | None = None
    remedy_hint: str | None = None
    data: dict[str, Any] = field(default_factory=dict)
    exit_code: int = EXIT_OK
    raw: bool = False   # True: the JSON answer is ``data`` alone (a document, not a state query)

    def to_dict(self) -> dict[str, Any]:
        """The JSON object, contract keys first (or the document alone when ``raw``)."""
        if self.raw:
            return dict(self.data)
        doc: dict[str, Any] = {
            "installed": self.installed,
            "status": self.status,
            "remedy": self.remedy,
        }
        if self.remedy_hint is not None:
            doc["remedy_hint"] = self.remedy_hint
        for key, value in self.data.items():
            doc.setdefault(key, value)
        return doc

    def to_json(self) -> str:
        """One line, one object, nothing else."""
        return json.dumps(self.to_dict(), ensure_ascii=True)
