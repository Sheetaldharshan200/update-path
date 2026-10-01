"""``exakit sql``: one statement, read-only by default, with the engine's faults translated into remedies."""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from exakit.domain.errors import BadInput, NotRunning
from exakit.domain.result import Result

from . import Context
from .runtime_ops import exapump, profile_name

READ_WORDS = ("SELECT", "WITH", "DESCRIBE", "DESC", "EXPLAIN", "SHOW")
WRITE_WORDS = ("INSERT", "UPDATE", "DELETE", "MERGE", "CREATE", "DROP", "ALTER", "TRUNCATE", "GRANT", "REVOKE",
               "IMPORT", "EXPORT", "COMMIT", "ROLLBACK", "OPEN", "CLOSE", "FLUSH", "KILL", "ENFORCE", "EXECUTE", "CALL")


@dataclass(slots=True)
class SqlArgs:
    statement: str | None = None
    file: str | None = None
    write: bool = False


def parse_args(args: list[str]) -> SqlArgs:
    """The statement, the file, the flags."""
    parsed = SqlArgs()
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--":
            if i + 1 < len(args):
                _statement(parsed, args[i + 1])
            i += 2
            continue
        if arg.startswith("-- ") or "\n" in arg:
            _statement(parsed, arg)
        elif arg == "--write":
            parsed.write = True
        elif arg in ("--json", "-j"):
            pass
        elif arg in ("--file", "-f"):
            if i + 1 >= len(args):
                raise BadInput("--file needs a path: exakit sql --file query.sql")
            parsed.file = args[i + 1]
            i += 1
        elif arg.startswith("--file="):
            parsed.file = arg.split("=", 1)[1]
        elif arg.startswith("-"):
            raise BadInput(f"Unknown option '{arg}' for sql (supported: --write, --json, --file <path>).")
        else:
            _statement(parsed, arg)
        i += 1
    if parsed.file and parsed.statement:
        raise BadInput("Pass ONE statement, quoted, or --file: not both.")
    return parsed


def _statement(parsed: SqlArgs, text: str) -> None:
    if parsed.statement is not None:
        raise BadInput("Pass ONE statement, quoted: exakit sql 'SELECT 1'")
    parsed.statement = text


def clean(text: str) -> str:
    """The statement without comment lines and surrounding blanks."""
    lines = [line for line in text.splitlines() if line.strip() and not re.match(r"^\s*--", line)]
    body = "\n".join(lines).rstrip()
    return body[:-1].rstrip() if body.endswith(";") else body


def first_word(text: str) -> str:
    """The statement's first keyword, upper-cased."""
    folded = re.sub(r"[\n\t]", " ", text).lstrip().upper()
    match = re.match(r"[A-Z]+", folded)
    return match.group(0) if match else ""


def check_read_only(text: str) -> None:
    """Refuse a writing statement unless --write was given."""
    word = first_word(text)
    if word in READ_WORDS:
        pass
    elif word in WRITE_WORDS:
        raise BadInput(f"That is not a read statement ({word}). Re-run with --write to run it deliberately: "
                       "the profile it uses is the ADMIN connection, not the read-only MCP user.")
    else:
        raise BadInput(f"'{word or text[:20]}' is not an SQL statement this command recognises (SELECT, WITH, DESCRIBE, EXPLAIN, SHOW; "
                       "or --write for a change).")
    if ";" in text.rstrip("; \n"):
        raise BadInput("Only one statement at a time: exakit sql 'SELECT 1'")


def remedy_lines(output: str, statement: str) -> tuple[list[str], str | None]:
    """The translated remedy lines and the one runnable command, from the engine's text."""
    text = output
    lines: list[str] = []
    command = None
    if re.search(r"onnection refused|Errno 61|Errno 111|could not connect|Failed to connect to|actively refused|os error 10061", text, re.I):
        lines.append("That is the database not answering - it is stopped or unreachable. Start it with: exakit start (then check: exakit status)")
        command = "exakit start"
    if re.search(r"tls handshake|TLS error", text, re.I):
        lines.append("Something answered on the database port, but it is not Exasol (the TLS handshake failed). Check with: exakit status - "
                     "a conflict names the process holding the port; stop it, then: exakit start")
        command = command or "exakit status"
    if re.search(r"unexpected FETCH_|unexpected TOP_|FETCH FIRST", text) or ("syntax error" in text and re.search(r" TOP |\(TOP ", statement.upper())):
        lines.append("Exasol pages result sets with LIMIT <n> (optionally OFFSET) - not FETCH FIRST or TOP. Rewrite the query with LIMIT.")
    if "not found" in text and re.search(r"object|table|column|schema|view", text, re.I):
        lines.append("A named object does not exist as written. Check the spelling and the schema qualifier - describe it first "
                     "(MCP: describe_exasol_table_or_view; SQL: DESCRIBE <schema>.<table>).")
        if "STARTER_KIT" in statement.upper():
            lines.append("Columns loaded from your own files keep their exact names, in quotes: SELECT \"column name\" FROM STARTER_KIT.TABLE")
    if re.search(r"insufficient privileges|42500", text):
        lines.append("The write was refused by the read-only guardrail.")
        lines.append("To run a write deliberately, use the admin path: exakit sql --write '<statement>'. Never route it through "
                     "'exapump -p starter-kit' by reflex.")
    return lines, command


def error_detail(output: str) -> str:
    """The remedy lines for the faults users hit first."""
    lines = output.splitlines()
    errors = [line for line in lines if line.startswith("Error: ")]
    if errors:
        return errors[-1][len("Error: "):]
    for line in lines:
        if ("rror" in line or "failed" in line) and not line.startswith(("Hint:", "Error in statement")):
            return line
    return lines[0] if lines else "query failed"


def run(ctx: Context, args: list[str]) -> Result:
    """``exakit sql``: one statement through exapump."""
    parsed = parse_args(args)
    ctx.manifest()
    text = clean(_statement_text(parsed))
    if not text:
        raise BadInput("Nothing to run: pass one statement, quoted, or --file <path>.")
    if not parsed.write:
        check_read_only(text)
    pump = exapump(ctx)
    if pump is None:
        raise NotRunning("exapump (the SQL client) is not installed", remedy="exakit update")
    done = pump.sql(profile_name(ctx), text, json_rows=ctx.json)
    return _json_answer(done, text) if ctx.json else _text_answer(ctx, done, text)


def _statement_text(parsed) -> str:
    if parsed.file:
        path = Path(parsed.file).expanduser()
        if not path.is_file():
            raise BadInput(f"No such file: {parsed.file}")
        return path.read_text(encoding="utf-8")
    if parsed.statement is not None:
        return parsed.statement
    if not sys.stdin.isatty():
        return sys.stdin.read()
    return ""


def _json_answer(done, text: str) -> Result:
    """{"ok": true, "rows", "row_count"} or {"ok": false, "error", "remedy", "remedy_hint"}; the object alone on stdout."""
    if done.ok:
        try:
            rows = json.loads(done.out) if done.out.strip() else []
        except ValueError:
            rows = []
        data = {"ok": True, "rows": rows, "row_count": len(rows) if isinstance(rows, list) else None}
        return Result(True, "ok", data=data, raw=True)
    lines, command = remedy_lines(done.out + done.err, text)
    data = {"ok": False, "error": error_detail(done.out + done.err), "remedy": command, "remedy_hint": "\n".join(lines) or None}
    return Result(True, "failed", data=data, raw=True, exit_code=done.code or 1)


def _text_answer(ctx: Context, done, text: str) -> Result:
    output = (done.out + done.err).rstrip("\n")
    if done.ok:
        if output:
            ctx.ui.text(output)
        return Result(True, "ok")
    lines, _ = remedy_lines(output, text)
    if lines:
        for line in lines:
            ctx.ui.text(f"! {line}")
        ctx.ui.text("\n".join(line for line in output.splitlines() if not re.match(r"^\s*Hint: ", line)))
    else:
        ctx.ui.text(output)
    return Result(True, "failed", exit_code=done.code or 1)
