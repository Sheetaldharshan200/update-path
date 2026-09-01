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
echo "an add-on's skill ships with its add-on, not before it:"
# ---------------------------------------------------------------------------
# A skill for a marketplace add-on is no use until the add-on is there: its
# whole job is to give an agent triggers for a tool, and matching those triggers
# for a tool that is not installed is worse than not shipping the skill. So the
# AI-bridge step places CORE skills only, and an add-on's skill arrives as part
# of installing the add-on.
#
# Ownership is DECLARED in the skill's frontmatter ("addon: <id>"), not guessed
# from the folder name, so nothing here or in the shell names a skill.
mkdir -p "$WORK/fakekit/skills/zz-owned-skill"
cat > "$WORK/fakekit/skills/zz-owned-skill/SKILL.md" <<'EOF'
---
name: zz-owned-skill
addon: zz-fake-addon
description: A skill owned by a test add-on. Triggers — "never".
EOF
printf -- '---\nBody.\n' >> "$WORK/fakekit/skills/zz-owned-skill/SKILL.md"

check "the owner is read from the frontmatter" "zz-fake-addon" \
    "$(exakit_skill_addon "$WORK/fakekit/skills/zz-owned-skill/SKILL.md")"
check "a core skill declares no owner" "" \
    "$(exakit_skill_addon "$WORK/fakekit/skills/zz-invented-skill/SKILL.md")"
check "the add-on's skills are found by id" "zz-owned-skill" \
    "$(exakit_skills_for_addon zz-fake-addon)"

# Whether the add-on is installed is the only input that moves this.
ZZ_ADDON_INSTALLED=0
exakit_marketplace_addon_installed() {
    [ "$1" = "zz-fake-addon" ] || return 1
    [ "${ZZ_ADDON_INSTALLED:-0}" = "1" ]
}

# 1. The skills step must NOT place it while the add-on is absent.
for _zz_root in "$WORK/claude" "$WORK/agents"; do rm -rf "$_zz_root/zz-owned-skill"; done
exakit_install_skills >"$WORK/install2.log" 2>&1
check "the skills step skips an absent add-on's skill" "available" \
    "$(exakit_skill_state zz-owned-skill)"
check "...and still places the core one" "installed" \
    "$(exakit_skill_state zz-invented-skill)"
lacks "the manifest does not claim it either" "zz-owned-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"

# 2. Installing the add-on places it.
exakit_install_addon_skills zz-fake-addon
check "installing the add-on places its skill" "installed" \
    "$(exakit_skill_state zz-owned-skill)"
has "...and the manifest records it, so uninstall can find it" "zz-owned-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"

# 3. A refresh while the add-on IS installed keeps it, rather than treating the
#    skills step as the only authority and sweeping it away again.
ZZ_ADDON_INSTALLED=1
exakit_install_skills >"$WORK/install3.log" 2>&1
check "a refresh keeps an installed add-on's skill" "installed" \
    "$(exakit_skill_state zz-owned-skill)"

# 4. Removing the add-on takes it back out. A skill left behind advertises
#    triggers for a tool that is no longer on the machine.
exakit_remove_addon_skills zz-fake-addon
check "removing the add-on removes its skill" "available" \
    "$(exakit_skill_state zz-owned-skill)"
lacks "...and the manifest stops claiming it" "zz-owned-skill" \
    "$(manifest_get components.skills.installed 2>/dev/null || true)"
check "the core skill is untouched throughout" "installed" \
    "$(exakit_skill_state zz-invented-skill)"

unset -f exakit_marketplace_addon_installed
ZZ_ADDON_INSTALLED=0

# 5. The SHIPPED add-on skills actually declare an owner, and it is a real
#    add-on id. Without this the machinery above works and nothing uses it.
_zz_addon_ids="$(exakit_marketplace_addons 2>/dev/null | cut -d'|' -f1 | tr '\n' ' ')"
_zz_owned=0
for _zz_skill in $(ls -1 "$ROOT/skills" 2>/dev/null); do
    [ -f "$ROOT/skills/$_zz_skill/SKILL.md" ] || continue
    _zz_owner="$(exakit_skill_field "$ROOT/skills/$_zz_skill/SKILL.md" addon)"
    [ -n "$_zz_owner" ] || continue
    _zz_owned=$((_zz_owned + 1))
    case " $_zz_addon_ids " in
        *" $_zz_owner "*) _zz_ok="a marketplace add-on" ;;
        *) _zz_ok="'$_zz_owner', which is not a marketplace add-on" ;;
    esac
    check "$_zz_skill is owned by" "a marketplace add-on" "$_zz_ok"
done
if [ "$_zz_owned" -gt 0 ]; then _zz_any="yes"; else _zz_any="no"; fi
check "some shipped skill is add-on owned" "yes" "$_zz_any"

# ...and the declaration cannot be quietly dropped from one of them. Without
# this, deleting a single "addon:" line turns that skill back into a core one
# installed up front, and the loop above just tests one skill fewer -- a guard
# that gets weaker exactly when the thing it guards is broken. Keyed off the
# add-on registry, so it needs no skill name of its own: an add-on that ships a
# skill under its own name must own it.
for _zz_id in $_zz_addon_ids; do
    [ -f "$ROOT/skills/$_zz_id/SKILL.md" ] || continue
    check "the $_zz_id skill still declares its owner" "$_zz_id" \
        "$(exakit_skill_field "$ROOT/skills/$_zz_id/SKILL.md" addon)"
done

# 6. The PowerShell twin, asserted as text: there is no pwsh here, and Windows
#    runs the same marketplace.
_ZZ_PS_COMMON="$ROOT/setup/lib/exakit-common.ps1"
_ZZ_PS_CLI="$ROOT/setup/exakit.ps1"
# The WIRING, on both sides. The lifecycle above calls the two functions
# directly, so it stays green even if nothing ever calls them from the install
# and uninstall paths -- which is the whole feature.
_ZZ_SH_COMMON="$(cat "$ROOT/setup/lib/common.sh")"
has "the marketplace install places the add-on's skills" \
    'exakit_install_addon_skills "$1"' "$_ZZ_SH_COMMON"
has "...and uninstalling the add-on removes them" \
    'exakit_remove_addon_skills "$_uc_key"' "$_ZZ_SH_COMMON"
has "the twin reads the owner"        "function Get-ExakitSkillAddon" "$(cat "$_ZZ_PS_COMMON")"
has "...and gates the skills step"    "Test-ExakitSkillWanted -Path" "$(cat "$_ZZ_PS_COMMON")"
has "...and installs with the add-on" "Install-ExakitAddonSkills \$id" "$(cat "$_ZZ_PS_COMMON")"
has "...and removes with it"          "Remove-ExakitAddonSkills \$Key" "$(cat "$_ZZ_PS_CLI")"

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

printf '\n== the skills panel says the same three things on both platforms ==\n'

# The stale branch existed only in the shell. On Windows a kit update that left
# the installed copies behind said NOTHING: the skills read "installed", which
# was true and useless, and the reader had no way to know the kit had moved
# underneath them. It matters more now that the skill set has a version that
# actually changes -- it moved to 1.3.0 in the same round this was found.
SH_COMMON="$(cat "$ROOT/setup/lib/common.sh")"
has "the shell detects a stale skill set" \
    'ui_panel_line "Installed from skill set $_skl_have; this kit carries $_skl_want."' "$SH_COMMON"
has "...and the twin does too" \
    'Write-ExakitPanelLine "Installed from skill set $skillsHave; this kit carries $skillsWant."' "$PS_COMMON"
has "the shell offers the refresh"  'ui_panel_line "Refresh them:  exakit skills-install"' "$SH_COMMON"
has "...and so does the twin"       'Write-ExakitPanelLine "Refresh them:  exakit skills-install"' "$PS_COMMON"
# Both read the same two values to decide, or they can disagree about staleness.
has "the shell compares installed against advertised" \
    'exakit_versions_value components.skills.version' "$SH_COMMON"
has "...and the twin compares the same pair" \
    'Get-ExakitVersionsValue -Path "components.skills.version"' "$PS_COMMON"
# Nothing is said when everything is installed AND current: the panel watches
# for staleness itself, so telling the reader to watch for it was one more line.
lacks "the shell offers no command when there is nothing to do" \
    "All installed. Refresh after a kit update" "$SH_COMMON"
lacks "...nor does the twin" \
    "All installed. Refresh after a kit update" "$PS_COMMON"

echo
printf 'passed: %d, failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
