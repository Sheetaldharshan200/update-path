"""One re-export so app modules read the kit version without reaching into the component package's internals."""

from exakit.components.kit import kit_version_at

__all__ = ["kit_version_at"]
