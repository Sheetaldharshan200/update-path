#!/bin/sh
# ensure-python.sh - the ONLY shell that knows how a Python gets onto this machine.
#
# Sourced (not run) by install.sh and by the `exakit` launcher. Defines
# ensure_python, which leaves EXAKIT_PYTHON set to a usable interpreter:
#
#   1. EXAKIT_PYTHON, when set and it runs Python 3.11 or newer
#   2. the interpreter a previous run recorded under $EXAKIT_HOME/python/interpreter
#   3. otherwise: uv (found, or downloaded as a pinned, digest-checked release
#      archive named in the kit's versions.json), then `uv python install 3.12`
#      into $EXAKIT_HOME/python, then record the interpreter
#
# Never the system Python: the macOS Xcode stub and the Windows Store stub both
# exist, are executable, and fail. Never a download from a read-only query
# (EXAKIT_READONLY_QUERY=1): those answer "unknown" and exit 3 instead.
#
# POSIX sh. No logic beyond "is Python here". Twin: bootstrap/ensure-python.ps1.

EXAKIT_PYTHON_VERSION="${EXAKIT_PYTHON_VERSION:-3.12}"

_ep_say() { [ "${EXAKIT_VERBOSE_BOOTSTRAP:-0}" = 1 ] && printf '  - %s\n' "$*" >&2; return 0; }
_ep_fail() { printf '  [x] %s\n' "$*" >&2; return 1; }

# _ep_runs <interpreter> - true when it runs and is 3.11 or newer.
_ep_runs() {
    [ -n "$1" ] && [ -x "$1" ] || return 1
    "$1" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1
}

# _ep_platform_key - the <os>-<arch> token versions.json keys digests by.
_ep_platform_key() {
    case "$(uname -s)" in Darwin) _ep_os=macos ;; Linux) _ep_os=linux ;; *) return 1 ;; esac
    case "$(uname -m)" in x86_64|amd64) _ep_arch=x86_64 ;; arm64|aarch64) _ep_arch=aarch64 ;; *) return 1 ;; esac
    printf '%s-%s\n' "$_ep_os" "$_ep_arch"
}

# _ep_uv_triple <platform-key> - the Rust target triple uv names its archives by.
_ep_uv_triple() {
    case "$1" in
        macos-aarch64) echo aarch64-apple-darwin ;;
        macos-x86_64)  echo x86_64-apple-darwin ;;
        linux-aarch64) echo aarch64-unknown-linux-gnu ;;
        linux-x86_64)  echo x86_64-unknown-linux-gnu ;;
        *) return 1 ;;
    esac
}

# _ep_versions_value <dot.path> - one scalar from the kit's versions.json,
# read with the canonical-layout awk the kit has always used when no Python exists.
_ep_versions_value() {
    awk -v want="$1" '
        { n = match($0, /[^ ]/); if (n == 0) next
          depth = int((n - 1) / 2); if (depth < 1) next
          rest = substr($0, n)
          if (!match(rest, /^"[^"]*" *:/)) next
          key = substr(rest, 1, RLENGTH); val = substr(rest, RLENGTH + 1)
          sub(/^"/, "", key); sub(/" *:$/, "", key); keys[depth] = key
          sub(/^ +/, "", val)
          if (val == "" || val == "{" || val == "[") next
          if (substr(val, 1, 1) == "\"") { sub(/",$/, "\"", val); val = substr(val, 2, length(val) - 2) } else { sub(/,$/, "", val) }
          path = keys[1]; for (i = 2; i <= depth; i++) path = path "." keys[i]
          if (path == want) { print val; exit } }
    ' "$EXAKIT_KIT_DIR/versions.json" 2>/dev/null
}

_ep_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
    else return 1; fi
}

# _ep_install_uv - download the pinned uv release archive, verify it, unpack it.
_ep_install_uv() {
    _ep_key="$(_ep_platform_key)" || return 1
    _ep_triple="$(_ep_uv_triple "$_ep_key")" || return 1
    _ep_ver="$(_ep_versions_value tools.uv.version)"
    _ep_want="$(_ep_versions_value "tools.uv.sha256.$_ep_key")"
    [ -n "$_ep_ver" ] || { _ep_fail "The kit's versions.json names no uv version (tools.uv.version)."; return 1; }
    _ep_url="https://github.com/astral-sh/uv/releases/download/$_ep_ver/uv-$_ep_triple.tar.gz"
    _ep_dir="$EXAKIT_HOME/tools/uv"
    mkdir -p "$_ep_dir" || return 1
    _ep_tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-uv.XXXXXX")" || return 1
    _ep_say "Downloading uv $_ep_ver"
    curl -fsSL --proto '=https' --retry 2 --connect-timeout 15 --max-time 300 -o "$_ep_tmp" "$_ep_url" \
        || { rm -f "$_ep_tmp"; _ep_fail "Could not download $_ep_url"; return 1; }
    if [ -n "$_ep_want" ]; then
        _ep_got="$(_ep_sha256 "$_ep_tmp")"
        if [ "$_ep_got" != "$_ep_want" ] && [ "${EXAKIT_ALLOW_UNVERIFIED_UV:-0}" != 1 ]; then
            rm -f "$_ep_tmp"
            _ep_fail "The uv download did not match its published checksum (expected $_ep_want, got $_ep_got)."
            return 1
        fi
    elif [ "${EXAKIT_ALLOW_UNVERIFIED_UV:-0}" != 1 ]; then
        rm -f "$_ep_tmp"
        _ep_fail "versions.json carries no uv digest for $_ep_key; refusing an unverified download (EXAKIT_ALLOW_UNVERIFIED_UV=1 overrides)."
        return 1
    fi
    tar -xzf "$_ep_tmp" -C "$_ep_dir" --strip-components 1 || { rm -f "$_ep_tmp"; _ep_fail "Could not unpack uv."; return 1; }
    rm -f "$_ep_tmp"
    chmod 755 "$_ep_dir/uv" "$_ep_dir/uvx" 2>/dev/null
    [ -x "$_ep_dir/uv" ]
}

# _ep_find_uv - the uv to use: EXAKIT_UV_BIN, the kit's own copy, or PATH.
_ep_find_uv() {
    if [ -n "${EXAKIT_UV_BIN:-}" ] && [ -x "$EXAKIT_UV_BIN" ]; then echo "$EXAKIT_UV_BIN"; return 0; fi
    if [ -x "$EXAKIT_HOME/tools/uv/uv" ]; then echo "$EXAKIT_HOME/tools/uv/uv"; return 0; fi
    command -v uv 2>/dev/null && return 0
    return 1
}

# ensure_python - see the header. Returns 0 with EXAKIT_PYTHON exported, 3 when a
# read-only query may not download, 1 when a Python could not be had.
ensure_python() {
    EXAKIT_HOME="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
    EXAKIT_KIT_DIR="${EXAKIT_KIT_DIR:-$EXAKIT_HOME/kit}"
    _ep_record="$EXAKIT_HOME/python/interpreter"
    if _ep_runs "${EXAKIT_PYTHON:-}"; then export EXAKIT_PYTHON; return 0; fi
    if [ -f "$_ep_record" ]; then
        EXAKIT_PYTHON="$(head -1 "$_ep_record" 2>/dev/null)"
        if _ep_runs "$EXAKIT_PYTHON"; then export EXAKIT_PYTHON; return 0; fi
    fi
    if [ "${EXAKIT_READONLY_QUERY:-0}" = 1 ]; then
        return 3
    fi
    command -v curl >/dev/null 2>&1 || { _ep_fail "curl is required to set up the kit's Python."; return 1; }
    _ep_uv="$(_ep_find_uv)" || { _ep_install_uv || return 1; _ep_uv="$EXAKIT_HOME/tools/uv/uv"; }
    _ep_say "Setting up the kit's Python $EXAKIT_PYTHON_VERSION (managed by uv, never the system one)"
    mkdir -p "$EXAKIT_HOME/python" || return 1
    UV_PYTHON_INSTALL_DIR="$EXAKIT_HOME/python" "$_ep_uv" python install "$EXAKIT_PYTHON_VERSION" --quiet \
        || { _ep_fail "uv could not install Python $EXAKIT_PYTHON_VERSION."; return 1; }
    EXAKIT_PYTHON="$(UV_PYTHON_INSTALL_DIR="$EXAKIT_HOME/python" "$_ep_uv" python find "$EXAKIT_PYTHON_VERSION" 2>/dev/null)"
    _ep_runs "$EXAKIT_PYTHON" || { _ep_fail "The Python uv installed does not run."; return 1; }
    printf '%s\n' "$EXAKIT_PYTHON" > "$_ep_record"
    export EXAKIT_PYTHON
    return 0
}
