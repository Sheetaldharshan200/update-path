#!/usr/bin/env bash
# help.sh - the kit's help system, rendered from data rather than hardcoded text.
#
# WHY THIS EXISTS
#
# Help used to live in three different places: a heredoc in `usage()`, the
# comment block at the top of `setup/exakit`, and catalog.tsv. Three sources
# drift, and none of them could describe a COMPONENT - only a command. This
# module replaces all three with one document per component (setup/help/*.json)
# plus one for the CLI itself, so `exakit --help`, `exakit help --all`,
# `exakit <component> --help` and `exakit catalog` all read the same data.
#
# WHERE THE DATA COMES FROM, IN ORDER
#   1. the cached copy fetched from the kit repository, while it is fresh
#   2. the copy that shipped with this kit (setup/help/)
#
# The fetch mirrors the versions.json policy exactly: https only, short
# timeouts, validated before it is trusted, written atomically, and NEVER
# fatal - a machine with no network renders the copy on disk and says nothing.
# That is what makes the text correctable without shipping a kit update while
# staying safe offline.

EXAKIT_HELP_REPO="${EXAKIT_HELP_REPO:-$EXAKIT_KIT_REPO}"
EXAKIT_HELP_URL="${EXAKIT_HELP_URL:-https://raw.githubusercontent.com/${EXAKIT_HELP_REPO}/main/setup/help}"
EXAKIT_HELP_TTL="${EXAKIT_HELP_TTL:-86400}"
EXAKIT_HELP_CACHE_DIR="${EXAKIT_HELP_CACHE_DIR:-$EXAKIT_CACHE_DIR/help}"
EXAKIT_HELP_OFFLINE="${EXAKIT_HELP_OFFLINE:-0}"

# exakit_help_kit_dir - the documents that shipped with this kit copy.
exakit_help_kit_dir() {
    if [ -d "${_lib_dir:-}/../help" ]; then
        (cd "$_lib_dir/../help" && pwd)
    else
        printf '%s\n' "${EXAKIT_HOME:-$HOME/.exasol-starter-kit}/kit/setup/help"
    fi
}

# exakit_help_ids - every document id this kit knows about, one per line.
# Read from the shipped directory: the cache only ever holds ids that exist
# here, so a stale cache can never invent a component.
exakit_help_ids() {
    _hi_dir="$(exakit_help_kit_dir)"
    [ -d "$_hi_dir" ] || return 1
    for _hi_f in "$_hi_dir"/*.json; do
        [ -f "$_hi_f" ] || continue
        _hi_b="${_hi_f##*/}"
        printf '%s\n' "${_hi_b%.json}"
    done
}

exakit_help_is_id() {
    exakit_help_ids 2>/dev/null | grep -qx "$1"
}

# _exakit_help_valid <file> - a document is trusted only if it parses and
# carries the id and schema_version it claims to. An unreadable or truncated
# download must never replace a good copy.
_exakit_help_valid() {
    [ -s "$1" ] || return 1
    exakit_can_run_python || return 1
    run_python - "$1" "$2" <<'EXAKIT_HELP_VALID_PY' >/dev/null 2>&1
import json, sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(doc, dict)
assert doc.get("id") == sys.argv[2]
assert int(doc.get("schema_version", 0)) >= 1
EXAKIT_HELP_VALID_PY
}

_exakit_help_cache_fresh() {
    [ -f "$1" ] || return 1
    case "$EXAKIT_HELP_TTL" in
        ''|*[!0-9]*) return 1 ;;
        0) return 1 ;;
    esac
    _hcf_mtime="$(_exakit_file_mtime "$1")"
    case "$_hcf_mtime" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(( $(date +%s) - _hcf_mtime ))" -lt "$EXAKIT_HELP_TTL" ]
}

# exakit_help_fetch <id> - refresh one cached document. Silent and never fatal.
#
# The attempt marker is what keeps help INSTANT. Without it a repository that
# has not published these documents yet (or any offline machine) pays a curl
# timeout on every single run, because a failure leaves nothing behind to
# remember it by. The marker is touched before the request, so one attempt per
# id per TTL is made whatever the outcome - success, 404 or no network.
exakit_help_fetch() {
    _hf_id="$1"
    [ "$EXAKIT_HELP_OFFLINE" = "1" ] && return 1
    case "$EXAKIT_HELP_URL" in
        https://*) ;;
        *) _exakit_log_file "WARN  refusing to fetch help over a non-HTTPS URL"; return 1 ;;
    esac
    _hf_cache="$EXAKIT_HELP_CACHE_DIR/$_hf_id.json"
    _hf_attempt="$EXAKIT_HELP_CACHE_DIR/.attempt-$_hf_id"
    _exakit_help_cache_fresh "$_hf_cache" && return 2
    _exakit_help_cache_fresh "$_hf_attempt" && return 2
    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$EXAKIT_HELP_CACHE_DIR" 2>/dev/null || return 1
    : > "$_hf_attempt" 2>/dev/null || true
    _hf_tmp="$_hf_cache.tmp.$$"
    if ! curl -fsSL --proto '=https' --retry 1 \
            --connect-timeout "${EXAKIT_HELP_CONNECT_TIMEOUT:-2}" \
            --max-time "${EXAKIT_HELP_MAX_TIME:-5}" \
            -o "$_hf_tmp" "$EXAKIT_HELP_URL/$_hf_id.json" 2>/dev/null; then
        rm -f "$_hf_tmp"
        _exakit_log_file "INFO  help fetch failed for $_hf_id - using the copy on disk"
        return 1
    fi
    if ! _exakit_help_valid "$_hf_tmp" "$_hf_id"; then
        rm -f "$_hf_tmp"
        _exakit_log_file "WARN  fetched help for $_hf_id did not validate - using the copy on disk"
        return 1
    fi
    mv -f "$_hf_tmp" "$_hf_cache" 2>/dev/null || { rm -f "$_hf_tmp"; return 1; }
    _exakit_log_file "INFO  help refreshed for $_hf_id"
    return 0
}

# exakit_help_doc_local <id> - the best document already on disk. No network.
exakit_help_doc_local() {
    _hdl_cache="$EXAKIT_HELP_CACHE_DIR/$1.json"
    if [ -f "$_hdl_cache" ] && _exakit_help_valid "$_hdl_cache" "$1"; then
        printf '%s\n' "$_hdl_cache"
        return 0
    fi
    _hdl_ship="$(exakit_help_kit_dir)/$1.json"
    [ -f "$_hdl_ship" ] || return 1
    printf '%s\n' "$_hdl_ship"
}

# exakit_help_doc <id> - print the path of the best document available,
# refreshing this one from the repository first.
exakit_help_doc() {
    _hd_id="$1"
    _hd_cache="$EXAKIT_HELP_CACHE_DIR/$_hd_id.json"
    _hd_ship="$(exakit_help_kit_dir)/$_hd_id.json"
    exakit_help_fetch "$_hd_id" >/dev/null 2>&1 || true
    if [ -f "$_hd_cache" ] && _exakit_help_valid "$_hd_cache" "$_hd_id"; then
        printf '%s\n' "$_hd_cache"
        return 0
    fi
    [ -f "$_hd_ship" ] || return 1
    printf '%s\n' "$_hd_ship"
}

# _exakit_help_docs_args <primary> - "id=path" for every document.
#
# Only <primary> - the document this screen is actually ABOUT - is refreshed
# from the repository. Every other document is read from disk, because the
# overview and the catalog only skim them for a tagline or a summary, and nine
# network round trips to render one screen is not a help system anyone waits for.
_exakit_help_docs_args() {
    _hda_primary="${1:-exakit}"
    exakit_help_ids 2>/dev/null | while IFS= read -r _hda_id; do
        [ -n "$_hda_id" ] || continue
        if [ "$_hda_id" = "$_hda_primary" ]; then
            _hda_path="$(exakit_help_doc "$_hda_id" 2>/dev/null)" || continue
        else
            _hda_path="$(exakit_help_doc_local "$_hda_id" 2>/dev/null)" || continue
        fi
        printf '%s=%s\n' "$_hda_id" "$_hda_path"
    done
}

# exakit_help_render <mode> [arg] - every screen this module draws.
exakit_help_render() {
    _hr_mode="$1"
    _hr_arg="${2:-}"
    exakit_can_run_python || {
        # No python: fall back to the shipped exakit document, read as text, so
        # help still says something useful instead of dying.
        _hr_ship="$(exakit_help_kit_dir)/exakit.json"
        [ -f "$_hr_ship" ] && printf 'exakit - help data at %s (python3 is needed to render it)\n' "$_hr_ship"
        return 1
    }
    if [ -t 1 ] && [ "${EXAKIT_HELP_PLAIN:-0}" != "1" ]; then _hr_color=1; else _hr_color=0; fi
    _hr_width="${COLUMNS:-0}"
    case "$_hr_width" in ''|*[!0-9]*) _hr_width=0 ;; esac
    if [ "$_hr_width" -lt 40 ] && command -v tput >/dev/null 2>&1; then
        _hr_width="$(tput cols 2>/dev/null || echo 0)"
        case "$_hr_width" in ''|*[!0-9]*) _hr_width=0 ;; esac
    fi
    [ "$_hr_width" -lt 40 ] && _hr_width=80

    # The screen's subject decides what gets refreshed: a component page asks
    # for that component, everything else is about the CLI itself.
    if [ "$_hr_mode" = "component" ] && [ -n "$_hr_arg" ]; then
        _hr_primary="$_hr_arg"
    else
        _hr_primary="exakit"
    fi

    # shellcheck disable=SC2046
    run_python - "$_hr_mode" "$_hr_color" "$_hr_width" "$_hr_arg" \
        $(_exakit_help_docs_args "$_hr_primary" | tr '\n' ' ') <<'EXAKIT_HELP_RENDER_PY'
import json, sys, textwrap

mode, color, width, arg = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3]), sys.argv[4]
docs = {}
for pair in sys.argv[5:]:
    if "=" not in pair:
        continue
    key, path = pair.split("=", 1)
    try:
        docs[key] = json.load(open(path, encoding="utf-8"))
    except Exception:
        pass

WRAP = min(width, 100)

if color:
    CY, CYB, DIM, B, GN, YL, R = ("\033[36m", "\033[1;36m", "\033[2m",
                                  "\033[1m", "\033[1;32m", "\033[33m", "\033[0m")
else:
    CY = CYB = DIM = B = GN = YL = R = ""

def out(text=""):
    sys.stdout.write(text + "\n")

def para(text, indent="  ", first=None):
    for line in textwrap.wrap(text, width=WRAP - len(indent)) or [""]:
        out((first if first is not None else indent) + line)
        first = None

def rule():
    out("  %s%s%s" % (CY, "-" * (min(WRAP, 72) - 2), R))

def header(title, subtitle=""):
    out()
    rule()
    out("   %s%s%s%s" % (CYB, title, R, ("  %s%s%s" % (DIM, subtitle, R)) if subtitle else ""))
    rule()

def section(title):
    out()
    out("  %s%s%s" % (B, title, R))
    out()

def kv(key, value, pad=16):
    para(value, indent=" " * (4 + pad), first="    %s%-*s%s" % (GN, pad, key, R))

def cmd_line(prefix, command, options, summary, pad=22, indent="    "):
    label = ("%s %s" % (prefix, command)).strip() if prefix else command
    if options:
        label = "%s %s" % (label, options)
    if len(label) <= pad and summary:
        para(summary, indent=" " * (len(indent) + pad + 1),
             first="%s%s%-*s%s " % (indent, GN, pad, label, R))
    else:
        out("%s%s%s%s" % (indent, GN, label, R))
        if summary:
            para(summary, indent=indent + "  ")

def commands_of(doc):
    return doc.get("commands", []) or []

# Every binary the kit documents. A command whose first word is one of these is
# already spelled out ("exakit start" on the runtime page); anything else is a
# bare subcommand and gets its document's prefix put in front.
KNOWN_TOOLS = ("exakit", "exapump", "exasol", "dash-server",
               "exasol-json-tables", "exasol-mcp-server", "exasol-mcp-server-http")

def invocation(doc_id, entry):
    """The command as a reader would actually type it."""
    command = (entry.get("command") or "").strip()
    parts = command.split()
    if parts and parts[0] in KNOWN_TOOLS:
        return command
    prefix = (docs.get(doc_id) or {}).get("invocation_prefix") or doc_id
    return ("%s %s" % (prefix, command)).strip()

def invocation_with_options(doc_id, entry):
    label = invocation(doc_id, entry)
    options = entry.get("options") or ""
    if options:
        label = "%s %s" % (label, options)
    return label

def find_command(doc, name):
    name = name.strip().lower()
    exact, prefix = [], []
    for entry in commands_of(doc):
        key = entry.get("command", "").lower()
        if key == name:
            exact.append(entry)
        elif key.startswith(name + " ") or name.startswith(key + " "):
            prefix.append(entry)
    return exact or prefix

def render_command_detail(doc, entry, prefix=""):
    label = ("%s %s" % (prefix, entry.get("command", ""))).strip()
    opts = entry.get("options", "")
    out()
    out("  %s%s%s%s" % (B, label, (" " + opts) if opts else "", R))
    out()
    para(entry.get("description") or entry.get("summary", ""), indent="    ")
    if entry.get("warning"):
        out()
        para(entry["warning"], indent="    ", first="    %s!%s " % (YL, R) + "")
    if entry.get("exit_codes"):
        out()
        out("    %sExit codes%s" % (DIM, R))
        for code in sorted(entry["exit_codes"], key=lambda c: int(c)):
            out("      %s%s%s  %s" % (GN, code, R, entry["exit_codes"][code]))
    if entry.get("environment"):
        out()
        out("    %sEnvironment%s" % (DIM, R))
        for line in entry["environment"]:
            para(line, indent="        ", first="      " + "")
    if entry.get("examples"):
        out()
        out("    %sExamples%s" % (DIM, R))
        for example in entry["examples"]:
            out("      %s%s%s" % (CY, example, R))
    out()

# ---------------------------------------------------------------- overview --
def render_overview():
    doc = docs.get("exakit")
    if not doc:
        out("No help data found. Reinstall the kit or run: exakit update exakit")
        return 1
    header(doc.get("title", "exakit"), doc.get("tagline", ""))
    out()
    para(doc.get("role", ""), indent="   ")

    if doc.get("quickstart"):
        section("Start here")
        for number, step in enumerate(doc["quickstart"], 1):
            out("    %s%s.%s %s" % (B, number, R, step.get("step", "")))
            if step.get("run"):
                out("       %s%s%s" % (CY, step["run"], R))
            if step.get("note"):
                para(step["note"], indent="       %s" % DIM)
                if color:
                    sys.stdout.write(R)
        out()

    by_name = {c.get("command"): c for c in commands_of(doc)}
    for group in doc.get("groups", []):
        section(group.get("title", ""))
        for name in group.get("commands", []):
            entry = by_name.get(name)
            if not entry:
                continue
            cmd_line("", invocation("exakit", entry), "", entry.get("summary", ""), pad=24)

    others = [key for key in sorted(docs) if key != "exakit"]
    if others:
        # Each component names its own commands as a reader would type them.
        # A bare list of component names told nobody what they could actually
        # run; "exakit <component> --help" is the deeper page, not the summary.
        section("Components")
        for key in others:
            sub = docs[key]
            out("    %s%s%s  %s%s%s" % (B, key, R, DIM, sub.get("tagline", ""), R))
            for entry in commands_of(sub):
                cmd_line("", invocation_with_options(key, entry), "",
                         entry.get("summary") or entry.get("description", ""),
                         pad=34, indent="      ")
            out()

    out()
    para("Every command also answers --help. Browse everything with: exakit catalog",
         indent="  %s" % DIM)
    if color:
        sys.stdout.write(R)
    out()
    return 0

# --------------------------------------------------------------------- all --
def render_all():
    doc = docs.get("exakit")
    if not doc:
        return 1
    header("exakit - every command", doc.get("tagline", ""))
    by_name = {c.get("command"): c for c in commands_of(doc)}
    seen = set()
    for group in doc.get("groups", []):
        section(group.get("title", ""))
        for name in group.get("commands", []):
            entry = by_name.get(name)
            if not entry or name in seen:
                continue
            seen.add(name)
            cmd_line("", invocation_with_options("exakit", entry), "",
                     entry.get("summary", ""), pad=30)
    rest = [c for c in commands_of(doc) if c.get("command") not in seen]
    if rest:
        section("Other")
        for entry in rest:
            cmd_line("", invocation_with_options("exakit", entry), "",
                     entry.get("summary", ""), pad=30)
    out()
    para("Detail for one command: exakit <command> --help", indent="  %s" % DIM)
    if color:
        sys.stdout.write(R)
    out()
    return 0

# --------------------------------------------------------------- component --
def render_component(key):
    doc = docs.get(key)
    if not doc:
        out("  No help document for '%s'." % key)
        out("  Known: %s" % ", ".join(sorted(docs)))
        return 1
    header(doc.get("title", key), doc.get("tagline", ""))
    out()
    para(doc.get("role", ""), indent="   ")

    facts = [("Repository", doc.get("repo")), ("Package", doc.get("package")),
             ("Binary", doc.get("binary")), ("Runs via", doc.get("runs_via")),
             ("Image", doc.get("image")), ("Config", doc.get("config")),
             ("Profile", doc.get("profile")), ("Venv", doc.get("venv")),
             ("Python", doc.get("python")), ("URL", doc.get("url")),
             ("Control plane", doc.get("control_plane")),
             ("DSN", doc.get("dsn")), ("Admin user", doc.get("admin_user")),
             ("DB user", doc.get("db_user")),
             ("Deployment", doc.get("deployment_dir")),
             ("Platforms", doc.get("platforms")), ("Requires", doc.get("requires")),
             ("Installed by", doc.get("installed_by")), ("Docs", doc.get("docs"))]
    facts = [(k, v) for k, v in facts if v]
    if facts:
        section("At a glance")
        for key_name, value in facts:
            kv(key_name, value)

    if doc.get("warning"):
        section("Important")
        para(doc["warning"], indent="    ", first="    %s!%s " % (YL, R))

    if doc.get("boundary"):
        section("The read-only boundary")
        para(doc["boundary"], indent="    ")

    if doc.get("clients"):
        section("Supported clients")
        para(", ".join(doc["clients"]), indent="    ")

    if doc.get("quickstart"):
        section("How to start")
        for number, step in enumerate(doc["quickstart"], 1):
            out("    %s%s.%s %s" % (B, number, R, step.get("step", "")))
            if step.get("run"):
                out("       %s%s%s" % (CY, step["run"], R))
            if step.get("note"):
                para(step["note"], indent="       ")

    if commands_of(doc):
        section("Commands")
        for entry in commands_of(doc):
            cmd_line("", invocation_with_options(key, entry), "",
                     entry.get("summary") or entry.get("description", ""), pad=34)

    if doc.get("snippets"):
        section("Example")
        for snippet in doc["snippets"]:
            out("    %s%s%s" % (DIM, snippet.get("title", ""), R))
            for line in snippet.get("code", "").split("\n"):
                out("      %s%s%s" % (CY, line, R))

    if doc.get("environment"):
        section("Environment")
        for item in doc["environment"]:
            kv(item.get("name", ""), item.get("effect", ""), pad=26)

    if doc.get("notes"):
        section("Good to know")
        for note in doc["notes"]:
            para(note, indent="      ", first="    %s-%s " % (DIM, R))

    if doc.get("troubleshooting"):
        section("If something goes wrong")
        for item in doc["troubleshooting"]:
            out("    %s%s%s" % (B, item.get("symptom", ""), R))
            para(item.get("remedy", ""), indent="      ")

    if doc.get("see_also"):
        section("See also")
        para(", ".join(doc["see_also"]), indent="    ")
    out()
    return 0

# ----------------------------------------------------------------- command --
def render_command(name):
    doc = docs.get("exakit")
    matches = find_command(doc, name) if doc else []
    if matches:
        for entry in matches:
            render_command_detail(doc, entry, prefix="exakit")
        return 0
    for key in sorted(docs):
        if key == "exakit":
            continue
        found = find_command(docs[key], name)
        if found:
            for entry in found:
                render_command_detail(docs[key], entry)
            out("  %sFull reference: exakit %s --help%s" % (DIM, key, R))
            out()
            return 0
    if name in docs:
        return render_component(name)
    out()
    out("  No help entry for '%s'." % name)
    out("  Try: exakit catalog %s   or   exakit help --all" % name)
    out()
    return 1

# ----------------------------------------------------------------- catalog --
def catalog_rows():
    rows = []
    for key in sorted(docs):
        doc = docs[key]
        tool = "exakit" if key == "exakit" else key
        for entry in commands_of(doc):
            command = entry.get("command", "")
            # A component document may list a command that belongs to another
            # tool (exakit start on a runtime page); keep the tool it names.
            parts = command.split()
            if parts and parts[0] in ("exakit", "exapump", "exasol") and key != parts[0]:
                rows.append({"tool": parts[0], "command": " ".join(parts[1:]),
                             "options": entry.get("options", ""),
                             "description": entry.get("summary") or entry.get("description", ""),
                             "source": key})
            else:
                rows.append({"tool": tool, "command": command,
                             "options": entry.get("options", ""),
                             "description": entry.get("summary") or entry.get("description", ""),
                             "source": key})
    seen, unique = set(), []
    for row in rows:
        key = (row["tool"], row["command"], row["options"])
        if key in seen:
            continue
        seen.add(key)
        unique.append(row)
    return unique

def render_catalog(search):
    rows = catalog_rows()
    if search:
        needle = search.lower()
        rows = [r for r in rows if needle in
                (" ".join([r["tool"], r["command"], r["options"], r["description"]])).lower()]
    header("command catalog", ("results for \"%s\"" % search) if search else
                              "exakit - exapump - exasol - components")
    if not rows:
        out()
        out("  %sNo commands match \"%s\".%s  Try: exakit catalog mcp" % (DIM, search, R))
        out()
        return 1
    current = None
    for row in rows:
        if row["tool"] != current:
            current = row["tool"]
            section(current)
        cmd_line("", row["command"], row["options"], row["description"], pad=26)
    out()
    para("Tip: exakit catalog <search>, or exakit <component> --help for the full page.",
         indent="  %s" % DIM)
    if color:
        sys.stdout.write(R)
    out()
    return 0

def render_json(which):
    # Shape kept compatible with the original `exakit catalog --json`: one
    # object carrying a "commands" array of tool/command/options/description.
    rows = catalog_rows()
    for row in rows:
        row["invocation"] = ("%s %s" % (row["tool"], row["command"])).strip()
    if which in ("", "all"):
        payload = {"schema_version": 1, "search": None, "count": len(rows),
                   "commands": rows, "documents": docs}
    elif which in docs:
        payload = docs[which]
    else:
        needle = which.lower()
        hit = [r for r in rows if needle in
               (" ".join([r["tool"], r["command"], r["options"], r["description"]])).lower()]
        payload = {"schema_version": 1, "search": which, "count": len(hit),
                   "commands": hit}
    print(json.dumps(payload, indent=2))
    return 0

if mode == "overview":
    sys.exit(render_overview())
elif mode == "all":
    sys.exit(render_all())
elif mode == "component":
    sys.exit(render_component(arg))
elif mode == "command":
    sys.exit(render_command(arg))
elif mode == "catalog":
    sys.exit(render_catalog(arg))
elif mode == "json":
    sys.exit(render_json(arg))
else:
    sys.exit(render_overview())
EXAKIT_HELP_RENDER_PY
}
