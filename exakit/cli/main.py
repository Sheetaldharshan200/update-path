"""``exakit``: one entry point, one dispatch, one place errors become exit codes.

Global flags (``--json``/``-j``, ``--yes``/``-y``, ``--dry-run``) may appear
anywhere; the first bare word is the command (``HANDLERS`` is the full set).
A bare component id renders its help
page, ``<command> --help`` renders that command's page, and anything else is
a refusal with exit 2.
"""

from __future__ import annotations

import os
import sys
import traceback
from collections.abc import Callable

from exakit.app import Context, notice
from exakit.app.requirements import supported_platforms
from exakit.domain.errors import BadInput, ExakitError, Failed
from exakit.domain.result import Result
from exakit.ui import tui

from . import _context, commands

READONLY_COMMANDS: frozenset[str] = frozenset({"help", "catalog", "whats-new", "version", "status", "info",
                                               "skills", "logs", "mcp-status", "persona", "preflight", "guide"})
HANDLERS: dict[str, Callable[[list[str], Context], Result]] = {
    "help": commands.help_command, "-h": commands.help_command, "--help": commands.help_command,
    "catalog": commands.catalog_command, "whats-new": commands.whats_new_command,
    "version": commands.version_command, "--version": commands.version_command, "-v": commands.version_command,
    "persona": commands.persona_command,
    "skills": commands.skills_command, "skills-install": commands.skills_install_command,
    "mcp-setup": commands.mcp_setup_command, "mcp-status": commands.mcp_status_command,
    "mcp-doctor": commands.mcp_doctor_command, "mcp-remove": commands.mcp_remove_command,
    "sql": commands.sql_command, "logs": commands.logs_command, "data-load": commands.data_load_command,
    "marketplace": commands.marketplace_command, "uninstall": commands.uninstall_command,
    "status": commands.status_command, "info": commands.info_command, "start": commands.start_command,
    "stop": commands.stop_command, "autostart": commands.autostart_command, "update": commands.update_command,
    "install": commands.install_command, "preflight": commands.preflight_command,
    "repair-runtime": commands.repair_runtime_command, "migrate": commands.migrate_command,
    "guide": commands.guide_command,
}
ALIASES = {"-h": "help", "--help": "help", "--version": "version", "-v": "version"}


def _parse(argv: list[str]) -> tuple[str, list[str], dict[str, bool]]:
    flags = {"json": False, "yes": False, "dry_run": False}
    command = ""
    rest: list[str] = []
    for arg in argv:
        if arg in ("--json", "-j"):
            flags["json"] = True
        elif arg in ("--yes", "-y"):
            flags["yes"] = True
        elif arg == "--dry-run":
            flags["dry_run"] = True
        elif not command:
            command = arg
        else:
            rest.append(arg)
    return command or "help", rest, flags


def _emit(result: Result, ctx: Context) -> None:
    if ctx.json:
        sys.stdout.write(result.to_json() + "\n")
        sys.stdout.flush()


def _emit_refusal(err: ExakitError, ctx: Context | None, json_mode: bool) -> None:
    if json_mode:
        import json as _json
        sys.stdout.write(_json.dumps(err.refusal()) + "\n")
        sys.stdout.flush()
        return
    if ctx is not None:
        ctx.ui.card(err.message, log_path=str(ctx.log.path) if ctx.log.path else None, remedy=err.remedy)
    else:
        sys.stderr.write(f"\n  [x] {err.message}\n")


def main(argv: list[str] | None = None) -> int:
    """The entry point: parse, dispatch, map errors to exit codes."""
    argv = list(sys.argv[1:] if argv is None else argv)
    command, rest, flags = _parse(argv)
    command = ALIASES.get(command, command)
    ctx: Context | None = None
    try:
        # `exakit sql --help` is a query, not a help request; every other command answers its page.
        wants_page = command != "sql" and command not in ("help",) and any(a in ("--help", "-h") for a in rest)
        readonly = command in READONLY_COMMANDS or wants_page or command not in HANDLERS
        ctx = _context.build(json=flags["json"], yes=flags["yes"], dry_run=flags["dry_run"], readonly=readonly, mutating=not readonly)
        if wants_page or (command not in HANDLERS and not rest and commands.is_help_topic(command, ctx)):
            page = commands.topic_help(command, ctx)      # a command's --help, or a bare component id
            _emit(page, ctx)
            return page.exit_code
        if command in HANDLERS:
            result = _run(command, rest, ctx)
            _emit(result, ctx)
            notice.maybe_show(ctx, command)
            return result.exit_code
        raise unknown_command(command)
    except ExakitError as err:
        _emit_refusal(err, ctx, flags["json"])
        return err.code
    except KeyboardInterrupt:
        return 130
    except Exception as err:  # the last line of defence: a user never sees a traceback, the log does
        return _unexpected(err, ctx, flags["json"])


def _run(command: str, rest: list[str], ctx: Context) -> Result:
    """Run the command: inside the Textual screens when this run wants them and they can be had, else as is."""
    handler = HANDLERS[command]
    if tui.wanted(ctx.env, sys.stdout, command=command, args=rest, json=ctx.json, dry_run=ctx.dry_run) and _platform_ok(ctx):
        site = _context.tui_site(ctx)
        if site is not None and tui.load(site):
            return tui.run(ctx, lambda: handler(rest, ctx), title="Exasol Personal Local Starter Kit", subtitle=f"exakit {command}")
    return handler(rest, ctx)


def _platform_ok(ctx: Context) -> bool:
    """False on a machine the local database cannot run on: it must refuse in words, without the screens' venv being written."""
    supported = supported_platforms(ctx)
    return not supported or ctx.platform.platform_key in supported


def _unexpected(err: Exception, ctx: Context | None, json_mode: bool) -> int:
    """A bug, reported like any failure (exit 1, the refusal object under --json); EXAKIT_DEBUG=1 re-raises it."""
    if os.environ.get("EXAKIT_DEBUG") == "1":
        raise err
    if ctx is not None and ctx.log.path:
        ctx.log.line("ERROR", "unexpected: " + "".join(traceback.format_exception(err)).rstrip())
    where = f" (details: {ctx.log.path})" if ctx is not None and ctx.log.path else ""
    failed = Failed(f"Unexpected error: {type(err).__name__}: {err}{where}", hint="re-run with EXAKIT_DEBUG=1 for the traceback")
    _emit_refusal(failed, ctx, json_mode)
    return failed.code


def unknown_command(command: str) -> BadInput:
    """The refusal for an unknown command."""
    return BadInput(f"Unknown command '{command}'.", remedy="exakit catalog --json")
