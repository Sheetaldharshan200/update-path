"""``exakit update [<target>] [--yes]``: the work plan, never a status table; the runtime only with an answer."""

from __future__ import annotations

from exakit.components import for_component, known
from exakit.domain.errors import BadInput, Failed
from exakit.domain.result import Result
from exakit.domain.versions import VersionPolicy, is_newer
from exakit.lifecycles import for_addon

from . import Context
from .machine import addon_installed_version, installed_version
from .runtime_ops import runtime
from .version import available, kit_current, min_kit_needed, source_line, supported

HEAVY = {"runtime"}
RUNTIME_WORDS = {"runtime", "database", "db"}


def targets(ctx: Context, target: str) -> list[str]:
    """The components an update target names, in order."""
    manifest = ctx.manifest()
    if target == "all":
        out = ["exakit", "runtime", "exapump", "mcp", "pyexasol", "skills"]
        out += [a.id for a in ctx.catalog.addons() if addon_installed_version(ctx, a, manifest)[1]]
        return out
    if target in RUNTIME_WORDS:
        return ["runtime"]
    if target in ("personal", "exakit", "exapump", "mcp", "pyexasol", "skills") or ctx.catalog.has_addon(target):
        return [target]
    raise BadInput(f"Unknown update target '{target}' (see: exakit version)")


def actual(ctx: Context, component: str) -> str:
    """The component id behind a runtime word."""
    if component in RUNTIME_WORDS:
        rtype = ctx.manifest().runtime_type()
        if not rtype:
            raise Failed("No runtime is recorded in the manifest.")
        return rtype
    return component


def current_version(ctx: Context, component: str) -> str | None:
    """The installed version of a component or add-on, or None."""
    if ctx.catalog.has_addon(component):
        return for_addon(ctx, ctx.catalog.addon(component)).installed_version()
    return installed_version(ctx, component, ctx.manifest_or_none())[0]


def is_ahead(current: str | None, advertised: str | None) -> bool:
    """True when the installed version is newer than the advertised one."""
    return bool(current and advertised and current not in ("unknown", "not installed") and is_newer(current, advertised))


def parse_args(args: list[str]) -> tuple[str, list[str], bool]:
    """(target, runtime options, --yes). Options are only for the Personal runtime update."""
    yes = False
    rest = []
    for arg in args:
        if arg in ("-y", "--yes"):
            yes = True
        else:
            rest.append(arg)
    target = rest[0] if rest else "all"
    if target.startswith("-"):
        raise BadInput(f"Unknown option '{target}' for update (supported: --yes; a component name selects what to update).")
    options = rest[1:]
    if options and target not in RUNTIME_WORDS | {"personal"}:
        raise Failed("Update options are only supported for Personal runtime updates.")
    return target, options, yes


# --- the runtime offer ------------------------------------------------------------------


def _preanswer(ctx: Context, yes: bool) -> str | None:
    if yes:
        return "yes"
    value = ctx.env.get("EXAKIT_CONFIRM_RUNTIME_UPDATE", "").strip().lower()
    return "yes" if value in ("1", "y", "yes") else "no" if value in ("0", "n", "no") else None


def _explain(ctx: Context, name: str, current: str, latest: str) -> None:
    ctx.ui.warn(f"{name} {current} -> {latest} needs the database stopped.")
    ctx.ui.info("The launcher is replaced; the database is checked afterwards and started again if it ends up down - usually under a minute.")
    ctx.ui.info("Your data is kept: this update neither deletes nor migrates the tables in your database.")


def _major_differs(current: str, latest: str) -> bool:
    from exakit.components.personal import major
    return bool(major(current) and major(latest) and major(current) != major(latest))


def offer_runtime(ctx: Context, name: str, current: str, latest: str, yes: bool) -> bool:
    """True when the runtime update ran; False when it was deferred (and said why)."""
    if _major_differs(current, latest):
        ctx.ui.warn(f"{name} {current} -> {latest} is a major upgrade: it needs a backup and a data migration, so a routine update does not start it.")
        return False
    answer = _preanswer(ctx, yes)
    if answer == "no":
        ctx.ui.warn(f"{name} {current} -> {latest} was left alone: the database update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE).")
        ctx.ui.info("Apply it when convenient:  exakit update")
        return False
    if answer is None:
        if not ctx.ui.interactive:
            ctx.ui.warn(f"{name} {current} -> {latest} needs the database stopped, so it is not part of a routine update.")
            ctx.ui.info("Apply it when convenient:  exakit update")
            ctx.ui.info("Unattended runs can opt in:  exakit update --yes  (or EXAKIT_CONFIRM_RUNTIME_UPDATE=1)")
            return False
        _explain(ctx, name, current, latest)
        if not ctx.ui.confirm("Stop the database and update the runtime now?", default=False):
            ctx.ui.info("Nothing was stopped. Apply it when convenient:  exakit update")
            return False
    else:
        _explain(ctx, name, current, latest)
    apply_runtime(ctx)
    return True


def apply_runtime(ctx: Context, options: list[str] | None = None) -> None:
    """Update the Exasol Personal runtime through the launcher."""
    rt = runtime(ctx)
    was_running = rt.status().state == "running"
    for_component(ctx, "runtime").update(options)
    state = rt.status().state
    if was_running and state not in ("running", "starting"):
        ctx.ui.info("Bringing the database back up")
        rt.start(ctx.ui.info)
        rt.wait_ready_or_deploy(ctx.ui.info)
        state = rt.status().state
    if state == "running":
        ctx.ui.ok("Runtime updated and the database is running again.")
    elif state == "starting":
        ctx.ui.ok("Runtime updated; the database is still coming up - check it with: exakit status")
    else:
        ctx.ui.warn(f"Runtime updated, but the database reports '{state}' - start it with: exakit start")


# --- the loop -------------------------------------------------------------------------------


def update_one(ctx: Context, component: str, options: list[str]) -> None:
    """Update one component or add-on."""
    if ctx.catalog.has_addon(component):
        for_addon(ctx, ctx.catalog.addon(component)).update()
        return
    if component in RUNTIME_WORDS or component == "personal":
        apply_runtime(ctx, options)
        return
    if not known(component):
        raise Failed(f"Unknown update target: {component}")
    for_component(ctx, component).update(options)


def _skip_reason(ctx: Context, target: str, name: str, current: str | None, advertised: str | None) -> str | None:
    """Why this component is left alone on a routine update (None means: update it)."""
    if not supported(ctx, name):
        if target == "all":
            return "skip"
        raise Failed(f"{name} has no build for this platform, so there is nothing to update.")
    if target == "all" and advertised is None:
        ctx.ui.warn(f"No advertised version for {name} - skipping it. Details: exakit version")
        return "skip"
    if is_ahead(current, advertised):
        ctx.ui.ok(f"{name} {current or 'unknown'} is newer than the tested {advertised} - keeping yours")
        return "skip"
    if current and advertised and current == advertised and (target == "all" or not ctx.catalog.has_addon(name)):
        return "skip"
    needed = min_kit_needed(ctx, name)
    if needed and not _min_kit_ok(ctx, needed):
        ctx.ui.warn(f"{name} {advertised} needs kit >= {needed} - update the kit first: exakit update")
        if target == "all":
            return "skip"
        raise Failed(f"Refusing to install {name} {advertised} on kit {kit_current(ctx) or 'unknown'}.")
    return None


def _min_kit_ok(ctx: Context, needed: str) -> bool:
    kit = kit_current(ctx)
    return not kit or kit in ("unknown", needed) or is_newer(kit, needed)


def _update_component(ctx: Context, component: str, name: str, target: str, options: list[str], yes: bool,
                      planned: list[dict[str, str | None]]) -> tuple[int, int]:
    """(acted, deferred) for one component: skipped, planned (dry run), offered (a runtime) or updated."""
    current = current_version(ctx, name)
    resolved = available(ctx, name)
    advertised = resolved.version if resolved else None
    if _skip_reason(ctx, target, name, current, advertised) == "skip":
        return 0, 0
    if ctx.dry_run:
        planned.append({"component": name, "current": current, "advertised": advertised})
        ctx.ui.info(f"{name} {current or 'not installed'} -> {advertised or 'unknown'}   (dry run: nothing changes)")
        return 0, 0
    if target == "all" and component in HEAVY:
        return _offer_heavy(ctx, name, current, advertised, yes)
    if advertised:
        ctx.ui.info(f"{name} {current or 'not installed'} -> {advertised}")
    update_one(ctx, component, options)
    return 1, 0


def _offer_heavy(ctx: Context, name: str, current: str | None, advertised: str | None, yes: bool) -> tuple[int, int]:
    """(acted, deferred) for a runtime change under ``update all``: offered, never forced."""
    if not (current and advertised) or current in ("unknown", advertised):
        return 0, 0
    return (1, 0) if offer_runtime(ctx, name, current, advertised, yes) else (0, 1)


def run(ctx: Context, args: list[str]) -> Result:
    """``exakit update``: apply the advertised versions, offering the runtime change."""
    target, options, yes = parse_args(args)
    ctx.manifest()
    plan = targets(ctx, target)
    if ctx.policy is VersionPolicy.MANIFEST:
        ctx.versions.refresh(force=True)
    if ctx.policy is not VersionPolicy.MANIFEST or ctx.versions.source_label() != "baked":
        ctx.ui.info(source_line(ctx))
    acted = deferred = 0
    planned: list[dict[str, str | None]] = []
    for component in plan:
        if component in RUNTIME_WORDS and not ctx.manifest().runtime_type():
            if target != "all":
                raise Failed("No runtime is recorded in the manifest.")
            continue
        name = actual(ctx, component) if component in RUNTIME_WORDS else component
        done, held = _update_component(ctx, component, name, target, options, yes, planned)
        acted, deferred = acted + done, deferred + held
    if ctx.dry_run:
        return Result(True, "dry-run", data={"planned": planned})
    if not acted and not deferred:
        ctx.ui.ok("Everything is already current.")
    if deferred:
        ctx.ui.info("See everything, including the deferred runtime change: exakit version")
    return Result(True, "updated" if acted else "deferred" if deferred else "current", data={"updated": acted, "deferred": deferred})
