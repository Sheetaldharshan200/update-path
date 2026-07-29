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
# No installs, no network: the fetch is a stubbed curl.
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
else
    check "powershell(versions_manifest)" "skipped" "skipped"
    check "powershell(non_https_refused)" "skipped" "skipped"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
