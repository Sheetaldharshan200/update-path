# exasol-vscode.ps1 - Exasol for VS Code (editor extension): managed install +
# validation.
#
# Windows counterpart of exasol-vscode.sh. A MARKETPLACE ADD-ON: never
# installed by the setup scripts. The user picks it from `exakit marketplace`;
# once installed it joins `exakit update` like every other component.
#
# Extension facts:
#   - github.com/exasol-labs/exasol-vscode; extension id exasol.exasol-vscode
#   - releases carry ONE platform-independent exasol-vscode-<ver>.vsix with a
#     sha256 digest published by the release API - verified with the same
#     three-tier chain exapump uses (versions.json -> pinned -> release API).
#   - installed with VS Code's own CLI: code --install-extension <vsix>. The
#     extension lives in VS Code's extensions dir, NOT under the kit home;
#     `exakit uninstall` removes a KIT-INSTALLED copy through the
#     Uninstall-ExasolVscode hook below (selectable on its own from the
#     uninstall menu), and never touches one the user installed themselves.
#   - a copy the user already installed from the VS Code Marketplace counts as
#     "on this system": the kit never offers a second one and never manages it.

$script:ExasolVscodeVersionFallback = if ($env:EXAKIT_EXASOL_VSCODE_VERSION_FALLBACK) { $env:EXAKIT_EXASOL_VSCODE_VERSION_FALLBACK } else { "1.7.0" }
$script:ExasolVscodeVersion = if ($env:EXAKIT_EXASOL_VSCODE_VERSION) { $env:EXAKIT_EXASOL_VSCODE_VERSION } else { "" }
$script:ExasolVscodeRepo = if ($env:EXAKIT_EXASOL_VSCODE_REPO) { $env:EXAKIT_EXASOL_VSCODE_REPO } else { "exasol-labs/exasol-vscode" }
$script:ExasolVscodeExtId = if ($env:EXAKIT_EXASOL_VSCODE_EXT_ID) { $env:EXAKIT_EXASOL_VSCODE_EXT_ID } else { "exasol.exasol-vscode" }
# Optional extensions-dir override: tests point this at a sandbox so a real
# install never touches the user's VS Code profile.
$script:ExasolVscodeExtDir = if ($env:EXAKIT_EXASOL_VSCODE_EXTDIR) { $env:EXAKIT_EXASOL_VSCODE_EXTDIR } else { "" }

# VS Code's `code` command, discovered the way the kit discovers Docker
# Desktop: PATH first, then the places the app actually lives when the user
# never registered the shell command. $null means "no VS Code on this machine".
# Twin of exasol_vscode_code_cli in exasol-vscode.sh.
function Get-ExasolVscodeCodeCli {
    $recorded = Get-ExakitManifestValue "components.exasol_vscode.code_cli"
    if ($recorded -and (Test-Path $recorded)) { return $recorded }
    $found = Get-Command code -ErrorAction SilentlyContinue
    if ($found -and $found.Source) { return $found.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"),
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    return $null
}

# Run the code CLI with the optional sandbox extensions-dir applied.
function Invoke-ExasolVscodeCode {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $cli = Get-ExasolVscodeCodeCli
    if (-not $cli) { return $null }
    if ($script:ExasolVscodeExtDir) {
        $Arguments = @("--extensions-dir", $script:ExasolVscodeExtDir) + $Arguments
    }
    return (& $cli @Arguments 2>$null)
}

# The version VS Code itself reports for the extension; $null when it is not
# installed there. The single source of truth for "is it really on this machine".
function Get-ExasolVscodeLiveVersion {
    $listing = Invoke-ExasolVscodeCode -Arguments @("--list-extensions", "--show-versions")
    if (-not $listing) { return $null }
    foreach ($line in @($listing)) {
        $line = ("" + $line).Trim()
        if ($line -match ("^(?i)" + [regex]::Escape($script:ExasolVscodeExtId) + "@(.+)$")) {
            return $Matches[1]
        }
    }
    return $null
}

# KIT-MANAGED install only: the manifest record proves the kit installed it,
# and VS Code's own listing proves it is still there.
function Get-ExasolVscodeInstalledVersion {
    if (-not (Get-ExakitManifestValue "components.exasol_vscode.version")) { return $null }
    return (Get-ExasolVscodeLiveVersion)
}

# An editor extension is only an option when the editor is here. Without VS
# Code the add-on is not offered at all: no row in the marketplace, no mention
# in the closing offer or the discovery lines. An already kit-installed copy
# stays visible either way, so it can still be updated or removed.
# Twin of exasol_vscode_applicable.
function Test-ExasolVscodeApplicable {
    return [bool](Get-ExasolVscodeCodeCli)
}

function Get-ExasolVscodeApplicableReason {
    return "VS Code was not found (install it from https://code.visualstudio.com, then run: exakit marketplace)"
}

function Get-ExasolVscodeAssetName {
    param([Parameter(Mandatory)][string]$Version)
    return "exasol-vscode-$Version.vsix"
}

# The digest the download is verified against - same three-tier chain as
# exapump. Twin of exasol_vscode_expected_sha256.
function Get-ExasolVscodeExpectedSha256 {
    param([Parameter(Mandatory)][string]$Version)
    $advertised = Get-ExakitVersionsValue -Path "components.exasol-vscode.version"
    if ($advertised -and $advertised -eq $Version) {
        $digest = Get-ExakitVersionsValue -Path "components.exasol-vscode.sha256.vsix"
        if ($digest -and $digest -match '^[0-9a-f]{64}$') { return $digest }
    }
    $digest = Get-ExasolVscodePinnedSha256 -Version $Version
    if ($digest) { return $digest }
    return (Get-ExasolVscodeDigestFromApi -Version $Version)
}

# Digest of the bundled fallback release (published by the release API).
function Get-ExasolVscodePinnedSha256 {
    param([Parameter(Mandatory)][string]$Version)
    switch ($Version) {
        "1.7.0" { return "901badff486da4f41bb285463be152dd036437cdd54fbbde51328954c8e9b3c5" }
    }
    return ""
}

function Get-ExasolVscodeDigestFromApi {
    param([Parameter(Mandatory)][string]$Version)
    try {
        $release = Invoke-RestMethod -UseBasicParsing -TimeoutSec 30 `
            -Uri "https://api.github.com/repos/$($script:ExasolVscodeRepo)/releases/tags/v$Version"
    } catch {
        return ""
    }
    $asset = Get-ExasolVscodeAssetName -Version $Version
    foreach ($entry in @($release.assets)) {
        if ($entry.name -eq $asset -and ("" + $entry.digest).StartsWith("sha256:")) {
            return ("" + $entry.digest).Substring(7)
        }
    }
    return ""
}

# Report a soft failure and return $false. Marketplace add-ons follow the
# pyexasol contract: nothing here may end the caller's run.
function Write-ExasolVscodeNotInstalled {
    param([Parameter(Mandatory)][string]$Reason)
    Warn2 "Exasol for VS Code was not installed: $Reason"
    Warn2 "Everything else in the kit is unaffected. Retry with: exakit update exasol-vscode"
    if (Get-Command Set-ExakitFailureReason -ErrorAction SilentlyContinue) {
        Set-ExakitFailureReason $Reason
    }
    Set-ExakitManifestValue "components.exasol_vscode.validated" $false
    return $false
}

function Install-ExasolVscode {
    # Resolve the advertised version here: neither caller has one ready. The
    # marketplace path runs from the exakit CLI, where the installer's version
    # resolution has not run; the setup script's closing offer does not load the
    # CLI at all, so Get-ExakitComponentAvailable is not even defined there.
    # Get-ExakitAddonAdvertisedVersion answers in both.
    if (-not $script:ExasolVscodeVersion) {
        $script:ExasolVscodeVersion = Get-ExakitAddonAdvertisedVersion -Id "exasol-vscode" -Fallback $script:ExasolVscodeVersionFallback
    }

    $cli = Get-ExasolVscodeCodeCli
    if (-not $cli) {
        return (Write-ExasolVscodeNotInstalled "VS Code's 'code' command was not found - install VS Code (https://code.visualstudio.com), then retry")
    }

    $live = Get-ExasolVscodeLiveVersion
    if ($live -and $live -eq $script:ExasolVscodeVersion -and $env:EXAKIT_FORCE_COMPONENT_INSTALL -ne "1") {
        Ok "Exasol for VS Code $live already installed"
    } else {
        $asset = Get-ExasolVscodeAssetName -Version $script:ExasolVscodeVersion
        $url = "https://github.com/$($script:ExasolVscodeRepo)/releases/download/v$($script:ExasolVscodeVersion)/$asset"
        $vsix = Join-Path ([System.IO.Path]::GetTempPath()) ("exakit-" + [guid]::NewGuid().ToString() + ".vsix")
        Info "Downloading Exasol for VS Code v$($script:ExasolVscodeVersion) ($asset)"
        try {
            # Animated: the download is the longest silent stretch of this
            # install. Twin of fetch_quiet on the shell side.
            [void](Invoke-ExakitWithSpinner -Label "Downloading $asset" -Body {
                Invoke-WebRequest -UseBasicParsing -TimeoutSec 300 -Uri $url -OutFile $vsix
            })
        } catch {
            Remove-Item -Force -ErrorAction SilentlyContinue $vsix
            return (Write-ExasolVscodeNotInstalled "the download failed: $url ($_)")
        }

        # Same verification bar as exapump: a downloaded artifact is never
        # installed unverified - soft-fail instead of throwing, because the
        # marketplace contract says nothing here may end the caller's run.
        $expected = Get-ExasolVscodeExpectedSha256 -Version $script:ExasolVscodeVersion
        if ($expected) {
            $actual = (Get-FileHash -Algorithm SHA256 -Path $vsix).Hash.ToLower()
            if ($actual -ne $expected) {
                Remove-Item -Force -ErrorAction SilentlyContinue $vsix
                return (Write-ExasolVscodeNotInstalled "checksum mismatch for $asset (expected $expected, got $actual)")
            }
            Ok "Checksum verified: $asset"
        } elseif ($env:EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE -eq "1") {
            Warn2 "No digest available for $asset - proceeding WITHOUT checksum verification (EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE=1)."
        } else {
            Remove-Item -Force -ErrorAction SilentlyContinue $vsix
            return (Write-ExasolVscodeNotInstalled "no checksum is available for $asset; refusing an unverified extension. Add its digest to versions.json (components.exasol-vscode.sha256.vsix) or check network access to the release API. Override at your own risk with EXAKIT_ALLOW_UNVERIFIED_EXASOL_VSCODE=1")
        }

        Info "Installing the extension into VS Code"
        $installArgs = @("--install-extension", $vsix, "--force")
        if ($script:ExasolVscodeExtDir) { $installArgs = @("--extensions-dir", $script:ExasolVscodeExtDir) + $installArgs }
        $previous = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Continue"
            $out = & $cli @installArgs 2>&1 | Out-String
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previous
        }
        if ($script:LogFile) { $out | Add-Content -Path $script:LogFile }
        Remove-Item -Force -ErrorAction SilentlyContinue $vsix
        if ($code -ne 0) {
            return (Write-ExasolVscodeNotInstalled "code --install-extension failed (see log)")
        }
        # The install is not done until VS Code can answer for the version.
        $now = Get-ExasolVscodeLiveVersion
        if (-not $now) {
            return (Write-ExasolVscodeNotInstalled "VS Code does not list $($script:ExasolVscodeExtId) after the install (see log)")
        }
        Ok "Exasol for VS Code installed ($now)"
    }

    Set-ExakitManifestValue "components.exasol_vscode.version" $script:ExasolVscodeVersion
    Set-ExakitManifestValue "components.exasol_vscode.extension_id" $script:ExasolVscodeExtId
    Set-ExakitManifestValue "components.exasol_vscode.code_cli" $cli
    return $true
}

# VS Code's own listing is the proof. Soft, like every marketplace validation.
function Test-ExasolVscode {
    $live = Get-ExasolVscodeLiveVersion
    if (-not $live) {
        Warn2 "VS Code does not list $($script:ExasolVscodeExtId). Recorded validated=false; retry with: exakit update exasol-vscode"
        Set-ExakitManifestValue "components.exasol_vscode.validated" $false
        return
    }
    Set-ExakitManifestValue "components.exasol_vscode.validated" $true
    Ok "Exasol for VS Code answers: $($script:ExasolVscodeExtId)@$live"
    # See the note on Write-DashServerUsagePanel: a marketplace install is not
    # where a reference card belongs.
    if ($script:ExakitQuietDetail) {
        Write-ExakitLog "DATA" "exasol-vscode: the Exasol view appears in VS Code's activity bar"
        return
    }
    Start-ExakitPanel "Exasol for VS Code"
    Write-ExakitPanelLine "Open VS Code    the Exasol view appears in the activity bar"
    Write-ExakitPanelLine "Connect it      DSN and credentials: exakit info"
    Write-ExakitPanelLine "Update          exakit update exasol-vscode"
    Complete-ExakitPanel
}

# Get-ExasolVscodeSummary - the one fact worth a place on the result line.
# Optional registry hook (SummaryFn); twin of exasol_vscode_summary.
function Get-ExasolVscodeSummary {
    # 32 characters: the finished cell truncates at 33 in the plain palette.
    return "Exasol view in VS Code's sidebar"
}

# Remove the KIT-MANAGED extension from VS Code through VS Code's own CLI,
# plus the manifest record. -DryRun only narrates the plan. A copy the kit
# never installed (no manifest record - a VS Code Marketplace install) is
# refused: the kit does not uninstall what it does not manage. Best-effort
# and idempotent. Twin of exasol_vscode_uninstall.
function Uninstall-ExasolVscode {
    param([switch]$DryRun)
    if (-not (Get-ExakitManifestValue "components.exasol_vscode.version")) {
        Info "The Exasol VS Code extension is not kit-managed - nothing to remove."
        Info "A copy you installed yourself is removed inside VS Code, or with: code --uninstall-extension $($script:ExasolVscodeExtId)"
        return $true
    }
    if ($DryRun) {
        Info "  will remove: the Exasol VS Code extension ($($script:ExasolVscodeExtId)) from VS Code"
        return $true
    }
    if (Get-ExasolVscodeLiveVersion) {
        Info "Removing the Exasol VS Code extension ($($script:ExasolVscodeExtId))"
        [void](Invoke-ExasolVscodeCode -Arguments @("--uninstall-extension", $script:ExasolVscodeExtId))
        if (Get-ExasolVscodeLiveVersion) {
            Warn2 "VS Code still lists $($script:ExasolVscodeExtId) - a running VS Code may hold it; remove it from the Extensions view."
        }
    }
    Remove-ExakitManifestValue "components.exasol_vscode"
    Remove-ExakitManifestValue "desired.exasol_vscode"
    Ok "Exasol for VS Code removed - reinstall any time with: exakit marketplace"
    return $true
}

# Install the advertised version. Doubles as the repair command. Asked for
# explicitly, so a failure here IS a failure. Twin of exasol_vscode_update.
function Update-ExasolVscode {
    $available = Get-ExakitComponentAvailable "exasol-vscode"
    if (-not $available) { Fail "Could not resolve the advertised exasol-vscode version." }
    $current = Get-ExasolVscodeInstalledVersion
    if ($current -and $current -eq $available) {
        Ok "Exasol for VS Code is already current ($current)"
        return
    }
    if ($current) { Info "Updating Exasol for VS Code $current -> $available" }
    else { Info "Installing Exasol for VS Code $available" }
    $script:ExasolVscodeVersion = $available
    $env:EXAKIT_FORCE_COMPONENT_INSTALL = "1"
    try {
        if (-not (Install-ExasolVscode)) {
            Fail "Exasol for VS Code could not be installed - see the warning above and the log."
        }
    } finally {
        Remove-Item Env:EXAKIT_FORCE_COMPONENT_INSTALL -ErrorAction SilentlyContinue
    }
    Test-ExasolVscode
    Set-ExakitManifestValue "desired.exasol_vscode" $script:ExasolVscodeVersion
    Ok "Exasol for VS Code updated; database data was not changed"
}
