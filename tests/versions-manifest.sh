#!/usr/bin/env bash
# versions-manifest.sh — proves the versions.json contract.
#
# versions.json is the maintainer-edited record of the tested version set, so
# every machine reads it and no machine may be broken by it. This test covers
# the four promises the readers make:
#
#   1. the shipped document is accepted, and a corrupt, newer-schema, or
#      unsafely-typed one is refused (a version lands in a download URL);
#   2. the Python reader and the no-Python awk fallback return the SAME values
#      (that agreement is what the formatting invariants exist for);
#   3. a failed or invalid fetch never loses a good cached copy, and the TTL
#      keeps normal commands off the network;
#   4. resolution degrades fetch -> cache -> baked kit copy -> fallback and
#      never fails a command.
#
# It also covers what install-time resolution does with those answers, and the
# rule that pyexasol — the last, optional Component — can never end a run.
#
# No installs, no network: the fetch is a stubbed curl, and resolution runs
# against a deliberately non-HTTPS endpoint (refused before any connection).
#
#   bash tests/versions-manifest.sh

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FIX="$WORK/fixtures"
mkdir -p "$FIX"

# The kit home is redirected for the whole run: nothing here may touch a real
# installation. common.sh derives its paths at source time, so this comes first.
EXAKIT_HOME="$WORK/home"
EXAKIT_BIN_DIR="$WORK/bin"
mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"

# shellcheck source=/dev/null
. "$ROOT/setup/lib/common.sh"

REAL="$ROOT/versions.json"

# shipped <dotted.path> - a value straight out of the shipped document, read with
# plain json.load rather than either of the kit's readers.
#
# Nothing here may hardcode what versions.json currently says. A version bump is
# meant to be a one-file pull request, and every literal copied out of that file
# turns it into a two-file one -- which is exactly what happened: the first
# automated bump PR failed 15 checks that were only asserting the old numbers
# back at themselves. What these tests actually owe you is that the two readers
# agree with each other and with the document, whatever it holds today.
shipped() {
    python3 - "$REAL" "$1" <<'SHIPPED_PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split("."):
    node = node[part]
print(node)
SHIPPED_PY
}

# --- fixtures ----------------------------------------------------------------
# Variants are derived from the shipped document so they keep its canonical
# shape; only the property under test differs.
sed 's/"schema_version": 1/"schema_version": 2/' "$REAL" > "$FIX/schema2.json"
python3 - "$REAL" "$FIX/bad-charset.json" <<'CHARSET_PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["components"]["exapump"]["version"] += " rm -rf /"
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
CHARSET_PY
sed 's/"macos-aarch64": "[0-9a-f]*"/"macos-aarch64": "nothexnothexnothex"/' "$REAL" > "$FIX/bad-digest.json"
printf 'this is not json\n' > "$FIX/corrupt.json"
printf '[{"schema_version": 1}]\n' > "$FIX/array.json"
cat > "$FIX/no-kit.json" <<'EOF'
{
  "schema_version": 1,
  "components": {
    "mcp": {
      "version": "1.10.1"
    }
  }
}
EOF
# The kit2 block is optional and additive: a document carrying it must still
# validate on a client that predates Kit 2 support.
cat > "$FIX/kit2.json" <<'EOF'
{
  "schema_version": 1,
  "updated": "2026-07-29",
  "kit": {
    "version": "0.2.0"
  },
  "components": {
    "mcp": {
      "version": "1.10.1",
      "package": "exasol-mcp-server",
      "severity": "normal"
    }
  },
  "kit2": {
    "version": "0.1.0",
    "min_kit_version": "0.2.0",
    "severity": "recommended",
    "note": "Trusted AI Workflow add-on"
  }
}
EOF
sed 's/"version": "0.1.0"/"version": "0.1.0 evil"/' "$FIX/kit2.json" > "$FIX/kit2-bad.json"

# no_python <command...> — run one reader with every Python route closed, so
# the awk fallback is the only thing that can answer.
no_python() (
    EXAKIT_DISABLE_SYSTEM_PYTHON=1
    exakit_ensure_uv() { return 1; }
    "$@"
)

# validate_rc <file> — validation exit code (0 ok, 2 newer schema, 1 refused).
validate_rc() {
    exakit_versions_validate "$1" >/dev/null 2>&1
    printf '%s\n' "$?"
}

# both_rc <label> <expected> <file> — the gate must agree with and without Python.
both_rc() {
    check "$1 (python)" "$2" "$(validate_rc "$3")"
    check "$1 (no python)" "$2" "$(no_python validate_rc "$3")"
}

# both_value <label> <expected> <dot.path> [file] — same for the reader.
both_value() {
    _bv_file="${4:-}"
    check "$1 (python)" "$2" "$(exakit_versions_value "$3" "$_bv_file" 2>/dev/null || printf 'absent')"
    check "$1 (no python)" "$2" "$(no_python exakit_versions_value "$3" "$_bv_file" 2>/dev/null || printf 'absent')"
}

echo "validation gate:"
both_rc "shipped versions.json" 0 "$REAL"
both_rc "newer schema" 2 "$FIX/schema2.json"
both_rc "version outside the safe charset" 1 "$FIX/bad-charset.json"
both_rc "digest that is not 64 hex chars" 1 "$FIX/bad-digest.json"
both_rc "no kit block" 1 "$FIX/no-kit.json"
both_rc "not json at all" 1 "$FIX/corrupt.json"
both_rc "an array instead of one object" 1 "$FIX/array.json"
both_rc "missing file" 1 "$WORK/does-not-exist.json"
both_rc "optional kit2 block" 0 "$FIX/kit2.json"
both_rc "kit2 version outside the charset" 1 "$FIX/kit2-bad.json"
schema_ahead="$( exakit_versions_validate "$FIX/schema2.json" >/dev/null 2>&1
                 if exakit_versions_schema_ahead; then printf yes; else printf no; fi )"
check "newer schema is reported as ahead" "yes" "$schema_ahead"

echo "reader (Python and the awk fallback must agree):"
for _path in kit.version components.personal.version components.nano.version \
             components.nano.image components.exapump.version components.mcp.version \
             components.mcp.package components.pyexasol.version \
             components.exapump.sha256.macos-aarch64 \
             components.exapump.sha256.windows-x86_64; do
    both_value "$_path" "$(shipped "$_path")" "$_path" "$REAL"
done
both_value "unknown component" "absent" components.nope.version "$REAL"
both_value "kit2 absent from the shipped document" "absent" kit2.version "$REAL"
both_value "kit2.version" "0.1.0" kit2.version "$FIX/kit2.json"
both_value "kit2.min_kit_version" "0.2.0" kit2.min_kit_version "$FIX/kit2.json"
both_value "kit2.note" "Trusted AI Workflow add-on" kit2.note "$FIX/kit2.json"
both_value "severity" "recommended" kit2.severity "$FIX/kit2.json"

echo "kit copy (what 'installed' means for the kit itself):"
mkdir -p "$EXAKIT_HOME/kit/mcp"
cp "$REAL" "$EXAKIT_HOME/kit/versions.json"
check "baked document is the kit copy" "$EXAKIT_HOME/kit/versions.json" "$(exakit_versions_baked_doc)"
V_KIT="$(shipped kit.version)"
check "kit bundled version" "$V_KIT" "$(exakit_kit_bundled_version)"
check "kit bundled version (no python)" "$V_KIT" "$(no_python exakit_kit_bundled_version)"
check "user agent" "exakit-update-check/$V_KIT" "$(exakit_versions_user_agent | cut -d' ' -f1)"
printf 'garbage\n' > "$EXAKIT_HOME/kit/versions.json"
check "unreadable kit copy is not a version" "absent" \
    "$(exakit_kit_bundled_version 2>/dev/null || printf absent)"
cp "$REAL" "$EXAKIT_HOME/kit/versions.json"

echo "resolution chain (a command must never fail over a version lookup):"
EXAKIT_VERSIONS_CACHE="$EXAKIT_HOME/cache/versions.json"
check "no cache -> baked kit copy" "baked" "$( exakit_versions_source )"
V_BAKED_EXAPUMP="$(shipped components.exapump.version)"
check "baked value is readable" "$V_BAKED_EXAPUMP" "$( exakit_versions_value components.exapump.version )"
mkdir -p "$EXAKIT_HOME/cache"
# A sentinel, not a plausible version: it has to be impossible for the cached
# answer to coincide with the baked one, or this proves nothing.
V_CACHED_EXAPUMP="0.0.0-from-the-cache"
python3 - "$REAL" "$EXAKIT_VERSIONS_CACHE" "$V_CACHED_EXAPUMP" <<'CACHE_PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["components"]["exapump"]["version"] = sys.argv[3]
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
CACHE_PY
check "cache wins over the kit copy" "cache" "$( exakit_versions_source )"
check "cached value is used" "$V_CACHED_EXAPUMP" "$( exakit_versions_value components.exapump.version )"
printf 'corrupted by hand\n' > "$EXAKIT_VERSIONS_CACHE"
check "unreadable cache falls back to the kit copy" "baked" "$( exakit_versions_source )"
check "kit copy answers again" "$V_BAKED_EXAPUMP" "$( exakit_versions_value components.exapump.version )"
rm -f "$EXAKIT_VERSIONS_CACHE"
no_doc="$( exakit_repo_root() { return 1; }
           printf '%s ' "$(exakit_versions_source)"
           if exakit_versions_value kit.version >/dev/null 2>&1; then printf found; else printf absent; fi )"
check "nothing on disk -> fallback constants" "fallback absent" "$no_doc"

echo "cache refresh (stubbed curl, no network):"
# The stub answers with whatever $SERVE points at, or fails when $CURL_FAIL=1 —
# enough to exercise every branch of the fetch without a server.
stub_curl() {
    curl() {
        _co=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) _co="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        [ "${CURL_FAIL:-0}" = 1 ] && return 22
        cp "$SERVE" "$_co"
    }
}
fetch_state="$( stub_curl
    SERVE="$REAL"
    EXAKIT_VERSIONS_CACHE="$WORK/fetch/versions.json"
    exakit_versions_update_cache >/dev/null 2>&1
    printf '%s %s ' "$?" "$_EXAKIT_VERSIONS_SOURCE"
    [ -f "$EXAKIT_VERSIONS_CACHE" ] && printf 'cached '
    # Only the validated document may exist — no half-written temporary file.
    printf '%s' "$(ls "$WORK/fetch" | tr '\n' ',')" )"
check "first fetch writes the cache atomically" "0 fetched cached versions.json," "$fetch_state"

ttl_state="$( stub_curl
    SERVE="$REAL"
    EXAKIT_VERSIONS_CACHE="$WORK/fetch/versions.json"
    exakit_versions_update_cache >/dev/null 2>&1; printf '%s ' "$?"
    exakit_versions_update_cache force >/dev/null 2>&1; printf '%s ' "$?"
    EXAKIT_VERSIONS_TTL=0
    exakit_versions_update_cache >/dev/null 2>&1; printf '%s' "$?" )"
check "fresh cache is not refetched (2), force and ttl=0 are" "2 0 0" "$ttl_state"

preserved="$( stub_curl
    EXAKIT_VERSIONS_CACHE="$WORK/fetch/versions.json"
    cp "$EXAKIT_VERSIONS_CACHE" "$WORK/good.json"
    SERVE="$REAL"
    CURL_FAIL=1
    exakit_versions_update_cache force >/dev/null 2>&1; printf '%s ' "$?"
    CURL_FAIL=0
    SERVE="$FIX/bad-digest.json"
    exakit_versions_update_cache force >/dev/null 2>&1; printf '%s ' "$?"
    if cmp -s "$WORK/good.json" "$EXAKIT_VERSIONS_CACHE"; then printf 'preserved '; else printf 'CLOBBERED '; fi
    printf '%s' "$(ls "$WORK/fetch" | tr '\n' ',')" )"
check "a failed or invalid fetch keeps the good cache" "1 1 preserved versions.json," "$preserved"

http_refused="$( stub_curl
    SERVE="$REAL"
    EXAKIT_VERSIONS_CACHE="$WORK/plain/versions.json"
    EXAKIT_VERSIONS_URL="http://example.invalid/versions.json"
    exakit_versions_update_cache force >/dev/null 2>&1; printf '%s ' "$?"
    [ -d "$WORK/plain" ] && printf 'wrote' || printf 'nothing' )"
check "a non-HTTPS endpoint is refused outright" "1 nothing" "$http_refused"

echo "install-time resolution:"
# Expectations are read from the manifest itself, so bumping a Component does not
# mean editing this test.
V_PERSONAL="$(exakit_versions_value components.personal.version "$REAL")"
V_NANO="$(exakit_versions_value components.nano.version "$REAL")"
V_EXAPUMP="$(exakit_versions_value components.exapump.version "$REAL")"
V_MCP="$(exakit_versions_value components.mcp.version "$REAL")"
V_PYEXASOL="$(exakit_versions_value components.pyexasol.version "$REAL")"

# resolve_set <shell-statements> — resolve in a subshell (so nothing leaks into
# the next case) and print "<source> <personal> <nano> <exapump> <mcp> <pyexasol>".
# The endpoint is non-HTTPS on purpose: it is refused outright, which keeps the
# whole test offline while still exercising the fetch-then-fall-back path.
resolve_set() (
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    EXAKIT_MANIFEST="$WORK/absent-manifest.json"
    EXAKIT_PERSONAL_VERSION=""; EXAKIT_NANO_TAG=""; EXAKIT_EXAPUMP_VERSION=""
    EXAKIT_MCP_VERSION=""; EXAKIT_PYEXASOL_VERSION=""
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    eval "${1:-}"
    exakit_resolve_install_versions >/dev/null 2>&1
    printf '%s %s %s %s %s %s\n' "$EXAKIT_VERSIONS_SOURCE_USED" "$EXAKIT_PERSONAL_VERSION" \
        "$EXAKIT_NANO_TAG" "$EXAKIT_EXAPUMP_VERSION" "$EXAKIT_MCP_VERSION" "$EXAKIT_PYEXASOL_VERSION"
)

check "manifest policy (default) reads the kit copy" \
    "baked $V_PERSONAL $V_NANO $V_EXAPUMP $V_MCP $V_PYEXASOL" "$(resolve_set)"
check "an env override beats the manifest" \
    "baked $V_PERSONAL $V_NANO 9.9.9 $V_MCP $V_PYEXASOL" \
    "$(resolve_set 'EXAKIT_EXAPUMP_VERSION=9.9.9')"
check "no document at all -> the fallback constants" \
    "fallback $EXAKIT_PERSONAL_VERSION_FALLBACK $EXAKIT_NANO_TAG_FALLBACK $EXAKIT_EXAPUMP_VERSION_FALLBACK $EXAKIT_MCP_VERSION_FALLBACK $EXAKIT_PYEXASOL_VERSION_FALLBACK" \
    "$(resolve_set 'exakit_repo_root() { return 1; }')"
mkdir -p "$EXAKIT_HOME/cache"
sed 's/"version": "'"$V_EXAPUMP"'"/"version": "0.12.0"/' "$REAL" > "$EXAKIT_VERSIONS_CACHE"
check "a cached document beats the kit copy" \
    "cache $V_PERSONAL $V_NANO 0.12.0 $V_MCP $V_PYEXASOL" "$(resolve_set)"
check "pinned policy ignores the document entirely" \
    "fallback $EXAKIT_PERSONAL_VERSION_FALLBACK $EXAKIT_NANO_TAG_FALLBACK $EXAKIT_EXAPUMP_VERSION_FALLBACK $EXAKIT_MCP_VERSION_FALLBACK $EXAKIT_PYEXASOL_VERSION_FALLBACK" \
    "$(resolve_set 'EXAKIT_VERSION_POLICY=pinned')"
check "latest policy still asks upstream" \
    "latest 7.7.7 8.8.8 7.7.7 6.6.6 6.6.6" \
    "$(resolve_set 'EXAKIT_VERSION_POLICY=latest
                    exakit_latest_github_release_version() { echo 7.7.7; }
                    exakit_latest_docker_tag() { echo 8.8.8; }
                    exakit_latest_pypi_version() { echo 6.6.6; }')"
rm -f "$EXAKIT_VERSIONS_CACHE"

recorded="$( EXAKIT_HOME="$WORK/record-home"
             EXAKIT_MANIFEST="$WORK/record-home/manifest.json"
             EXAKIT_VERSIONS_CACHE="$WORK/record-home/cache/versions.json"
             EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
             EXAKIT_PERSONAL_VERSION=""; EXAKIT_NANO_TAG=""; EXAKIT_EXAPUMP_VERSION=""
             EXAKIT_MCP_VERSION=""; EXAKIT_PYEXASOL_VERSION=""
             _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
             mkdir -p "$EXAKIT_HOME/kit/mcp"
             cp "$REAL" "$EXAKIT_HOME/kit/versions.json"
             manifest_init >/dev/null 2>&1
             exakit_resolve_install_versions >/dev/null 2>&1
             printf '%s %s %s' "$(manifest_get version_policy)" \
                 "$(manifest_get desired.versions_source)" "$(manifest_get desired.exapump)" )"
check "the install records where the versions came from" "manifest baked $V_EXAPUMP" "$recorded"

echo "exapump digest chain:"
digest_chain="$( . "$ROOT/setup/lib/detect.sh"
    . "$ROOT/setup/lib/exapump.sh"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_VERSIONS_CACHE="$WORK/no-cache.json"
    EXAKIT_EXAPUMP_VERSION="$V_EXAPUMP"
    _asset="$(exapump_asset_name)"
    _advertised="$(exakit_versions_value "components.exapump.sha256.${_asset#exapump-$V_EXAPUMP-}" "$REAL")"
    [ "$(exapump_expected_sha256 "$_asset")" = "$_advertised" ] && printf 'manifest ' || printf 'WRONG '
    # A version the manifest does not advertise must not borrow its digest: the
    # chain has to fall through to the pinned table and then the release API.
    exapump_pinned_sha256() { printf '' ; }
    exapump_release_digest_from_api() { printf 'from-api\n'; }
    EXAKIT_EXAPUMP_VERSION="0.0.0-not-advertised"
    printf '%s' "$(exapump_expected_sha256 "exapump-0.0.0-not-advertised-linux-x86_64")" )"
check "the advertised version verifies against the manifest digest" "manifest from-api" "$digest_chain"

echo "resilient install (pyexasol cannot end a run):"
mkdir -p "$WORK/failing-uv"
printf '#!/bin/sh\nexit 1\n' > "$WORK/failing-uv/uv"
chmod +x "$WORK/failing-uv/uv"
soft_fail="$( EXAKIT_HOME="$WORK/pyx-home"
    EXAKIT_MANIFEST="$WORK/pyx-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/pyx-home/bin"
    EXAKIT_PYEXASOL_VENV="$WORK/pyx-home/pyexasol-venv"
    EXAKIT_PYEXASOL_VERSION="$V_PYEXASOL"
    mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    PATH="$WORK/failing-uv:$PATH"
    if pyexasol_install >/dev/null 2>&1; then printf 'installed '; else printf 'soft-failed '; fi
    printf '%s ' "$(manifest_get components.pyexasol.validated 2>/dev/null || printf unset)"
    printf '%s' "$(manifest_get components.pyexasol.version 2>/dev/null || printf no-version)" )"
check "a uv that cannot run records the miss instead of dying" \
    "soft-failed false no-version" "$soft_fail"

# The real promise: the exakit helper step comes AFTER pyexasol, so a pyexasol
# failure must not stop the run from installing the command that fixes it.
mkdir -p "$WORK/fake-kit"
cp "$REAL" "$WORK/fake-kit/versions.json"
completed="$( EXAKIT_HOME="$WORK/kss-home"
    EXAKIT_MANIFEST="$WORK/kss-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/kss-home/bin"
    EXAKIT_PYEXASOL_VENV="$WORK/kss-home/pyexasol-venv"
    EXAKIT_PYEXASOL_VERSION="$V_PYEXASOL"
    mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    # Out of scope for this test: data load, MCP client setup, skills, PATH hints.
    exakit_maybe_offer_data_load() { :; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    PATH="$WORK/failing-uv:$PATH"
    kit_shared_steps 3 6 "$ROOT/setup" "$WORK/fake-kit" >/dev/null 2>&1
    [ -x "$EXAKIT_BIN_DIR/exakit" ] && printf 'exakit-installed ' || printf 'NO-EXAKIT '
    [ -f "$EXAKIT_HOME/kit/versions.json" ] && printf 'manifest-copied ' || printf 'NO-MANIFEST '
    printf '%s' "$(manifest_get steps_completed | tr -d ' "[]')" )"
check "the run completes and the kit copy carries the manifest" \
    "exakit-installed manifest-copied exakit_helper" "$completed"

# Re-running the installer over an older install (the 0.1.0 -> 0.2.0 path) is the
# one case where the step flag lies: install.sh has already replaced the kit copy,
# but exakit_helper is marked and a command is on disk, so the step skips. The
# installed command is a COPY of setup/exakit, so it has to be compared with the
# kit's own script or the user drives the new library with the old command.
rerun="$( EXAKIT_HOME="$WORK/rerun-home"
    EXAKIT_MANIFEST="$WORK/rerun-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/rerun-home/bin"
    EXAKIT_PYEXASOL_VENV="$WORK/rerun-home/pyexasol-venv"
    EXAKIT_PYEXASOL_VERSION="$V_PYEXASOL"
    mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    exakit_maybe_offer_data_load() { :; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    PATH="$WORK/failing-uv:$PATH"
    # Stand in for the older install: step already marked, previous command on disk.
    printf '#!/bin/sh\nprintf 0.1.0\n' > "$EXAKIT_BIN_DIR/exakit"
    chmod +x "$EXAKIT_BIN_DIR/exakit"
    mark_step exakit_helper >/dev/null 2>&1
    _out="$(kit_shared_steps 3 6 "$ROOT/setup" "$WORK/fake-kit" 2>&1)"
    # grep rather than case: inside a command substitution bash 3.2 reads the
    # close-paren of a case pattern as the end of the substitution itself, and
    # quote characters in a comment here confuse it the same way. Keep both out.
    if printf '%s\n' "$_out" | grep -q 'out of date'; then
        printf 'said-out-of-date '
    else
        printf 'SILENT '
    fi
    if cmp -s "$ROOT/setup/exakit" "$EXAKIT_BIN_DIR/exakit"; then printf 'refreshed'; else printf 'STALE'; fi )"
check "a re-run refreshes the command an older install left behind" \
    "said-out-of-date refreshed" "$rerun"

# ...and it must leave a command that already matches alone, or every re-run
# announces an upgrade that did not happen.
noop="$( EXAKIT_HOME="$WORK/noop-home"
    EXAKIT_MANIFEST="$WORK/noop-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/noop-home/bin"
    EXAKIT_PYEXASOL_VENV="$WORK/noop-home/pyexasol-venv"
    EXAKIT_PYEXASOL_VERSION="$V_PYEXASOL"
    mkdir -p "$EXAKIT_HOME" "$EXAKIT_BIN_DIR"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    exakit_maybe_offer_data_load() { :; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    PATH="$WORK/failing-uv:$PATH"
    install -m 755 "$ROOT/setup/exakit" "$EXAKIT_BIN_DIR/exakit"
    mark_step exakit_helper >/dev/null 2>&1
    _out="$(kit_shared_steps 3 6 "$ROOT/setup" "$WORK/fake-kit" 2>&1)"
    if printf '%s\n' "$_out" | grep -q 'out of date'; then
        printf 'REFRESHED-ANYWAY'
    else
        printf 'left-alone'
    fi )"
check "a re-run leaves an up-to-date command alone" "left-alone" "$noop"

echo "update-check table:"
# One fixture install, one advertised set, every interesting row at once:
#   exakit    0.2.0            = 0.2.0             -> current (and NOT "inspect")
#   nano      2026.2.0-nano.2 -> 2026.3.0-nano.1   -> heavy
#   exapump   0.13.0          -> 0.12.0            -> ahead, nothing offered
#   mcp       1.10.1          -> 1.11.0 critical   -> severity + note
#   pyexasol  not installed   -> 2.2.2             -> repair action
UC="$WORK/uc-home"
mkdir -p "$UC/kit/mcp" "$UC/cache" "$UC/bin"
# Installed versions are read from disk now, so the fixture supplies the disk: a
# stub that reports 0.13.0 is what puts the install AHEAD of the advertised 0.12.0,
# on any machine, whether or not a real exapump is installed.
printf '#!/bin/sh\necho "exapump 0.13.0"\n' > "$UC/bin/exapump"
chmod +x "$UC/bin/exapump"
cat > "$UC/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "installed_at": "2026-07-29T10:00:00Z",
  "kit": {
    "version": "0.2.0",
    "source": "example/starter-kit@main"
  },
  "runtime": {
    "type": "nano",
    "image": "docker.io/exasol/nano:2026.2.0-nano.2"
  },
  "components": {
    "exapump": {
      "version": "0.13.0",
      "path": "$UC/bin/exapump"
    },
    "mcp_server": {
      "package": "exasol-mcp-server",
      "version": "1.10.1"
    },
    "pyexasol": {
      "validated": false
    }
  },
  "steps_completed": []
}
EOF
cat > "$UC/kit/versions.json" <<'EOF'
{
  "schema_version": 1,
  "updated": "2026-07-29",
  "kit": {
    "version": "0.2.0"
  },
  "components": {
    "nano": {
      "version": "2026.3.0-nano.1",
      "image": "exasol/nano",
      "severity": "normal"
    },
    "exapump": {
      "version": "0.12.0",
      "severity": "recommended",
      "note": "0.13.0 mis-detects CSV headers; 0.12.0 is the tested build."
    },
    "mcp": {
      "version": "1.11.0",
      "package": "exasol-mcp-server",
      "severity": "critical"
    },
    "pyexasol": {
      "version": "2.2.2"
    },
    "personal": {
      "version": "2.0.0-rc4"
    }
  }
}
EOF

# row <table> <first column> — one row of a rendered table, colour escapes
# removed and runs of spaces squeezed to one, so a whole row can be compared
# exactly. The Severity cell is coloured when the suite is run on a terminal
# (UI_FANCY), and an exact comparison must hold either way.
row() {
    printf '%s\n' "$1" | grep -m1 "^$2 " | sed "s/$(printf '\033')\[[0-9;]*m//g" | tr -s ' '
}

# has <label> <needle> <haystack>
has() {
    case "$3" in
        *"$2"*) check "$1" "present" "present" ;;
        *)      check "$1" "present" "MISSING" ;;
    esac
}
lacks() {
    case "$3" in
        *"$2"*) check "$1" "absent" "PRESENT" ;;
        *)      check "$1" "absent" "absent" ;;
    esac
}

uc_table="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_update_check all 2>&1 )"

# The header line itself, squeezed: the middle column is Tagged. Matching the
# bare word would also match the "Available versions from ..." source line below
# it, so the whole header is pinned instead — including its order.
check "the column is Tagged, not Available or Latest" \
    "Component Installed Tagged Severity Action" "$(row "$uc_table" Component)"
lacks "the old Latest header is gone" "Latest" "$uc_table"
has "there is a Severity column" "Severity" "$uc_table"
has "the kit row compares its own version" "exakit     0.2.0" "$uc_table"
# The Installed column must keep showing what is installed. Asking
# exakit_version_newer about a possible rollback passes the versions in reverse,
# and bash has no function-local variables here: a callee that reused the name
# _current would silently overwrite the row's installed version.
has "installed stays installed (exapump)" "exapump    0.13.0" "$uc_table"
has "installed stays installed (nano)" "nano       2026.2.0-nano.2" "$uc_table"
has "installed stays installed (mcp)" "mcp        1.10.1" "$uc_table"
lacks "no row is stuck on inspect" "inspect" "$uc_table"
has "a runtime change is marked heavy" "exakit update runtime (heavy)" "$uc_table"
# The whole ahead row, squeezed: the tagged version is shown bare (the column
# name says what the number is, so the old "(older)" suffix is gone) and the
# action is exactly "none". It used to read "none — yours is newer than tested",
# which apologised for the install and made the tested set sound abandoned.
check "an install ahead of the tagged set says only none" \
    "exapump 0.13.0 0.12.0 recommended none" "$(row "$uc_table" exapump)"
lacks "no version cell is annotated (older)" "(older)" "$uc_table"
lacks "and nothing apologises for the install" "newer than tested" "$uc_table"
lacks "no downgrade is offered" "exakit update exapump" "$uc_table"
lacks "and no confirmation is promised" "advisory rollback" "$uc_table"
has "a critical severity is shown" "critical" "$uc_table"
has "a recommended severity is shown" "recommended" "$uc_table"
has "the maintainer note is printed" "0.13.0 mis-detects CSV headers" "$uc_table"
has "a missing component offers the repair" "exakit update pyexasol" "$uc_table"
has "normal severities stay quiet" "-          " "$uc_table"
has "the source of the answers is stated" "Available versions from" "$uc_table"

min_kit_table="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    # A component that needs a newer kit must send the user to the kit first.
    exakit_component_min_kit() { [ "$1" = "mcp" ] && printf '9.9.9\n'; return 0; }
    exakit_print_update_check mcp 2>&1 )"
has "min_kit_version routes to the kit first" "update exakit first (needs kit >= 9.9.9)" "$min_kit_table"

echo "the full table belongs to update-check alone:"
version_out="$( EXAKIT_HOME="$UC" EXAKIT_MANIFEST="$UC/manifest.json" \
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
    bash "$ROOT/setup/exakit" version 2>&1 )"
has "version reports the installed kit version" "Kit version:    0.2.0" "$version_out"
lacks "version prints no comparison table" "Component update check" "$version_out"
# Framed like the connection panel, not three loose lines that read like an error.
has "version frames the waiting updates" "Updates available" "$version_out"
has "version points at update-check" "See what's new   exakit update-check" "$version_out"
has "version points at update" "Apply them       exakit update" "$version_out"

update_out="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    exakit_update all 2>&1 )"
lacks "update prints no comparison table either" "Component update check" "$update_out"
has "update states its work plan" "mcp 1.10.1 -> 1.11.0" "$update_out"
has "update applies the light components" "APPLIED mcp" "$update_out"
lacks "update never applies the runtime by itself" "APPLIED runtime" "$update_out"
has "update explains the deferred runtime" "needs the database stopped" "$update_out"

echo "the user's own choice still wins:"
# The install path honours EXAKIT_*_VERSION; the update path must too, or the
# documented "downgrade of my own choosing" movement quietly does something else.
override_avail="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_EXAPUMP_VERSION="0.11.2"
    printf '%s %s' "$(exakit_component_available exapump)" "$(exakit_component_available mcp)" )"
check "an env override outranks the manifest" "0.11.2 1.11.0" "$override_avail"
override_confirm="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_EXAPUMP_VERSION="0.11.2"
    if exakit_component_is_ahead exapump; then printf 'ahead'; else printf 'NOT-AHEAD'; fi )"
check "but an override naming an older version is still not a downgrade lever" \
    "ahead" "$override_confirm"

echo "a routine update never dies on one component:"
unknown_skip="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    # Nothing is advertised at all (an unreadable manifest looks like this).
    exakit_component_available() { return 1; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    exakit_update all 2>&1 )"
has "an unadvertised component is skipped, not fatal" "No advertised version for mcp" "$unknown_skip"
lacks "and nothing is applied blindly" "APPLIED" "$unknown_skip"

current_only="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    # Everything installed matches what is advertised.
    exakit_component_available() { exakit_component_current "$1"; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    exakit_update all 2>&1 )"
has "an up-to-date install says so once" "Everything is already current." "$current_only"
lacks "without listing every component" "is current (" "$current_only"

echo "installed versions come from disk, not just from the record:"
# The record says what the kit installed. A user can upgrade pyexasol inside its
# venv or drop in another exapump build, and an update check that trusted the
# record would compare against a version nobody is running.
LIVE="$WORK/live-home"
mkdir -p "$LIVE/bin" "$LIVE/venv/bin" "$LIVE/kit/mcp" "$LIVE/cache"
cp "$REAL" "$LIVE/kit/versions.json"
printf '#!/bin/sh\necho "exapump 0.13.0"\n' > "$LIVE/bin/exapump"
printf '#!/bin/sh\necho 2.9.9\n' > "$LIVE/venv/bin/python"
chmod +x "$LIVE/bin/exapump" "$LIVE/venv/bin/python"
cat > "$LIVE/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": { "version": "0.2.0" },
  "runtime": { "type": "nano", "version": "2.0.0-rc4", "image": "docker.io/exasol/nano:2026.2.0-nano.2" },
  "components": {
    "exapump": { "version": "0.11.2", "path": "$LIVE/bin/exapump" },
    "mcp_server": { "version": "1.10.1" },
    "pyexasol": { "version": "2.2.2", "python": "$LIVE/venv/bin/python" }
  },
  "steps_completed": []
}
EOF

live_read() (
    EXAKIT_HOME="$LIVE"
    EXAKIT_MANIFEST="$LIVE/manifest.json"
    eval "${2:-}"
    exakit_component_current "$1" 2>/dev/null || printf 'not installed'
)

check "exapump: the binary on disk wins over the record" "0.13.0" "$(live_read exapump)"
check "pyexasol: the venv wins over the record" "2.9.9" "$(live_read pyexasol)"
# A probe that runs but says nothing usable: keep the record rather than claim
# the component vanished.
check "a silent probe falls back to the record" "0.11.2" \
    "$(live_read exapump 'printf "#!/bin/sh\nexit 3\n" > "$LIVE/bin/exapump"; chmod +x "$LIVE/bin/exapump"')"
# Provably absent is different from unknown: the table should offer the reinstall.
check "a missing binary reports not installed" "not installed" \
    "$(live_read exapump 'rm -f "$LIVE/bin/exapump"; PATH="/nonexistent"')"
check "a missing venv reports not installed" "not installed" \
    "$(live_read pyexasol 'rm -f "$LIVE/venv/bin/python"')"
# The MCP server is materialised per launch by uvx, so its record stands.
check "the MCP server keeps its recorded version" "1.10.1" "$(live_read mcp)"

# A component that is gone must read as gone in EVERY command. Swallowing the reader's
# "provably absent" verdict made `exakit version` print a recorded version while
# update-check and status both said "not installed".
# PATH must not contain a real exapump either, or the binary fallback finds the
# tester's own install; python3 has to stay reachable for the manifest reads.
absent_version="$( rm -f "$LIVE/bin/exapump" "$LIVE/venv/bin/python"
    EXAKIT_HOME="$LIVE" PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin" \
        bash "$ROOT/setup/exakit" version 2>&1 )"
has "version agrees that a deleted exapump is gone" "exapump:        not installed" "$absent_version"
has "version agrees that a deleted venv is gone" "pyexasol:       not installed" "$absent_version"
# Put them back for anything that follows.
printf '#!/bin/sh\necho "exapump 0.13.0"\n' > "$LIVE/bin/exapump"
printf '#!/bin/sh\necho 2.9.9\n' > "$LIVE/venv/bin/python"
chmod +x "$LIVE/bin/exapump" "$LIVE/venv/bin/python"

# Clients that disagree must yield ONE comparable version, not a joined list: the list
# compared as newer than the advertised version, so an unattended update read it as a
# rollback and skipped MCP entirely.
mcp_not_rollback="$( EXAKIT_HOME="$LIVE"
    EXAKIT_MANIFEST="$LIVE/manifest.json"
    exakit_component_available() { printf '1.10.1\n'; }
    exakit_component_current() { printf '1.9.0\n'; }
    if exakit_component_is_ahead mcp; then printf 'AHEAD'; else printf 'not-ahead'; fi )"
check "and an older pin is not mistaken for being ahead" "not-ahead" "$mcp_not_rollback"

# The launcher is a different axis from the runtime: personal_update --apply installs a
# new launcher but leaves runtime.version behind until the data migration is done.
# Reporting the launcher there hid the outstanding migration.
check "personal reports the recorded runtime, not the launcher" "2.0.0-rc4" \
    "$( EXAKIT_HOME="$LIVE"; EXAKIT_MANIFEST="$LIVE/manifest.json"; EXAKIT_BIN_DIR="$LIVE/rt"
        mkdir -p "$LIVE/rt"; printf '#!/bin/sh\necho 9.9.9\n' > "$LIVE/rt/exasol"
        chmod +x "$LIVE/rt/exasol"
        exakit_installation_runtime_type() { printf personal; }
        exakit_component_current personal 2>/dev/null )"

# The container is not always called exasol-nano.
check "nano resolves the recorded container name" "2026.9.9-nano.7" \
    "$( EXAKIT_HOME="$LIVE"; EXAKIT_MANIFEST="$LIVE/manifest.json"
        exakit_installation_runtime_type() { printf nano; }
        nano_resolve_names() { EXAKIT_NANO_CONTAINER="custom-nano"; }
        nano_engine() { printf "%s" "$LIVE/rt/fake-engine"; }
        mkdir -p "$LIVE/rt"
        # Answers only when asked about the resolved name, so a probe that ignored
        # nano_resolve_names would get nothing and fall back to the record.
        printf '#!/bin/sh\ncase " $* " in *" custom-nano "*) echo "docker.io/exasol/nano:2026.9.9-nano.7" ;; esac\n' \
            > "$LIVE/rt/fake-engine"; chmod +x "$LIVE/rt/fake-engine"
        exakit_component_current nano 2>/dev/null )"

# The runtime is probed too, but with one deliberate difference: a probe that cannot
# answer keeps the record instead of reporting absence. A stopped container engine
# is an ordinary state; the runtime row must not flicker to "inspect" because Docker
# Desktop is closed.
mkdir -p "$LIVE/rt"
printf '#!/bin/sh\necho 3.1.4\n' > "$LIVE/rt/exasol"
printf '#!/bin/sh\necho "docker.io/exasol/nano:2026.9.9-nano.7"\n' > "$LIVE/rt/fake-engine"
chmod +x "$LIVE/rt/exasol" "$LIVE/rt/fake-engine"
# The fixture records type nano, so asking for `personal` must return nothing even
# with a launcher sitting right there: a runtime this kit does not manage is not
# installed. PATH is left alone on purpose — stripping it hides python3, and the kit
# then reaches for uv, which is noise rather than a result.
runtime_read() (
    EXAKIT_HOME="$LIVE"
    EXAKIT_MANIFEST="$LIVE/manifest.json"
    EXAKIT_BIN_DIR="$LIVE/rt"
    eval "${2:-}"
    exakit_component_current "$1" 2>/dev/null || printf 'not installed'
)
# The launcher is NOT the runtime version: personal_update --apply installs a new
# launcher and deliberately leaves runtime.version behind until the data migration is
# finished, so the record is the only honest answer here.
check "personal reports the record, launcher present or not" "2.0.0-rc4" \
    "$(runtime_read personal 'exakit_installation_runtime_type() { printf personal; }')"
check "personal is not installed on a Nano box" "not installed" "$(runtime_read personal)"
check "nano: the container tag wins over the record" "2026.9.9-nano.7" \
    "$(runtime_read nano 'nano_engine() { printf "%s" "$LIVE/rt/fake-engine"; }')"
check "nano: an engine that will not answer keeps the record" "2026.2.0-nano.2" \
    "$(runtime_read nano 'nano_engine() { printf none; }')"

# The MCP server is never installed as such: uvx materialises it per launch, so what
# exists is the spec pinned into each AI client config. The status operation is stubbed
# to hand back a config path, and the pin is read out of the file itself.
mkdir -p "$LIVE/mcp"
printf '{"mcpServers":{"exasol":{"command":"uvx","args":["exasol-mcp-server@1.9.0"]}}}\n' \
    > "$LIVE/mcp/client-a.json"
printf '{"mcpServers":{"exasol":{"command":"uvx","args":["exasol-mcp-server@1.10.1"]}}}\n' \
    > "$LIVE/mcp/client-b.json"
mcp_read() (
    EXAKIT_HOME="$LIVE"
    EXAKIT_MANIFEST="$LIVE/manifest.json"
    exakit_run_mcp_operation_cli() {
        printf '{"artifacts":[%s]}\n' "$MCP_ARTIFACTS" > "$3"
    }
    eval "${1:-}"
    exakit_component_current mcp 2>/dev/null || printf 'not installed'
)
check "mcp: the pin in the client config is what will run" "1.9.0" \
    "$(MCP_ARTIFACTS='{"path":"'"$LIVE"'/mcp/client-a.json"}' mcp_read)"
# Clients that disagree yield the OLDEST pin: this value is compared against the
# advertised version, and the oldest is the weakest link — the client that would launch
# the most outdated server. Which client is stale belongs to mcp-doctor.
check "mcp: disagreeing clients yield the oldest pin" "1.9.0" \
    "$(MCP_ARTIFACTS='{"path":"'"$LIVE"'/mcp/client-a.json"},{"path":"'"$LIVE"'/mcp/client-b.json"}' mcp_read)"
check "mcp: no configured client keeps the record" "1.10.1" \
    "$(MCP_ARTIFACTS='' mcp_read)"
check "mcp: no mcp module at all keeps the record" "1.10.1" \
    "$(mcp_read 'unset -f exakit_run_mcp_operation_cli')"

echo "exakit version names both what is on the machine and what the kit installed:"
# Its own fixture on purpose: the cases above delete stubs to test absence, and this
# one needs them present. One runtime key only (a real manifest has version OR image).
DR="$WORK/drift-home"
mkdir -p "$DR/bin" "$DR/venv/bin" "$DR/kit/mcp"
cp "$REAL" "$DR/kit/versions.json"
printf '#!/bin/sh\necho "exapump 0.13.0"\n' > "$DR/bin/exapump"
printf '#!/bin/sh\necho 2.9.9\n' > "$DR/venv/bin/python"
chmod +x "$DR/bin/exapump" "$DR/venv/bin/python"
drift_manifest() {
    cat > "$DR/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": { "version": "0.2.0" },
  "runtime": { "type": "nano", "image": "docker.io/exasol/nano:2026.2.0-nano.2" },
  "components": {
    "exapump": { "version": "$1", "path": "$DR/bin/exapump" },
    "mcp_server": { "package": "exasol-mcp-server", "version": "1.10.1" },
    "pyexasol": { "version": "$2", "python": "$DR/venv/bin/python" }
  },
  "steps_completed": []
}
EOF
}
# EXAKIT_HOME has to be exported into the child: `exakit version` is a separate
# process, and a plain assignment in this shell would leave it reading the real
# installation instead of the fixture.
version_out() {
    EXAKIT_HOME="$DR" bash "$ROOT/setup/exakit" version 2>&1
}
drift_manifest 0.11.2 2.2.2
drift_out="$(version_out)"
has "a hand-upgraded exapump shows both" "0.13.0  (kit installed 0.11.2)" "$drift_out"
has "a hand-upgraded pyexasol shows both" "2.9.9  (kit installed 2.2.2)" "$drift_out"
# Nothing changed outside the kit: the record and the machine agree, so the line stays
# as short as it always was.
drift_manifest 0.13.0 2.9.9
agree_out="$(version_out)"
lacks "and says nothing extra when they agree" "(kit installed" "$agree_out"
# The Nano runtime records a full image reference but probes back a bare tag; the two
# must be compared as tags, or every Nano install would claim a phantom difference.
has "the runtime row compares tag with tag" "Runtime:        nano 2026.2.0-nano.2" "$agree_out"

echo "a component with no build for this machine is never offered:"
# exapump publishes nothing for Windows on ARM, and nothing for a CPU outside
# x86_64/arm64. Offering `exakit update exapump` there fails deep inside the installer,
# so the row says why instead.
unsupported_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    detect_arch() { printf unsupported; }
    exakit_print_update_check exapump 2>&1 )"
has "the row says not available" "exapump    not available" "$unsupported_row"
has "and explains why once" "no exapump build exists for this platform" "$unsupported_row"
lacks "and offers no command" "exakit update exapump" "$unsupported_row"
unsupported_apply="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    detect_arch() { printf unsupported; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    ( exakit_update exapump </dev/null 2>&1 ) )"
has "an explicit update explains rather than failing deep" "no build for this platform" "$unsupported_apply"
lacks "and installs nothing" "APPLIED" "$unsupported_apply"

echo "the table's verdict binds the apply path too:"
# uc_run <statements> — `exakit update all` against the fixture, with the real
# component updaters replaced by a marker so the decisions are what is observed.
uc_run() (
    EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    eval "${1:-}"
    ( exakit_update all </dev/null 2>&1 ); printf 'rc=%s' "$?"
)

min_kit_apply="$(uc_run 'exakit_component_min_kit() { [ "$1" = mcp ] && printf "9.9.9\n"; return 0; }')"
has "a kit-blocked component says so" "needs kit >= 9.9.9" "$min_kit_apply"
lacks "and is not installed anyway" "APPLIED mcp" "$min_kit_apply"
has "while the rest of the run continues" "APPLIED pyexasol" "$min_kit_apply"

ahead_skip="$(uc_run)"
lacks "an install ahead of the manifest is never downgraded" "APPLIED exapump" "$ahead_skip"
has "and the skip is stated" "is newer than the tested 0.12.0" "$ahead_skip"
has "but its neighbours still are" "APPLIED mcp" "$ahead_skip"
has "and the run itself succeeds" "rc=0" "$ahead_skip"

personal_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_update_check personal 2>&1 )"
has "a runtime this machine does not run is listed" "personal   not installed" "$personal_row"
lacks "but never offered for installation" "exakit update personal" "$personal_row"

echo "the Tagged column matches the policy in force:"
pinned_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSION_POLICY=pinned
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_update_check exapump 2>&1 )"
has "pinned policy offers the built-in fallback" "$EXAKIT_EXAPUMP_VERSION_FALLBACK" "$pinned_row"
has "and says where that came from" "built-in fallbacks" "$pinned_row"
lacks "not the manifest" "versions manifest that shipped" "$pinned_row"

override_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_EXAPUMP_VERSION=9.9.9
    exakit_print_update_check exapump 2>&1 )"
has "an override reaches the Tagged column" "9.9.9" "$override_row"
has "and is credited as an override" "EXAKIT_* environment overrides" "$override_row"
lacks "the maintainers' note is withheld from it" "mis-detects CSV headers" "$override_row"

unreadable_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$WORK/no-such-cache.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_repo_root() { return 1; }
    exakit_print_update_check exapump 2>&1 )"
has "no readable document is stated plainly" "could not be read" "$unreadable_row"
has "and the row admits it does not know" "inspect" "$unreadable_row"

echo "never backwards (no prompt, no override, no exception):"
ahead="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    if exakit_component_is_ahead exapump; then printf 'ahead '; else printf 'NOT-AHEAD '; fi
    # The env override that used to pre-answer the confirmation must not resurrect
    # the behaviour now that the confirmation itself is gone.
    EXAKIT_ALLOW_DOWNGRADE=1
    if exakit_component_is_ahead exapump; then printf 'still-ahead'; else printf 'OVERRIDDEN'; fi )"
check "an install ahead of the manifest stays ahead, override or not" \
    "ahead still-ahead" "$ahead"
# The behaviour that used to prompt: asking for that component by name must now
# succeed and do nothing, rather than fail or ask.
one_ahead="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_init_logging() { :; }
    exakit_update_component() { printf 'APPLIED %s\n' "$1"; }
    ( exakit_update exapump </dev/null 2>&1 ); printf 'rc=%s' "$?" )"
has "asking for it by name explains the skip" "is newer than the tested 0.12.0" "$one_ahead"
lacks "and applies nothing" "APPLIED exapump" "$one_ahead"
lacks "without asking anything" "Downgrade" "$one_ahead"
has "and exits clean" "rc=0" "$one_ahead"

echo "a failed component cannot strand the install:"
# The failure this prevents: exapump has 32 die() calls and runs three steps before
# the exakit command is installed, so a broken download used to leave a deployed
# database, no CLI, and nothing to repair it with but the whole installer again.
mkdir -p "$WORK/soft-kit"
cp "$REAL" "$WORK/soft-kit/versions.json"
soft="$( EXAKIT_HOME="$WORK/soft-home"
    EXAKIT_MANIFEST="$WORK/soft-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/soft-home/bin"
    mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    # exapump dies the way a bad download does; MCP works; pyexasol misses softly.
    exapump_install() { die "Could not install exapump"; }
    exapump_create_profile() { :; }
    exapump_validate_connection() { :; }
    mcp_install() { :; }
    mcp_validate() { :; }
    pyexasol_install() { return 1; }
    pyexasol_validate() { :; }
    exakit_maybe_offer_data_load() { printf 'OFFERED-DATA-LOAD\n'; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    _out="$(kit_shared_steps 3 6 "$ROOT/setup" "$WORK/soft-kit" 2>&1)"
    [ -x "$EXAKIT_BIN_DIR/exakit" ] && printf 'cli ' || printf 'NO-CLI '
    printf '%s ' "$(manifest_get steps_completed | tr -d '\" []' )"
    printf '%s\n' "$_out" | grep -q 'OFFERED-DATA-LOAD' && printf 'data-offered' || printf 'data-skipped'
    printf ' '
    printf '%s\n' "$_out" | grep -q 'exakit update exapump' && printf 'repair-exapump' || printf 'NO-REPAIR-EXAPUMP'
    printf ' '
    printf '%s\n' "$_out" | grep -q 'exakit update pyexasol' && printf 'repair-pyexasol' || printf 'NO-REPAIR-PYEXASOL' )"
check "a dying component leaves a working CLI, a repair line, and no half-marked step" \
    "cli mcp,exakit_helper data-skipped repair-exapump repair-pyexasol" "$soft"

# Nothing failing must not produce a summary out of thin air.
quiet="$( EXAKIT_HOME="$WORK/soft-ok-home"
    EXAKIT_MANIFEST="$WORK/soft-ok-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/soft-ok-home/bin"
    mkdir -p "$EXAKIT_HOME"
    . "$ROOT/setup/lib/pyexasol.sh"
    manifest_init >/dev/null 2>&1
    exapump_install() { :; }
    exapump_create_profile() { :; }
    exapump_validate_connection() { :; }
    mcp_install() { :; }
    mcp_validate() { :; }
    pyexasol_install() { :; }
    pyexasol_validate() { :; }
    exakit_maybe_offer_data_load() { :; }
    exakit_maybe_offer_mcp_setup() { :; }
    exakit_maybe_offer_skills_install() { :; }
    ensure_path_hint() { :; }
    _out="$(kit_shared_steps 3 6 "$ROOT/setup" "$WORK/soft-kit" 2>&1)"
    printf '%s\n' "$_out" | grep -q 'components are missing\|component is missing' && printf 'SPURIOUS' || printf 'silent'
    printf ' %s' "$(manifest_get steps_completed | tr -d '\" []' )" )"
check "a clean run says nothing and marks everything" \
    "silent exapump,mcp,pyexasol,exakit_helper" "$quiet"
echo "release notes travel with the kit:"
mkdir -p "$WORK/wn-kit"
printf '# What is new\n\n## 0.3.0\n\n- the newer thing\n\n## 0.2.0\n\n- the older thing\n' \
    > "$WORK/wn-kit/WHATS-NEW.md"
check "a section is read whole and stops at the next heading" "- the older thing" \
    "$(exakit_whats_new_section "$WORK/wn-kit" 0.2.0 | tr -d '[:space:]' | sed 's/^-*//;s/^/- /;s/\(.\)$/\1/' >/dev/null; \
       exakit_whats_new_section "$WORK/wn-kit" 0.2.0 | grep -v '^$' | head -1)"
check "the later section is separate" "- the newer thing" \
    "$(exakit_whats_new_section "$WORK/wn-kit" 0.3.0 | grep -v '^$' | head -1)"
# Silence, not noise, for the two cases a real upgrade meets.
check "an unknown version is silent" "rc=1" \
    "$(exakit_whats_new_section "$WORK/wn-kit" 9.9.9 >/dev/null 2>&1; printf 'rc=%s' "$?")"
check "a kit copy without the file is silent" "rc=1" \
    "$(exakit_whats_new_section "$WORK" 0.2.0 >/dev/null 2>&1; printf 'rc=%s' "$?")"
# A heading with nothing under it must not print an empty panel.
printf '# What is new\n\n## 0.4.0\n\n\n## 0.3.0\n\n- real\n' > "$WORK/wn-kit/WHATS-NEW.md"
check "an empty section counts as no section" "rc=1" \
    "$(exakit_whats_new_section "$WORK/wn-kit" 0.4.0 >/dev/null 2>&1; printf 'rc=%s' "$?")"

# An installer re-run that moved the kit version says what changed; one that did
# not must stay quiet, or every idempotent re-run reads like an upgrade.
wn_kit_root="$WORK/wn-run-kit"
mkdir -p "$wn_kit_root"
cp "$REAL" "$wn_kit_root/versions.json"
printf '# What is new\n\n## 0.2.0\n\n- upgraded-line-only-here\n' > "$wn_kit_root/WHATS-NEW.md"
wn_run() {
    # The kit copy IS the repo root as far as exakit_repo_root is concerned, as long
    # as kit/mcp exists. Building it that way beats stubbing the resolver - and
    # without it the lookup would fall through to the real WHATS-NEW.md in this
    # checkout, which has a 0.2.0 section and would pass for the wrong reason. The
    # sentinel line below only exists in the fixture.
    ( EXAKIT_HOME="$WORK/wn-home-$1"
      EXAKIT_MANIFEST="$WORK/wn-home-$1/manifest.json"
      EXAKIT_BIN_DIR="$WORK/wn-home-$1/bin"
      mkdir -p "$EXAKIT_HOME/kit/mcp"
      cp "$wn_kit_root/versions.json" "$wn_kit_root/WHATS-NEW.md" "$EXAKIT_HOME/kit/"
      . "$ROOT/setup/lib/pyexasol.sh"
      manifest_init >/dev/null 2>&1
      exapump_install() { :; }; exapump_create_profile() { :; }; exapump_validate_connection() { :; }
      mcp_install() { :; }; mcp_validate() { :; }
      pyexasol_install() { :; }; pyexasol_validate() { :; }
      exakit_maybe_offer_data_load() { :; }
      exakit_maybe_offer_mcp_setup() { :; }
      exakit_maybe_offer_skills_install() { :; }
      ensure_path_hint() { :; }
      EXAKIT_UPGRADED_FROM="$1"
      kit_shared_steps 3 6 "$ROOT/setup" "$wn_kit_root" 2>&1 )
}
has "an upgrading re-run prints the notes" "upgraded-line-only-here" "$(wn_run 0.1.0)"
has "and says where it came from" "upgraded from 0.1.0" "$(wn_run 0.1.0)"
lacks "an unchanged re-run stays quiet" "upgraded-line-only-here" "$(wn_run 0.2.0)"

echo "a hanging container engine cannot stall a version lookup:"
# The failure this prevents: `docker info` and `docker container inspect` do not
# return while Docker Desktop is starting, and an unbounded probe left
# `exakit version` printing nothing for as long as that took.
mkdir -p "$WORK/hang-bin"
printf '#!/bin/sh\nsleep 300\n' > "$WORK/hang-bin/docker"
chmod +x "$WORK/hang-bin/docker"
hang_start="$(date +%s)"
hang="$( PATH="$WORK/hang-bin:$PATH"
    EXAKIT_ENGINE_PROBE_TIMEOUT=2
    unset EXAKIT_NANO_ENGINE
    # detect.sh is where the engine detection lives, and this file does not source
    # it by default: without this the call is a silent "command not found", which
    # looks exactly like a pass.
    . "$ROOT/setup/lib/detect.sh"
    if [ "$(detect_container_runtime)" = "none" ]; then printf 'gave-up'; else printf 'HUNG-OR-FOUND'; fi )"
hang_elapsed=$(( $(date +%s) - hang_start ))
check "a docker that never answers is treated as no engine" "gave-up" "$hang"
if [ "$hang_elapsed" -le 20 ]; then
    check "and it gives up promptly" "prompt" "prompt"
else
    check "and it gives up promptly" "prompt" "took ${hang_elapsed}s"
fi
# The tag probe must still answer, from the record, while the engine hangs.
HG="$WORK/hang-home"
mkdir -p "$HG/kit/mcp"
cp "$REAL" "$HG/kit/versions.json"
printf '{"manifest_version":1,"runtime":{"type":"nano","image":"docker.io/exasol/nano:2026.1.0-nano.9"}}\n' \
    > "$HG/manifest.json"
hang_tag="$( EXAKIT_HOME="$HG"
    EXAKIT_MANIFEST="$HG/manifest.json"
    PATH="$WORK/hang-bin:$PATH"
    EXAKIT_ENGINE_PROBE_TIMEOUT=2
    nano_engine() { printf 'docker\n'; }
    nano_resolve_names() { :; }
    exakit_installed_nano_tag )"
check "the recorded tag answers instead" "2026.1.0-nano.9" "$hang_tag"
# The bounded runner's own contract, independent of docker.
bounded="$( if exakit_run_bounded 2 sleep 30 >/dev/null 2>&1; then printf 'NO-CUTOFF'; else printf "rc=$?"; fi
            printf ' '
            if exakit_run_bounded 5 printf 'ok' >/dev/null 2>&1; then printf 'fast-ok'; else printf 'FAST-FAILED'; fi )"
check "the runner cuts off a hang and passes a quick command through" "rc=124 fast-ok" "$bounded"

echo "the manifest date reads as a date:"
# A calendar date must never be shifted into local time: TZ is set to a zone west
# of UTC to prove the day does not move backwards.
dates="$( TZ="Pacific/Honolulu"
    printf '%s|' "$(exakit_format_manifest_date 2026-07-29)"
    printf '%s|' "$(exakit_format_manifest_date 2026-01-09)"
    printf '%s|' "$(exakit_format_manifest_date 2026-12-31)"
    printf '%s|' "$(exakit_format_manifest_date not-a-date)"
    printf '%s|' "$(exakit_format_manifest_date 2026-13-01)"
    printf '%s' "$(exakit_format_manifest_date '')" )"
check "formatted, zero-stripped, and passed through when unparseable" \
    "July 29, 2026|January 9, 2026|December 31, 2026|not-a-date|2026-13-01|" "$dates"
source_line="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_versions_source_line 2>&1 )"
has "and the source line spells it out" "updated July 29, 2026" "$source_line"
lacks "with no ISO date left" "2026-07-29" "$source_line"

echo "after-command notice (severity-gated, once a day, stderr only):"
NT="$WORK/notice-home"
mkdir -p "$NT/kit/mcp" "$NT/cache" "$NT/bin"
cp "$REAL" "$NT/kit/versions.json"
printf '#!/bin/sh\necho "exapump 0.11.2"\n' > "$NT/bin/exapump"
chmod +x "$NT/bin/exapump"
cat > "$NT/manifest.json" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": {
    "version": "0.2.0"
  },
  "runtime": {
    "type": "nano",
    "image": "docker.io/exasol/nano:2026.2.0-nano.2"
  },
  "components": {
    "exapump": {
      "version": "0.11.2",
      "path": "$NT/bin/exapump"
    },
    "mcp_server": {
      "version": "1.10.1"
    }
  },
  "steps_completed": []
}
EOF
# Advertise one recommended light bump and one critical heavy bump.
python3 - "$REAL" "$WORK/notice-versions.json" <<'PY'
import collections, json, sys
with open(sys.argv[1]) as handle:
    doc = json.load(handle, object_pairs_hook=collections.OrderedDict)
doc["components"]["exapump"]["version"] = "0.12.0"
doc["components"]["exapump"]["severity"] = "recommended"
doc["components"]["nano"]["version"] = "2026.3.0-nano.1"
doc["components"]["nano"]["severity"] = "critical"
# A genuine normal-severity bump: the recorded install is on 1.10.1, so this is
# pending. Without the version change there was nothing to announce, and an
# assertion about it would pass or fail for the wrong reason.
doc["components"]["mcp"]["version"] = "1.11.0"
doc["components"]["mcp"]["severity"] = "normal"
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
PY

# The notice refuses to speak unless stderr is a terminal, so the harness has to
# provide one. script(1) does that, with two different command lines in the wild:
# BSD/macOS takes the command as arguments, util-linux takes it after -c.
NOTICE_PTY="none"
if command -v script >/dev/null 2>&1; then
    # stdin must be /dev/null: macOS script(1) refuses to start when its stdin is
    # a socket, which is what a CI or agent shell hands it.
    if script -q /dev/null /bin/echo probe </dev/null >/dev/null 2>&1; then
        NOTICE_PTY="bsd"
    elif script -q -c "/bin/echo probe" /dev/null </dev/null >/dev/null 2>&1; then
        NOTICE_PTY="util-linux"
    fi
fi

# notice <versions-doc> [statements] — run the notice on a pty and return what it
# wrote, stripped of the line breaks the pty inserts at its 80-column edge (a wrap
# must not be able to hide a phrase from an assertion) and of script(1)'s own EOT.
notice() {
    _n_doc="$1"
    _n_extra="${2:-}"
    cp "$_n_doc" "$NT/kit/versions.json"
    cat > "$WORK/notice-run.sh" <<EOF
EXAKIT_NO_FANCY=1
EXAKIT_HOME='$NT'
EXAKIT_MANIFEST='$NT/manifest.json'
EXAKIT_VERSIONS_CACHE='$NT/cache/versions.json'
EXAKIT_VERSIONS_URL='http://offline.invalid/versions.json'
EXAKIT_NOTICE_STATE='$NT/cache/notice-state.json'
. '$ROOT/setup/lib/common.sh'
_EXAKIT_VERSIONS_DOC=''; _EXAKIT_VERSIONS_SOURCE=''
$_n_extra
exakit_notice_after_command
EOF
    case "$NOTICE_PTY" in
        bsd)        script -q /dev/null /bin/bash "$WORK/notice-run.sh" </dev/null 2>&1 ;;
        util-linux) script -q -c "/bin/bash $WORK/notice-run.sh" /dev/null </dev/null 2>&1 ;;
        *)          printf '' ;;
    esac | tr -d '\r\n\004\010' | sed 's/\^D//g'
}

if [ "$NOTICE_PTY" = "none" ]; then
    # Without a pty the notice cannot be observed at all (that is its own gate).
    for _skipped in "a recommended light bump is announced as recommended" "with the cheap command" \
                    "a critical heavy bump is announced as critical" "as a database stop, not a one-liner" \
                    "and never told to just run update" "the kill switch is advertised" \
                    "a normal-severity bump is announced too" \
                    "and it speaks again on the very next command" \
                    "an explicit interval still shows it once" \
                    "and then holds off for the interval" \
                    "a routine bump is announced" "without claiming it is recommended" \
                    "or critical" "the kill switch silences it" \
                    "latest policy has no severities to gate on"; do
        check "$_skipped" "skipped" "skipped"
    done
else
rm -f "$NT/cache/notice-state.json"
flagged="$(notice "$WORK/notice-versions.json")"
has "a recommended light bump is announced as recommended" \
    "A recommended update is available for exapump" "$flagged"
has "with the cheap command" "apply in seconds:  exakit update" "$flagged"
has "a critical heavy bump is announced as critical" \
    "A critical update is available for nano" "$flagged"
has "as a database stop, not a one-liner" "requires stopping the database" "$flagged"
lacks "and never told to just run update" "nano — apply in seconds" "$flagged"
has "the kill switch is advertised" "EXAKIT_NO_UPDATE_NOTICE=1" "$flagged"
# Every severity is announced now, so the routine one appears too - and appears
# WITHOUT borrowing urgency it was never given.
has "a normal-severity bump is announced too" "mcp" "$flagged"

repeat="$(notice "$WORK/notice-versions.json")"
has "and it speaks again on the very next command" \
    "A recommended update is available for exapump" "$repeat"

# The throttle is still there for anyone who wants it, just not the default. It
# needs a clean slate: the runs above have already recorded a "last shown".
rm -f "$NT/cache/notice-state.json"
throttled_first="$(notice "$WORK/notice-versions.json" 'EXAKIT_NOTICE_INTERVAL=86400')"
has "an explicit interval still shows it once" \
    "A recommended update is available for exapump" "$throttled_first"
throttled_again="$(notice "$WORK/notice-versions.json" 'EXAKIT_NOTICE_INTERVAL=86400')"
check "and then holds off for the interval" "" \
    "$(printf '%s' "$throttled_again" | tr -d '[:space:]')"
rm -f "$NT/cache/notice-state.json"

# The shipped document against an install that is behind it: a routine bump, which
# must now be mentioned, and must not call itself recommended or critical.
only_normal="$(notice "$REAL")"
has "a routine bump is announced" "update is available for exapump" "$only_normal"
lacks "without claiming it is recommended" "A recommended" "$only_normal"
lacks "or critical" "A critical" "$only_normal"

# The plan cache: printed every run, computed rarely. Counted by a probe stub that
# appends a line each time it is asked, which is the only way to tell "said the same
# thing again" from "worked it out again".
# Counted at the exapump stub itself rather than by overriding a reader: the test
# then cannot pass because it guessed the wrong internal function name.
rm -f "$NT/cache/notice-plan" "$NT/cache/notice-state.json" "$WORK/probe-count"
printf '#!/bin/sh\nprintf x >> "%s"\necho "exapump 0.11.2"\n' "$WORK/probe-count" > "$NT/bin/exapump"
chmod +x "$NT/bin/exapump"
probe_count() { [ -f "$WORK/probe-count" ] && wc -c < "$WORK/probe-count" | tr -d ' ' || printf 0; }
cached_first="$(notice "$WORK/notice-versions.json")"
has "the first run still says its piece" "update is available" "$cached_first"
probes_after_first="$(probe_count)"
check "and it did probe" "yes" "$([ "$probes_after_first" -gt 0 ] && printf yes || printf no)"
plan_stamp() { sed -n 's/^computed_at=//p' "$NT/cache/notice-plan" 2>/dev/null | head -1; }
stamp_after_first="$(plan_stamp)"
cached_second="$(notice "$WORK/notice-versions.json")"
has "the second run says the same thing" "update is available" "$cached_second"
# Served from the plan, not worked out again. The probe count is no longer the signal:
# the cached path deliberately re-probes its pending candidates so it can never repeat
# an update that has already been taken.
check "and did not recompute the verdict" "$stamp_after_first" "$(plan_stamp)"

# A cached plan must not repeat an update the user has already taken. This is the
# real-world failure it fixes: a plan computed while MCP was mid-install kept saying
# "an update is available for mcp" while `exakit update-check`, run seconds later in
# the same session, reported everything current.
plan_detail="$(sed -n 's/^light=//p' "$NT/cache/notice-plan" | head -1)"
has "the plan records the advertised version with each candidate" "exapump:" "$plan_detail"
# The stub catches up. Nothing else changes -- not the manifest, not the document --
# which is precisely the blind spot a signature alone cannot see.
printf '#!/bin/sh\nprintf x >> "%s"\necho "exapump 0.12.0"\n' "$WORK/probe-count" > "$NT/bin/exapump"
chmod +x "$NT/bin/exapump"
caught_up="$(notice "$WORK/notice-versions.json")"
lacks "a candidate that caught up is dropped" "for exapump" "$caught_up"
has "and the ones still behind are kept" "mcp" "$caught_up"
# Back to behind, so what follows sees the same fixture as before.
printf '#!/bin/sh\nprintf x >> "%s"\necho "exapump 0.11.2"\n' "$WORK/probe-count" > "$NT/bin/exapump"
chmod +x "$NT/bin/exapump"

# update-check computes the truth the long way, so it retires the plan: nothing it
# just contradicted may be repeated by the next command.
notice "$WORK/notice-versions.json" >/dev/null
retired="$( EXAKIT_HOME="$NT"
    EXAKIT_MANIFEST="$NT/manifest.json"
    EXAKIT_NOTICE_PLAN="$NT/cache/notice-plan"
    EXAKIT_VERSIONS_CACHE="$NT/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    [ -f "$EXAKIT_NOTICE_PLAN" ] && printf 'had-plan '
    exakit_print_update_check all >/dev/null 2>&1
    [ -f "$EXAKIT_NOTICE_PLAN" ] && printf 'STILL-THERE' || printf 'retired' )"
check "update-check retires the cached plan" "had-plan retired" "$retired"

# A TTL of zero is how you ask for the old behaviour of always recomputing.
notice "$WORK/notice-versions.json" 'EXAKIT_NOTICE_PLAN_TTL=0' >/dev/null
check "a zero TTL recomputes every time" "yes" \
    "$([ "$(probe_count)" -gt "$probes_after_first" ] && printf yes || printf no)"

# Applying an update must silence it on the NEXT command, not fifteen minutes later.
# The manifest is what every update rewrites, so a change to it retires the plan --
# and it has to work when both happen inside the same second, which is why the plan
# is keyed on content and not on a timestamp.
rm -f "$NT/cache/notice-plan"
notice "$WORK/notice-versions.json" >/dev/null
plan_sig_before="$(sed -n 's/^sig=//p' "$NT/cache/notice-plan" | head -1)"
printf ' ' >> "$NT/manifest.json"
plan_still_fresh="$( EXAKIT_HOME="$NT"
    EXAKIT_MANIFEST="$NT/manifest.json"
    EXAKIT_NOTICE_PLAN="$NT/cache/notice-plan"
    EXAKIT_VERSIONS_CACHE="$NT/cache/versions.json"
    if _exakit_notice_plan_fresh; then printf 'STILL-FRESH'; else printf 'retired'; fi )"
check "a rewritten manifest retires the plan within the same second" "retired" "$plan_still_fresh"
check "the plan records what it was derived from" "yes" \
    "$([ -n "$plan_sig_before" ] && printf yes || printf no)"

# The bookkeeping must not leak: cksum on a missing cache file used to make the
# SHELL print a failed-redirection error, straight past the notice's own stderr.
no_cache_leak="$( EXAKIT_HOME="$NT"
    EXAKIT_MANIFEST="$NT/manifest.json"
    EXAKIT_VERSIONS_CACHE="$WORK/definitely-not-here.json"
    _exakit_notice_signature 2>&1 >/dev/null )"
check "a missing versions cache prints nothing" "" "$no_cache_leak"

kill_switch="$(notice "$WORK/notice-versions.json" 'EXAKIT_NO_UPDATE_NOTICE=1')"
check "the kill switch silences it" "" "$(printf '%s' "$kill_switch" | tr -d '[:space:]')"

latest_policy="$(notice "$WORK/notice-versions.json" 'EXAKIT_VERSION_POLICY=latest')"
check "latest policy has no severities to gate on" "" "$(printf '%s' "$latest_policy" | tr -d '[:space:]')"
fi

# The gate that keeps it out of logs and pipes: no tty on stderr, no notice.
piped="$( EXAKIT_HOME="$NT"
    EXAKIT_MANIFEST="$NT/manifest.json"
    EXAKIT_VERSIONS_CACHE="$NT/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    EXAKIT_NOTICE_STATE="$NT/cache/notice-state.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    cp "$WORK/notice-versions.json" "$NT/kit/versions.json"
    exakit_notice_after_command 2>&1 )"
check "no terminal on stderr, no notice" "" "$(printf '%s' "$piped" | tr -d '[:space:]')"

# The commands that must never carry it, and the ones that must.
if grep -q '_with_notice cmd_status' "$ROOT/setup/exakit" && \
   grep -q '_with_notice cmd_mcp_doctor' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_update' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_version' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_uninstall' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice usage' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_catalog' "$ROOT/setup/exakit"; then
    check "hooked into the right commands only" "yes" "yes"
else
    check "hooked into the right commands only" "yes" "no"
fi
# A notice may not change what a command reported to a script.
rc_preserved="$( _with_notice() { "$@"; _wn_rc=$?; exakit_notice_after_command || true; return $_wn_rc; }
    exakit_notice_after_command() { printf 'notice\n' >&2; return 0; }
    _with_notice false; printf 'rc=%s' "$?" )"
check "the command's exit status survives the notice" "rc=1" "$rc_preserved"

echo "Kit 2 awareness (the block's absence is the launch switch):"
# The shipped versions.json has no kit2 block, and nothing may advertise Kit 2
# until a reviewed pull request adds one. This is the gate, asserted directly.
check "the shipped manifest advertises no Kit 2" "absent" \
    "$(exakit_versions_value kit2.version "$REAL" 2>/dev/null || printf absent)"
K2="$WORK/kit2-home"
mkdir -p "$K2/kit/mcp" "$K2/cache"
cat > "$K2/manifest.json" <<'EOF'
{
  "manifest_version": 1,
  "kit_level": 1,
  "kit": {
    "version": "0.2.0"
  },
  "runtime": {
    "type": "nano",
    "image": "docker.io/exasol/nano:2026.2.0-nano.2"
  },
  "components": {},
  "steps_completed": []
}
EOF
cp "$REAL" "$K2/kit/versions.json"

# kit2_table <versions-doc> [statements] — the table as a Kit 1 (or stubbed Kit 2)
# machine would render it against the given advertised document.
kit2_table() (
    EXAKIT_HOME="$K2"
    EXAKIT_MANIFEST="$K2/manifest.json"
    EXAKIT_VERSIONS_CACHE="$K2/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    cp "$1" "$K2/kit/versions.json"
    eval "${2:-}"
    exakit_print_update_check all 2>&1
)

no_kit2="$(kit2_table "$REAL")"
lacks "no kit2 block -> not a word about Kit 2" "Kit 2" "$no_kit2"
lacks "and no kit2 row" "kit2 " "$no_kit2"

# Enabling the path is exactly one edit: add the block.
python3 - "$REAL" "$WORK/with-kit2.json" <<'PY'
import json, sys, collections
with open(sys.argv[1]) as handle:
    doc = json.load(handle, object_pairs_hook=collections.OrderedDict)
doc["kit2"] = collections.OrderedDict(
    [("version", "0.1.0"), ("min_kit_version", "0.2.0"), ("severity", "normal"),
     ("note", "Trusted AI Workflow add-on")])
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
PY
with_kit2="$(kit2_table "$WORK/with-kit2.json")"
has "the block turns the discovery line on" "Kit 2 (Trusted AI Workflow add-on) is available" "$with_kit2"
has "and names the command" "exakit upgrade-kit2" "$with_kit2"
lacks "a Kit 1 machine gets no kit2 row" "kit2       " "$with_kit2"

# A kit too old for the add-on must not be told to add it.
python3 - "$WORK/with-kit2.json" "$WORK/with-kit2-future.json" <<'PY'
import json, sys, collections
with open(sys.argv[1]) as handle:
    doc = json.load(handle, object_pairs_hook=collections.OrderedDict)
doc["kit2"]["min_kit_version"] = "9.9.9"
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
PY
future_kit2="$(kit2_table "$WORK/with-kit2-future.json")"
lacks "an unsatisfied min_kit_version keeps it hidden" "Kit 2 (" "$future_kit2"

# Once Kit 2 is installed the discovery line gives way to a real row.
level2="$(kit2_table "$WORK/with-kit2.json" \
    'manifest_get() { case "$1" in kit_level) printf "2\n" ;;
                                   kit2.version) printf "0.1.0\n" ;;
                                   runtime.type) printf "nano\n" ;;
                                   kit.version) printf "0.2.0\n" ;;
                                   *) return 1 ;; esac; }')"
has "Kit 2 installed -> its own row" "kit2       0.1.0" "$level2"
lacks "and no discovery line any more" "is available — add it with" "$level2"
level2_behind="$(kit2_table "$WORK/with-kit2.json" \
    'manifest_get() { case "$1" in kit_level) printf "2\n" ;;
                                   kit2.version) printf "0.0.9\n" ;;
                                   runtime.type) printf "nano\n" ;;
                                   kit.version) printf "0.2.0\n" ;;
                                   *) return 1 ;; esac; }')"
has "an older bundle offers the update" "exakit update kit2" "$level2_behind"

# `exakit update kit2` is only meaningful once Kit 2 is installed, and it never
# invents assets the kit copy does not carry.
kit2_update_at_level1="$( EXAKIT_HOME="$K2"
    EXAKIT_MANIFEST="$K2/manifest.json"
    ( exakit_update_kit2 2>&1 ) )"
has "updating Kit 2 at Kit 1 explains itself" "Kit 2 is not installed" "$kit2_update_at_level1"
kit2_update_behind="$( EXAKIT_HOME="$K2"
    EXAKIT_MANIFEST="$K2/manifest.json"
    EXAKIT_VERSIONS_CACHE="$K2/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    cp "$WORK/with-kit2.json" "$K2/kit/versions.json"
    mkdir -p "$K2/kit/upgrade"
    printf '#!/usr/bin/env bash\necho STAGED\n' > "$K2/kit/upgrade/upgrade-kit2.sh"
    manifest_get() { [ "$1" = kit_level ] && printf '2\n' && return 0; return 1; }
    # This kit copy carries an older bundle than the manifest advertises.
    exakit_kit2_bundled_version() { printf '0.0.9\n'; }
    exakit_update_kit2 2>&1 )"
has "a kit copy behind the advertised bundle says so" "update it first" "$kit2_update_behind"
lacks "and stages nothing" "STAGED" "$kit2_update_behind"
kit2_update_current="$( EXAKIT_HOME="$K2"
    EXAKIT_MANIFEST="$K2/manifest.json"
    EXAKIT_VERSIONS_CACHE="$K2/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    manifest_get() { [ "$1" = kit_level ] && printf '2\n' && return 0; return 1; }
    exakit_kit2_bundled_version() { printf '0.1.0\n'; }
    exakit_update_kit2 2>&1 )"
has "a current kit copy re-stages the assets" "STAGED" "$kit2_update_current"
cp "$REAL" "$K2/kit/versions.json"

echo "kit self-update (stubbed download, no network):"
# A real tarball of a fake kit: the download is stubbed, but everything after it —
# unpacking, the required-file gate, the staged-version gate, the backup/swap and
# the recorded identity — is the production code path.
# make_kit_tarball <dest.tgz> <kit-version> [omit-path]
make_kit_tarball() {
    _mk_dest="$1"
    _mk_version="$2"
    _mk_omit="${3:-}"
    # Keyed by the archive being built, not by the version: two archives of the
    # same version (one deliberately incomplete) must not share a source tree.
    _mk_src="$WORK/kit-src-$(basename "$_mk_dest" | tr -c 'A-Za-z0-9' '_')"
    rm -rf "$_mk_src"
    MK_LAST_SRC="$_mk_src/repo-main"
    mkdir -p "$_mk_src/repo-main/setup/lib"
    for _mk_file in setup/exakit setup/lib/common.sh setup/lib/runtime-nano.sh \
                    setup/lib/runtime-personal.sh setup/lib/exapump.sh setup/lib/mcp.sh \
                    setup/exakit.ps1 setup/lib/exakit-common.ps1; do
        [ "$_mk_file" = "$_mk_omit" ] && continue
        printf '# fake %s from kit %s\n' "$_mk_file" "$_mk_version" > "$_mk_src/repo-main/$_mk_file"
    done
    if [ "$_mk_omit" != "versions.json" ]; then
        sed 's/"version": "0.2.0"/"version": "'"$_mk_version"'"/' "$REAL" > "$_mk_src/repo-main/versions.json"
    fi
    # Release notes for the version this archive carries: the update prints them
    # from the copy it just staged, so they have to travel with it.
    printf '# What is new\n\n## %s\n\n- a line only kit %s could print\n' \
        "$_mk_version" "$_mk_version" > "$_mk_src/repo-main/WHATS-NEW.md"
    ( cd "$_mk_src" && tar -czf "$_mk_dest" repo-main )
}

# self_update <served-tarball> <advertised> — run the real updater against a
# sandbox kit home and report what it did.
self_update() (
    EXAKIT_HOME="$WORK/su-home"
    EXAKIT_MANIFEST="$WORK/su-home/manifest.json"
    EXAKIT_BIN_DIR="$WORK/su-home/bin"
    rm -rf "$EXAKIT_HOME"
    mkdir -p "$EXAKIT_HOME/kit/mcp" "$EXAKIT_BIN_DIR"
    printf 'the kit copy that is about to be replaced\n' > "$EXAKIT_HOME/kit/marker.txt"
    cp "$REAL" "$EXAKIT_HOME/kit/versions.json"
    manifest_init >/dev/null 2>&1
    manifest_set kit.version 0.2.0 >/dev/null 2>&1
    SU_ADVERTISED="$2"
    SU_SERVE="$1"
    exakit_component_available() { printf '%s\n' "$SU_ADVERTISED"; }
    curl() {
        _co=""
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o) _co="$2"; shift 2 ;;
                https://*) _su_url="$1"; shift ;;
                *) shift ;;
            esac
        done
        # Only the main branch archive exists in this world; the tag fallbacks 404.
        case "$_su_url" in
            *refs/heads/main.tar.gz) cp "$SU_SERVE" "$_co" ;;
            *) return 22 ;;
        esac
    }
    ( exakit_update_self >"$WORK/su-out.txt" 2>&1 ); printf 'rc=%s ' "$?"
    printf 'version=%s source=%s ' "$(manifest_get kit.version 2>/dev/null || printf none)" \
        "$(manifest_get kit.source 2>/dev/null || printf none)"
    [ -f "$EXAKIT_HOME/kit/versions.json" ] && printf 'kit-present ' || printf 'NO-KIT '
    grep -q 'fake setup/exakit ' "$EXAKIT_HOME/kit/setup/exakit" 2>/dev/null && printf 'replaced ' || printf 'not-replaced '
    [ -x "$EXAKIT_BIN_DIR/exakit" ] && printf 'cli-installed ' || printf 'NO-CLI '
    ls -d "$EXAKIT_HOME"/kit.backup-* >/dev/null 2>&1 && printf 'backup-kept' || printf 'NO-BACKUP'
)

make_kit_tarball "$WORK/kit-0.3.0.tgz" 0.3.0
PS_KIT_SRC="$MK_LAST_SRC"       # reused by the PowerShell self-update check below
# The recorded source is the kit repository the library defaults to, not a literal:
# which repository that is can be retargeted (a fork, for testing), and none of
# these checks are about its name.
check "a newer kit replaces the copy and records itself" \
    "rc=0 version=0.3.0 source=$EXAKIT_KIT_REPO@main kit-present replaced cli-installed backup-kept" \
    "$(self_update "$WORK/kit-0.3.0.tgz" 0.3.0)"

# The raw endpoint can be minutes ahead of the branch archive: record what landed.
make_kit_tarball "$WORK/kit-0.2.5.tgz" 0.2.5
lag_state="$(self_update "$WORK/kit-0.2.5.tgz" 0.3.0)"
check "a lagging archive records the version that landed" \
    "rc=0 version=0.2.5 source=$EXAKIT_KIT_REPO@main kit-present replaced cli-installed backup-kept" \
    "$lag_state"
has "and says the manifest was ahead" "not the advertised 0.3.0" "$(cat "$WORK/su-out.txt")"

# An archive without versions.json is refused: the new copy would have no offline
# version tier and could not say what it is.
make_kit_tarball "$WORK/kit-no-manifest.tgz" 0.3.0 versions.json
check "an archive without versions.json is refused" \
    "rc=1 version=0.2.0 source=none kit-present not-replaced NO-CLI NO-BACKUP" \
    "$(self_update "$WORK/kit-no-manifest.tgz" 0.3.0)"
has "and says the kit copy was left alone" "existing kit copy was left untouched" "$(cat "$WORK/su-out.txt")"

# One of v0.1.0's eight required paths missing must fail the same way.
make_kit_tarball "$WORK/kit-no-common.tgz" 0.3.0 setup/lib/common.sh
check "an archive missing a v0.1.0 required file is refused" \
    "rc=1 version=0.2.0 source=none kit-present not-replaced NO-CLI NO-BACKUP" \
    "$(self_update "$WORK/kit-no-common.tgz" 0.3.0)"

echo "Windows parity (versions manifest):"
if command -v pwsh >/dev/null 2>&1; then
    PS_HOME="$WORK/ps-home"
    mkdir -p "$PS_HOME/kit/mcp" "$PS_HOME/cache"
    cp "$REAL" "$PS_HOME/kit/versions.json"
    # A cached copy that differs from the kit copy proves which one is read. The
    # sentinel cannot coincide with whatever the document advertises today.
    PS_CACHED_EXAPUMP="0.0.0-from-the-cache"
    python3 - "$REAL" "$PS_HOME/cache/versions.json" "$PS_CACHED_EXAPUMP" <<'PS_CACHE_PY'
import json, sys
doc = json.load(open(sys.argv[1]))
doc["components"]["exapump"]["version"] = sys.argv[3]
with open(sys.argv[2], "w") as handle:
    json.dump(doc, handle, indent=2)
    handle.write("\n")
PS_CACHE_PY
    touch "$PS_HOME/cache/versions.json"
    ps_state="$(EXAKIT_HOME="$PS_HOME" EXAKIT_BIN_DIR="$PS_HOME/bin" \
        EXAKIT_VERSIONS_CACHE="$PS_HOME/cache/versions.json" \
        EXAKIT_VERSIONS_URL="https://127.0.0.1:1/versions.json" \
        VM_ROOT="$ROOT" VM_FIX="$FIX" pwsh -NoProfile -Command '
        . (Join-Path $env:VM_ROOT "setup/lib/exakit-common.ps1")
        $real = Join-Path $env:VM_ROOT "versions.json"
        $out = @()
        $out += (Test-ExakitVersionsDoc -Path $real)
        $out += (Test-ExakitVersionsDoc -Path (Join-Path $env:VM_FIX "schema2.json"))
        $out += (Test-ExakitVersionsDoc -Path (Join-Path $env:VM_FIX "bad-digest.json"))
        $out += (Test-ExakitVersionsDoc -Path (Join-Path $env:VM_FIX "corrupt.json"))
        $out += (Test-ExakitVersionsDoc -Path (Join-Path $env:VM_FIX "kit2.json"))
        $out += (Get-ExakitVersionsValue -Path "components.exapump.version" -DocPath $real)
        $out += (Get-ExakitVersionsValue -Path "components.exapump.sha256.windows-x86_64" -DocPath $real).Substring(0, 8)
        $out += (Get-ExakitKitBundledVersion)
        # The TTL keeps a normal command off the network; -Force cannot reach
        # 127.0.0.1:1, and that failure must leave the cached copy in place.
        $out += (Update-ExakitVersionsCache)
        $out += (Update-ExakitVersionsCache -Force)
        $out += (Get-ExakitVersionsValue -Path "components.exapump.version")
        $out += (Get-ExakitVersionsSource)
        Write-Output ($out -join " ")
    ' | tail -1 | tr -d '\r')"
    check "powershell(versions_manifest)" \
        "0 2 1 1 0 $(shipped components.exapump.version) $(shipped components.exapump.sha256.windows-x86_64 | cut -c1-8) $(shipped kit.version) 2 1 $PS_CACHED_EXAPUMP cache" \
        "$ps_state"
    ps_http="$(EXAKIT_HOME="$PS_HOME" EXAKIT_BIN_DIR="$PS_HOME/bin" \
        EXAKIT_VERSIONS_CACHE="$PS_HOME/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://example.invalid/versions.json" \
        VM_ROOT="$ROOT" pwsh -NoProfile -Command '
        . (Join-Path $env:VM_ROOT "setup/lib/exakit-common.ps1")
        Write-Output (Update-ExakitVersionsCache -Force)
    ' | tail -1 | tr -d '\r')"
    check "powershell(non_https_refused)" "1" "$ps_http"

    # The table is mirrored code, so compare the real thing: run the PowerShell
    # CLI against the SAME fixture install and manifest the bash rows came from.
    # Both sides must reach the same verdict for every row.
    ps_table="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" update-check all 2>&1 | tr -d '\r')"
    check "powershell: Tagged column" \
        "Component Installed Tagged Severity Action" "$(row "$ps_table" Component)"
    has "powershell: kit row is comparable" "exakit     0.2.0             0.2.0" "$ps_table"
    has "powershell: installed stays installed" "exapump    0.13.0" "$ps_table"
    has "powershell: heavy runtime row" "exakit update runtime (heavy)" "$ps_table"
    check "powershell: older advertised version" \
        "exapump 0.13.0 0.12.0 recommended none" "$(row "$ps_table" exapump)"
    has "powershell: critical severity" "critical" "$ps_table"
    has "powershell: maintainer note" "0.13.0 mis-detects CSV headers" "$ps_table"
    has "powershell: repair action for a missing component" "exakit update pyexasol" "$ps_table"
    # The decisions the bash rows above make must be the same ones here.
    ps_personal="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" update-check personal 2>&1 | tr -d '\r')"
    has "powershell: an absent runtime is listed" "personal   not installed" "$ps_personal"
    lacks "powershell: but never offered for installation" "exakit update personal" "$ps_personal"
    ps_pinned="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" EXAKIT_VERSION_POLICY=pinned \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" update-check exapump 2>&1 | tr -d '\r')"
    has "powershell: pinned policy uses the fallback" "built-in fallbacks" "$ps_pinned"
    ps_override="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        EXAKIT_EXAPUMP_VERSION=9.9.9 \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" update-check exapump 2>&1 | tr -d '\r')"
    has "powershell: an override is credited" "EXAKIT_* environment overrides" "$ps_override"
    lacks "powershell: and withholds the maintainer note" "mis-detects CSV headers" "$ps_override"
    # The Windows self-update, for real: the download cmdlet is shadowed by a
    # function in the same session, so everything after it - the required-file
    # gate, the staged-version gate, the backup/swap, the shim and the recorded
    # identity - is the production path. (The deferred swap is Windows-only: it
    # exists because Windows will not rename a directory whose files are open, so
    # it cannot be provoked here.)
    PS_SU="$WORK/ps-su"
    rm -rf "$PS_SU"
    mkdir -p "$PS_SU/home/kit/mcp" "$PS_SU/home/bin"
    printf 'the kit copy that is about to be replaced\n' > "$PS_SU/home/kit/marker.txt"
    cp "$REAL" "$PS_SU/home/kit/versions.json"
    python3 - "$PS_KIT_SRC" "$PS_SU/kit-0.3.0.zip" <<'PY'
import pathlib, sys, zipfile
src, dest = pathlib.Path(sys.argv[1]), sys.argv[2]
with zipfile.ZipFile(dest, "w") as archive:
    for path in sorted(src.rglob("*")):
        if path.is_file():
            archive.write(path, pathlib.Path("repo-main") / path.relative_to(src))
PY
    ps_self="$(EXAKIT_HOME="$PS_SU/home" EXAKIT_BIN_DIR="$PS_SU/home/bin" \
        VM_ROOT="$ROOT" SU_ZIP="$PS_SU/kit-0.3.0.zip" pwsh -NoProfile -Command '
        . "$env:VM_ROOT/setup/lib/exakit-common.ps1"
        # Only the main-branch archive exists in this world; the tags 404.
        function Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec, $UserAgent)
            if ($Uri -notlike "*refs/heads/main.zip") { throw "404" }
            Copy-Item -Force $env:SU_ZIP $OutFile
        }
        Initialize-ExakitManifest
        Set-ExakitManifestValue "kit.version" "0.2.0"
        Update-ExakitSelf -Advertised "0.3.0" -Installed "0.2.0" | Out-Null
        $kit = Join-Path $env:EXAKIT_HOME "kit"
        $out = @()
        $out += (Get-ExakitManifestValue "kit.version")
        $out += (Get-ExakitManifestValue "kit.source")
        if (Test-Path (Join-Path $kit "versions.json")) { $out += "kit-present" } else { $out += "NO-KIT" }
        if ((Get-Content -Raw (Join-Path $kit "setup/exakit")) -like "*fake setup/exakit*") { $out += "replaced" } else { $out += "not-replaced" }
        if (Test-Path (Join-Path $env:EXAKIT_BIN_DIR "exakit.cmd")) { $out += "shim-written" } else { $out += "NO-SHIM" }
        if (Get-ChildItem -Path $env:EXAKIT_HOME -Filter "kit.backup-*" -ErrorAction SilentlyContinue) { $out += "backup-kept" } else { $out += "NO-BACKUP" }
        Write-Output ($out -join " ")
    ' 2>&1 | tail -1 | tr -d '\r')"
    # Nothing above sets EXAKIT_KIT_REPO for pwsh, so the slug in this line is the
    # PowerShell default measured against the bash one: the two must not drift.
    check "powershell(self_update)" \
        "0.3.0 $EXAKIT_KIT_REPO@main kit-present replaced shim-written backup-kept" \
        "$ps_self"
    # The notice is mirrored code and its wording carries the cost of the update, so
    # compare the real thing against the same fixture the bash lines came from.
    if [ "$NOTICE_PTY" != "none" ]; then
        rm -f "$NT/cache/notice-state.json"
        cp "$WORK/notice-versions.json" "$NT/kit/versions.json"
        cat > "$WORK/ps-notice.ps1" <<'PSEOF'
$env:EXAKIT_HOME = $env:NT
$env:EXAKIT_BIN_DIR = "$env:NT/bin"
$env:EXAKIT_VERSIONS_CACHE = "$env:NT/cache/versions.json"
$env:EXAKIT_VERSIONS_URL = "http://offline.invalid/versions.json"
$env:EXAKIT_NOTICE_STATE = "$env:NT/cache/notice-state.json"
. "$env:VM_ROOT/setup/lib/exakit-common.ps1"
# The component readers live in the CLI; load it with a harmless command.
. "$env:VM_ROOT/setup/exakit.ps1" -Command "help" *> $null
Show-ExakitUpdateNotice
PSEOF
        case "$NOTICE_PTY" in
            bsd) ps_notice="$(NT="$NT" VM_ROOT="$ROOT" script -q /dev/null                     pwsh -NoProfile -File "$WORK/ps-notice.ps1" </dev/null 2>&1)" ;;
            *)   ps_notice="$(NT="$NT" VM_ROOT="$ROOT" script -q                     -c "pwsh -NoProfile -File $WORK/ps-notice.ps1" /dev/null </dev/null 2>&1)" ;;
        esac
        ps_notice="$(printf '%s' "$ps_notice" | tr -d '\r\n\004\010' | sed 's/\^D//g')"
        has "powershell: recommended light bump" "A recommended update is available for exapump" "$ps_notice"
        has "powershell: critical heavy bump" "A critical update is available for nano" "$ps_notice"
        has "powershell: the heavy line names the cost" "requires stopping the database" "$ps_notice"
        cp "$REAL" "$NT/kit/versions.json"
    else
        check "powershell: recommended light bump" "skipped" "skipped"
        check "powershell: critical heavy bump" "skipped" "skipped"
        check "powershell: the heavy line names the cost" "skipped" "skipped"
    fi
    ps_version="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" version 2>&1 | tr -d '\r')"
    has "powershell: version reports the kit version" "Kit version:    0.2.0" "$ps_version"
    lacks "powershell: version prints no table" "Component update check" "$ps_version"
    has "powershell: version frames the waiting updates" "Updates available" "$ps_version"
    has "powershell: version points at update-check" "See what's new   exakit update-check" "$ps_version"
else
    check "powershell(versions_manifest)" "skipped" "skipped"
    check "powershell(non_https_refused)" "skipped" "skipped"
    for _skipped in "Tagged column" "kit row is comparable" "installed stays installed" \
                    "heavy runtime row" "older advertised version" "critical severity" \
                    "maintainer note" "repair action for a missing component" \
                    "an absent runtime is listed" "but never offered for installation" \
                    "pinned policy uses the fallback" "an override is credited" \
                    "and withholds the maintainer note" \
                    "version reports the kit version" "version prints no table" \
                    "version frames the waiting updates" "version points at update-check" "(self_update)" \
                    "recommended light bump" "critical heavy bump" \
                    "the heavy line names the cost"; do
        check "powershell: $_skipped" "skipped" "skipped"
    done
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
