#!/usr/bin/env bash
# agent-operability.sh — proves the machine-facing contract an unattended agent
# branches on: status exit codes and --json, the mcp-doctor stopped-database
# short-circuit, the read-only allowlist merge, the DB error translator, the
# dataset visibility in status, and dataset COMMENT coverage.
#
#   bash tests/agent-operability.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok   %s = %s\n' "$1" "$3"; else FAIL=$((FAIL+1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"; fi; }
has() { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "status exit codes are the answer:"
check "not installed exits 4" "4" "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" status >/dev/null 2>&1; echo $?)"
has "and the JSON form says so" '"installed": false' "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
check "not installed --json exits 4 too" "4" "$(EXAKIT_HOME="$WORK/none" bash "$ROOT/setup/exakit" status --json >/dev/null 2>&1; echo $?)"

# A manifest whose nano container does not exist reads as a stopped database.
mkdir -p "$WORK/stopped"
printf '{\n  "runtime": {\n    "type": "nano"\n  },\n  "data": {\n    "datasets": {\n      "tpch": {\n        "loaded": true\n      }\n    }\n  }\n}\n' > "$WORK/stopped/manifest.json"
check "stopped database exits 3" "3" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status >/dev/null 2>&1; echo $?)"
_sj="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status --json 2>/dev/null)"
check "the JSON is valid JSON" "yes" "$(printf '%s' "$_sj" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
has "and carries running=false" '"running": false' "$_sj"
has "and the loaded datasets" '"tpch"' "$_sj"
has "prose names the datasets too" "tpch" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status 2>/dev/null | grep '^Datasets:')"
has "prose names the fix" "exakit start" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status 2>/dev/null | tail -1)"
check "an unknown status flag is refused nonzero" "1" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" status --nope >/dev/null 2>&1; echo $?)"

echo "mcp-doctor diagnoses the stopped database first:"
_doc="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" mcp-doctor 2>&1)"
check "exit 3, same as status" "3" "$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" mcp-doctor >/dev/null 2>&1; echo $?)"
has "and names the remedy" "exakit start" "$_doc"
_docj="$(EXAKIT_HOME="$WORK/stopped" bash "$ROOT/setup/exakit" mcp-doctor --json 2>/dev/null)"
check "the JSON form is valid" "yes" "$(printf '%s' "$_docj" | python3 -m json.tool >/dev/null 2>&1 && echo yes || echo no)"
has "and carries the remedy" '"remedy": "exakit start"' "$_docj"

echo "every subcommand answers --help from the catalog:"
for _cmd in status data-load logs uninstall marketplace; do
    _h="$(bash "$ROOT/setup/exakit" "$_cmd" --help 2>&1; echo "rc=$?")"
    has "$_cmd --help shows its entry" "exakit $_cmd" "$_h"
    has "and exits 0" "rc=0" "$_h"
done

echo "the read-only allowlist merge:"
. "$ROOT/setup/lib/common.sh" >/dev/null 2>&1
_alh="$WORK/allow-home"
mkdir -p "$_alh"
check "fresh file gets the full list" "ADDED 7" "$(HOME="$_alh" exakit_apply_readonly_allowlist)"
check "second run adds nothing" "ADDED 0" "$(HOME="$_alh" exakit_apply_readonly_allowlist)"
printf '{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]}}' > "$_alh/.claude/settings.json"
HOME="$_alh" exakit_apply_readonly_allowlist >/dev/null
check "existing settings survive the merge" "opus ls-kept status-added deny-set" "$(python3 -c "
import json; d=json.load(open('$_alh/.claude/settings.json'))
print(d['model'],
      'ls-kept' if 'Bash(ls:*)' in d['permissions']['allow'] else 'ls-LOST',
      'status-added' if 'Bash(exakit status:*)' in d['permissions']['allow'] else 'status-MISSING',
      'deny-set' if 'Bash(exakit uninstall:*)' in d['permissions']['deny'] else 'deny-MISSING')")"
printf 'not json' > "$_alh/.claude/settings.json"
check "a malformed file is left alone" "SKIP unreadable|not json" \
    "$(HOME="$_alh" exakit_apply_readonly_allowlist)|$(cat "$_alh/.claude/settings.json")"

echo "the database error translator:"
has "connection refused names exakit start" "exakit start" \
    "$(exakit_explain_db_error "[Errno 61] Connection refused" 2>&1)"
has "FETCH FIRST names LIMIT" "LIMIT" \
    "$(exakit_explain_db_error "syntax error, unexpected FETCH_, expecting UNION_" 2>&1)"
has "object not found names describe" "describe" \
    "$(exakit_explain_db_error "object O_TOTALAMOUNT not found [line 1]" 2>&1)"
check "an unknown error adds nothing" "0" \
    "$(exakit_explain_db_error "some other failure" 2>&1 | wc -l | tr -d ' ')"

echo "dataset semantics ship as COMMENTs:"
for _ds in tpch energy weather; do
    check "$_ds schema carries table comments" "yes" \
        "$(grep -q 'COMMENT ON TABLE' "$ROOT/data/datasets/$_ds/01_create_schema.sql" && echo yes || echo no)"
done
# Every declared column in every dataset has a COMMENT ON COLUMN — a new
# column without one fails here, so the describe path never goes dark again.
check "every column of every dataset is commented" "all-covered" "$(python3 - "$ROOT" <<'PYEOF'
import re, sys
root = sys.argv[1]
missing = []
for ds in ("tpch", "energy", "weather"):
    s = open("%s/data/datasets/%s/01_create_schema.sql" % (root, ds)).read()
    commented = set(m.upper() for m in re.findall(r"COMMENT ON COLUMN (\w+)\.(\w+)", s) for m in [m[0] + "." + m[1]])
    for tbl, body in re.findall(r"TABLE (\w+) \((.*?)\n\)", s, re.S):
        for line in body.splitlines():
            line = line.strip()
            if not line or line.startswith("--") or line.upper().startswith("CONSTRAINT"):
                continue
            col = line.split()[0].upper().strip(",")
            if col and ("%s.%s" % (tbl.upper(), col)) not in commented:
                missing.append("%s:%s.%s" % (ds, tbl, col))
print("all-covered" if not missing else " ".join(missing[:5]))
PYEOF
)"

echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
