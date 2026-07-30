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

# --- fixtures ----------------------------------------------------------------
# Variants are derived from the shipped document so they keep its canonical
# shape; only the property under test differs.
sed 's/"schema_version": 1/"schema_version": 2/' "$REAL" > "$FIX/schema2.json"
sed 's/"version": "0.11.2"/"version": "0.11.2 rm -rf \/"/' "$REAL" > "$FIX/bad-charset.json"
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
both_value "kit.version" "0.2.0" kit.version "$REAL"
both_value "components.personal.version" "2.0.0-rc4" components.personal.version "$REAL"
both_value "components.nano.version" "2026.2.0-nano.2" components.nano.version "$REAL"
both_value "components.nano.image" "exasol/nano" components.nano.image "$REAL"
both_value "components.exapump.version" "0.11.2" components.exapump.version "$REAL"
both_value "components.mcp.version" "1.10.1" components.mcp.version "$REAL"
both_value "components.mcp.package" "exasol-mcp-server" components.mcp.package "$REAL"
both_value "components.pyexasol.version" "2.2.2" components.pyexasol.version "$REAL"
both_value "exapump digest (macos-aarch64)" \
    "e1438c69f26cdcca69ad1b7211aa9495524c53ff1badebee91d5a631c503616b" \
    components.exapump.sha256.macos-aarch64 "$REAL"
both_value "exapump digest (windows-x86_64)" \
    "8a2e8199a94f1b21782e4c68179948bfa43217c82c9b9b2a25eaec4532305237" \
    components.exapump.sha256.windows-x86_64 "$REAL"
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
check "kit bundled version" "0.2.0" "$(exakit_kit_bundled_version)"
check "kit bundled version (no python)" "0.2.0" "$(no_python exakit_kit_bundled_version)"
check "user agent" "exakit-update-check/0.2.0" "$(exakit_versions_user_agent | cut -d' ' -f1)"
printf 'garbage\n' > "$EXAKIT_HOME/kit/versions.json"
check "unreadable kit copy is not a version" "absent" \
    "$(exakit_kit_bundled_version 2>/dev/null || printf absent)"
cp "$REAL" "$EXAKIT_HOME/kit/versions.json"

echo "resolution chain (a command must never fail over a version lookup):"
EXAKIT_VERSIONS_CACHE="$EXAKIT_HOME/cache/versions.json"
check "no cache -> baked kit copy" "baked" "$( exakit_versions_source )"
check "baked value is readable" "0.11.2" "$( exakit_versions_value components.exapump.version )"
mkdir -p "$EXAKIT_HOME/cache"
sed 's/"version": "0.11.2"/"version": "0.12.0"/' "$REAL" > "$EXAKIT_VERSIONS_CACHE"
check "cache wins over the kit copy" "cache" "$( exakit_versions_source )"
check "cached value is used" "0.12.0" "$( exakit_versions_value components.exapump.version )"
printf 'corrupted by hand\n' > "$EXAKIT_VERSIONS_CACHE"
check "unreadable cache falls back to the kit copy" "baked" "$( exakit_versions_source )"
check "kit copy answers again" "0.11.2" "$( exakit_versions_value components.exapump.version )"
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

echo "update-check table:"
# One fixture install, one advertised set, every interesting row at once:
#   exakit    0.2.0            = 0.2.0             -> current (and NOT "inspect")
#   nano      2026.2.0-nano.2 -> 2026.3.0-nano.1   -> heavy
#   exapump   0.13.0          -> 0.12.0            -> advisory rollback
#   mcp       1.10.1          -> 1.11.0 critical   -> severity + note
#   pyexasol  not installed   -> 2.2.2             -> repair action
UC="$WORK/uc-home"
mkdir -p "$UC/kit/mcp" "$UC/cache"
cat > "$UC/manifest.json" <<'EOF'
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
      "version": "0.13.0"
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

has "the column is Available, not Latest" "Available" "$uc_table"
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
has "an older advertised version is flagged" "0.12.0 (older)" "$uc_table"
has "and explained as an advisory rollback" "advisory rollback" "$uc_table"
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
has "version says something is waiting" "New versions are available." "$version_out"
has "version points at update-check" "See what's new:  exakit update-check" "$version_out"

update_out="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_ALLOW_DOWNGRADE=1
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
    ( exakit_confirm_downgrade exapump </dev/null 2>&1 ) )"
has "and still goes through the confirmation gate" "0.13.0 is NEWER than the advertised 0.11.2" "$override_confirm"

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

min_kit_apply="$(uc_run 'exakit_component_min_kit() { [ "$1" = mcp ] && printf "9.9.9\n"; return 0; }
                        EXAKIT_ALLOW_DOWNGRADE=1')"
has "a kit-blocked component says so" "needs kit >= 9.9.9" "$min_kit_apply"
lacks "and is not installed anyway" "APPLIED mcp" "$min_kit_apply"
has "while the rest of the run continues" "APPLIED exapump" "$min_kit_apply"

refused="$(uc_run)"
lacks "a refused rollback is not applied" "APPLIED exapump" "$refused"
has "but its neighbours still are" "APPLIED mcp" "$refused"
has "and the run itself succeeds" "rc=0" "$refused"

personal_row="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    exakit_print_update_check personal 2>&1 )"
has "a runtime this machine does not run is listed" "personal   not installed" "$personal_row"
lacks "but never offered for installation" "exakit update personal" "$personal_row"

echo "the Available column matches the policy in force:"
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
has "an override reaches the Available column" "9.9.9" "$override_row"
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

echo "advisory rollback (never silent):"
blocked="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    # The refusal calls die(), which exits: run it in its own subshell so the
    # exit status can still be reported here.
    ( exakit_confirm_downgrade exapump </dev/null 2>&1 ); printf 'rc=%s' "$?" )"
has "a rollback is announced" "0.13.0 is NEWER than the advertised 0.12.0" "$blocked"
has "the maintainer note is repeated" "0.12.0 is the tested build" "$blocked"
has "an unattended run refuses it" "Set EXAKIT_ALLOW_DOWNGRADE=1" "$blocked"
has "and exits non-zero" "rc=1" "$blocked"
allowed="$( EXAKIT_HOME="$UC"
    EXAKIT_MANIFEST="$UC/manifest.json"
    EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json"
    EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json"
    _EXAKIT_VERSIONS_DOC=""; _EXAKIT_VERSIONS_SOURCE=""
    EXAKIT_ALLOW_DOWNGRADE=1
    exakit_confirm_downgrade exapump </dev/null >/dev/null 2>&1; printf 'rc=%s' "$?" )"
check "EXAKIT_ALLOW_DOWNGRADE=1 lets it through" "rc=0" "$allowed"

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
check "a newer kit replaces the copy and records itself" \
    "rc=0 version=0.3.0 source=exasol-labs/exasol-personal-local-starterkit@main kit-present replaced cli-installed backup-kept" \
    "$(self_update "$WORK/kit-0.3.0.tgz" 0.3.0)"

# The raw endpoint can be minutes ahead of the branch archive: record what landed.
make_kit_tarball "$WORK/kit-0.2.5.tgz" 0.2.5
lag_state="$(self_update "$WORK/kit-0.2.5.tgz" 0.3.0)"
check "a lagging archive records the version that landed" \
    "rc=0 version=0.2.5 source=exasol-labs/exasol-personal-local-starterkit@main kit-present replaced cli-installed backup-kept" \
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
    # A cached copy that differs from the kit copy proves which one is read.
    sed 's/"version": "0.11.2"/"version": "0.12.0"/' "$REAL" > "$PS_HOME/cache/versions.json"
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
    check "powershell(versions_manifest)" "0 2 1 1 0 0.11.2 8a2e8199 0.2.0 2 1 0.12.0 cache" "$ps_state"
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
    has "powershell: Available column" "Available" "$ps_table"
    has "powershell: kit row is comparable" "exakit     0.2.0             0.2.0" "$ps_table"
    has "powershell: installed stays installed" "exapump    0.13.0" "$ps_table"
    has "powershell: heavy runtime row" "exakit update runtime (heavy)" "$ps_table"
    has "powershell: older advertised version" "0.12.0 (older)" "$ps_table"
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
    check "powershell(self_update)" \
        "0.3.0 exasol-labs/exasol-personal-local-starterkit@main kit-present replaced shim-written backup-kept" \
        "$ps_self"
    ps_version="$(EXAKIT_HOME="$UC" EXAKIT_BIN_DIR="$UC/bin" \
        EXAKIT_VERSIONS_CACHE="$UC/cache/versions.json" \
        EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" \
        pwsh -NoProfile -File "$ROOT/setup/exakit.ps1" version 2>&1 | tr -d '\r')"
    has "powershell: version reports the kit version" "Kit version:    0.2.0" "$ps_version"
    lacks "powershell: version prints no table" "Component update check" "$ps_version"
    has "powershell: version says something is waiting" "New versions are available." "$ps_version"
else
    check "powershell(versions_manifest)" "skipped" "skipped"
    check "powershell(non_https_refused)" "skipped" "skipped"
    for _skipped in "Available column" "kit row is comparable" "installed stays installed" \
                    "heavy runtime row" "older advertised version" "critical severity" \
                    "maintainer note" "repair action for a missing component" \
                    "an absent runtime is listed" "but never offered for installation" \
                    "pinned policy uses the fallback" "an override is credited" \
                    "and withholds the maintainer note" \
                    "version reports the kit version" "version prints no table" \
                    "version says something is waiting" "(self_update)"; do
        check "powershell: $_skipped" "skipped" "skipped"
    done
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
