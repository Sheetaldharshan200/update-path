"""exakit: the Exasol Personal Local Starter Kit, one Python implementation.

Layers, dependencies pointing down only:
    cli -> ui / app -> domain
    app -> adapters (behind Protocols) -> the machine
See docs/architecture.md and docs/design.md.
"""

from __future__ import annotations

__all__ = ["__version__"]

# The kit's own version is the one the tree's versions.json advertises; it is
# read lazily by app.version so importing the package never touches the disk.
__version__ = "0.3.0"
