#!/usr/bin/env python3
"""What icacls says about a file protect_path tightened: the Windows CI prints this so ACL drift can be read from real output."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from mcp.runtime import filesystem as fs


def main() -> int:
    folder = Path(tempfile.mkdtemp(prefix="acl-diag-"))
    plain = folder / "config.json"
    plain.write_text("{}", encoding="utf-8")
    print("USERNAME:", os.environ.get("USERNAME"), "| realpath:", os.path.realpath(plain))
    print("protect_path ->", fs.protect_path(plain))
    print(subprocess.run(["icacls", str(plain)], capture_output=True, text=True, check=False).stdout)
    print("describe_protection ->", fs.describe_protection(plain))
    written = folder / "written.json"
    fs.FileSystem().write_text(written, "{}")
    print(subprocess.run(["icacls", str(written)], capture_output=True, text=True, check=False).stdout)
    print("describe(written) ->", fs.describe_protection(written))
    return 0


if __name__ == "__main__":
    sys.exit(main())
