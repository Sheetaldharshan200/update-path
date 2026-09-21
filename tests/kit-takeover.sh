#!/usr/bin/env bash
# kit-takeover.sh — installing this kit over a DIFFERENT starter kit.
#
# A machine can only hold one: both kits put their command in the same bin
# directory, their staged copy at ~/.exasol-starter-kit/kit, and their state in
# the same manifest. So an install over the official kit at
# exasol-labs/exasol-personal-local-starterkit is a REPLACEMENT.
#
# Two things have to be true of it, and they pull in opposite directions. It
# must actually replace: a module the new kit DELETED cannot go on living in the
# staged copy, because that copy is what an installed exakit loads. And it must
# not replace the part that matters: the database, its credentials and the
# deployment are the user's, both kits deploy the same Exasol Personal, and an
# install command that quietly destroyed a database would be indefensible.
#
#   bash tests/kit-takeover.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ok   $1 = $3"
          else FAIL=$((FAIL+1)); echo "  FAIL $1: expected $2, got $3"; fi; }
has()   { case "$3" in *"$2"*) check "$1" present present ;; *) check "$1" present MISSING ;; esac; }
lacks() { case "$3" in *"$2"*) check "$1" absent PRESENT ;; *) check "$1" absent absent ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/exakit-takeover.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
OFFICIAL="exasol-labs/exasol-personal-local-starterkit"
OURS="Sheetaldharshan200/update-path"

seed() { # seed <kit.source>
    _s_home="$WORK/home"; rm -rf "$_s_home"; mkdir -p "$_s_home"
    printf '{"manifest_version":1,"kit":{"source":"%s","version":"0.1.0"}}\n' "$1" > "$_s_home/manifest.json"
    printf '%s\n' "$_s_home"
}
ask() { # ask <kit.source-installed> <repo-being-installed> <expression>
    # seed a kit copy alongside the record: these cases are about WHICH kit is
    # installed, not about whether one is, which the section below covers.
    _a_home="$(seed "$1")"; mkdir -p "$_a_home/kit"
    EXAKIT_HOME="$_a_home" EXAKIT_BIN_DIR="$_a_home/bin" ROOT="$ROOT" INSTALLING="$2" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        '"$3"'' </dev/null 2>&1 | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g'
}

echo "a different kit is recognised, an update is not:"
check "the official kit is foreign" "$OFFICIAL" \
    "$(ask "$OFFICIAL@0.1.0" "$OURS@main" 'exakit_foreign_kit_repo "$INSTALLING" || echo none')"
check "the same repo at another tag is not" "none" \
    "$(ask "$OURS@0.2.0" "$OURS@main" 'exakit_foreign_kit_repo "$INSTALLING" || echo none')"
# A local working-tree install belongs to nobody, so it is never called foreign.
check "a checkout install is not foreign" "none" \
    "$(ask "checkout:/some/path" "$OURS@main" 'exakit_foreign_kit_repo "$INSTALLING" || echo none')"
check "no record at all is not foreign" "none" \
    "$(ask "" "$OURS@main" 'exakit_foreign_kit_repo "$INSTALLING" || echo none')"

echo
echo "a record left behind by an uninstall is not an installation:"
# THE BUG THIS EXISTS FOR. An uninstall that is interrupted, cannot reach a
# file, or whose Windows half cleans up differently, leaves kit.source sitting
# in the manifest with nothing behind it. Trusting that record told a user their
# old kit was still installed immediately after they had removed it - and left
# them no way to argue with it. The record has to be corroborated by something
# the kit actually put on disk.
_bare="$(seed "$OFFICIAL@0.1.0")"          # a manifest, and nothing else
check "a bare record claims nothing" "none" \
    "$(EXAKIT_HOME="$_bare" EXAKIT_BIN_DIR="$_bare/bin" ROOT="$ROOT" INSTALLING="$OURS@main" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        exakit_foreign_kit_repo "$INSTALLING" || echo none' </dev/null 2>&1)"
check "...and nothing is announced either" "" \
    "$(EXAKIT_HOME="$_bare" EXAKIT_BIN_DIR="$_bare/bin" ROOT="$ROOT" INSTALLING="$OURS@main" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        exakit_announce_kit_takeover "$INSTALLING"' </dev/null 2>&1 | tr -d '[:space:]')"
# The staged kit copy is proof enough on its own...
mkdir -p "$_bare/kit"
check "a staged kit copy is corroboration" "$OFFICIAL" \
    "$(EXAKIT_HOME="$_bare" EXAKIT_BIN_DIR="$_bare/bin" ROOT="$ROOT" INSTALLING="$OURS@main" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        exakit_foreign_kit_repo "$INSTALLING" || echo none' </dev/null 2>&1)"
# ...and so is the command it installed, on its own.
_bare2="$(seed "$OFFICIAL@0.1.0")"; mkdir -p "$_bare2/bin"
printf '#!/bin/sh\nexit 0\n' > "$_bare2/bin/exakit"; chmod +x "$_bare2/bin/exakit"
check "an installed exakit command is too" "$OFFICIAL" \
    "$(EXAKIT_HOME="$_bare2" EXAKIT_BIN_DIR="$_bare2/bin" ROOT="$ROOT" INSTALLING="$OURS@main" bash -c '
        . "$ROOT/setup/lib/common.sh" 2>/dev/null
        exakit_foreign_kit_repo "$INSTALLING" || echo none' </dev/null 2>&1)"

echo
echo "the replacement is announced, and scoped out loud:"
OUT="$(ask "$OFFICIAL@0.1.0" "$OURS@main" 'exakit_announce_kit_takeover "$INSTALLING"')"
has "the other kit is named"              "$OFFICIAL" "$OUT"
has "...and the tooling is what changes"  "replaces its tooling" "$OUT"
has "...and the data is said to be safe"  "are not touched" "$OUT"
# Silence on a plain update: this line is for a takeover, not for every install.
OUT2="$(ask "$OURS@0.2.0" "$OURS@main" 'exakit_announce_kit_takeover "$INSTALLING"')"
check "an update says nothing" "" "$(printf '%s' "$OUT2" | tr -d '[:space:]')"

echo
echo "a module the new kit deleted does not survive the replacement:"
# The real hazard, with the real files: the official kit ships runtime-nano.sh,
# nano.ps1 and catalog.tsv, all three removed from this kit on purpose. A merge
# copy leaves them in lib/, where an installed exakit would still load them.
STAGE="$WORK/home2"; mkdir -p "$STAGE/kit/setup/lib" "$STAGE/kit/mcp"
for _leftover in runtime-nano.sh nano.ps1 catalog.tsv; do : > "$STAGE/kit/setup/lib/$_leftover"; done
: > "$STAGE/kit/setup/lib/common.sh"
check "the old kit's files are staged to begin with" "3" \
    "$(ls "$STAGE/kit/setup/lib" | grep -cE 'runtime-nano.sh|nano.ps1|catalog.tsv')"
# The clear the installer runs, exactly as kit_shared_steps spells it.
for _stale in "$STAGE/kit/setup/lib" "$STAGE/kit/setup/help" "$STAGE/kit/mcp" "$STAGE/kit/sql" "$STAGE/kit/skills"; do
    rm -rf "$_stale"
done
check "...and none of them is left afterwards" "0" \
    "$(ls "$STAGE/kit/setup/lib" 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "the installer really does clear before it copies:"
KSS="$(awk '/^kit_shared_steps\(\)/,/^}$/' "$ROOT/setup/lib/common.sh")"
has "the shell half clears the staged subtrees" 'rm -rf "$_kss_stale"' "$KSS"
has "...before the library is copied over"      'cp -R "$_script_dir/lib"' "$KSS"
WIN="$(cat "$ROOT/setup/setup-windows.ps1")"
has "the Windows half clears them too"          'Remove-Item -Recurse -Force $stale' "$WIN"
has "...and announces the takeover first"       "Show-ExakitKitTakeover" "$WIN"
lacks "neither half removes the kit home itself" 'rm -rf "$EXAKIT_HOME"' "$KSS"

echo
echo "both setup scripts ask before they overwrite the evidence:"
for _s in setup-macos.sh setup-linux.sh; do
    _body="$(cat "$ROOT/setup/$_s")"
    _before="$(printf '%s\n' "$_body" | sed -n '1,/manifest_set kit.source/p')"
    has "$_s announces before recording" "exakit_announce_kit_takeover" "$_before"
done

echo
echo "kit-takeover.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
