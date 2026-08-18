#!/usr/bin/env bash
# skills.sh — proves the AI skills layer: every shipped SKILL.md carries the
# frontmatter agents match on, the registry is derived from the filesystem
# (so adding a skill stays a one-folder change), the install/list/state
# contract, and the promise that uninstall removes only what the kit placed.
# Pure logic against a sandboxed kit home: no network, no installs.
#
#   bash tests/skills.sh

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

check() { # check <label> <expected> <actual>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  ok   %s = %s\n' "$1" "$3"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

has() { # has <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "present" "present" ;; *) check "$1" "present" "MISSING" ;; esac
}

lacks() { # lacks <label> <needle> <haystack>
    case "$3" in *"$2"*) check "$1" "absent" "PRESENT" ;; *) check "$1" "absent" "absent" ;; esac
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The kit home is redirected for the whole run: nothing here may touch a real
# installation, and the discovery roots are redirected for the same reason —
# a test must never write into the developer's own ~/.claude/skills.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
EXAKIT_SKILL_ROOTS="$WORK/claude $WORK/agents"
export EXAKIT_HOME EXAKIT_BIN_DIR EXAKIT_MANIFEST EXAKIT_SKILL_ROOTS
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/ui.sh"
# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"

# ---------------------------------------------------------------------------
echo
echo "every shipped skill is loadable by an agent:"
# ---------------------------------------------------------------------------
# A skill an agent cannot identify is dead weight: the name is the directory
# contract, and the description is the ONLY thing an agent sees before it
# decides to load the body. Both are asserted for every skill that ships.
SKILL_COUNT=0
for _dir in "$ROOT"/skills/*/; do
    [ -f "$_dir/SKILL.md" ] || continue
    _id="$(basename "$_dir")"
    SKILL_COUNT=$((SKILL_COUNT + 1))
    _name="$(exakit_skill_field "$_dir/SKILL.md" name)"
    _desc="$(exakit_skill_field "$_dir/SKILL.md" description)"
    check "$_id: name matches its directory" "$_id" "${_name:-MISSING}"
    if [ -n "$_desc" ]; then
        check "$_id: has a description" "yes" "yes"
    else
        check "$_id: has a description" "yes" "MISSING"
    fi
    # The "Triggers —" list is how an agent decides when to fire the skill.
    # skills/README.md promises it is kept accurate; an absent one means the
    # skill can only ever be loaded by being named explicitly.
    has "$_id: description carries Triggers" "Triggers" "$_desc"
    # A summary is what `exakit skills` renders; it must not be empty and must
    # not still carry the trigger list.
    _sum="$(exakit_skill_summary "$_desc")"
    if [ -n "$_sum" ]; then
        check "$_id: summary is non-empty" "yes" "yes"
    else
        check "$_id: summary is non-empty" "yes" "EMPTY"
    fi
    lacks "$_id: summary drops the triggers" "Triggers" "$_sum"
done

# Guards against the whole point of this feature being quietly lost: the kit
# grew skills for each component and add-on, so a build carrying only the
# original starter skill is a packaging regression, not a valid state.
if [ "$SKILL_COUNT" -ge 2 ]; then
    check "the kit ships more than one skill" "yes" "yes"
else
    check "the kit ships more than one skill" "yes" "only $SKILL_COUNT"
fi

# ---------------------------------------------------------------------------
echo
echo "the registry is the filesystem, not a hardcoded list:"
# ---------------------------------------------------------------------------
# This is the property skills/README.md sells: "add a folder under
# skills/<name>/SKILL.md" with no code edit anywhere. A hardcoded skill name in
# the shell layer would silently take that away — exactly how the old
# uninstall fallback came to name a skill that never shipped.
# Skill ids that are ALSO marketplace add-on ids (dash-server, json-tables,
# exasol-vscode) legitimately appear in the shell layer as add-on registry
# entries, so they are exempt: the thing under test is that no skill needs a
# name in the code to work, not that the string never occurs.
_addon_ids="$(exakit_marketplace_addons 2>/dev/null | cut -d'|' -f1)"
for _hardcode in $(ls -1 "$ROOT/skills" 2>/dev/null); do
    [ -f "$ROOT/skills/$_hardcode/SKILL.md" ] || continue
    case " $(printf '%s' "$_addon_ids" | tr '\n' ' ') " in
        *" $_hardcode "*) continue ;;
    esac
    # Match the id as a whole token: "exasol-mcp" is a substring of the MCP
    # package name exasol-mcp-server, which is a legitimate constant.
    _pat="$_hardcode([^-A-Za-z0-9]|$)"
    # grep -c prints 0 AND exits 1 when nothing matches, so swallow the status
    # rather than appending a second count.
    _hits="$(grep -cE -- "$_pat" "$ROOT/setup/lib/common.sh" 2>/dev/null || true)"
    check "common.sh does not hardcode $_hardcode" "0" "${_hits:-0}"
    _hits_ps="$(grep -cE -- "$_pat" "$ROOT/setup/exakit.ps1" 2>/dev/null || true)"
    check "exakit.ps1 does not hardcode $_hardcode" "0" "${_hits_ps:-0}"
done

# A skill invented at run time is picked up with no code change at all.
mkdir -p "$WORK/fakekit/mcp" "$WORK/fakekit/skills/zz-invented-skill"
# The fake kit needs the real versions.json: the install records which skill
# set it came from, and that is read from the kit copy.
cp "$ROOT/versions.json" "$WORK/fakekit/versions.json"
cat > "$WORK/fakekit/skills/zz-invented-skill/SKILL.md" <<'EOF'
---
name: zz-invented-skill
description: A skill that exists only in this test. Triggers — "never".
---
Body.
EOF
# A directory with no SKILL.md must be ignored rather than half-registered.
mkdir -p "$WORK/fakekit/skills/zz-empty-dir"
# ...and one whose frontmatter cannot be read must be skipped consistently,
# so `exakit skills` never lists what skills-install refuses to copy.
mkdir -p "$WORK/fakekit/skills/zz-broken-frontmatter"
printf 'no frontmatter here at all\n' > "$WORK/fakekit/skills/zz-broken-frontmatter/SKILL.md"

exakit_repo_root() { printf '%s\n' "$WORK/fakekit"; }

REG="$(exakit_skills_registry)"
has  "an invented skill registers itself" "zz-invented-skill" "$REG"
lacks "a directory without SKILL.md is ignored" "zz-empty-dir" "$REG"
lacks "unreadable frontmatter is skipped" "zz-broken-frontmatter" "$REG"

# ---------------------------------------------------------------------------
echo
echo "install, state and the JSON contract:"
# ---------------------------------------------------------------------------
printf '{"components": {}}\n' > "$EXAKIT_MANIFEST"

check "before install: state is available" "available" "$(exakit_skill_state zz-invented-skill)"

exakit_install_skills >"$WORK/install.log" 2>&1
INSTALL_RC=$?
check "install succeeds" "0" "$INSTALL_RC"
check "after install: state is installed" "installed" "$(exakit_skill_state zz-invented-skill)"
check "the broken skill was not copied" "available" "$(exakit_skill_state zz-broken-frontmatter)"
has "install refused the broken skill out loud" "zz-broken-frontmatter" "$(cat "$WORK/install.log")"

# Present in one discovery root only — a half-finished install or a hand
# deletion. It needs its own word because the remedy differs from "never
# installed", and `exakit skills` must not call it installed.
rm -rf "$WORK/agents/zz-invented-skill"
check "one root missing: state is partial" "partial" "$(exakit_skill_state zz-invented-skill)"

# What the install recorded is the only honest answer to "which skills are
# ours to remove" once the kit copy is gone.
# Read from versions.json, not hardcoded: the assertion is "the install records
# the shipped skill-set version", and a literal turns every legitimate bump of
# that version into a failure that says nothing about the behaviour.
_skills_version="$(python3 -c "
import json; print(json.load(open('$ROOT/versions.json'))['components']['skills']['version'])")"
has "manifest records the skill set version" "$_skills_version" \
    "$(manifest_get components.skills.version 2>/dev/null || true)"
has "manifest records what was installed" "zz-invented-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"

# The listing is a state query, so it must answer machine-readably with
# nothing else on stdout — the same contract status/info/mcp-doctor keep.
JSON="$(exakit_skills_list --json 2>/dev/null)"
has "--json names the skill" '"name":"zz-invented-skill"' "$JSON"
has "--json carries the state" '"state":' "$JSON"
if printf '%s' "$JSON" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    check "--json is parseable" "yes" "yes"
else
    check "--json is parseable" "yes" "NOT-JSON"
fi

# ---------------------------------------------------------------------------
echo
echo "uninstall removes only what the kit placed:"
# ---------------------------------------------------------------------------
# The discovery folders are shared with every other skill the user has. The
# kit sweeping them wholesale would destroy work it never owned.
mkdir -p "$WORK/claude/somebody-elses-skill"
: > "$WORK/claude/somebody-elses-skill/SKILL.md"
mkdir -p "$WORK/claude/zz-invented-skill" "$WORK/agents/zz-invented-skill"
: > "$WORK/claude/zz-invented-skill/SKILL.md"
: > "$WORK/agents/zz-invented-skill/SKILL.md"

# _exakit_remove_installed_skills reads $HOME, so redirect it for this section
# only and re-point the roots at the same place.
_HOME_SAVED="$HOME"
HOME="$WORK/fakehome"; export HOME
mkdir -p "$HOME/.claude/skills/zz-invented-skill" \
         "$HOME/.agents/skills/zz-invented-skill" \
         "$HOME/.claude/skills/somebody-elses-skill"

_exakit_remove_installed_skills 0 >/dev/null 2>&1
if [ -e "$HOME/.claude/skills/zz-invented-skill" ]; then
    check "a kit skill is removed" "gone" "STILL-THERE"
else
    check "a kit skill is removed" "gone" "gone"
fi
if [ -e "$HOME/.claude/skills/somebody-elses-skill" ]; then
    check "a foreign skill is kept" "kept" "kept"
else
    check "a foreign skill is kept" "kept" "REMOVED"
fi
HOME="$_HOME_SAVED"; export HOME

# ---------------------------------------------------------------------------
echo
echo "the CLI and the docs agree:"
# ---------------------------------------------------------------------------
CATALOG="$(python3 -c "
import json
doc = json.load(open('$ROOT/setup/help/exakit.json'))
print(chr(10).join(c['command'] for c in doc['commands']))")"
has "catalog lists exakit skills"         "skills" "$CATALOG"
has "catalog lists exakit skills-install" "skills-install" "$CATALOG"
has "the bash CLI dispatches skills"      "skills)" "$(cat "$ROOT/setup/exakit")"
has "the PowerShell CLI dispatches skills" '"skills"' "$(cat "$ROOT/setup/exakit.ps1")"

# versions.json carries the skill set, so a stale installed copy is detectable
# after a kit update rather than being invisible.
has "versions.json carries components.skills" '"skills"' "$(cat "$ROOT/versions.json")"
has "the CI component set expects skills" '"skills"' \
    "$(cat "$ROOT/.github/workflows/versions.yml")"

# Twin parity: both shells implement the same registry, or Windows silently
# loses the feature.
PS_COMMON="$(cat "$ROOT/setup/lib/exakit-common.ps1")"
for _fn in Get-ExakitSkillsDir Get-ExakitSkillField Get-ExakitSkillSummary \
           Get-ExakitSkillsRegistry Get-ExakitSkillState Show-ExakitSkills; do
    has "PowerShell twin defines $_fn" "function $_fn" "$PS_COMMON"
done

# Every skill the docs advertise must actually ship.
README="$(cat "$ROOT/skills/README.md")"
for _dir in "$ROOT"/skills/*/; do
    [ -f "$_dir/SKILL.md" ] || continue
    _id="$(basename "$_dir")"
    has "skills/README.md lists $_id" "$_id" "$README"
done

echo
printf 'passed: %d, failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
