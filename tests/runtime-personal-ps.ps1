#!/usr/bin/env pwsh
# runtime-personal-ps.ps1 - behavioural tests for setup/lib/runtime-personal.ps1
# (the Windows twin of runtime-personal.sh). Dot-sources the real modules
# against a fully sandboxed kit home and asserts the twin holds the same
# contracts the sh suite pins: the deployment's own port beats the constant,
# state files answer for the deployed version, the wedge probe reads the
# launcher's workflow state, the guest rebuild is recognised, the manifest keys
# come out identical to the sh side's, and the per-subcommand --auto-approve
# probe says yes and no against a stub launcher.
#
#   pwsh -NoProfile -File tests/runtime-personal-ps.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$script:PASS = 0
$script:FAIL = 0
function Check($label, $expected, $actual) {
    if ("$expected" -eq "$actual") { $script:PASS++; Write-Host "  ok   $label = $actual" }
    else { $script:FAIL++; Write-Host "  FAIL $($label): expected $expected, got $actual" }
}

# --- sandbox ----------------------------------------------------------------
$work = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-rp-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force -Path $work | Out-Null
$env:EXAKIT_HOME = Join-Path $work "home"
$env:EXAKIT_BIN_DIR = Join-Path $work "bin"
$env:EXAKIT_PERSONAL_DEPLOY_DIR = Join-Path $work "no-deployment-yet"
Remove-Item Env:EXAKIT_PERSONAL_VERSION -ErrorAction SilentlyContinue

. (Join-Path $repo "setup/lib/exakit-common.ps1")
. (Join-Path $repo "setup/lib/runtime-personal.ps1")

# HERMETIC LAUNCHER. Get-PersonalCli falls back to an "exasol" on PATH, so
# without this every probe answers from the developer's real launcher - and a
# check that pins a launcher VERSION then passes or fails on which machine ran
# it. The stub answers the three things the probes ask: its version, the
# per-subcommand help, and `info`.
# $env:OS, not $IsWindows: the automatic variable does not exist on 5.1, where
# it is $null and would route the Windows runner onto the sh stub (and chmod).
$onWindows = ($env:OS -like "*Windows*")
$script:stubSeq = 0
function New-StubLauncher([string]$Version) {
    $script:stubSeq++
    $dir = Join-Path $work "stub$($script:stubSeq)"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if ($onWindows) {
        $path = Join-Path $dir "exasol.cmd"
        # %~1/%~2, not %1/%2: Invoke-ExakitBounded quotes every argument and cmd
        # keeps those quotes in %1, so an unstripped compare never matches.
        Set-Content -Path $path -Encoding Ascii -Value @(
            "@echo off",
            "if `"%~1`"==`"version`" (echo $Version",
            "exit /b 0)",
            "if `"%~1 %~2`"==`"install --help`" (echo   -a, --auto-approve   Approve host preparation",
            "exit /b 0)",
            "echo   --help    help"
        )
    } else {
        $path = Join-Path $dir "exasol"
        Set-Content -Path $path -Value @(
            "#!/bin/sh",
            "if [ `"`$1`" = version ]; then printf '$Version\n'; exit 0; fi",
            "if [ `"`$1 `$2`" = 'install --help' ]; then printf '  -a, --auto-approve   Approve host preparation\n'; exit 0; fi",
            "printf '  --help    help\n'",
            "exit 0"
        )
        chmod +x $path
    }
    return $path
}

Write-Host "the deployment's own port beats the constant:"
$dep = Join-Path $work "deploy"
New-Item -ItemType Directory -Force -Path $dep | Out-Null
Set-Content -Path (Join-Path $dep "deployment.json") -Value '{"connection": {"host": "127.0.0.1", "dbPort": 8571, "username": "sys"}}'
$script:PersonalDeployDir = $dep
Check "port(configured)" 8571 (Get-PersonalDbPort)
$script:PersonalDeployDir = Join-Path $work "absent"
Check "port(no deployment falls back)" 8563 (Get-PersonalDbPort)

Write-Host "state files answer for the deployed version:"
$dep2 = Join-Path $work "deploy2"
New-Item -ItemType Directory -Force -Path $dep2 | Out-Null
Set-Content -Path (Join-Path $dep2 ".exasolLauncher.version") -Value "2.2.0"
$script:PersonalDeployDir = $dep2
Check "deployed(bare version file)" "2.2.0" (Get-PersonalDeployedVersion)
Remove-Item -Force (Join-Path $dep2 ".exasolLauncher.version")
Set-Content -Path (Join-Path $dep2 ".exasolLauncherState.json") -Value '{"deploymentVersion": "v2.1.5", "currentWorkflowState": {"interrupted": {"reason": "killed"}}}'
Check "deployed(state json, v stripped)" "2.1.5" (Get-PersonalDeployedVersion)
Set-Content -Path (Join-Path $dep2 ".exasolLauncher.version") -Value "not a version!!"
Check "garbage reads as unknown, never a blocker" "" "$(Get-PersonalDeployedVersion)"
Remove-Item -Force (Join-Path $dep2 ".exasolLauncher.version")

Write-Host "the wedge probe reads the launcher's workflow state:"
Check "wedged(interrupted present)" $true (Test-PersonalDeploymentWedged)
Set-Content -Path (Join-Path $dep2 ".exasolLauncherState.json") -Value '{"deploymentVersion": "2.1.5", "currentWorkflowState": {}}'
Check "wedged(clean state)" $false (Test-PersonalDeploymentWedged)

Write-Host "the guest rebuild is recognised, and only across a launcher change:"
Set-Content -Path (Join-Path $dep2 ".exasolLauncher.version") -Value "2.2.0"
Remove-Item Env:EXAKIT_PERSONAL_VERSION -ErrorAction SilentlyContinue
# The LAUNCHER's own version decides this, so a stub reports it.
$script:PersonalBinPath = New-StubLauncher "2.3.0-rc2"
Check "the launcher reports its own version" "2.3.0-rc2" (Get-PersonalLauncherVersion)
Check "rebuild(2.2.0 deployment, 2.3 launcher)" $true (Test-PersonalGuestRebuildExpected)
$script:PersonalBinPath = New-StubLauncher "2.2.0"
Check "rebuild(same version)" $false (Test-PersonalGuestRebuildExpected)
$script:PersonalBinPath = New-StubLauncher "2.3.0-rc2"

Write-Host "the manifest keys are the sh side's, byte for byte:"
Set-Content -Path (Join-Path $dep2 "deployment.json") -Value '{"connection": {"host": "127.0.0.1", "dbPort": 8571, "username": "sys"}}'
Set-Content -Path (Join-Path $dep2 "secrets.json") -Value '{"dbPassword": "s3cret"}'
Initialize-ExakitManifest
Set-PersonalManifest "stopped"
Check "runtime.type" "personal" (Get-ExakitManifestValue "runtime.type")
Check "runtime.dsn" "127.0.0.1:8571" (Get-ExakitManifestValue "runtime.dsn")
Check "runtime.user" "sys" (Get-ExakitManifestValue "runtime.user")
Check "runtime.tls" "self-signed" (Get-ExakitManifestValue "runtime.tls")
Check "runtime.status is the argument, never assumed" "stopped" (Get-ExakitManifestValue "runtime.status")
# runtime.version is the COMPONENT versions.json names - the launcher - so a
# completed update converges instead of advertising itself forever; the
# deployment's own version rides beside it.
Check "runtime.version is the launcher's" "2.3.0-rc2" (Get-ExakitManifestValue "runtime.version")
Check "runtime.deployment_version is the deployment's" "2.2.0" (Get-ExakitManifestValue "runtime.deployment_version")
# ...and the rebuild notice retires once a start has completed under it.
Set-ExakitManifestValue "runtime.guest_rebuilt_for" "2.3.0-rc2"
Check "a completed start retires the rebuild notice" $false (Test-PersonalGuestRebuildExpected)
Remove-ExakitManifestValue "runtime.guest_rebuilt_for"
$credFile = Join-Path $script:CredsDir "personal_sys_password"
Check "the password lands in the credentials store" $true (Test-Path $credFile)
Check "runtime.password_file points at it" $credFile (Get-ExakitManifestValue "runtime.password_file")
# The password itself is compared where it lives, never printed on a FAIL line.
Check "the stored credential is the secrets' password" $true ((Get-Content $credFile -Raw).Trim() -eq "s3cret")

Write-Host "the per-subcommand --auto-approve probe, against a stub launcher:"
# A stub whose install advertises the flag and whose start does not - the exact
# case the sh suite pins, because no top-level probe can tell them apart.
# The same hermetic stub the rebuild checks used.
$script:PersonalBinPath = New-StubLauncher "2.3.0-rc2"
Check "a launcher that takes the flag gets it" "--auto-approve" (Get-PersonalAutoApproveFlag "install")
Check "a launcher that does not is left alone" "" "$(Get-PersonalAutoApproveFlag 'start')"

Write-Host "status vocabulary:"
# The stub answers `info` (exit 0), the deployment dir exists, nothing listens
# on the fixture port - a stopped deployment, in the documented word.
$script:PersonalDeployDir = $dep2
Check "status(deployment exists, port silent)" "stopped" (Get-PersonalStatus)
$script:PersonalDeployDir = Join-Path $work "absent"
Check "status(no deployment)" "not deployed" (Get-PersonalStatus)

Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "passed: $($script:PASS), failed: $($script:FAIL)"
if ($script:FAIL -gt 0) { exit 1 }
