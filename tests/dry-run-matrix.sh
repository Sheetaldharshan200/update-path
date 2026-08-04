#!/usr/bin/env bash
# dry-run-matrix.sh — exercises the detection and routing logic against
# simulated environments (stubbed uname / container CLIs). No installs.
#
#   bash tests/dry-run-matrix.sh

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

# make_stub_env <uname-s> <uname-m> — builds a PATH dir with a stubbed uname.
make_stub_env() {
    _dir="$(mktemp -d)"
    cat > "$_dir/uname" <<EOF
#!/bin/sh
case "\${1:-}" in
    -s) echo "$1" ;;
    -m) echo "$2" ;;
    *)  echo "$1" ;;
esac
EOF
    chmod +x "$_dir/uname"
    echo "$_dir"
}

echo "detect_os / detect_arch matrix:"
for spec in "Darwin arm64 macos arm64" \
            "Darwin x86_64 macos x86_64" \
            "Linux x86_64 linux x86_64" \
            "Linux aarch64 linux arm64" \
            "FreeBSD amd64 unsupported x86_64"; do
    set -- $spec
    stub="$(make_stub_env "$1" "$2")"
    got_os="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_os")"
    got_arch="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_arch")"
    # WSL looks like Linux to uname; the /proc/version branch cannot be
    # simulated on macOS and is covered by a run on real WSL.
    [ "$1" = "Linux" ] && [ "$got_os" = "wsl" ] && got_os="linux"
    check "os($1)" "$3" "$got_os"
    check "arch($2)" "$4" "$got_arch"
    rm -rf "$stub"
done

echo "container runtime detection:"
# No docker/podman on PATH at all -> none
empty="$(mktemp -d)"
for tool in bash sh grep awk cat uname command; do
    _p="$(command -v $tool)" && ln -s "$_p" "$empty/$tool" 2>/dev/null
done
got="$(PATH="$empty" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime")"
check "runtime(no CLIs)" "none" "$got"
got="$(PATH="$empty" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime_detail")"
check "runtime_detail(no CLIs)" "none" "$got"

# docker present but daemon down -> docker-stopped, and not selected.
# A FAILING podman stub is created alongside: the stub dir is prepended to
# the real PATH, so on a machine with a healthy real podman the fallback
# would otherwise leak in and detection would (correctly, but off-test)
# return podman instead of the docker-* state under test.
stub="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' > "$stub/docker" && chmod +x "$stub/docker"
printf '#!/bin/sh\nexit 1\n' > "$stub/podman" && chmod +x "$stub/podman"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime_detail")"
check "runtime_detail(docker down)" "docker-stopped" "$got"

# docker daemon UP but the user lacks socket permission (not in the docker
# group) -> docker-permission, so the error names the real remedy (usermod)
# instead of telling the user to start a daemon that is already running.
printf '#!/bin/sh\necho "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock" >&2\nexit 1\n' > "$stub/docker" && chmod +x "$stub/docker"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime_detail")"
check "runtime_detail(docker permission)" "docker-permission" "$got"

# docker present and healthy -> docker
printf '#!/bin/sh\nexit 0\n' > "$stub/docker" && chmod +x "$stub/docker"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime")"
check "runtime(docker up)" "docker" "$got"

# podman only -> podman. The docker stub must FAIL rather than be removed:
# the stub dir is prepended to the real PATH, so on a machine with a healthy
# Docker the real binary would leak in and detection would return docker.
printf '#!/bin/sh\nexit 1\n' > "$stub/docker" && chmod +x "$stub/docker"
printf '#!/bin/sh\nexit 0\n' > "$stub/podman" && chmod +x "$stub/podman"
got="$(PATH="$stub:$PATH" bash -c ". '$ROOT/setup/lib/detect.sh'; detect_container_runtime")"
check "runtime(podman only)" "podman" "$got"
rm -rf "$stub" "$empty"

echo "install.sh dispatch:"
# Dry-run against a local tarball server is overkill; verify the routing
# table statically instead: every platform maps to the right setup script.
grep -q 'setup_script="setup/setup-macos.sh"' "$ROOT/install.sh" && \
    check "dispatch(macos)" "setup-macos.sh" "setup-macos.sh" || \
    check "dispatch(macos)" "setup-macos.sh" "missing"
grep -q 'setup_script="setup/setup-wsl.sh"' "$ROOT/install.sh" && \
    check "dispatch(linux/wsl)" "setup-wsl.sh" "setup-wsl.sh" || \
    check "dispatch(linux/wsl)" "setup-wsl.sh" "missing"

echo "mcp credential fallback:"
_mcp_test_dir="$(mktemp -d)"
EXAKIT_CREDS_DIR="$_mcp_test_dir/credentials"
mkdir -p "$_mcp_test_dir/credentials"
printf 'readonly-secret\n' > "$_mcp_test_dir/credentials/mcp_readonly_password"
manifest_get() {
    case "$1" in
        components.mcp_server.connection.user)
            return 1
            ;;
        components.mcp_server.connection.password_file)
            return 1
            ;;
        components.mcp_server.user)
            printf '%s\n' "legacy-marker"
            ;;
        runtime.user)
            printf '%s\n' "sys"
            ;;
        runtime.password_file)
            printf '%s\n' "$_mcp_test_dir/credentials/db_password"
            ;;
        *)
            return 1
            ;;
    esac
}
. "$ROOT/setup/lib/mcp.sh"
_mcp_user="$(mcp_credentials | awk -F '\t' '{print $1}')"
check "mcp_credentials(legacy fallback)" "mcp_readonly" "$_mcp_user"
rm -rf "$_mcp_test_dir"

echo "update command routing:"
update_targets="$(bash -c ". '$ROOT/setup/lib/common.sh'; exakit_update_targets all" | tr '\n' ' ')"
check "update_targets(all)" "exakit runtime exapump mcp pyexasol " "$update_targets"
personal_target="$(bash -c ". '$ROOT/setup/lib/common.sh'; exakit_update_targets personal" | tr '\n' ' ')"
check "update_targets(personal)" "personal " "$personal_target"
if grep -q 'mcp.sh' "$ROOT/setup/exakit"; then
    check "exakit_sources(mcp)" "yes" "yes"
else
    check "exakit_sources(mcp)" "yes" "no"
fi
if grep -q 'cmd_update "$@"' "$ROOT/setup/exakit" && \
   grep -q 'exakit_update_component "$_component" "$@"' "$ROOT/setup/lib/common.sh"; then
    check "update_options(forwarded)" "yes" "yes"
else
    check "update_options(forwarded)" "yes" "no"
fi
if bash -c ". '$ROOT/setup/lib/common.sh'; exakit_version_newer 3.0.0 2.0.0"; then
    check "version_newer(3>2)" "yes" "yes"
else
    check "version_newer(3>2)" "yes" "no"
fi
# One row per target, every one of them behind: the table must offer an update
# command for each. EXAKIT_VERSION_POLICY is pinned so the harness cannot reach
# the network, and the available versions come from the stub below.
_stub_bin="$(mktemp -d)"
printf '#!/bin/sh\necho "exapump 0.11.2"\n' > "$_stub_bin/exapump"
printf '#!/bin/sh\necho 2.2.2\n' > "$_stub_bin/python"
chmod +x "$_stub_bin/exapump" "$_stub_bin/python"
update_action="$(bash -c "
EXAKIT_VERSION_POLICY=pinned
. '$ROOT/setup/lib/common.sh'
manifest_get() {
  case \"\$1\" in
    runtime.type) printf '%s\n' nano ;;
    runtime.image) printf '%s\n' docker.io/exasol/nano:2026.2.0-nano.2 ;;
    components.exapump.version) printf '%s\n' 0.11.2 ;;
    components.exapump.path) printf '%s\n' '$_stub_bin/exapump' ;;
    components.pyexasol.python) printf '%s\n' '$_stub_bin/python' ;;
    components.mcp_server.version) printf '%s\n' 1.10.1 ;;
    components.pyexasol.version) printf '%s\n' 2.2.2 ;;
    kit.version) printf '%s\n' 0.2.0 ;;
    kit.source) printf '%s\n' example/starter@0.2.0 ;;
    *) return 1 ;;
  esac
}
# The MCP version is read LIVE, so without this the fixture reads whatever MCP this
# machine happens to have installed. The day a real install went past the advertised
# 1.11.0, that turned the mcp row into an installed-is-newer row with an action of
# \"none\" and quietly cost this check one of its five update commands.
exakit_installed_mcp_version() { printf '%s\n' 1.10.1 ; }
exakit_component_available() {
  case \"\$1\" in
    nano) printf '%s\n' 2026.3.0-nano.1 ;;
    exapump) printf '%s\n' 0.12.0 ;;
    mcp) printf '%s\n' 1.11.0 ;;
    pyexasol) printf '%s\n' 2.3.0 ;;
    exakit) printf '%s\n' 0.3.0 ;;
  esac
}
exakit_print_update_check all
" | grep -c '^[a-z].*exakit update')"
check "update_check(commands)" "5" "$update_action"

# The runtime is the only heavy target, and a routine `exakit update` must
# announce it instead of stopping the database on its own.
update_plan="$(bash -c "
EXAKIT_VERSION_POLICY=pinned
. '$ROOT/setup/lib/common.sh'
manifest_get() {
  case \"\$1\" in
    runtime.type) printf '%s\n' nano ;;
    runtime.image) printf '%s\n' docker.io/exasol/nano:2026.2.0-nano.2 ;;
    components.exapump.version) printf '%s\n' 0.11.2 ;;
    kit.version) printf '%s\n' 0.2.0 ;;
    *) return 1 ;;
  esac
}
exakit_component_available() {
  case \"\$1\" in
    nano) printf '%s\n' 2026.3.0-nano.1 ;;
    exapump) printf '%s\n' 0.11.2 ;;
    *) return 1 ;;
  esac
}
exakit_init_logging() { :; }
exakit_update_component() { printf 'APPLIED %s\n' \"\$1\"; }
exakit_update all
" 2>&1)"
if printf '%s' "$update_plan" | grep -q 'needs the database stopped' && \
   ! printf '%s' "$update_plan" | grep -q 'APPLIED runtime'; then
    check "update_all(defers_heavy)" "yes" "yes"
else
    check "update_all(defers_heavy)" "yes" "no"
fi

personal_major_plan="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
manifest_get() {
  case \"\$1\" in
    runtime.version) printf '%s\n' 2.0.0 ;;
    *) return 1 ;;
  esac
}
exakit_component_available() { printf '%s\n' 3.0.0; }
personal_update --plan
" 2>&1 | grep -c 'exakit update personal --backup')"
check "personal_major(plan)" "1" "$personal_major_plan"

personal_reuse_guard="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
EXAKIT_PERSONAL_PORT=8563
_stub_dir=\"\$(mktemp -d)\"
printf '#!/bin/sh\n[ \"\$1\" = info ] && exit 0\nexit 1\n' > \"\$_stub_dir/exasol\"
chmod +x \"\$_stub_dir/exasol\"
personal_cli() { printf '%s\n' \"\$_stub_dir/exasol\"; }
port_in_use() { return 1; }
if personal_deployment_running; then printf reuse; else printf deploy; fi
rm -rf \"\$_stub_dir\"
")"
check "personal_reuse_guard(no-port)" "deploy" "$personal_reuse_guard"

personal_reuse_when_port_open="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
EXAKIT_PERSONAL_PORT=8563
_stub_dir=\"\$(mktemp -d)\"
printf '#!/bin/sh\n[ \"\$1\" = info ] && exit 0\nexit 1\n' > \"\$_stub_dir/exasol\"
chmod +x \"\$_stub_dir/exasol\"
personal_cli() { printf '%s\n' \"\$_stub_dir/exasol\"; }
port_in_use() { return 0; }
if personal_deployment_running; then printf reuse; else printf deploy; fi
rm -rf \"\$_stub_dir\"
")"
check "personal_reuse_guard(open-port)" "reuse" "$personal_reuse_when_port_open"

_personal_backup_dir="$(mktemp -d)"
mkdir -p "$_personal_backup_dir/deploy"
printf 'deployment state\n' > "$_personal_backup_dir/deploy/marker.txt"
personal_backup_count="$(bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/detect.sh'
. '$ROOT/setup/lib/runtime-personal.sh'
EXAKIT_HOME='$_personal_backup_dir/home'
EXAKIT_PERSONAL_DEPLOY_DIR='$_personal_backup_dir/deploy'
EXAKIT_LOG_FILE='$_personal_backup_dir/backup.log'
manifest_set() { :; }
personal_status() { printf '%s\n' stopped; }
personal_upgrade_backup 2.0.0 3.0.0 >/dev/null
find \"\$EXAKIT_HOME/backups\" -name 'personal-upgrade-*.tar.gz' | wc -l | tr -d ' '
")"
check "personal_major(backup)" "1" "$personal_backup_count"
rm -rf "$_personal_backup_dir"

echo "version lookup fallbacks without Python/uv:"
fallback_versions="$(bash -c "
. '$ROOT/setup/lib/common.sh'
EXAKIT_DISABLE_SYSTEM_PYTHON=1
exakit_ensure_uv() { return 1; }
curl() {
  case \"\$*\" in
    *api.github.com*) printf '%s\n' '{\"tag_name\":\"v9.8.7\"}' ;;
    *pypi.org*) printf '%s\n' '{\"info\":{\"version\":\"6.5.4\"}}' ;;
    *hub.docker.com*) printf '%s\n' '{\"results\":[{\"name\":\"2026.4.0-nano.1\"},{\"name\":\"latest\"}]}' ;;
  esac
}
printf '%s %s %s ' \"\$(exakit_latest_github_release_version owner/repo)\" \"\$(exakit_latest_pypi_version pkg)\" \"\$(exakit_latest_docker_tag exasol/nano)\"
if exakit_version_newer 3.0.0 2.9.9; then printf yes; else printf no; fi
")"
check "lookup_fallback(no-python)" "9.8.7 6.5.4 2026.4.0-nano.1 yes" "$fallback_versions"

echo "managed binary precedence:"
_bin_test_dir="$(mktemp -d)"
mkdir -p "$_bin_test_dir/kit-bin" "$_bin_test_dir/path-bin"
printf '#!/bin/sh\necho kit\n' > "$_bin_test_dir/kit-bin/exapump"
printf '#!/bin/sh\necho path\n' > "$_bin_test_dir/path-bin/exapump"
chmod +x "$_bin_test_dir/kit-bin/exapump" "$_bin_test_dir/path-bin/exapump"
managed_exapump="$(PATH="$_bin_test_dir/path-bin:$PATH" bash -c "
. '$ROOT/setup/lib/common.sh'
. '$ROOT/setup/lib/exapump.sh'
EXAKIT_EXAPUMP_BIN='$_bin_test_dir/kit-bin/exapump'
exapump_cli
")"
check "exapump_cli(prefers-managed)" "$_bin_test_dir/kit-bin/exapump" "$managed_exapump"
rm -rf "$_bin_test_dir"

# mcp-doctor is what people run when an AI client looks wrong, so it names the one
# command that fixes it. Only doctor: status/validate/repair are not that question.
if grep -q 'doctor) info "Connect or re-connect AI clients any time with:  exakit mcp-setup"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Connect or re-connect AI clients any time with:  exakit mcp-setup' "$ROOT/setup/lib/mcp.ps1"; then
    check "mcp_doctor(names_the_remedy)" "yes" "yes"
else
    check "mcp_doctor(names_the_remedy)" "yes" "no"
fi

echo "install time is shown in the machine's own timezone:"
# The manifest keeps UTC ISO 8601; only the display is localised. TZ is pinned per
# case so the expectation is deterministic on any machine that runs this suite.
for tz_spec in "UTC|2026-07-30T05:50:21Z|July 30, 2026 at 5:50 AM" \
               "Asia/Kolkata|2026-05-03T12:00:00Z|May 3, 2026 at 5:30 PM" \
               "America/New_York|2026-05-03T12:00:00Z|May 3, 2026 at 8:00 AM" \
               "UTC|2026-07-30T00:30:00Z|July 30, 2026 at 12:30 AM" \
               "UTC|2026-07-30T12:05:00Z|July 30, 2026 at 12:05 PM"; do
    tz_name="${tz_spec%%|*}"
    tz_rest="${tz_spec#*|}"
    tz_input="${tz_rest%%|*}"
    tz_want="${tz_rest#*|}"
    tz_got="$(TZ="$tz_name" bash -c ". '$ROOT/setup/lib/common.sh'; exakit_format_local_time '$tz_input'")"
    check "local_time($tz_name)" "$tz_want" "$tz_got"
done
# A timestamp nobody can parse is still better shown than swallowed.
tz_passthrough="$(bash -c ". '$ROOT/setup/lib/common.sh'; exakit_format_local_time 'not-a-date'")"
check "local_time(unparseable passes through)" "not-a-date" "$tz_passthrough"
if grep -q 'exakit_format_local_time "$(manifest_get installed_at' "$ROOT/setup/exakit" && \
   grep -q 'Format-ExakitLocalTime (Get-ExakitManifestValue' "$ROOT/setup/exakit.ps1"; then
    check "local_time(wired on both platforms)" "yes" "yes"
else
    check "local_time(wired on both platforms)" "yes" "no"
fi

echo "self-update staging guard:"
if grep -q 'exakit-kit-stage' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Downloaded starter kit is incomplete' "$ROOT/setup/lib/common.sh" && \
   grep -q 'existing kit copy was left untouched' "$ROOT/setup/lib/common.sh"; then
    check "self_update(staged_validation)" "yes" "yes"
else
    check "self_update(staged_validation)" "yes" "no"
fi
# A successful self-update must record the version that actually landed, not just
# where it came from: exakit_component_current reads kit.version first, so without
# this write the kit reports its old version forever and re-downloads every time.
if grep -q 'manifest_set kit.version "\$_staged_version"' "$ROOT/setup/lib/common.sh"; then
    check "self_update(records_kit_version)" "yes" "yes"
else
    check "self_update(records_kit_version)" "yes" "no"
fi
# main is the primary source (kit scripts live there; a tag exists only where a
# release was cut), and versions.json is on the required list — without it the new
# copy has no offline version tier and cannot say what version it is.
if grep -q 'archive/refs/heads/main.tar.gz' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit-common.ps1 versions.json' "$ROOT/setup/lib/common.sh"; then
    check "self_update(main_and_manifest)" "yes" "yes"
else
    check "self_update(main_and_manifest)" "yes" "no"
fi
# Windows is no longer warn-only: the same flow exists there, including the
# deferred swap for the files this very script runs from.
if grep -q 'function Update-ExakitSelf' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'archive/refs/heads/main.zip' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q '"versions.json"' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Complete-ExakitSelfUpdateDeferred' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Update-ExakitSelf -Advertised' "$ROOT/setup/exakit.ps1"; then
    check "self_update(windows_path)" "yes" "yes"
else
    check "self_update(windows_path)" "yes" "no"
fi

echo "Windows parity guards:"
if command -v pwsh >/dev/null 2>&1; then
    ps_parse="$(pwsh -NoProfile -Command '
      $files = @("setup/lib/exakit-common.ps1","setup/lib/nano.ps1","setup/lib/mcp.ps1","setup/setup-windows-docker.ps1","setup/exakit.ps1")
      foreach ($f in $files) {
        $errors = $null
        $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw $f), [ref]$errors)
        if ($errors) { Write-Output "no"; exit 0 }
      }
      Write-Output "yes"
    ' | tr -d '\r')"
    check "powershell(parse)" "yes" "$ps_parse"

    # Default (manifest) policy: the Windows path must resolve to exactly what
    # versions.json advertises. Expectations are read from that file, so a
    # Component bump never means editing this guard. A non-HTTPS endpoint keeps
    # the check offline — it is refused before any connection is attempted — and
    # the kit copy under the temporary home is the document being read.
    _ps_tmp="$(mktemp -d)"
    mkdir -p "$_ps_tmp/home/kit/mcp"
    cp "$ROOT/versions.json" "$_ps_tmp/home/kit/versions.json"
    _read_advertised() { bash -c ". '$ROOT/setup/lib/common.sh'; exakit_versions_value '$1' '$ROOT/versions.json'"; }
    exp_versions="baked $(_read_advertised components.nano.version) $(_read_advertised components.exapump.version) $(_read_advertised components.mcp.version)"
    ps_versions="$(EXAKIT_HOME="$_ps_tmp/home" EXAKIT_BIN_DIR="$_ps_tmp/bin" \
      EXAKIT_VERSIONS_URL="http://offline.invalid/versions.json" pwsh -NoProfile -Command '
      . ./setup/lib/exakit-common.ps1
      Initialize-ExakitManifest
      Resolve-ExakitInstallVersions
      Write-Output "$($script:VersionsSourceUsed) $script:NanoTag $script:ExapumpVersion $script:McpVersion"
    ' | tail -1 | tr -d '\r')"
    check "powershell(manifest_policy)" "$exp_versions" "$ps_versions"

    # Any other policy value is the offline branch: the compiled-in constants,
    # compared against the *Fallback variables themselves so this guard has no
    # literals to fall out of date either.
    ps_pinned="$(EXAKIT_HOME="$_ps_tmp/home2" EXAKIT_BIN_DIR="$_ps_tmp/bin2" EXAKIT_VERSION_POLICY=pinned pwsh -NoProfile -Command '
      . ./setup/lib/exakit-common.ps1
      Initialize-ExakitManifest
      Resolve-ExakitInstallVersions
      $matchesFallbacks = ($script:NanoTag -eq $script:NanoTagFallback) -and
        ($script:ExapumpVersion -eq $script:ExapumpVersionFallback) -and
        ($script:McpVersion -eq $script:McpVersionFallback) -and
        ($script:PyexasolVersion -eq $script:PyexasolVersionFallback)
      Write-Output "$($script:VersionsSourceUsed) $matchesFallbacks"
    ' | tail -1 | tr -d '\r')"
    rm -rf "$_ps_tmp"
    check "powershell(version_policy_fallback)" "fallback True" "$ps_pinned"
else
    check "powershell(parse)" "skipped" "skipped"
    check "powershell(manifest_policy)" "skipped" "skipped"
    check "powershell(version_policy_fallback)" "skipped" "skipped"
fi
# The live-lookup helpers stay in the library: `latest` policy is still supported.
if grep -q 'Resolve-ExakitInstallVersions' "$ROOT/setup/setup-windows-docker.ps1" && \
   grep -q 'Get-ExakitLatestDockerTag' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitLatestGithubRelease' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitLatestPypiVersion' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "windows_install(latest_resolution)" "yes" "yes"
else
    check "windows_install(latest_resolution)" "yes" "no"
fi
if grep -q 'Update-ExakitVersionsCache' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitVersionsValue' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Update-ExakitSelf' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Set-ExakitCmdShim' "$ROOT/setup/setup-windows-docker.ps1" && \
   grep -q 'Get-ExakitKitVersionAt' "$ROOT/setup/setup-windows-docker.ps1" && \
   grep -q 'Get-ExapumpExpectedSha256' "$ROOT/setup/lib/exapump.ps1"; then
    check "windows_install(manifest_wiring)" "yes" "yes"
else
    check "windows_install(manifest_wiring)" "yes" "no"
fi
# Soft-failing components, both sides. A component that dies must not take the run
# down with it: the exakit command is installed last, and without it a user whose
# exapump download broke has no way to repair anything.
if grep -q 'exakit_soft_step exapump' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_soft_step mcp' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_soft_step pyexasol' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_print_soft_failures' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Invoke-ExakitSoftStep -Component "exapump"' "$ROOT/setup/setup-windows-docker.ps1" && \
   grep -q 'Invoke-ExakitSoftStep -Component "mcp"' "$ROOT/setup/setup-windows-docker.ps1" && \
   grep -q 'Invoke-ExakitSoftStep -Component "pyexasol"' "$ROOT/setup/setup-windows-docker.ps1" && \
   grep -q 'Write-ExakitSoftFailures' "$ROOT/setup/setup-windows-docker.ps1"; then
    check "install(components_soft_fail)" "yes" "yes"
else
    check "install(components_soft_fail)" "yes" "no"
fi
# Release notes, both sides: the command, the print after a self-update, and the
# file travelling into the kit copy (without that last part `exakit whats-new`
# works from a checkout and then dies with it).
if grep -q 'cmd_whats_new' "$ROOT/setup/exakit" && \
   grep -q 'exakit_whats_new_section' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_print_whats_new "$_staged_version"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'WHATS-NEW.md" "$EXAKIT_HOME/kit/' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Invoke-CmdWhatsNew' "$ROOT/setup/exakit.ps1" && \
   grep -q 'Get-ExakitWhatsNewSection' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Write-ExakitWhatsNew -Version $stagedVersion' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'WHATS-NEW.md' "$ROOT/setup/setup-windows-docker.ps1" && \
   [ -f "$ROOT/WHATS-NEW.md" ]; then
    check "whats_new(both_sides)" "yes" "yes"
else
    check "whats_new(both_sides)" "yes" "no"
fi
# The upgrade box, both sides: the record taken before kit.version is overwritten,
# and the box that reads it. Both halves have to exist on both platforms or one of
# them announces an upgrade the other stays silent about.
if grep -q 'exakit_note_kit_upgrade() {' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_whats_new_versions() {' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_whats_new_points() {' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_print_whats_new_box() {' "$ROOT/setup/lib/common.sh" && \
   grep -q 'exakit_note_kit_upgrade "$KIT_ROOT"' "$ROOT/setup/setup-macos.sh" && \
   grep -q 'exakit_note_kit_upgrade "$KIT_ROOT"' "$ROOT/setup/setup-wsl.sh" && \
   grep -q 'function Set-ExakitKitUpgradeNote {' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'function Get-ExakitWhatsNewVersions {' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'function Get-ExakitWhatsNewPoints {' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'function Write-ExakitWhatsNewBox {' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Set-ExakitKitUpgradeNote -KitRoot $KitRoot' "$ROOT/setup/setup-windows-docker.ps1"; then
    check "whats_new_box(both_sides)" "yes" "yes"
else
    check "whats_new_box(both_sides)" "yes" "no"
fi
# Placement, on all three platforms: after the connection details, before the
# closing "Next:" line. Anywhere earlier and the connection panel pushes the box
# off the screen, which is the whole reason it moved out of the step output.
wn_box_placement() { # wn_box_placement <file> <panel-call> <box-call>
    awk -v panel="$2" -v box="$3" '
        index($0, panel) && panel_at == 0 { panel_at = NR }
        index($0, box)   && box_at == 0   { box_at = NR }
        index($0, "Next: exakit status") && next_at == 0 { next_at = NR }
        END {
            if (panel_at > 0 && box_at > panel_at && next_at > box_at) print "panel,box,next"
            else printf "panel=%d box=%d next=%d\n", panel_at, box_at, next_at
        }
    ' "$1"
}
check "whats_new_box(order_macos)" "panel,box,next" \
    "$(wn_box_placement "$ROOT/setup/setup-macos.sh" \
        'connection_panel' 'exakit_print_whats_new_box "$KIT_ROOT"')"
check "whats_new_box(order_wsl)" "panel,box,next" \
    "$(wn_box_placement "$ROOT/setup/setup-wsl.sh" \
        'connection_panel' 'exakit_print_whats_new_box "$KIT_ROOT"')"
check "whats_new_box(order_windows)" "panel,box,next" \
    "$(wn_box_placement "$ROOT/setup/setup-windows-docker.ps1" \
        'Show-ExakitConnectionPanel' 'Write-ExakitWhatsNewBox -KitRoot')"
# The short help is the only command list most people ever read: a bare `exakit`,
# `exakit help` and any unknown command all print it, while the full reference is
# behind `--all`. Staying current has to be visible there, or the update path
# exists and nobody finds it. The bash half is run for real; the PowerShell half
# is a mirrored string array, so it is read.
short_help="$(EXAKIT_NO_UPDATE_NOTICE=1 bash "$ROOT/setup/exakit" help 2>&1 || true)"
ps_help_lines=0
# _ui_visible_len measures what the user SEES, and ui_panel_end uses it twice:
# once to pick the box width, once to pad each line. It used a BRE alternation
# `\|` to accept either OSC 8 terminator -- a GNU sed extension that BSD sed
# ignores -- so on macOS a hyperlinked line returned its RAW byte length, became
# the widest line, blew the box out to 124 columns and closed its own border
# early. Escapes are built LITERALLY here on purpose: sourcing ui.sh re-derives
# UI_FANCY from `-t 1`, so calling ui_link in a piped test emits plain text and
# would prove nothing at all.
vis_probe="$(
    . "$ROOT/setup/lib/ui.sh" 2>/dev/null
    _v_two="$(printf 'SQL client:   \033]8;;https://dbeaver.io/download/\033\\DBeaver\033]8;;\033\\ or \033]8;;https://www.dbvis.com/download/\033\\DbVisualizer\033]8;;\033\\')"
    _v_bel="$(printf 'x \033]8;;http://a\007L\033]8;;\007 y')"
    _v_sgr="$(printf '\033[1mbold\033[0m plain')"
    printf '%s %s %s %s' "$(_ui_visible_len "SQL client:   DBeaver or DbVisualizer")" \
        "$(_ui_visible_len "$_v_two")" "$(_ui_visible_len "$_v_bel")" "$(_ui_visible_len "$_v_sgr")"
)"
check "visible_len(plain two-link BEL SGR)" "37 37 5 10" "$vis_probe"

# The helper being right is not the same as the BOX being right, so assert the
# rendered rows: every row of a panel containing a hyperlink must be equal width.
panel_widths="$(
    . "$ROOT/setup/lib/ui.sh" 2>/dev/null
    UI_FANCY=1
    _p_link="$(printf 'SQL client:   \033]8;;https://dbeaver.io/download/\033\\DBeaver\033]8;;\033\\ or \033]8;;https://www.dbvis.com/download/\033\\DbVisualizer\033]8;;\033\\')"
    ui_panel_begin "Connection details"
    ui_panel_line "Logs:         ~/.exasol-starter-kit/logs"
    ui_panel_line "$_p_link"
    ui_panel_line "How to connect: exakit guide"
    ui_panel_end
)"
# strip every escape, then count distinct rendered row lengths: 1 means aligned
distinct="$(printf '%s\n' "$panel_widths" | LC_ALL=C sed \
    -e 's/'"$(printf '\033')"'\[[0-9;]*m//g' \
    -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*'"$(printf '\007')"'//g' \
    -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*'"$(printf '\033')"'\\//g' \
    | awk 'NF { print length($0) }' | sort -u | wc -l | tr -d ' ')"
check "panel(hyperlinked rows all one width)" "1" "$distinct"

for _hl in "Keeping up to date:" "  version " "  update-check " "  update "; do
    grep -qF "\"$_hl" "$ROOT/setup/exakit.ps1" && ps_help_lines=$((ps_help_lines + 1))
done
if printf '%s' "$short_help" | grep -q 'Keeping up to date:' && \
   printf '%s' "$short_help" | grep -qE '^  version {2,}' && \
   printf '%s' "$short_help" | grep -qE '^  update-check {2,}' && \
   printf '%s' "$short_help" | grep -qE '^  update {2,}' && \
   [ "$ps_help_lines" = 4 ]; then
    check "help(update_path_listed_both_sides)" "yes" "yes"
else
    check "help(update_path_listed_both_sides)" "yes" "no"
fi
# `exakit info --json` is the machine-readable surface: the install record, byte for
# byte, and nothing else on stdout. Two things break that - re-serialising it (the
# output would be free to disagree with the file), and anything printing alongside
# it. The update notice is the standing risk there, which is why the json branch
# stays outside `_with_notice` and sets $script:JsonOutput on the PowerShell side.
# Missing record: a non-zero exit and an empty stdout, never a half-document.
_ij="$(mktemp -d)"
mkdir -p "$_ij/have" "$_ij/none"
printf '{\n  "kit": {\n    "version": "0.2.0"\n  }\n}\n' > "$_ij/have/manifest.json"
_ij_out="$(EXAKIT_HOME="$_ij/have" bash "$ROOT/setup/exakit" info --json 2>"$_ij/err")"
_ij_alias="$(EXAKIT_HOME="$_ij/have" bash "$ROOT/setup/exakit" info -j 2>/dev/null)"
_ij_none="$(EXAKIT_HOME="$_ij/none" bash "$ROOT/setup/exakit" info --json 2>/dev/null)"; _ij_rc=$?
if [ "$_ij_out" = "$(cat "$_ij/have/manifest.json")" ] && \
   [ "$_ij_alias" = "$_ij_out" ] && \
   [ ! -s "$_ij/err" ] && \
   [ -z "$_ij_none" ] && [ "$_ij_rc" != 0 ] && \
   grep -q 'cmd_info_json' "$ROOT/setup/exakit" && \
   ! grep -q '_with_notice cmd_info_json' "$ROOT/setup/exakit" && \
   grep -q 'Invoke-CmdInfoJson' "$ROOT/setup/exakit.ps1" && \
   grep -q 'JsonOutput = \$true' "$ROOT/setup/exakit.ps1" && \
   grep -q 'if (-not \$script:JsonOutput -and' "$ROOT/setup/exakit.ps1" && \
   grep -qF 'Get-Content -Raw -Encoding UTF8 -Path $script:ManifestPath' "$ROOT/setup/exakit.ps1"; then
    check "info(json_is_the_record_verbatim)" "yes" "yes"
else
    check "info(json_is_the_record_verbatim)" "yes" "no"
fi
rm -rf "$_ij"
# Bounded engine probes, both sides. `docker info` does not return while Docker
# Desktop is starting, so every read-path probe has to be able to give up. The
# PowerShell half must use .Arguments and not .ArgumentList, which exists only on
# .NET Core and would throw on the Windows PowerShell 5.1 these scripts support.
if grep -q 'exakit_run_bounded' "$ROOT/setup/lib/common.sh" && \
   grep -q '_detect_engine_probe docker info' "$ROOT/setup/lib/detect.sh" && \
   grep -q 'Invoke-ExakitBounded' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Invoke-ExakitBounded' "$ROOT/setup/lib/nano.ps1" && \
   grep -q 'Invoke-ExakitBounded' "$ROOT/setup/exakit.ps1" && \
   grep -q '\$info\.Arguments = ' "$ROOT/setup/lib/exakit-common.ps1" && \
   ! grep -qE '\$info\.ArgumentList' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "engine_probe(bounded_both_sides)" "yes" "yes"
else
    check "engine_probe(bounded_both_sides)" "yes" "no"
fi
# The notice plan cache, both sides. Keyed on content rather than mtime, because
# bash compares mtimes by the second and an update that rewrote the manifest in the
# same second the plan was written would otherwise look fresh.
if grep -q '_exakit_notice_plan_fresh' "$ROOT/setup/lib/common.sh" && \
   grep -q '_exakit_notice_signature' "$ROOT/setup/lib/common.sh" && \
   grep -q 'cksum "$EXAKIT_MANIFEST"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Test-ExakitNoticePlanFresh' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-ExakitNoticeSignature' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Get-FileHash' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q '_exakit_notice_still_behind' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Get-ExakitNoticeStillBehind' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'rm -f "$EXAKIT_NOTICE_PLAN"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Remove-Item -Force $script:NoticePlanPath' "$ROOT/setup/exakit.ps1"; then
    check "notice(plan_cached_both_sides)" "yes" "yes"
else
    check "notice(plan_cached_both_sides)" "yes" "no"
fi
# Re-run freshness, both sides: the exakit_helper flag says "installed", not
# "current", so a re-run over an older install has to compare what is on disk with
# what this kit would write. bash compares the installed COPY of setup/exakit; the
# Windows shim only points at the kit copy, so there it is the shim's own content.
# The behavioural halves live in tests/versions-manifest.sh.
if grep -q 'cmp -s "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit"' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Test-ExakitCmdShimCurrent' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'Test-ExakitCmdShimCurrent' "$ROOT/setup/setup-windows-docker.ps1" && \
   grep -q 'Get-ExakitCmdShimContent' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "rerun(refreshes_stale_command)" "yes" "yes"
else
    check "rerun(refreshes_stale_command)" "yes" "no"
fi
# The Kit 2 surface: both wrappers, the update target, the catalog rows, and the
# Windows answer. Whether Kit 2 is ADVERTISED is a separate switch (the kit2 block
# in versions.json) and is asserted in tests/versions-manifest.sh.
if grep -q 'upgrade-kit2)  cmd_kit2_script' "$ROOT/setup/exakit" && \
   grep -q 'rollback-kit2) cmd_kit2_script' "$ROOT/setup/exakit" && \
   grep -q 'exakit_update_kit2' "$ROOT/setup/lib/common.sh" && \
   grep -q 'manifest_set kit2.version' "$ROOT/upgrade/upgrade-kit2.sh" && \
   grep -q 'upgrade-kit2' "$ROOT/setup/lib/catalog.tsv" && \
   grep -q 'Write-ExakitKit2NotAvailable' "$ROOT/setup/exakit.ps1"; then
    check "kit2(cli_surface)" "yes" "yes"
else
    check "kit2(cli_surface)" "yes" "no"
fi
if grep -q 'nano_update_snapshot' "$ROOT/setup/lib/runtime-nano.sh" && \
   grep -q 'nano_restore_previous_container' "$ROOT/setup/lib/runtime-nano.sh" && \
   grep -q 'New-NanoUpdateSnapshot' "$ROOT/setup/lib/nano.ps1" && \
   grep -q 'Restore-PreviousNanoContainer' "$ROOT/setup/lib/nano.ps1"; then
    check "nano_update(recoverability)" "yes" "yes"
else
    check "nano_update(recoverability)" "yes" "no"
fi
if grep -q 'mcp_update_snapshot' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'New-McpUpdateSnapshot' "$ROOT/setup/lib/mcp.ps1" && \
   grep -q 'backups.mcp_update.latest' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'backups.mcp_update.latest' "$ROOT/setup/lib/mcp.ps1"; then
    check "mcp_update(snapshot)" "yes" "yes"
else
    check "mcp_update(snapshot)" "yes" "no"
fi
# The MCP update must judge itself by the pin in the AI client configs — what uvx
# will actually launch, and what update-check reports as Installed — and it must be
# the thing that rewrites those configs. A guard that read
# components.mcp_server.version instead answered "already current" for a version no
# client was running. Both sides carry the same two halves.
if grep -q 'exakit_component_current mcp' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'mcp_refresh_client_pins' "$ROOT/setup/lib/mcp.sh" && \
   grep -q 'Update-McpClientPins' "$ROOT/setup/lib/mcp.ps1" && \
   grep -q 'Update-McpClientPins' "$ROOT/setup/exakit.ps1" && \
   ! grep -q 'Run exakit mcp-setup to refresh AI client configs' "$ROOT/setup/exakit.ps1"; then
    check "mcp_update(live_pin_guard)" "yes" "yes"
else
    check "mcp_update(live_pin_guard)" "yes" "no"
fi

echo "step re-verification before skipping:"
# A manifest saying steps_completed: ["launcher"] with no launcher on disk made
# every re-run skip step 1 and then fail step 2 (which needs the launcher), for
# ever: the one step that could repair the install was the one being skipped.
# begin_step now skips only when the tick AND the disk agree, and an artifact it
# cannot prove is gone ("unknown") must never override the tick — re-running the
# runtime step on a guess would stop a working database.
#
# _sv_state <home> <step> <extra-shell> — step_artifact_state's verdict.
# _sv_step  <home> <step> <extra-shell> — what begin_step decides:
#   "skip"  begin_step returned 1 (caller skips the step)
#   "rerun" begin_step returned 0 and said why (recorded done, artifact gone)
#   "run"   begin_step returned 0 with no re-run notice (never recorded done)
_sv_state() {
    bash -c "
set -u
EXAKIT_HOME='$1'
EXAKIT_BIN_DIR='$1/bin'
. '$ROOT/setup/lib/common.sh'
$3
step_artifact_state '$2'
" 2>/dev/null
}
_sv_step() {
    bash -c "
set -u
EXAKIT_HOME='$1'
EXAKIT_BIN_DIR='$1/bin'
. '$ROOT/setup/lib/common.sh'
$3
if begin_step '$2' 'Step 1/1  probe' > '$1/begin.out' 2>&1; then
    if grep -q 'what it installed is missing' '$1/begin.out'; then
        printf rerun
    else
        printf run
    fi
else
    printf skip
fi
"
}
# The launcher cases must not see a launcher this machine happens to have on
# PATH: personal_cli() would resolve it, so step_artifact_state counts it as
# present (and is right to). Drop any PATH entry holding one — python3, which
# step_done needs, stays reachable.
_sv_path_without_exasol() {
    _svp=""
    _svp_ifs="$IFS"
    IFS=:
    for _svp_dir in $PATH; do
        [ -x "$_svp_dir/exasol" ] && continue
        _svp="${_svp:+$_svp:}$_svp_dir"
    done
    IFS="$_svp_ifs"
    printf '%s\n' "$_svp"
}
_SV_CLEAN_PATH="$(_sv_path_without_exasol)"

# launcher, recorded done, binary gone -> the bug: must re-run, not skip.
_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin"
printf '{"steps_completed": ["launcher"], "components": {}}\n' > "$_sv_home/manifest.json"
_sv_launcher_setup="PATH='$_SV_CLEAN_PATH'; . '$ROOT/setup/lib/detect.sh'; . '$ROOT/setup/lib/runtime-personal.sh'"
check "step_state(launcher missing)" "missing" \
    "$(_sv_state "$_sv_home" launcher "$_sv_launcher_setup")"
check "begin_step(launcher missing)" "rerun" \
    "$(_sv_step "$_sv_home" launcher "$_sv_launcher_setup")"
# ...and with the binary back, the completed step must still be skipped.
printf '#!/bin/sh\nexit 0\n' > "$_sv_home/bin/exasol"
chmod +x "$_sv_home/bin/exasol"
check "step_state(launcher present)" "present" \
    "$(_sv_state "$_sv_home" launcher "$_sv_launcher_setup")"
check "begin_step(launcher present)" "skip" \
    "$(_sv_step "$_sv_home" launcher "$_sv_launcher_setup")"
rm -rf "$_sv_home"

# exakit_helper: the same shape, on the artifact the helper step installs.
_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin"
printf '{"steps_completed": ["exakit_helper"], "components": {}}\n' > "$_sv_home/manifest.json"
check "step_state(exakit_helper missing)" "missing" "$(_sv_state "$_sv_home" exakit_helper "")"
check "begin_step(exakit_helper missing)" "rerun" "$(_sv_step "$_sv_home" exakit_helper "")"
printf '#!/bin/sh\nexit 0\n' > "$_sv_home/bin/exakit"
chmod +x "$_sv_home/bin/exakit"
check "step_state(exakit_helper present)" "present" "$(_sv_state "$_sv_home" exakit_helper "")"
check "begin_step(exakit_helper present)" "skip" "$(_sv_step "$_sv_home" exakit_helper "")"
rm -rf "$_sv_home"

# runtime is the "unknown" case that matters most: no file test can prove a
# database deployment is gone, so a completed runtime step is ALWAYS skipped.
_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin"
printf '{"steps_completed": ["runtime", "mcp", "pyexasol"], "components": {}}\n' > "$_sv_home/manifest.json"
for _sv_unknown in runtime mcp pyexasol; do
    check "step_state($_sv_unknown)" "unknown" "$(_sv_state "$_sv_home" "$_sv_unknown" "")"
    check "begin_step($_sv_unknown recorded)" "skip" "$(_sv_step "$_sv_home" "$_sv_unknown" "")"
done
# A step that was never recorded runs, with no re-run notice.
check "begin_step(launcher not recorded)" "run" "$(_sv_step "$_sv_home" launcher "$_sv_launcher_setup")"
rm -rf "$_sv_home"

# exapump is judged by the path the install recorded. No recorded path is
# "unknown" (an older install, or a soft failure) — never "missing".
_sv_home="$(mktemp -d)"
mkdir -p "$_sv_home/bin"
printf '{"steps_completed": ["exapump"], "components": {}}\n' > "$_sv_home/manifest.json"
check "step_state(exapump unrecorded)" "unknown" "$(_sv_state "$_sv_home" exapump "")"
check "begin_step(exapump unrecorded)" "skip" "$(_sv_step "$_sv_home" exapump "")"
printf '{"steps_completed": ["exapump"], "components": {"exapump": {"path": "%s"}}}\n' \
    "$_sv_home/bin/exapump" > "$_sv_home/manifest.json"
check "step_state(exapump missing)" "missing" "$(_sv_state "$_sv_home" exapump "")"
check "begin_step(exapump missing)" "rerun" "$(_sv_step "$_sv_home" exapump "")"
printf '#!/bin/sh\nexit 0\n' > "$_sv_home/bin/exapump"
chmod +x "$_sv_home/bin/exapump"
check "step_state(exapump present)" "present" "$(_sv_state "$_sv_home" exapump "")"
check "begin_step(exapump present)" "skip" "$(_sv_step "$_sv_home" exapump "")"
rm -rf "$_sv_home"

# The check must cost nothing on every install: file tests only. Anything that
# could wake a container engine, or reach the network, belongs nowhere near it.
_sv_body="$(awk '/^step_artifact_state\(\) \{/ { inside = 1 } inside { print } inside && /^}/ { exit }' \
    "$ROOT/setup/lib/common.sh")"
if printf '%s\n' "$_sv_body" | grep -q 'launcher)' && \
   ! printf '%s\n' "$_sv_body" | grep -Eq 'docker|podman|curl|fetch |nano_status|personal_status|exasol info'; then
    check "step_state(file_tests_only)" "yes" "yes"
else
    check "step_state(file_tests_only)" "yes" "no"
fi

# Both sides carry the same two halves: the artifact table and a begin_step that
# only lets a proven "missing" override the manifest tick.
if grep -q 'step_artifact_state' "$ROOT/setup/lib/common.sh" && \
   grep -q 'Get-ExakitStepArtifactState' "$ROOT/setup/lib/exakit-common.ps1" && \
   grep -q 'what it installed is missing' "$ROOT/setup/lib/common.sh" && \
   grep -q 'what it installed is missing' "$ROOT/setup/lib/exakit-common.ps1"; then
    check "step_state(ps_parity)" "yes" "yes"
else
    check "step_state(ps_parity)" "yes" "no"
fi

echo
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ]
