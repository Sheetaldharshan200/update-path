"""The migrated commands: parse their own options, call a use case, return a Result.

Each function takes the raw argument list after the command word and the
Context. Options are the legacy ones, refused with the legacy wording.
"""

from __future__ import annotations

import sys

from exakit.app import Context, data as data_app, guide as guide_app, help as help_app, info as info_app, install as install_app, migrate as migrate_app, repair as repair_app, requirements as requirements_app, uninstall as uninstall_app, runtime as runtime_app, status as status_app, update as update_app, logs as logs_app, marketplace as marketplace_app, mcp as mcp_app, persona as persona_app, skills as skills_app, sql as sql_app, version as version_app, whats_new
from exakit.app.machine import kit_root
from exakit.domain.errors import BadInput
from exakit.domain.result import Result
from exakit.ui.widgets import term_cols

JSON_FLAGS = ("--json", "-j")


def _split(args: list[str], allowed: tuple[str, ...], command: str) -> tuple[list[str], set[str]]:
    """Positional arguments and the flags seen; an unknown flag is refused the legacy way."""
    positional, flags = [], set()
    for arg in args:
        if arg.startswith("-"):
            if arg not in allowed:
                supported = ", ".join(a for a in allowed if a.startswith("--")) or "none"
                raise BadInput(f"Unknown option '{arg}' for {command} (supported: {supported}).")
            flags.add(arg)
        else:
            positional.append(arg)
    return positional, flags


def _help_docs(ctx: Context):
    return help_app.load_docs(kit_root(ctx) / "help")


def _help_color(ctx: Context) -> bool:
    return sys.stdout.isatty() and ctx.env.get("EXAKIT_HELP_PLAIN") != "1" and not ctx.json


# --- help / catalog / whats-new ---------------------------------------------------


def help_command(args: list[str], ctx: Context) -> Result:
    """``exakit help``: the overview, a topic's page, every command, or the JSON document."""
    positional, flags = _split(args, (*JSON_FLAGS, "--all", "-a", "--help", "-h"), "help")
    docs = _help_docs(ctx)
    topic = positional[0] if positional else ""
    if ctx.json:
        return Result(True, "ok", data=help_app.json_payload(docs, topic or "all"), raw=True)
    if "--all" in flags or "-a" in flags:
        mode, arg = "all", ""
    elif topic and topic in docs:
        mode, arg = "component", topic
    elif topic:
        mode, arg = "command", topic
    else:
        mode, arg = "overview", ""
    text, rc = help_app.render(docs, mode, arg, color=_help_color(ctx), width=term_cols())
    sys.stdout.write(text)
    return Result(True, "ok", exit_code=rc)


def topic_help(topic: str, ctx: Context) -> Result:
    """``exakit <command> --help`` and ``exakit <component>``: the page for one topic; under --json, its document."""
    docs = _help_docs(ctx)
    if ctx.json:
        return Result(True, "ok", data=help_app.json_payload(docs, topic), raw=True)
    mode = "component" if topic in docs else "command"
    text, rc = help_app.render(docs, mode, topic, color=_help_color(ctx), width=term_cols())
    sys.stdout.write(text)
    return Result(True, "ok", exit_code=rc)


def is_help_topic(topic: str, ctx: Context) -> bool:
    """True when ``topic`` is the id of a help document (a component or tool)."""
    return topic in _help_docs(ctx)


def catalog_command(args: list[str], ctx: Context) -> Result:
    """``exakit catalog [search]``: every command in one screen, or the JSON surface."""
    positional, _ = _split(args, JSON_FLAGS, "catalog")
    docs = _help_docs(ctx)
    search = " ".join(positional)
    if ctx.json:
        return Result(True, "ok", data=help_app.json_payload(docs, search or "all"), raw=True)
    text, rc = help_app.render(docs, "catalog", search, color=_help_color(ctx), width=term_cols())
    sys.stdout.write(text)
    return Result(True, "ok", exit_code=rc)


def whats_new_command(args: list[str], ctx: Context) -> Result:
    """``exakit whats-new [version]``: the cards from help/whats-new.json."""
    positional, _ = _split(args, JSON_FLAGS, "whats-new")
    return whats_new.run(ctx, positional[0] if positional else None)


# --- version --------------------------------------------------------------------------


def version_command(args: list[str], ctx: Context) -> Result:
    """``exakit version``: installed and advertised versions per component and add-on."""
    _split(args, JSON_FLAGS, "version")
    return version_app.run(ctx)


# --- persona ----------------------------------------------------------------------------


def persona_command(args: list[str], ctx: Context) -> Result:
    """``exakit persona list|show|plan|apply``: the persona use cases behind one entry."""
    positional, flags = _split(args, (*JSON_FLAGS, "--yes", "-y"), "persona")
    sub = positional[0] if positional else ""
    pid = positional[1] if len(positional) > 1 else ""
    if len(positional) > 2:
        raise BadInput(f"Too many arguments for persona: '{positional[2]}'.")
    if sub not in ("", "list", "show", "plan", "apply"):
        raise BadInput(f"Unknown persona subcommand '{sub}' (use list, show <id>, plan <id>, or apply <id>).")
    if (ctx.yes or "--yes" in flags or "-y" in flags) and sub != "apply":
        raise BadInput("--yes only applies to: exakit persona apply <id> --yes")
    if sub in ("show", "plan", "apply") and not pid:
        raise BadInput(f"persona {sub} needs an id (see: exakit persona list).")
    if sub in ("", "list") and pid:
        raise BadInput(f"persona list takes no id (did you mean: exakit persona show {pid}).")
    if pid:
        ctx.catalog.persona(pid)   # unknown id -> BadInput naming the known ones
    if sub == "list" or (sub == "" and (ctx.json or not ctx.ui.interactive)):
        result = persona_app.list_personas(ctx)
        if sub == "" and not ctx.json:
            ctx.ui.info("Without a terminal nothing is installed. Apply one with: exakit persona apply <id> --yes")
        return result
    if sub == "show":
        return persona_app.show(ctx, pid)
    if sub == "plan":
        return persona_app.plan(ctx, pid)
    ctx.yes = ctx.yes or "--yes" in flags or "-y" in flags
    return persona_app.apply(ctx, pid)


# --- status, info, start, stop, autostart ---------------------------------------------


def status_command(args: list[str], ctx: Context) -> Result:
    """``exakit status``: the kit's state, exit 3 when the database is not running."""
    _split(args, JSON_FLAGS, "status")
    return status_app.run(ctx)


def info_command(args: list[str], ctx: Context) -> Result:
    """``exakit info``: the connection panel, or the install record under --json."""
    _split(args, JSON_FLAGS, "info")
    return info_app.run(ctx)


def start_command(args: list[str], ctx: Context) -> Result:
    """``exakit start``: the database and the add-on services."""
    _split(args, (), "start")
    return runtime_app.start(ctx)


def stop_command(args: list[str], ctx: Context) -> Result:
    """``exakit stop``: the database and the add-on services; the data is kept."""
    _split(args, (), "stop")
    return runtime_app.stop(ctx)


def autostart_command(args: list[str], ctx: Context) -> Result:
    """``exakit autostart``: whether the kit's services start at login, and the offer to change it."""
    return runtime_app.autostart(ctx, args)


def update_command(args: list[str], ctx: Context) -> Result:
    """``exakit update [target]``: apply the advertised versions."""
    return update_app.run(ctx, args)


# --- marketplace and add-on uninstall --------------------------------------------------


def marketplace_command(args: list[str], ctx: Context) -> Result:
    """``exakit marketplace``: list, install or offer the optional add-ons."""
    return marketplace_app.run(ctx, args)


def uninstall_command(args: list[str], ctx: Context) -> Result:
    """``exakit uninstall [addon]``: one add-on, the menu, or everything with --yes."""
    return uninstall_app.run(ctx, args)


def install_command(args: list[str], ctx: Context) -> Result:
    """``exakit install``: the whole install, resumable; --dry-run shows the plan."""
    for arg in args:
        if arg.startswith("-"):
            raise BadInput(f"Unknown option '{arg}' for install (supported: --dry-run; answers come from EXAKIT_* variables or EXAKIT_PERSONA).")
        raise BadInput("install takes no arguments; answer its questions with EXAKIT_* variables or name a persona with EXAKIT_PERSONA=<id>.")
    return install_app.run(ctx)


def guide_command(args: list[str], ctx: Context) -> Result:
    """``exakit guide``: how to connect AI clients, SQL clients and Python."""
    _split(args, (), "guide")
    return guide_app.run(ctx)


def preflight_command(args: list[str], ctx: Context) -> Result:
    """``exakit preflight``: this machine's requirements, nothing written."""
    _split(args, JSON_FLAGS, "preflight")
    return requirements_app.preflight(ctx)


def repair_runtime_command(args: list[str], ctx: Context) -> Result:
    """``exakit repair-runtime``: rebuild an interrupted deployment, with consent."""
    return repair_app.run(ctx, args)


def migrate_command(args: list[str], ctx: Context) -> Result:
    """``exakit migrate docker-nano``: bring a legacy database's tables over."""
    return migrate_app.migrate(ctx, args)


# --- skills -----------------------------------------------------------------------------


def skills_command(args: list[str], ctx: Context) -> Result:
    """``exakit skills``: the skill set and where each skill stands."""
    positional, _ = _split(args, JSON_FLAGS, "skills")
    if positional:
        raise BadInput(f"Unknown option '{positional[0]}' for skills (supported: --json).")
    return skills_app.list_skills(ctx)


def skills_install_command(args: list[str], ctx: Context) -> Result:
    """``exakit skills-install``: place the skills into the agents' folders."""
    _split(args, (), "skills-install")
    ctx.manifest()   # exit 4 without an install record
    return skills_app.skills_install_command(ctx)


# --- MCP --------------------------------------------------------------------------------


def mcp_setup_command(args: list[str], ctx: Context) -> Result:
    """``exakit mcp-setup [clients]``: configure the MCP server in the AI clients."""
    for arg in args:
        if arg.startswith("-"):
            raise BadInput(f"Unknown option '{arg}' for mcp-setup (it takes none; name clients with EXAKIT_MCP_CLIENTS=claude,codex exakit mcp-setup).")
        raise BadInput("mcp-setup takes no arguments; name clients with EXAKIT_MCP_CLIENTS=<x> exakit mcp-setup")
    ctx.manifest()
    if not ctx.manifest().runtime_type():
        from exakit.domain.errors import NotRunning
        raise NotRunning("No runtime recorded in the manifest yet - re-run the installer, it resumes at the unfinished step.",
                         remedy=ctx.install_command())
    return mcp_app.setup(ctx)


def mcp_status_command(args: list[str], ctx: Context) -> Result:
    """``exakit mcp-status [clients]``: which clients the kit manages and their config files."""
    positional, _ = _split(args, JSON_FLAGS, "mcp-status")
    return mcp_app.status(ctx, positional)


def mcp_doctor_command(args: list[str], ctx: Context) -> Result:
    """``exakit mcp-doctor [clients]``: check and repair the MCP configuration."""
    positional, _ = _split(args, JSON_FLAGS, "mcp-doctor")
    return mcp_app.doctor(ctx, positional)


def mcp_remove_command(args: list[str], ctx: Context) -> Result:
    """``exakit mcp-remove <client>...``: take the kit's entries out of those clients."""
    positional, _ = _split(args, (), "mcp-remove")
    return mcp_app.remove(ctx, positional)


# --- sql and logs -----------------------------------------------------------------------


def sql_command(args: list[str], ctx: Context) -> Result:
    """``exakit sql <statement>``: one statement through exapump, with the read-only guardrail."""
    if args and args[0] in ("--help", "-h") and len(args) == 1:
        return topic_help("sql", ctx)
    return sql_app.run(ctx, args)


def logs_command(args: list[str], ctx: Context) -> Result:
    """``exakit logs [target]``: the install, database and add-on logs."""
    return logs_app.run(ctx, args)


# --- data -------------------------------------------------------------------------------


def data_load_command(args: list[str], ctx: Context) -> Result:
    """``exakit data-load [path]``: the bundled datasets, or the user's own files."""
    return data_app.data_load(ctx, args)
