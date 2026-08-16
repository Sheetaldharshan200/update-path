#!/usr/bin/env bash
# Guard `exakit mcp-status`: it answers "is my client set up?", per client.
#
# The screen used to reuse the generic MCP operation summary, which answers a
# different question. With no client named the selection is every client the kit
# SUPPORTS, so all eight printed whether one was configured or eight, and the
# per-client records were reduced to "Tracked 4 managed artifact(s)". A reader
# asking about their own Claude got the kit's capabilities and a count.
#
# The trap for a future change is that the data was always there - _status
# returns the artifacts - so a regression looks like a rendering tidy-up and
# reads as harmless. These checks are on the OUTPUT for that reason.
#
#   bash tests/mcp-status-clients.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fails=0
checks=0

pass() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export EXAKIT_HOME="$WORK/kh"; mkdir -p "$EXAKIT_HOME"

. "$ROOT/setup/lib/common.sh" 2>/dev/null || {
    printf 'FAIL could not source common.sh\n'; exit 1
}

# A status result shaped like the real one: two configured clients, one present
# but unconfigured, one absent. Written by hand so this suite needs no MCP
# runtime, no client on the machine, and no network.
cat > "$WORK/status.json" <<'JSON'
{
  "operation": "status",
  "status": "success",
  "summary": "Tracked 2 managed artifact(s).",
  "backup_reference": "72c3ba74-eccf-407c-8770-35f692bc801d",
  "selected_clients": ["claude_desktop", "claude_code", "cursor", "codex"],
  "details": {
    "clients": [
      {"client": "claude_desktop", "state": "configured", "path": "/home/u/Library/Application Support/Claude/claude_desktop_config.json"},
      {"client": "claude_code", "state": "configured", "path": "/home/u/.claude.json"},
      {"client": "cursor", "state": "not_set_up", "path": null},
      {"client": "codex", "state": "not_installed", "path": null}
    ]
  }
}
JSON

out="$(exakit_print_mcp_operation_summary "$WORK/status.json" 2>&1)"

# 1. Every client gets its own row, named the way a human knows it.
for pair in "Claude|claude_desktop" "Claude Code (CLI)|claude_code" "Cursor|cursor" "Codex|codex"; do
    label="${pair%%|*}"
    case "$out" in
        *"$label"*) pass "$label has a row" ;;
        *)          fail "$label has no row - status is not per client" ;;
    esac
done

# 2. The three states are distinguishable. "not set up" and "not installed" are
#    the pair that matters: only the first has an action the reader can take.
for want in "configured" "not set up" "not installed"; do
    case "$out" in
        *"$want"*) pass "the state \"$want\" is reported" ;;
        *)         fail "the state \"$want\" never appears" ;;
    esac
done
case "$out" in
    *"run: exakit mcp-setup"*) pass "an unconfigured but present client is told what to run" ;;
    *) fail "a client that is present but not set up offers no next step" ;;
esac

# 3. The config path is shown for a configured client: "is it set up?" is only
#    half answered without WHERE, which is the file to look at when it is wrong.
case "$out" in
    *".claude.json"*) pass "a configured client shows its config file" ;;
    *) fail "a configured client does not show its config path" ;;
esac

# 4. The old summary's two misleading lines are gone from THIS screen.
case "$out" in
    *"Tracked 2 managed artifact"*) fail "still reports a bare artifact count instead of clients" ;;
    *) pass "no bare artifact count" ;;
esac
case "$out" in
    *"Snapshot:"*) fail "a read-only status screen still prints a backup id" ;;
    *) pass "no snapshot id on a read-only screen" ;;
esac

# 5. Rows fit a terminal. A real path is long enough on its own to push the row
#    past 80, and a wrapped row loses the alignment the table exists for.
widest="$(printf '%s\n' "$out" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')"
if [ "$widest" -le 80 ]; then
    pass "every row fits 80 columns (widest $widest)"
else
    fail "a row is $widest columns wide - the table wraps and loses its alignment"
fi

# 6. Every OTHER operation keeps the operation summary: this is a status-only
#    change, and a repair or uninstall still needs its status, summary and the
#    snapshot it can be rolled back from.
sed 's/"operation": "status"/"operation": "repair"/' "$WORK/status.json" > "$WORK/repair.json"
rep="$(exakit_print_mcp_operation_summary "$WORK/repair.json" 2>&1)"
case "$rep" in
    *"MCP operation summary"*) pass "a non-status operation keeps the operation summary" ;;
    *) fail "the operation summary is gone for operations that still need it" ;;
esac
case "$rep" in
    *"Snapshot:"*) pass "and keeps the snapshot it can be rolled back from" ;;
    *) fail "a repair no longer reports its snapshot" ;;
esac

# 7. A result with no per-client detail must fall back, not print an empty table
#    (an older kit's result, or a runtime that could not detect anything).
printf '{"operation":"status","status":"success","summary":"Tracked 0 managed artifact(s)."}\n' > "$WORK/bare.json"
bare="$(exakit_print_mcp_operation_summary "$WORK/bare.json" 2>&1)"
case "$bare" in
    *"MCP operation summary"*) pass "a result without client detail falls back to the summary" ;;
    *) fail "a result without client detail prints neither a table nor a summary" ;;
esac

# 8. The PowerShell twin decides the same way; it cannot be executed here.
PS="$ROOT/setup/lib/mcp.ps1"
if grep -q 'operation -eq "status"' "$PS" && grep -q "MCP clients" "$PS"; then
    pass "the PowerShell twin renders a client table for status"
else
    fail "the PowerShell twin has no status client table - Windows keeps the old screen"
fi
if grep -q 'not_set_up' "$PS" && grep -q 'not_installed' "$PS"; then
    pass "the PowerShell twin knows both not-configured states"
else
    fail "the PowerShell twin does not distinguish not set up from not installed"
fi

printf '\n%d checks, %d failed\n' "$checks" "$fails"
[ "$fails" -eq 0 ]
