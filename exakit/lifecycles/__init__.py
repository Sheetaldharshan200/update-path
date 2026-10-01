"""Add-on lifecycles: the generic ways an optional tool is installed, checked, updated and removed.

``for_addon`` picks the implementation for a catalog entry: an add-on's own
module under ``exakit.addons`` when it needs bespoke steps, otherwise the
generic lifecycle for its ``kind``. Every lifecycle records the same manifest
block, ``components.<id_>``, and answers the same questions.
"""

from __future__ import annotations

import importlib
from collections.abc import Callable
from typing import Protocol

from exakit.domain.catalog import Addon

from .base import LifecycleBase, ServiceHooks


class Lifecycle(Protocol):
    addon: Addon
    def applicable(self) -> tuple[bool, str]: ...
    def system_present(self) -> bool: ...
    def installed_version(self) -> str | None: ...
    def target_version(self) -> str: ...
    def install(self, version: str) -> None: ...
    def validate(self) -> None: ...
    def update(self) -> None: ...
    def uninstall(self, *, dry_run: bool) -> list[str]: ...
    def service(self) -> ServiceHooks | None: ...
    def summary(self) -> str | None: ...


def for_addon(ctx, addon: Addon) -> LifecycleBase:
    """An ``exakit.addons.<id>`` module's ``Lifecycle`` when present, else the generic kind."""
    module_name = f"exakit.addons.{addon.id.replace('-', '_')}"
    try:
        module = importlib.import_module(module_name)
        return module.Lifecycle(ctx, addon)
    except ModuleNotFoundError as err:
        if err.name != module_name:
            raise
    from .python_venv import PythonVenvLifecycle
    from .binary import BinaryLifecycle
    from .host_extension import HostExtensionLifecycle
    generic: dict[str, Callable] = {"python-venv": PythonVenvLifecycle, "binary": BinaryLifecycle, "host-extension": HostExtensionLifecycle}
    if addon.kind not in generic:
        raise ValueError(f"add-on {addon.id} has kind '{addon.kind}' and no lifecycle module")
    return generic[addon.kind](ctx, addon)


__all__ = ["Lifecycle", "LifecycleBase", "ServiceHooks", "for_addon"]
