# exakit-common.ps1 - shared helpers for the Exasol Personal Local Starter Kit
# (Windows / PowerShell path).
#
# Dot-sourced by setup-windows-docker.ps1 and setup/exakit.ps1. Not meant to
# be executed directly. Targets Windows PowerShell 5.1 (built into every
# Windows 10/11 machine) as well as PowerShell 7+ - no version-7-only syntax
# (no ternary, no null-coalescing, no -AsHashtable on ConvertFrom-Json).
#
# Mirrors setup/lib/common.sh function-for-function so the two platforms
# cannot drift apart in behavior. Where bash shells out to a Python one-liner
# for JSON, this file uses native PowerShell JSON handling instead.

$ErrorActionPreference = "Stop"

# Suppress the progress stream for the whole kit. Two reasons: (1) it removes
# the "TCP connect to ..."-style progress banners that cmdlets like
# Test-NetConnection / Invoke-WebRequest pin to the top of the console, which
# users found noisy; (2) on Windows PowerShell 5.1 a visible progress bar makes
# Invoke-WebRequest an order of magnitude slower, so silencing it speeds up
# every download step. Callers that genuinely want progress can override.
$ProgressPreference = "SilentlyContinue"

# ---------------------------------------------------------------------------
# Shared visual layer (banner, boxes, spinner, colour palette)
# ---------------------------------------------------------------------------
# ui.ps1 owns how the installer LOOKS (twin of setup/lib/ui.sh). Dot-source it
# first so Info/Ok/Begin-ExakitStep/Show-ExakitConnectionPanel below can use
# its palette and glyphs. If it is somehow absent, install no-op stubs and an
# empty palette so nothing here breaks.
try { . (Join-Path $PSScriptRoot "ui.ps1") } catch { }
if (-not (Get-Command Start-ExakitSpinner -ErrorAction SilentlyContinue)) {
    $script:UiFancy = $false
    foreach ($v in 'UiReset','UiBold','UiDim','UiAccent','UiOk','UiWarn','UiErr','UiInfo','UiAsk') {
        Set-Variable -Scope script -Name $v -Value ""
    }
    $script:UiTick = "+"; $script:UiCross = "x"; $script:UiArrow = ">"; $script:UiBullet = "-"; $script:UiVB = "|"
    $script:UiTee = "|-"; $script:UiCorner = '`-'
    function Start-ExakitSpinner([string]$Label) { }
    function Stop-ExakitSpinner { }
    function Restore-ExakitCursor { }
    function Get-ExakitTilde([string]$Path) { return $Path }
    function Write-ExakitBanner {
        param([string]$Title = "Exasol Personal Local Starter Kit", [string]$Subtitle = "")
        Write-Host ""; Write-Host "  $Title"; if ($Subtitle) { Write-Host "  $Subtitle" }; Write-Host ""
    }
    function Start-ExakitPanel([string]$Title) { Write-Host ""; Write-Host "  -- $Title --" }
    function Write-ExakitPanelLine([string]$Text) { Write-Host "   $Text" }
    function Complete-ExakitPanel { Write-Host "" }
}

# ---------------------------------------------------------------------------
# State locations
# ---------------------------------------------------------------------------
$script:ExakitHome   = if ($env:EXAKIT_HOME) { $env:EXAKIT_HOME } else { Join-Path $HOME ".exasol-starter-kit" }
$script:LogDir       = Join-Path $script:ExakitHome "logs"
$script:CacheDir     = Join-Path $script:ExakitHome "cache"
$script:CredsDir     = Join-Path $script:ExakitHome "credentials"
$script:ManifestPath = Join-Path $script:ExakitHome "manifest.json"
$script:McpDir       = Join-Path $script:ExakitHome "mcp"
# Where an approved query is saved so it can be re-run tomorrow. The skill's
# closing step ("make it rerunnable") names this directory by name, so it has to
# exist: telling an agent to write into a path nothing creates turns the last
# step of the trust loop into a mkdir it has to guess at.
$script:WorkflowsDir = Join-Path $script:ExakitHome "workflows"
$script:BinDir       = if ($env:EXAKIT_BIN_DIR) { $env:EXAKIT_BIN_DIR } else { Join-Path $HOME ".local\bin" }
$script:ManagedPythonVersion = if ($env:EXAKIT_MANAGED_PYTHON_VERSION) { $env:EXAKIT_MANAGED_PYTHON_VERSION } else { "3.12" }
$script:McpReadonlyUser    = if ($env:EXAKIT_MCP_READONLY_USER) { $env:EXAKIT_MCP_READONLY_USER } else { "mcp_readonly" }
$script:McpReadonlySchemas = if ($env:EXAKIT_MCP_READONLY_SCHEMAS) { $env:EXAKIT_MCP_READONLY_SCHEMAS } else { "STARTER_KIT" }

# ---------------------------------------------------------------------------
# Component version policy
# ---------------------------------------------------------------------------
# manifest (default) - take the version set the maintainers tested together,
#                      from versions.json (see below).
# latest             - resolve each Component independently from its upstream
#                      (GitHub releases, PyPI, Docker Hub).
# anything else      - install the *Fallback versions below, no network at all.
$script:VersionPolicy = if ($env:EXAKIT_VERSION_POLICY) { $env:EXAKIT_VERSION_POLICY } else { "manifest" }
$script:NanoImage       = "exasol/nano"
$script:NanoTagFallback = if ($env:EXAKIT_NANO_TAG_FALLBACK) { $env:EXAKIT_NANO_TAG_FALLBACK } else { "2026.2.0-nano.3" }
$script:ExapumpVersionFallback = if ($env:EXAKIT_EXAPUMP_VERSION_FALLBACK) { $env:EXAKIT_EXAPUMP_VERSION_FALLBACK } else { "0.12.0" }
$script:McpVersionFallback = if ($env:EXAKIT_MCP_VERSION_FALLBACK) { $env:EXAKIT_MCP_VERSION_FALLBACK } else { "2.0.0" }
$script:NanoTag         = if ($env:EXAKIT_NANO_TAG) { $env:EXAKIT_NANO_TAG } else { "" }
$script:ExapumpVersion  = if ($env:EXAKIT_EXAPUMP_VERSION) { $env:EXAKIT_EXAPUMP_VERSION } else { "" }
$script:ExapumpRepo     = "exasol-labs/exapump"
$script:McpPackage      = if ($env:EXAKIT_MCP_PACKAGE) { $env:EXAKIT_MCP_PACKAGE } else { "exasol-mcp-server" }
$script:McpVersion      = if ($env:EXAKIT_MCP_VERSION) { $env:EXAKIT_MCP_VERSION } else { "" }
$script:PyexasolPackage = if ($env:EXAKIT_PYEXASOL_PACKAGE) { $env:EXAKIT_PYEXASOL_PACKAGE } else { "pyexasol" }
$script:PyexasolVersionFallback = if ($env:EXAKIT_PYEXASOL_VERSION_FALLBACK) { $env:EXAKIT_PYEXASOL_VERSION_FALLBACK } else { "2.3.1" }
$script:PyexasolVersion = if ($env:EXAKIT_PYEXASOL_VERSION) { $env:EXAKIT_PYEXASOL_VERSION } else { "" }
# Marketplace add-ons (dash-server, ...) carry their own version constants in
# their module files - they are not part of the install flow, so nothing here
# needs to know them.
$script:DbPort          = if ($env:EXAKIT_DB_PORT) { $env:EXAKIT_DB_PORT } else { "8563" }

# The versions manifest (versions.json at the root of the kit repository on
# main) is the maintainer-edited record of the version set that was tested
# together. It is fetched over plain HTTPS from GitHub's raw endpoint - the same
# trust domain that already serves install.ps1 - and cached under the kit home.
# Nothing is collected on our side: the request carries a User-Agent header and
# no query string, and no third party is involved.
if ($env:EXAKIT_KIT_REPO) { $script:KitRepo = $env:EXAKIT_KIT_REPO }
elseif ($env:EXAKIT_REPO) { $script:KitRepo = $env:EXAKIT_REPO }
else { $script:KitRepo = "exasol-labs/exasol-personal-local-starterkit" }
$script:VersionsUrl = if ($env:EXAKIT_VERSIONS_URL) { $env:EXAKIT_VERSIONS_URL } else { "https://raw.githubusercontent.com/$($script:KitRepo)/main/versions.json" }
# The public install entry point for Windows. Twin of EXAKIT_INSTALL_URL in
# common.sh, pointing at the PowerShell installer rather than the shell one.
$script:InstallUrl = if ($env:EXAKIT_INSTALL_URL) { $env:EXAKIT_INSTALL_URL } else { "https://www.exasol.com/install/starter-kit.ps1" }

# Get-ExakitInstallCommand - the install one-liner for THIS platform. Twin of
# exakit_install_command in common.sh. Windows runs irm | iex; it does not have
# curl piped into sh, which is what this line used to print.
function Get-ExakitInstallCommand {
    return "irm $($script:InstallUrl) | iex"
}
$script:VersionsTtl = 86400
if ($env:EXAKIT_VERSIONS_TTL -match '^[0-9]+$') { $script:VersionsTtl = [int]$env:EXAKIT_VERSIONS_TTL }
$script:VersionsCachePath = if ($env:EXAKIT_VERSIONS_CACHE) { $env:EXAKIT_VERSIONS_CACHE } else { Join-Path $script:CacheDir "versions.json" }
# Schema this kit understands. A document announcing a higher number is treated
# as unavailable (the resolution chain falls back) rather than guessed at.
$script:VersionsSchema = 1
$script:VersionsDocPath = ""
$script:VersionsSource = ""
$script:VersionsSchemaAhead = $false
# Which tier of the chain actually answered, recorded as desired.versions_source
# so a support question ("where did this version come from?") has an answer.
$script:VersionsSourceUsed = ""

New-Item -ItemType Directory -Force -Path $script:ExakitHome, $script:LogDir, $script:CredsDir, $script:BinDir | Out-Null

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# One log file per process by default (mirrors bash's exakit_init_logging);
# callers that want a distinct log (load-data, exakit CLI) set $script:LogFile
# themselves before calling Initialize-ExakitLogging.
function Initialize-ExakitLogging {
    if (-not $script:LogFile) {
        $script:LogFile = Join-Path $script:LogDir ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
    }
    New-Item -ItemType File -Force -Path $script:LogFile | Out-Null
    try { Protect-ExakitFile $script:LogFile } catch { }
}

function Write-ExakitLog([string]$Level, [string]$Msg) {
    if (-not $script:LogFile) { return }
    try {
        "{0} {1,-5} {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Msg | Add-Content -Path $script:LogFile -ErrorAction Stop
    } catch {
        # The log directory can disappear mid-run - uninstall removes the kit
        # home (which contains logs/) while later status lines are still being
        # logged. Stop logging rather than surfacing a spurious "Unexpected
        # error" after the work has already succeeded.
        $script:LogFile = $null
    }
}
# Glyphs/colours come from the shared palette (ui.ps1) when a fancy terminal
# is available; otherwise fall back to Write-Host -ForegroundColor so basic
# colour still works even if ANSI/VT could not be enabled.
# One gutter under a step header: actions/results indent to the same column, so
# a step's children read as one group (mirrors ui.sh's info/ok/warn/error).
function Info([string]$Msg) {
    if ($script:UiFancy) { Write-Host ("    {0}{1}{2} {3}" -f $script:UiDim, $script:UiBullet, $script:UiReset, $Msg) }
    else { Write-Host ("    {0} {1}" -f $script:UiBullet, $Msg) }
    Write-ExakitLog "INFO" $Msg
}
function Ok([string]$Msg) {
    if ($script:UiFancy) { Write-Host ("      {0}{1}{2} {3}" -f $script:UiOk, $script:UiTick, $script:UiReset, $Msg) }
    else { Write-Host ("      {0} {1}" -f $script:UiTick, $Msg) -ForegroundColor Green }
    Write-ExakitLog "OK" $Msg
}
function Warn2([string]$Msg) {
    if ($script:UiFancy) { Write-Host ("      {0}!{1} {2}" -f $script:UiWarn, $script:UiReset, $Msg) }
    else { Write-Host "      ! $Msg" -ForegroundColor Yellow }
    Write-ExakitLog "WARN" $Msg
}

# Show-ExakitDbErrorRemedy <text> - the error-translation layer for the database
# faults every agent and every new user hits first. The engine's own messages are
# precise but remedy-free ("Connection refused", "syntax error, unexpected
# FETCH_", "object X not found"); each match here appends the one line that names
# the fix. Callers pass whatever output they captured; unknown text is silent.
#
# This side had NO translator at all until now - the Windows and Nano paths got
# the raw engine text and nothing else, so "every error message names its remedy"
# was a macOS-only promise.
# twin: exakit_explain_db_error in setup/lib/common.sh. Keep the cases and the
# wording in step.
function Show-ExakitDbErrorRemedy {
    param([string]$Text)
    if (-not $Text) { return }
    if ($Text -match 'onnection refused' -or $Text -match 'Errno 61' -or
        $Text -match 'Errno 111' -or $Text -match '(?i)could not connect') {
        Warn2 "That is the database not answering - it is stopped or unreachable. Start it with: exakit start (then check: exakit status)"
    }
    if ($Text -match 'unexpected FETCH_' -or $Text -match 'unexpected TOP_' -or $Text -match 'FETCH FIRST') {
        Warn2 "Exasol pages result sets with LIMIT <n> (optionally OFFSET) - not FETCH FIRST or TOP. Rewrite the query with LIMIT."
    }
    if ($Text -match 'not found' -and
        ($Text -match '(?i)object' -or $Text -match '(?i)table' -or $Text -match '(?i)column' -or
         $Text -match '(?i)schema' -or $Text -match '(?i)view')) {
        Warn2 "A named object does not exist as written. Check the spelling and the schema qualifier - describe it first (MCP: describe_exasol_table_or_view; SQL: DESCRIBE <schema>.<table>)."
    }
    # A write refused for lack of privilege is the read-only guardrail doing its
    # job, and the tempting next move - re-run it through `exapump -p
    # starter-kit`, which connects as admin - is the one thing that breaks the
    # trust model. Say so where the error appears, not only in the docs.
    if ($Text -match '(?i)insufficient privileges' -or $Text -match '42500') {
        Warn2 "That write was refused by the DATABASE: the MCP user is read-only by design, and this is the guardrail working as intended."
        Warn2 "Do NOT re-run it through 'exapump -p starter-kit' - that profile is the ADMIN user and is not sandboxed. If a write is genuinely wanted, say so and let the user decide."
    }
}
# Menu rendering (mirrors ui.sh's ui_menu_option/ui_menu_hint): options nest
# under the "Choose ..." action line with the number in the accent colour; the
# how-to-answer hint is a dim afterthought.
function Write-ExakitMenuOption([int]$Number, [string]$Label) {
    if ($script:UiFancy) { Write-Host ("      {0}{1}.{2} {3}" -f $script:UiAccent, $Number, $script:UiReset, $Label) }
    else { Write-Host ("      {0}. {1}" -f $Number, $Label) }
}
function Write-ExakitMenuHint([string]$Text) {
    if ($script:UiFancy) { Write-Host ("      {0}{1}{2}" -f $script:UiDim, $Text, $script:UiReset) }
    else { Write-Host ("      {0}" -f $Text) }
}
# Read-ExakitCheckboxMenu (mirrors ui.sh's ui_checkbox_menu): multi-select
# rendered as checkboxes with a movable cursor - Up/Down (or j/k) move, Space
# toggles the highlighted option, Enter confirms and moves to the next step
# ("a" selects all). At least one option must stay selected (Enter on an
# empty selection re-asks). In fancy mode the block redraws in place so
# toggling feels live. Non-interactive runs keep the defaults and say so.
# Returns the selected 1-based indices, ascending.
function Read-ExakitCheckboxMenu {
    param(
        [string]$Title, [string[]]$Options, [int[]]$Defaults = @(), [int]$ExclusiveIndex = 0,
        [int]$GroupParent = 0, [int]$GroupFirst = 0, [int]$GroupLast = 0,
        [string]$GroupMode = "any"
    )
    # $ExclusiveIndex (1-based, 0 = none): an option that cannot be combined
    # with the others - think "Skip for now". Selecting it clears every other
    # choice; selecting any other choice clears it.
    # $GroupParent/$GroupFirst/$GroupLast (optional): row $GroupParent is a
    # group checkbox whose children are rows $GroupFirst..$GroupLast (header
    # and disabled rows in that range are skipped). Toggling the parent ON
    # selects every child; OFF clears them all. Toggling a child re-derives the
    # parent per $GroupMode: "any" (default) leaves it checked while ANY child
    # is checked (a group header), "all" only while EVERY child is checked - a
    # MASTER toggle, which is how EVERYTHING behaves in the uninstall menu.
    Info $Title
    $sel = New-Object 'System.Collections.Generic.List[int]'
    foreach ($d in $Defaults) {
        if ($d -ge 1 -and $d -le $Options.Count -and -not $sel.Contains($d)) { [void]$sel.Add($d) }
    }
    # The SELECTABLE rows in the group's range: header (#) and disabled (!) rows
    # sit inside it but can never be checked, so a select-all skips them and an
    # all-children rule must not wait on them.
    $groupChildren = {
        $out = @()
        for ($c = $GroupFirst; $c -le $GroupLast; $c++) {
            if ($c -lt 1 -or $c -gt $Options.Count) { continue }
            if ($Options[$c - 1].StartsWith("#") -or $Options[$c - 1].StartsWith("!")) { continue }
            $out += $c
        }
        return $out
    }
    $applyGroup = {
        param($toggled)
        if ($GroupParent -lt 1) { return }
        $children = & $groupChildren
        if ($toggled -eq $GroupParent) {
            $parentOn = $sel.Contains($GroupParent)
            foreach ($c in $children) {
                if ($parentOn) { if (-not $sel.Contains($c)) { [void]$sel.Add($c) } }
                else { [void]$sel.Remove($c) }
            }
        } elseif ($toggled -ge $GroupFirst -and $toggled -le $GroupLast) {
            # "all" makes the parent a MASTER toggle - checked only while EVERY
            # child is checked, so unticking any one of them releases it.
            # "any" (default) is the group-header rule.
            $on = $false
            if ($GroupMode -eq "all") {
                $on = $true
                foreach ($c in $children) { if (-not $sel.Contains($c)) { $on = $false; break } }
            } else {
                foreach ($c in $children) { if ($sel.Contains($c)) { $on = $true; break } }
            }
            if ($on) { if (-not $sel.Contains($GroupParent)) { [void]$sel.Add($GroupParent) } }
            else { [void]$sel.Remove($GroupParent) }
        }
    }
    $applyExclusive = {
        param($toggled)
        if ($ExclusiveIndex -lt 1) { return }
        if ($toggled -eq $ExclusiveIndex) {
            if ($sel.Contains($ExclusiveIndex)) { $sel.Clear(); [void]$sel.Add($ExclusiveIndex) }
        } elseif ($sel.Contains($ExclusiveIndex)) {
            [void]$sel.Remove($ExclusiveIndex)
        }
    }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        foreach ($i in @($sel | Sort-Object)) { Ok ("{0} (selected by default)" -f $Options[$i - 1]) }
        return @($sel | Sort-Object)
    }
    # A label starting with "#" is a GROUP HEADER: rendered as a plain caption
    # (no checkbox), never selectable, and skipped by the cursor.
    # A label starting with "!" is a DISABLED row: rendered as a dimmed,
    # unchecked checkbox (the label should say why - e.g. "not installed"),
    # never selectable, skipped by the cursor, and excluded from "a".
    $isHeader = { param($i) $Options[$i - 1].StartsWith("#") }
    $isDisabled = { param($i) $Options[$i - 1].StartsWith("!") }

    # The keyboard hint has to describe what the keys actually DO. On an
    # either/or menu - exactly two selectable rows, one of them exclusive -
    # Space does not toggle anything a reader would call a toggle: it moves the
    # tick from one answer to the other, which is choosing. A real multi-select
    # keeps "toggle", which is exactly what Space does there. Derived from the
    # menu's shape, not per call site. Mirrors ui_checkbox_menu in common.sh.
    $selectableCount = 0
    for ($i = 1; $i -le $Options.Count; $i++) {
        if ((& $isHeader $i) -or (& $isDisabled $i)) { continue }
        $selectableCount += 1
    }
    $spaceVerb = "Space to toggle"
    if ($ExclusiveIndex -ge 1 -and $selectableCount -eq 2) { $spaceVerb = "Space to select" }
    $step = {
        param($dir)
        for ($s = 0; $s -lt $Options.Count; $s++) {
            $script:cbCur += $dir
            if ($script:cbCur -lt 1) { $script:cbCur = $Options.Count }
            if ($script:cbCur -gt $Options.Count) { $script:cbCur = 1 }
            if (-not (& $isHeader $script:cbCur) -and -not (& $isDisabled $script:cbCur)) { return }
        }
    }
    $script:cbCur = 0
    & $step 1
    $firstDraw = $true
    while ($true) {
        if (-not $firstDraw -and $script:UiFancy) {
            # redraw the block in place: options + hint line
            Write-Host ("{0}[{1}A{0}[0J" -f $script:UiEsc, ($Options.Count + 1)) -NoNewline
        }
        $firstDraw = $false
        for ($i = 1; $i -le $Options.Count; $i++) {
            if (& $isHeader $i) {
                Write-Host ("    {0}" -f $Options[$i - 1].Substring(1)) -ForegroundColor Cyan
                continue
            }
            if (& $isDisabled $i) {
                if ($script:UiFancy) { Write-Host ("      {0}[ ] {1}{2}" -f $script:UiDim, $Options[$i - 1].Substring(1), $script:UiReset) }
                else { Write-Host ("      [ ] {0}" -f $Options[$i - 1].Substring(1)) }
                continue
            }
            $ptr = if ($i -eq $script:cbCur) { ">" } else { " " }
            if ($sel.Contains($i)) {
                if ($script:UiFancy) { Write-Host ("    {0} {1}[{2}]{3} {4}" -f $ptr, $script:UiOk, $script:UiTick, $script:UiReset, $Options[$i - 1]) }
                else { Write-Host ("    {0} [x] {1}" -f $ptr, $Options[$i - 1]) }
            } else {
                Write-Host ("    {0} [ ] {1}" -f $ptr, $Options[$i - 1])
            }
        }
        Write-ExakitMenuHint "Up/Down to move - $spaceVerb - Enter to confirm"
        $key = [Console]::ReadKey($true)
        $handled = $true
        switch ($key.Key) {
            "Enter"     { if ($sel.Count -gt 0) { return @($sel | Sort-Object) } }
            "Spacebar"  {
                if ($sel.Contains($script:cbCur)) { [void]$sel.Remove($script:cbCur) } else { [void]$sel.Add($script:cbCur) }
                & $applyGroup $script:cbCur
                & $applyExclusive $script:cbCur
            }
            "UpArrow"   { & $step -1 }
            "DownArrow" { & $step 1 }
            default     { $handled = $false }
        }
        if ($handled) { continue }
        switch -Regex ([string]$key.KeyChar) {
            '^[kK]$' { & $step -1 }
            '^[jJ]$' { & $step 1 }
            '^[aA]$' {
                # "all" means all real choices: never headers, never disabled
                # rows, never the exclusive option.
                $sel.Clear()
                for ($i = 1; $i -le $Options.Count; $i++) {
                    if ($i -ne $ExclusiveIndex -and -not (& $isHeader $i) -and -not (& $isDisabled $i)) { [void]$sel.Add($i) }
                }
            }
        }
    }
}
# Show-ExakitNoAiPanel - shown when the user skips MCP client setup: the
# database is still fully usable without an AI assistant, and this says how.
function Show-ExakitNoAiPanel {
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $hostName = "127.0.0.1"; $port = "8563"
    if ($dsn -match '^(.+):(\d+)$') { $hostName = $Matches[1]; $port = $Matches[2] }
    Write-Host ""
    Start-ExakitPanel "Using your database without an AI client"
    Write-ExakitPanelLine "Your database works great on its own - three easy ways in:"
    Write-ExakitPanelLine "GUI client:  DBeaver - https://dbeaver.io/download/"
    Write-ExakitPanelLine "             or DbVisualizer - https://www.dbvis.com/download/"
    Write-ExakitPanelLine "             New Connection > Exasol > Host $hostName Port $port"
    Write-ExakitPanelLine "Python:      pyexasol is preinstalled in its own environment:"
    Write-ExakitPanelLine "             $(Get-ExakitTilde (Join-Path $script:ExakitHome 'pyexasol-venv'))"
    Write-ExakitPanelLine "Terminal:    exapump interactive -p starter-kit   (SQL shell)"
    Write-ExakitPanelLine "Step-by-step (credentials, TLS setting, first query):  exakit guide"
    Write-ExakitPanelLine "Changed your mind about AI? Any time:  exakit mcp-setup"
    Complete-ExakitPanel
    Write-Host ""
}

# Show-ExakitGuide - friendly how-to-connect walkthrough (mirrors exakit_guide
# in common.sh): AI clients over MCP, GUI SQL clients (DBeaver, DbVisualizer), and Python.
function Show-ExakitGuide {
    if (-not (Test-Path $script:ManifestPath)) { Warn2 "No installation found. Run the installer first."; return }
    $dsn = Get-ExakitManifestValue "runtime.dsn"
    $hostName = "127.0.0.1"; $port = "8563"
    if ($dsn -match '^(.+):(\d+)$') { $hostName = $Matches[1]; $port = $Matches[2] }
    $user = Get-ExakitManifestValue "runtime.user"; if (-not $user) { $user = "sys" }
    $pwfile = Get-ExakitManifestValue "runtime.password_file"
    $mcpUser = Get-ExakitManifestValue "components.mcp_server.connection.user"

    Write-ExakitBanner "How to connect" "AI clients, SQL clients, Python - pick your door"

    Start-ExakitPanel "1 - Ask questions with an AI client (MCP)"
    Write-ExakitPanelLine "Connect one or more AI clients in a single guided step:"
    Write-ExakitPanelLine "  exakit mcp-setup"
    Write-ExakitPanelLine "Supported: Claude, Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue"
    Write-ExakitPanelLine "Then restart/reload the client and look for the MCP server 'exasol'."
    Write-ExakitPanelLine "First thing to ask it:"
    Write-ExakitPanelLine "  'List the schemas and tables in my Exasol database, then answer my"
    Write-ExakitPanelLine "   questions with read-only SQL - show me the SQL before you run it.'"
    Write-ExakitPanelLine "14 ready-made questions: data\example-questions.md (in the kit)"
    Complete-ExakitPanel

    Start-ExakitPanel "2 - Browse and query with a SQL client (GUI)"
    Write-ExakitPanelLine "Both free: DBeaver - https://dbeaver.io/download/"
    Write-ExakitPanelLine "           or DbVisualizer - https://www.dbvis.com/download/"
    Write-ExakitPanelLine "In DBeaver: Database > New Database Connection > search 'Exasol'"
    Write-ExakitPanelLine "  Host:      $hostName"
    Write-ExakitPanelLine "  Port:      $port"
    Write-ExakitPanelLine "  User:      $user"
    if ($pwfile) { Write-ExakitPanelLine "  Password:  Get-Content $(Get-ExakitTilde $pwfile)" }
    if ($mcpUser) { Write-ExakitPanelLine "  (read-only alternative: user $mcpUser)" }
    Write-ExakitPanelLine "  TLS:       local self-signed certificate - in Driver properties set"
    Write-ExakitPanelLine "             validateservercertificate = 0, then Test Connection > Finish."
    Write-ExakitPanelLine "Each bundled dataset has its own schema (TPCH, ENERGY, WEATHER);"
    Write-ExakitPanelLine "your own uploads default to STARTER_KIT."
    Complete-ExakitPanel

    Start-ExakitPanel "3 - Terminal and Python"
    Write-ExakitPanelLine "Interactive SQL shell:   exapump interactive -p starter-kit"
    Write-ExakitPanelLine "One-off query:           exapump sql -p starter-kit 'SELECT 42'"
    Write-ExakitPanelLine "Python (pyexasol preinstalled in its own environment):"
    Write-ExakitPanelLine "  $(Get-ExakitTilde (Join-Path $script:ExakitHome 'pyexasol-venv'))"
    Complete-ExakitPanel

    Start-ExakitPanel "Everything else"
    Write-ExakitPanelLine "Connection summary:   exakit info"
    Write-ExakitPanelLine "Load more data:       exakit data-load"
    Write-ExakitPanelLine "Health check:         exakit status - exakit mcp-doctor"
    Complete-ExakitPanel
    Write-Host ""
}

# ExakitFailException - a distinct exception type so callers can tell a
# deliberate Fail() apart from an unexpected error. Bash's die() only halts
# the current subshell (kit_shared_steps runs risky steps in one so a
# failure there cannot abort the whole install); PowerShell's `exit` has no
# such boundary within a single process, so Fail() throws instead. Top-level
# entry points (setup-windows-docker.ps1, exakit.ps1) catch it there and
# exit 1; interactive offers catch it locally and continue with a warning,
# matching bash's `|| true` pattern around exakit_maybe_offer_*.
class ExakitFailException : System.Exception {
    ExakitFailException([string]$Msg) : base($Msg) {}
}

function Fail([string]$Msg) {
    Stop-ExakitSpinner
    Restore-ExakitCursor
    # Record the reason before it is printed, so a soft step that swallows this
    # exception can quote the real sentence in the closing summary rather than a
    # bare exception type. Defined further down the file; guarded because Fail()
    # can run while the library is still being dot-sourced.
    if (Get-Command Set-ExakitFailureReason -ErrorAction SilentlyContinue) {
        Set-ExakitFailureReason $Msg
    }
    # Rendered as a small "card": prominent cross header, then a dim gutter
    # line to the log - the same shape as ui.sh's die().
    Write-Host ""
    if ($script:UiFancy) {
        Write-Host ("  {0}{1} {2}{3}{4}" -f $script:UiErr, $script:UiCross, $script:UiBold, $Msg, $script:UiReset)
        if ($script:LogFile) { Write-Host ("    {0}{1} Log: {2}{3}" -f $script:UiDim, $script:UiVB, $script:LogFile, $script:UiReset) }
    } else {
        Write-Host ("  {0} {1}" -f $script:UiCross, $Msg) -ForegroundColor Red
        if ($script:LogFile) { Write-Host ("    | Log: {0}" -f $script:LogFile) }
    }
    Write-ExakitLog "FATAL" $Msg
    throw [ExakitFailException]::new($Msg)
}

# Run a command, sending its output to the log file only. $Cmd is invoked via
# the call operator; args come from $Args (positional after $Cmd).
#
# A native command that writes to stderr can, under $ErrorActionPreference =
# 'Stop' (set globally by every entry point), surface as an uncaught
# terminating exception instead of just a non-zero exit code - this is a
# real, well-documented PowerShell quirk (worse on Windows PowerShell 5.1
# than on 7+) and is exactly what happened when Docker Desktop wasn't
# running: the friendly "Docker is installed but not running" message never
# ran because the underlying `docker info` call threw past it. Every caller
# of this function already checks the *returned exit code* and calls Fail()
# itself with a proper message, so any exception here is converted to a
# synthetic non-zero code instead of being allowed to escape - Fail() still
# happens, just from the caller, with the message it was meant to show.
function Invoke-ExakitLogged {
    param([Parameter(Mandatory)][string]$Cmd, [Parameter(ValueFromRemainingArguments)]$CmdArgs)
    Write-ExakitLog "CMD" "$Cmd $($CmdArgs -join ' ')"
    $previousErrorActionPreference = $ErrorActionPreference
    # Animate a spinner (in a background runspace) while the command runs. Its
    # output goes to the log, not the console, so the spinner is the only
    # console writer during the spin. The command execution below is unchanged.
    $spinLabel = if ($script:ExakitActiveLabel) { $script:ExakitActiveLabel } else { "working" }
    Start-ExakitSpinner $spinLabel
    try {
        # Native tools such as uvx and Docker can write progress/status to
        # stderr while still succeeding. With ErrorActionPreference = Stop,
        # Windows PowerShell can turn that stderr into a terminating error
        # before we can inspect the real process exit code.
        $ErrorActionPreference = "Continue"
        if ($script:LogFile) {
            & $Cmd @CmdArgs *>> $script:LogFile
        } else {
            & $Cmd @CmdArgs | Out-Null
        }
        return $LASTEXITCODE
    } catch {
        Write-ExakitLog "ERROR" "$Cmd threw instead of returning an exit code: $_"
        return 1
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Stop-ExakitSpinner
    }
}
# Test-ExakitInteractive - is there a console this run can actually ask a
# question on? One expression, one place: the prompts below take their default
# when it is false, and the runtime update offer in setup/exakit.ps1 refuses to
# stop a database when it is false. Twin of bash's `[ -t 0 ]` test in
# exakit_offer_runtime_update.
function Test-ExakitInteractive {
    if (-not [Environment]::UserInteractive) { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    return $true
}

# Confirm-ExakitPrompt "Question?" [DefaultYes] - non-interactive runs
# (no console input available, e.g. piped install) take the default.
function Confirm-ExakitPrompt {
    param([string]$Question, [bool]$DefaultYes = $true)
    if (-not (Test-ExakitInteractive)) {
        return $DefaultYes
    }
    $hint = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    if ($script:UiFancy) {
        Write-Host ("    {0}?{1} {2} {3}{4}{5} " -f $script:UiAsk, $script:UiReset, $Question, $script:UiDim, $hint, $script:UiReset) -NoNewline
    } else {
        Write-Host "    ? $Question $hint " -ForegroundColor Cyan -NoNewline
    }
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer -match '^(y|yes)$'
}

# Confirm-ExakitEnvPrompt <EnvName> "Question?" [DefaultYes] - twin of bash's
# confirm_env: a pre-set environment variable answers the question outright, so a
# scripted run is deterministic instead of silently taking the default. Anything
# else falls through to the prompt (which itself defaults when there is no
# console).
function Confirm-ExakitEnvPrompt {
    param(
        [Parameter(Mandatory)][string]$EnvName,
        [Parameter(Mandatory)][string]$Question,
        [bool]$DefaultYes = $false
    )
    # The accepted values are exactly confirm_env's list in setup/lib/common.sh -
    # deliberately not a looser set, so the same value means the same thing on both
    # platforms (-cmatch keeps the comparison case-sensitive, as bash's case does).
    $preset = [Environment]::GetEnvironmentVariable($EnvName)
    if ($preset) {
        if ($preset -cmatch '^(1|y|Y|yes|YES|Yes)$') { return $true }
        if ($preset -cmatch '^(0|n|N|no|NO|No)$') { return $false }
    }
    return (Confirm-ExakitPrompt $Question $DefaultYes)
}

# Read-ExakitPrompt "Question" ["default"] - non-interactive runs return the
# default immediately (mirrors bash's prompt_text over /dev/tty).
function Read-ExakitPrompt {
    param([string]$Question, [string]$Default = "")
    if (-not (Test-ExakitInteractive)) {
        return $Default
    }
    if ($script:UiFancy) {
        if ($Default) {
            Write-Host ("    {0}?{1} {2} {3}[{4}]{5} " -f $script:UiAsk, $script:UiReset, $Question, $script:UiDim, $Default, $script:UiReset) -NoNewline
        } else {
            Write-Host ("    {0}?{1} {2} " -f $script:UiAsk, $script:UiReset, $Question) -NoNewline
        }
    } elseif ($Default) {
        Write-Host "    ? $Question [$Default] " -ForegroundColor Cyan -NoNewline
    } else {
        Write-Host "    ? $Question " -ForegroundColor Cyan -NoNewline
    }
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

# Test-ExakitPortInUse <port> [host] - fast, quiet "is this TCP port already
# accepting connections?" check. Replaces Test-NetConnection, which is slow
# (it also does ICMP/traceroute work) and pins a "TCP connect to ..." progress
# banner to the top of the console. A raw TcpClient with a short timeout is
# sub-second and silent. Returns $true only if something is listening.
function Test-ExakitPortInUse {
    param([Parameter(Mandatory)][int]$Port, [string]$ComputerName = "127.0.0.1", [int]$TimeoutMs = 700)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------------------
# Python / uv (mirrors require_python3 / run_python: prefer a system python,
# fall back to a uv-managed one so the kit never hard-requires a system
# Python install)
# ---------------------------------------------------------------------------
function Test-ExakitSystemPython {
    if ($env:EXAKIT_DISABLE_SYSTEM_PYTHON -eq "1") { return $false }
    return [bool](Get-Command python -ErrorAction SilentlyContinue)
}

function Get-ExakitUvBin {
    if ($script:UvBin -and (Test-Path $script:UvBin)) { return $script:UvBin }
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { $script:UvBin = $cmd.Source; return $script:UvBin }
    $candidate = Join-Path $script:BinDir "uv.exe"
    if (Test-Path $candidate) { $script:UvBin = $candidate; return $script:UvBin }
    $candidate = Join-Path $HOME ".local\bin\uv.exe"
    if (Test-Path $candidate) { $script:UvBin = $candidate; return $script:UvBin }
    return $null
}

function Install-ExakitUv {
    $existing = Get-ExakitUvBin
    if ($existing) { return $existing }
    Info "Installing the managed Python bootstrapper (uv)"
    try {
        $env:UV_NO_MODIFY_PATH = "1"
        $env:INSTALLER_NO_MODIFY_PATH = "1"
        # HARDENING (eval-report): this fetches and executes the uv installer
        # unpinned/unverified, unlike the kit's checksum-verified artifacts.
        # Pin/verify to match the bash twin's chosen approach (keep both sides
        # identical). Behavior intentionally unchanged here pending that fix.
        Invoke-Expression (Invoke-RestMethod -Uri "https://astral.sh/uv/install.ps1") *>> $script:LogFile
    } catch {
        Fail "uv installation failed (see log): $_"
    }
    $bin = Get-ExakitUvBin
    if (-not $bin) {
        $candidate = Join-Path $HOME ".local\bin\uv.exe"
        if (Test-Path $candidate) { $bin = $candidate; $script:UvBin = $bin }
    }
    if (-not $bin) { Fail "uv installed but its binary was not found in $HOME\.local\bin." }
    Ok "uv installed at $bin"
    return $bin
}

function Assert-ExakitPython {
    if (Test-ExakitSystemPython) { return }
    if (-not (Install-ExakitUv)) { Fail "A Python runtime is required, and the automatic uv bootstrap failed." }
}

# Invoke-ExakitPython <script-text> <args...> - runs Python via the system
# interpreter if present, otherwise via a uv-managed one. Returns stdout as a
# single string; throws on a non-zero exit so callers can Fail() with context.
function Invoke-ExakitPython {
    param([Parameter(Mandatory)][string]$Script, [Parameter(ValueFromRemainingArguments)]$PyArgs)
    $tmp = [System.IO.Path]::GetTempFileName() + ".py"
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        Set-Content -Path $tmp -Value $Script -Encoding UTF8
        # Under the module-global $ErrorActionPreference = 'Stop', 2>&1 turns
        # the interpreter's FIRST stderr write into a terminating error that
        # tears the pipeline down - killing Python mid-run and surfacing only
        # that first line instead of the intended "Python exited with code N"
        # diagnostic. A script that merely warns on stderr while succeeding
        # would abort the caller outright. 'Continue' captures the full
        # output; the exit-code check below stays the real failure signal.
        # Same fix as Invoke-Exapump / Invoke-ExakitLogged.
        $ErrorActionPreference = "Continue"
        if (Test-ExakitSystemPython) {
            $out = & python $tmp @PyArgs 2>&1
        } else {
            $uv = Install-ExakitUv
            $out = & $uv run --python $script:ManagedPythonVersion --no-project python $tmp @PyArgs 2>&1
        }
        $code = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        if ($code -ne 0) { throw "Python exited with code ${code}: $out" }
        return ($out -join "`n")
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Manifest (native PowerShell JSON, no Python dependency for read/write)
# ---------------------------------------------------------------------------
function Initialize-ExakitManifest {
    # The home the skills tell an agent to write into, created with the home
    # itself rather than left for the agent to invent. Cheap, idempotent, and it
    # runs on every install AND every re-run, so an older install grows the
    # directory the moment the installer touches it again.
    New-Item -ItemType Directory -Force -Path $script:WorkflowsDir -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path $script:ManifestPath) {
        try {
            Get-Content $script:ManifestPath -Raw | ConvertFrom-Json | Out-Null
            return
        } catch {
            Warn2 "The install manifest is corrupted (interrupted run?) - rebuilding it; existing components will be re-detected"
            Move-Item -Force $script:ManifestPath "$script:ManifestPath.corrupt-$(Get-Date -Format 'yyyyMMddHHmmss')"
        }
    }
    $doc = [pscustomobject]@{
        manifest_version = 1
        kit_level        = 1
        installed_at     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        os               = "windows"
        arch             = $env:PROCESSOR_ARCHITECTURE
        runtime          = [pscustomobject]@{}
        components       = [pscustomobject]@{}
        data             = [pscustomobject]@{ loaded = $false }
        steps_completed  = @()
        log_dir          = $script:LogDir
    }
    Save-ExakitManifest $doc
}

function Read-ExakitManifest {
    if (-not (Test-Path $script:ManifestPath)) { return $null }
    return (Get-Content $script:ManifestPath -Raw | ConvertFrom-Json)
}

# Atomic write: an interrupted run must never leave a truncated manifest.
# Enter-ExakitManifestLock / Exit-ExakitManifestLock - twin of _exakit_locked in
# common.sh. A read-modify-write with no lock silently discards concurrent
# updates: measured on the bash side, 17 of 20 parallel writes were lost and
# every one of 30 rounds lost at least one. Two kit processes at once is not
# hypothetical - `exakit start` brings up the database and every service,
# autostart can fire one at boot while another runs, and an agent may issue two
# commands in parallel. FileShare::None is the exclusive-open equivalent of
# flock; a lock we cannot take must not fail an install, so we proceed unlocked
# rather than abort.
function Enter-ExakitManifestLock {
    $lockPath = "$script:ManifestPath.lock"
    for ($attempt = 0; $attempt -lt 200; $attempt++) {
        try {
            return [System.IO.File]::Open($lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
        } catch {
            Start-Sleep -Milliseconds 25
        }
    }
    return $null
}

function Exit-ExakitManifestLock($Handle) {
    if ($null -ne $Handle) { try { $Handle.Close() } catch { } }
}

function Save-ExakitManifest($Manifest) {
    # Unique temp name, not a shared "<path>.tmp": two writers sharing one can
    # interleave inside it, and the loser's move can publish a half-written file.
    $tmp = "$script:ManifestPath." + [System.Guid]::NewGuid().ToString("N") + ".tmp"
    try {
        $Manifest | ConvertTo-Json -Depth 12 | Set-Content -Path $tmp
        Move-Item -Force $tmp $script:ManifestPath
    } catch {
        if (Test-Path $tmp) { Remove-Item -Force -ErrorAction SilentlyContinue $tmp }
        throw
    }
    try { Protect-ExakitFile $script:ManifestPath } catch { }
}

function Get-ManifestValue {
    param($Manifest, [Parameter(Mandatory)][string]$Path)
    $node = $Manifest
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $node) { return $null }
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop) { return $null }
        $node = $prop.Value
    }
    return $node
}

function Set-ManifestValue {
    param($Manifest, [Parameter(Mandatory)][string]$Path, $Value)
    $parts = $Path -split '\.'
    $node = $Manifest
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $part = $parts[$i]
        $prop = $node.PSObject.Properties[$part]
        if ($null -eq $prop -or $null -eq $prop.Value) {
            $child = [pscustomobject]@{}
            $node | Add-Member -NotePropertyName $part -NotePropertyValue $child -Force
            $node = $child
        } else {
            $node = $prop.Value
        }
    }
    $node | Add-Member -NotePropertyName $parts[-1] -NotePropertyValue $Value -Force
}

# manifest_get equivalent: reads from disk fresh every call, like bash.
function Get-ExakitManifestValue {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { return $null }
    return (Get-ManifestValue -Manifest $doc -Path $Path)
}

# manifest_set equivalent: reads, mutates, writes atomically, every call.
function Set-ExakitManifestValue {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    # The lock has to span read AND write, or a concurrent writer reads the same
    # document and the last save wins.
    $lock = Enter-ExakitManifestLock
    try {
        $doc = Read-ExakitManifest
        if ($null -eq $doc) { Fail "Failed to update manifest ($Path): no manifest at $script:ManifestPath" }
        Set-ManifestValue -Manifest $doc -Path $Path -Value $Value
        Save-ExakitManifest $doc
    } finally {
        Exit-ExakitManifestLock $lock
    }
}

# Remove a key (and everything under it) from the manifest. Silent when the
# key is already absent; a partial uninstall must not fail over bookkeeping.
# Twin of manifest_del in common.sh.
function Remove-ExakitManifestValue {
    param([Parameter(Mandatory)][string]$Path)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { return }
    $parts = $Path -split "\."
    $node = $doc
    foreach ($part in $parts[0..($parts.Count - 2)]) {
        if ($node.PSObject.Properties[$part]) { $node = $node.$part } else { return }
    }
    if ($node.PSObject.Properties[$parts[-1]]) {
        $node.PSObject.Properties.Remove($parts[-1])
        Save-ExakitManifest $doc
    }
}

# Drop a step flag so a re-run of the installer reinstalls what a partial
# uninstall removed. Twin of exakit_unmark_step in common.sh.
function Remove-ExakitStepDone {
    param([Parameter(Mandatory)][string]$Step)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { return }
    $steps = Get-ManifestValue -Manifest $doc -Path "steps_completed"
    if ($null -eq $steps) { return }
    $remaining = @([array]$steps | Where-Object { $_ -ne $Step })
    Set-ManifestValue -Manifest $doc -Path "steps_completed" -Value $remaining
    Save-ExakitManifest $doc
}

# ---------------------------------------------------------------------------
# Versions manifest (versions.json)
# ---------------------------------------------------------------------------
# Twin of the exakit_versions_* set in setup/lib/common.sh. One document answers
# one question: "which version of each Component is the current tested set?".
# Maintainers edit it via pull request; clients read it. Nothing here may ever
# fail a command - every reader degrades along the chain
#
#   fresh fetch -> cached copy (any age) -> copy baked into the kit -> the
#   *Fallback variables above
#
# so an offline machine, a rate-limited network, or a hand-mangled cache all end
# up with a usable answer instead of an error. JSON is read natively here, so
# the bash side's no-Python fallback has no counterpart.

# Test-ExakitVersionsDoc - the gate every document passes before it is trusted.
# Returns 0 when the document can be used, 2 when it parses but announces a
# newer schema (the caller can hint at updating the kit), 1 otherwise.
# Rejects any version or digest outside the safe charset: advertised versions
# are interpolated into download URLs and command lines.
function Test-ExakitVersionsDoc {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return 1 }
    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if (-not $raw -or -not $raw.Trim()) { return 1 }
        $doc = $raw | ConvertFrom-Json
    } catch {
        Write-ExakitLog "WARN" "versions manifest did not parse ($Path)"
        return 1
    }
    if ($null -eq $doc -or $doc -is [System.Array] -or -not ($doc -is [System.Management.Automation.PSCustomObject])) { return 1 }
    $announced = Get-ManifestValue -Manifest $doc -Path "schema_version"
    if ($announced -ne $script:VersionsSchema) {
        if ($announced -is [int] -or $announced -is [long]) {
            if ($announced -gt $script:VersionsSchema) {
                $script:VersionsSchemaAhead = $true
                return 2
            }
        }
        return 1
    }
    $blocks = @()
    $kit = Get-ManifestValue -Manifest $doc -Path "kit"
    if ($null -eq $kit) { return 1 }
    $blocks += , $kit
    $components = Get-ManifestValue -Manifest $doc -Path "components"
    if ($null -eq $components -or $components.PSObject.Properties.Count -eq 0) { return 1 }
    foreach ($prop in $components.PSObject.Properties) { $blocks += , $prop.Value }
    # Optional and additive: absent until the first Kit 2 assets ship.
    $kit2 = Get-ManifestValue -Manifest $doc -Path "kit2"
    if ($null -ne $kit2) { $blocks += , $kit2 }

    foreach ($block in $blocks) {
        if ($null -eq $block -or -not ($block -is [System.Management.Automation.PSCustomObject])) { return 1 }
        $version = Get-ManifestValue -Manifest $block -Path "version"
        if (-not ($version -is [string]) -or $version -notmatch '^[A-Za-z0-9._+-]+$') { return 1 }
        $minKit = Get-ManifestValue -Manifest $block -Path "min_kit_version"
        if ($null -ne $minKit) {
            if (-not ($minKit -is [string]) -or $minKit -notmatch '^[A-Za-z0-9._+-]+$') { return 1 }
        }
        $digests = Get-ManifestValue -Manifest $block -Path "sha256"
        if ($null -ne $digests) {
            if (-not ($digests -is [System.Management.Automation.PSCustomObject]) -or $digests.PSObject.Properties.Count -eq 0) { return 1 }
            foreach ($digest in $digests.PSObject.Properties) {
                if (-not ($digest.Value -is [string]) -or $digest.Value -notmatch '^[0-9a-f]{64}$') { return 1 }
            }
        }
    }
    return 0
}

# The copy that shipped inside the installed kit: the last stop before the
# compiled-in fallbacks, and what makes an offline machine still agree with the
# release it installed.
function Get-ExakitVersionsBakedPath {
    $root = Get-ExakitRepoRoot
    if (-not $root) { return $null }
    $path = Join-Path $root "versions.json"
    if (-not (Test-Path $path)) { return $null }
    return $path
}

# Format-ExakitLocalTime <utc-iso> - a manifest timestamp rendered for a human:
# "May 3, 2026 at 5:30 PM", in the machine's own timezone. The manifest keeps UTC
# ISO 8601 (machine-readable state must not move); only the display changes.
# Falls back to the raw value, because an awkward timestamp beats none at all.
# Twin of exakit_format_local_time in setup/lib/common.sh. InvariantCulture keeps
# the month names identical to the bash side on a non-English Windows.
function Format-ExakitLocalTime {
    param([string]$Utc)
    if (-not $Utc) { return "" }
    try {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor `
                  [System.Globalization.DateTimeStyles]::AssumeUniversal
        $parsed = [datetime]::ParseExact($Utc.Trim(), "yyyy-MM-ddTHH:mm:ssZ", $culture, $styles)
        $local = $parsed.ToLocalTime()
        return ($local.ToString("MMMM d, yyyy", $culture) + " at " + $local.ToString("h:mm tt", $culture))
    } catch {
        return $Utc
    }
}

# Format-ExakitManifestDate - "2026-07-29" becomes "July 29, 2026".
#
# The twin of the bash exakit_format_manifest_date, and deliberately NOT built on
# Format-ExakitLocalTime: the manifest's "updated" is a calendar date, not an
# instant, so converting it to local time would render the day before on any
# machine west of UTC. ParseExact with no timezone styles keeps the date as
# written. Anything not of that shape is passed through untouched.
function Format-ExakitManifestDate {
    param([string]$Date)
    if (-not $Date) { return "" }
    try {
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $parsed = [datetime]::ParseExact($Date.Trim(), "yyyy-MM-dd", $culture,
                                        [System.Globalization.DateTimeStyles]::None)
        return $parsed.ToString("MMMM d, yyyy", $culture)
    } catch {
        return $Date
    }
}

# Invoke-ExakitSoftStep - run one component's install without letting it end the
# run. The twin of bash exakit_soft_step, and there for the same reason: the
# component installers Fail() on error, and a broken exapump used to stop setup
# before the exakit command existed, leaving a deployed database with nothing to
# repair it.
$script:ExakitSoftFailed = [ordered]@{}

# The reason the step now running gave up, set by Fail() and by the soft-miss
# reporters that return $false instead of throwing (Write-PyexasolNotInstalled).
# The twin of the bash failure note; a single process needs no file for it.
$script:ExakitLastFailureReason = ""

function Set-ExakitFailureReason {
    param([string]$Reason)
    $script:ExakitLastFailureReason = $Reason
}

function Get-ExakitFailureReason {
    $reason = $script:ExakitLastFailureReason
    $script:ExakitLastFailureReason = ""
    return $reason
}

# Register-ExakitSoftFailure - book a step as "did not complete" without the
# running machinery of Invoke-ExakitSoftStep.
#
# The soft-step wrapper is for component installers that Fail(); this is for the
# steps whose failure is caught and warned about locally (the data load, the AI
# client wiring, the skills copy). Before this they were invisible to the closing
# summary, so a user whose sample data never loaded saw a clean "Setup complete".
function Register-ExakitSoftFailure {
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Repair,
        [string]$Reason = "",
        [string]$Label = ""
    )
    # First failure wins: a later, vaguer report must not overwrite the specific
    # reason the original failure recorded.
    if ($script:ExakitSoftFailed.Contains($Component)) { return }
    if (-not $Label) { $Label = $Component }
    $script:ExakitSoftFailed[$Component] = [pscustomobject]@{
        Repair = $Repair
        Reason = $Reason
        Label  = $Label
    }
}

function Invoke-ExakitSoftStep {
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Repair,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Label = ""
    )
    Set-ExakitFailureReason ""
    try {
        $result = & $Body
        # Install-Pyexasol reports a soft miss by returning $false rather than
        # throwing, so a returned $false counts as a failure too. Its reason is
        # in $script:ExakitLastFailureReason, not in an exception message.
        if ($result -is [bool] -and -not $result) {
            $soft = Get-ExakitFailureReason
            if (-not $soft) { $soft = "the step reported failure (see the log)" }
            throw $soft
        }
        Set-ExakitFailureReason ""
        return $true
    } catch {
        # Fail() records the message it printed; an ordinary exception carries
        # its own. Either way the summary gets a real sentence, not "failed".
        $reason = Get-ExakitFailureReason
        if (-not $reason) { $reason = ("" + $_) }
        Register-ExakitSoftFailure -Component $Component -Repair $Repair -Reason $reason -Label $Label
        Write-ExakitLog "WARN" "$Component did not finish: $_"
        Warn2 "$Component did not finish - carrying on so the rest of the install completes"
        return $false
    }
}

function Test-ExakitSoftFailed {
    param([Parameter(Mandatory)][string]$Component)
    return $script:ExakitSoftFailed.Contains($Component)
}

# Invoke-ExakitBestEffort - run a closing offer (data load, MCP client setup,
# skills) so that NOTHING it does can end the run, and a failure still reaches
# the closing summary.
#
# The catch is deliberately untyped. These blocks used to catch
# [ExakitFailException] only, which covers a Fail() inside the offer but not a
# cmdlet error, a bad path, or a null reference - any of those aborted an install
# whose database was already up and running.
function Invoke-ExakitBestEffort {
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][string]$Repair,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Warning = ""
    )
    Set-ExakitFailureReason ""
    try {
        & $Body
        Set-ExakitFailureReason ""
        return $true
    } catch {
        $reason = Get-ExakitFailureReason
        if (-not $reason) { $reason = ("" + $_) }
        Write-ExakitLog "WARN" "$Component did not finish: $_"
        if ($Warning) { Warn2 $Warning }
        Warn2 "Carrying on so the rest of the install completes. Retry with: $Repair"
        Register-ExakitSoftFailure -Component $Component -Repair $Repair -Reason $reason -Label $Label
        return $false
    }
}

# The closing account of what did not make it: what went wrong, and the one
# command that installs it. Printed last, after the connection panel, so it is
# the final thing on screen rather than something scrolled past mid-install.
function Write-ExakitSoftFailures {
    if ($script:ExakitSoftFailed.Count -eq 0) { return }
    Write-Host ""
    if ($script:ExakitSoftFailed.Count -eq 1) {
        Warn2 "The install finished, but one step did not complete:"
    } else {
        Warn2 "The install finished, but $($script:ExakitSoftFailed.Count) steps did not complete:"
    }
    Write-Host ""
    foreach ($component in $script:ExakitSoftFailed.Keys) {
        $entry = $script:ExakitSoftFailed[$component]
        $reason = $entry.Reason
        if (-not $reason) { $reason = "the step did not finish (see the log)" }
        if ($script:UiFancy) {
            Write-Host ("      {0}{1}{2} is not installed: {3}" -f $script:UiBold, $entry.Label, $script:UiReset, $reason)
            Write-Host ("        reinstall it with:  {0}{1}{2}" -f $script:UiAccent, $entry.Repair, $script:UiReset)
        } else {
            Write-Host ("      {0} is not installed: {1}" -f $entry.Label, $reason)
            Write-Host ("        reinstall it with:  {0}" -f $entry.Repair)
        }
    }
    Write-Host ""
    Info "Everything else is ready - the database, and the exakit command itself."
    if ($script:LogFile) { Info "Full detail for each failure: $script:LogFile" }
    Info "See where you stand any time with: exakit status"
}

# Invoke-ExakitBounded - run an external command and give up on it after
# -TimeoutSeconds, returning $null if it had to be cut off.
#
# The twin of the bash exakit_run_bounded, and needed for the same reason: `docker
# info` and `docker container inspect` do not return while Docker Desktop is still
# starting, so an unbounded probe leaves `exakit version` printing nothing at all
# for as long as the engine takes. Reading a version is never worth that wait - the
# callers fall back to the recorded value, exactly as they do for a stopped engine.
#
# Uses Process directly rather than Start-Job: a job pays PowerShell startup per
# call, and WaitForExit(ms) is the one primitive that is honest about giving up.
function Invoke-ExakitBounded {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 8
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    # .Arguments, not .ArgumentList: the latter only exists on .NET Core, so it
    # would throw on Windows PowerShell 5.1 - and never on the pwsh 7 the tests
    # run under. Quote each argument, since one of them is a Go template.
    $quoted = @()
    foreach ($argument in $Arguments) {
        $quoted += '"' + ($argument -replace '"', '\"') + '"'
    }
    $info.Arguments = ($quoted -join " ")
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($info)
        # Read stdout on a task so a chatty command cannot fill the pipe buffer and
        # deadlock against our own WaitForExit.
        $reader = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            Write-ExakitLog "WARN" "$FilePath did not answer within ${TimeoutSeconds}s; giving up"
            return $null
        }
        if ($process.ExitCode -ne 0) { return $null }
        return $reader.Result
    } catch {
        Write-ExakitLog "WARN" "$FilePath could not be run: $_"
        return $null
    } finally {
        if ($process) { $process.Dispose() }
    }
}

# What's new - twins of the exakit_whats_new_* block in common.sh.
#
# ONE source: setup/whats-new.json, a version -> array-of-lines map. The cards the
# installer draws after an upgrade and the text `exakit whats-new` prints are the
# same lines. Silence when a version has no card is deliberate on both sides: a
# kit meeting a file that does not mention its version is not an error worth a
# word on screen.
$script:WhatsNewPointWidth = 68
$script:WhatsNewPointsPerVersion = 6

# Get-ExakitWhatsNewFile - the card source, or $null when this kit copy has none.
function Get-ExakitWhatsNewFile {
    param([string]$KitRoot = "")
    if (-not $KitRoot) { return $null }
    $file = Join-Path (Join-Path $KitRoot "setup") "whats-new.json"
    if (-not (Test-Path $file)) { return $null }
    return $file
}

# Get-ExakitWhatsNewDoc - the parsed file, or $null. Never throws: a hand-edited
# file with a stray comma must not end an upgrade that already succeeded.
function Get-ExakitWhatsNewDoc {
    param([string]$KitRoot = "")
    $file = Get-ExakitWhatsNewFile -KitRoot $KitRoot
    if (-not $file) { return $null }
    try { return (Get-Content -Raw -Path $file | ConvertFrom-Json) } catch { return $null }
}

# ConvertTo-ExakitVersionKey - a dotted number as a comparable array, or $null for
# anything else (a "_comment" key, a decorated heading). Skipped, never guessed at.
function ConvertTo-ExakitVersionKey {
    param([string]$Version)
    if ($Version -notmatch '^[0-9]+(\.[0-9]+)*$') { return $null }
    return @($Version -split '\.' | ForEach-Object { [int]$_ })
}

# Compare-ExakitVersionKey - -1, 0 or 1, field by field, shorter treated as zeros.
function Compare-ExakitVersionKey {
    param($A, $B)
    $max = [Math]::Max($A.Count, $B.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $x = 0; $y = 0
        if ($i -lt $A.Count) { $x = $A[$i] }
        if ($i -lt $B.Count) { $y = $B[$i] }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

# Get-ExakitWhatsNewVersions - the versions with cards inside (From, To], oldest
# first. A To older than From (a downgrade) selects nothing.
function Get-ExakitWhatsNewVersions {
    param([Parameter(Mandatory)][string]$KitRoot, [string]$From = "", [string]$To = "")
    $doc = Get-ExakitWhatsNewDoc -KitRoot $KitRoot
    if (-not $doc) { return @() }
    $lo = if ($From) { ConvertTo-ExakitVersionKey $From } else { $null }
    $hi = if ($To) { ConvertTo-ExakitVersionKey $To } else { $null }
    $found = @()
    foreach ($prop in $doc.PSObject.Properties) {
        if ($prop.Name.StartsWith("_")) { continue }
        $key = ConvertTo-ExakitVersionKey $prop.Name
        if (-not $key) { continue }
        if ($lo -and (Compare-ExakitVersionKey $key $lo) -le 0) { continue }
        if ($hi -and (Compare-ExakitVersionKey $key $hi) -gt 0) { continue }
        $found += ,@{ Key = $key; Name = $prop.Name }
    }
    $sorted = $found | Sort-Object -Property @{ Expression = { ($_.Key -join ".") } }
    # Sorting on the joined string would put 0.10.0 before 0.2.0, so order by the
    # numeric fields explicitly.
    $sorted = @($found)
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $j = $i
        while ($j -gt 0 -and (Compare-ExakitVersionKey $sorted[$j - 1].Key $sorted[$j].Key) -gt 0) {
            $tmp = $sorted[$j - 1]; $sorted[$j - 1] = $sorted[$j]; $sorted[$j] = $tmp
            $j--
        }
    }
    return @($sorted | ForEach-Object { $_.Name })
}

# Get-ExakitWhatsNewPoints - one "  - text" line per highlight of a version.
function Get-ExakitWhatsNewPoints {
    param([Parameter(Mandatory)][string]$KitRoot, [Parameter(Mandatory)][string]$Version)
    $doc = Get-ExakitWhatsNewDoc -KitRoot $KitRoot
    if (-not $doc) { return @() }
    $prop = $doc.PSObject.Properties[$Version]
    if (-not $prop) { return @() }
    $out = @()
    foreach ($line in @($prop.Value)) {
        if ($out.Count -ge $script:WhatsNewPointsPerVersion) { break }
        if ($line -isnot [string]) { continue }
        $t = ($line -replace '\s+', ' ').Trim()
        if (-not $t) { continue }
        # Authoring is guarded by tests/whats-new.sh; this is the last resort so
        # an over-long line cannot break the card's borders.
        if ($t.Length -gt $script:WhatsNewPointWidth) {
            $t = $t.Substring(0, $script:WhatsNewPointWidth - 3).TrimEnd() + "..."
        }
        $out += "  - $t"
    }
    return @($out)
}

# Write-ExakitWhatsNew - what `exakit whats-new` shows. False when there is no card.
function Write-ExakitWhatsNew {
    param([Parameter(Mandatory)][string]$Version, [string]$Heading = "")
    $root = Get-ExakitRepoRoot
    if (-not $root) { return $false }
    $points = @(Get-ExakitWhatsNewPoints -KitRoot $root -Version $Version)
    if ($points.Count -eq 0) { return $false }
    Write-Host ""
    if ($Heading) { Write-Host "  $Heading"; Write-Host "" }
    foreach ($p in $points) { Write-Host $p }
    Write-Host ""
    return $true
}

# Set-ExakitKitUpgradeNote - record the kit version installed BEFORE this run, for
# the box at the end to read. Call it while the manifest still holds the previous
# run's number.
#
# The record is in the manifest, not a script variable, because a run that dies
# partway has already overwritten kit.version: the next re-run would compare the
# new number against itself, decide nothing moved, and lose the notes for a hop
# nobody ever saw. A pending record therefore wins over anything this run computes,
# and only the box clears it.
function Set-ExakitKitUpgradeNote {
    param([Parameter(Mandatory)][string]$KitRoot)
    try {
        $pending = Get-ExakitManifestValue "kit.whats_new_from"
        if ($pending) { return }
        $was = Get-ExakitManifestValue "kit.version"
        $now = Get-ExakitKitVersionAt -KitRoot $KitRoot
        # A first-ever install has no previous version, and nothing to announce.
        if (-not $was -or -not $now -or $was -eq $now) { return }
        # Only forward. A downgrade has no notes to read out anyway, and recording
        # one would leave a pending marker no later run could resolve.
        if ((Compare-ExakitDottedVersion -A $now -B $was) -le 0) { return }
        Set-ExakitManifestValue "kit.whats_new_from" $was
    } catch { }
}

# Clear-ExakitKitUpgradeNote - the record is spent once the box has had its chance.
# Written through the low-level trio because Set-ExakitManifestValue takes -Value
# as a Mandatory parameter, which PowerShell refuses to bind to an empty string.
function Clear-ExakitKitUpgradeNote {
    try {
        $doc = Read-ExakitManifest
        if ($null -eq $doc) { return }
        Set-ManifestValue -Manifest $doc -Path "kit.whats_new_from" -Value ""
        Save-ExakitManifest $doc
    } catch { }
}

# Write-ExakitWhatsNewBox - one card per version crossed, after the connection
# panel. Prints only when the kit version moved during this run.
#
# No record means nothing is printed, which is the whole reason a first install and
# an idempotent re-run stay silent: the installer is documented as safe to re-run,
# and a card on every no-op run teaches people to ignore it.
# Mirrors exakit_print_whats_new_box in common.sh.
function Write-ExakitWhatsNewBox {
    param([string]$KitRoot = "")
    # Declared out here so the finally block can tell "no record, nothing to do"
    # from "record spent": a run with nothing to announce must not rewrite the
    # manifest at all.
    $from = ""
    try {
        $root = $KitRoot
        if (-not $root) { $root = Get-ExakitRepoRoot }
        $from = Get-ExakitManifestValue "kit.whats_new_from"
        if (-not $from) { return }
        $to = ""
        if ($root) { $to = Get-ExakitKitVersionAt -KitRoot $root }
        if (-not $to) { $to = Get-ExakitManifestValue "kit.version" }
        $versions = @()
        if ($root -and $to) { $versions = @(Get-ExakitWhatsNewVersions -KitRoot $root -From $from -To $to) }
        if ($versions.Count -eq 0) { return }

        # ONE width for every card. Complete-ExakitPanel sizes a panel to its own
        # longest line, so a three-version jump drew three boxes of three widths
        # and read as a staircase rather than one announcement.
        $width = 0
        $byVersion = @{}
        $drawn = @()
        foreach ($v in $versions) {
            $pts = @(Get-ExakitWhatsNewPoints -KitRoot $root -Version $v)
            # A version in range can still have nothing to say (an empty list).
            # It draws no card, so it must not make the run look announced.
            if ($pts.Count -eq 0) { continue }
            $byVersion[$v] = $pts
            $drawn += $v
            foreach ($p in $pts) { if ($p.Length -gt $width) { $width = $p.Length } }
        }
        if ($drawn.Count -eq 0) { return }
        $last = $drawn[$drawn.Count - 1]
        # One lead-in above the cards. The titles say which versions arrived;
        # only this says where the reader started. Printed only once a card is
        # certain: a lead-in with nothing under it is worse than silence.
        Write-Host ""
        Write-Host "  Your kit moved from $from to $to."
        foreach ($v in $drawn) {
            $pts = @($byVersion[$v])
            Write-Host ""
            Start-ExakitPanel "What's new in $v"
            foreach ($p in $pts) { Write-ExakitPanelLine $p.PadRight($width) }
            # Only on the last card: repeating it per version turns a pointer
            # into noise, and the newest version is the one to read in full.
            Complete-ExakitPanel
        }
    } catch {
        Write-ExakitLog "WARN" "The what's-new cards could not be built: $_"
    } finally {
        # Announced, or found nothing worth announcing: either way this move is
        # dealt with, and the record goes so the next re-run does not repeat it.
        if ($from) { Clear-ExakitKitUpgradeNote }
    }
}

# Get-ExakitKitVersionAt - kit.version as stated by a specific kit tree. The
# installer uses it on the tree it is installing FROM, which is not necessarily
# the copy under the kit home (that one may be an older install).
function Get-ExakitKitVersionAt {
    param([Parameter(Mandatory)][string]$KitRoot)
    $doc = Join-Path $KitRoot "versions.json"
    if (-not (Test-Path $doc)) { return $null }
    $version = Get-ExakitVersionsValue -Path "kit.version" -DocPath $doc
    if (-not $version -or $version -notmatch '^[A-Za-z0-9._+-]+$') { return $null }
    return $version
}

# Get-ExakitKitBundledVersion - kit.version as recorded by the kit copy on disk.
# This is what "installed" means for the kit itself; the manifest's kit.source
# only says where the copy came from.
function Get-ExakitKitBundledVersion {
    $root = Get-ExakitRepoRoot
    if (-not $root) { return $null }
    return (Get-ExakitKitVersionAt -KitRoot $root)
}

function Get-ExakitVersionsUserAgent {
    $kit = Get-ExakitKitBundledVersion
    if (-not $kit) { $kit = "unknown" }
    # Environment only, deliberately not Get-ExakitHostArch: the header is
    # cosmetic, and its WMI probe has no business delaying a version lookup.
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    elseif ($env:PROCESSOR_ARCHITECTURE) { $arch = $env:PROCESSOR_ARCHITECTURE }
    else { $arch = "unknown" }
    return "exakit-update-check/$kit (windows; $arch)"
}

# Seconds since the cached copy was written, or $null when there is no cache.
function Get-ExakitVersionsCacheAge {
    if (-not (Test-Path $script:VersionsCachePath)) { return $null }
    try {
        $written = (Get-Item $script:VersionsCachePath).LastWriteTimeUtc
    } catch {
        return $null
    }
    return [int]((Get-Date).ToUniversalTime() - $written).TotalSeconds
}

function Test-ExakitVersionsCacheFresh {
    $age = Get-ExakitVersionsCacheAge
    if ($null -eq $age) { return $false }
    return ($age -lt $script:VersionsTtl)
}

# Update-ExakitVersionsCache - refresh the cached document. Skips the network
# while the cache is younger than the TTL; -Force is for the explicit
# `exakit update-check`, which should always ask upstream.
# Returns 0 when a validated document was installed, 2 when the fetch was
# skipped as unnecessary, 1 when nothing could be fetched.
#
# A failed or invalid download never touches the cache: the temporary file lives
# in the cache directory (same volume) and only a validated document is moved
# into place, so a reader can never observe a half-written file.
function Update-ExakitVersionsCache {
    param([switch]$Force, [int]$TimeoutSec = 12)
    if ($script:VersionsUrl -notlike "https://*") {
        Write-ExakitLog "WARN" "refusing to fetch the versions manifest over a non-HTTPS URL"
        return 1
    }
    if (-not $Force -and (Test-ExakitVersionsCacheFresh)) { return 2 }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $script:VersionsCachePath -Parent) | Out-Null
    } catch {
        return 1
    }
    $tmp = "$($script:VersionsCachePath).tmp.$PID"
    try {
        Invoke-WebRequest -Uri $script:VersionsUrl -OutFile $tmp -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent (Get-ExakitVersionsUserAgent)
    } catch {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        Write-ExakitLog "INFO" "versions manifest fetch failed - keeping the cached copy"
        return 1
    }
    if ((Test-ExakitVersionsDoc -Path $tmp) -ne 0) {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        Write-ExakitLog "WARN" "fetched versions manifest did not validate - keeping the cached copy"
        return 1
    }
    try {
        Move-Item -Force $tmp $script:VersionsCachePath
    } catch {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        return 1
    }
    $script:VersionsDocPath = $script:VersionsCachePath
    $script:VersionsSource = "fetched"
    Write-ExakitLog "INFO" "versions manifest refreshed from $($script:VersionsUrl)"
    return 0
}

# Resolve-ExakitVersionsDoc - pick the document to read and remember it, so the
# validation gate runs once per command instead of once per lookup. Returns the
# path, or $null when only the compiled-in fallbacks are left.
function Resolve-ExakitVersionsDoc {
    if ($script:VersionsDocPath) { return $script:VersionsDocPath }
    # The cache is written only after validation, but anything under the kit
    # home can be edited by hand - re-check before trusting it.
    if ((Test-Path $script:VersionsCachePath) -and ((Test-ExakitVersionsDoc -Path $script:VersionsCachePath) -eq 0)) {
        $script:VersionsDocPath = $script:VersionsCachePath
        if (-not $script:VersionsSource) { $script:VersionsSource = "cache" }
        return $script:VersionsDocPath
    }
    $baked = Get-ExakitVersionsBakedPath
    if ($baked -and (Test-ExakitVersionsDoc -Path $baked) -eq 0) {
        $script:VersionsDocPath = $baked
        $script:VersionsSource = "baked"
        return $script:VersionsDocPath
    }
    $script:VersionsSource = "fallback"
    return $null
}

# Where the answers came from: fetched | cache | baked | fallback. Shown by
# update-check and recorded as desired.versions_source.
function Get-ExakitVersionsSource {
    if (-not $script:VersionsSource) { Resolve-ExakitVersionsDoc | Out-Null }
    if (-not $script:VersionsSource) { return "fallback" }
    return $script:VersionsSource
}

# True when a document was readable JSON but announced a newer schema, so
# callers can suggest updating the kit.
function Test-ExakitVersionsSchemaAhead {
    return $script:VersionsSchemaAhead
}

# Get-ExakitVersionsValue - the advertised value, e.g.
#   Get-ExakitVersionsValue -Path "components.exapump.version"
#   Get-ExakitVersionsValue -Path "components.exapump.sha256.windows-x86_64"
# $null means "not advertised" - never a failure to be propagated.
function Get-ExakitVersionsValue {
    param([Parameter(Mandatory)][string]$Path, [string]$DocPath = "")
    if (-not $DocPath) {
        $DocPath = Resolve-ExakitVersionsDoc
        if (-not $DocPath) { return $null }
    }
    if (-not (Test-Path $DocPath)) { return $null }
    try {
        $doc = Get-Content $DocPath -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        return $null
    }
    $value = Get-ManifestValue -Manifest $doc -Path $Path
    if ($null -eq $value) { return $null }
    if ($value -is [System.Management.Automation.PSCustomObject]) { return ($value | ConvertTo-Json -Compress) }
    return "" + $value
}

function Get-ExakitLatestGithubRelease {
    param([Parameter(Mandatory)][string]$Repo)
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 12
        return ("" + $release.tag_name).TrimStart("v")
    } catch { return "" }
}

function Get-ExakitLatestPypiVersion {
    param([Parameter(Mandatory)][string]$Package)
    try {
        $doc = Invoke-RestMethod -Uri "https://pypi.org/pypi/$Package/json" -UseBasicParsing -TimeoutSec 12
        return "" + $doc.info.version
    } catch { return "" }
}

# Return the docker image arch token for THIS machine: "amd64" or "arm64".
# Prefer the true hardware arch (WMI) so an x64-emulated PowerShell on an ARM
# device is not misread as amd64; fall back to the environment.
function Get-ExakitHostArch {
    try {
        $a = (Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1).Architecture
        if ($a -eq 12 -or $a -eq 5) { return "arm64" }
        if ($a -eq 9 -or $a -eq 0) { return "amd64" }
    } catch { }
    $p = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($p -match 'ARM') { return "arm64" }
    return "amd64"
}

function Get-ExakitLatestDockerTag {
    try {
        $doc = Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/$($script:NanoImage)/tags?page_size=100&ordering=last_updated" -UseBasicParsing -TimeoutSec 12
        # Keep the plain (multi-arch) tags plus this host's own arch, and drop
        # the other architecture's suffixed tags - otherwise the sort lands on
        # -arm64 (it sorts after -amd64) and an x86_64 host would pull an arm64
        # image that only runs under slow emulation.
        $arch = Get-ExakitHostArch
        if ($arch -eq "arm64") { $wrong = @("amd64", "x86_64", "x86-64") } else { $wrong = @("arm64", "aarch64") }
        $candidates = @($doc.results | ForEach-Object { $_.name } | Where-Object {
            ($_ -match '^\d+(\.\d+)+[-._A-Za-z0-9]*$') -and ($_ -notmatch 'latest') -and
            (-not (($_.ToLower() -split '[-._]') | Where-Object { $wrong -contains $_ }))
        })
        if ($candidates.Count -eq 0) { return "" }
        return ($candidates | Sort-Object { [regex]::Replace($_, '\d+', { param($m) $m.Value.PadLeft(12, '0') }) } | Select-Object -Last 1)
    } catch { return "" }
}

function Set-ExakitDesiredVersions {
    Set-ExakitManifestValue "version_policy" $script:VersionPolicy
    $source = $script:VersionsSourceUsed
    if (-not $source) { $source = "unknown" }
    Set-ExakitManifestValue "desired.versions_source" $source
    Set-ExakitManifestValue "desired.runtime.nano" $script:NanoTag
    Set-ExakitManifestValue "desired.exapump" $script:ExapumpVersion
    Set-ExakitManifestValue "desired.mcp" $script:McpVersion
    Set-ExakitManifestValue "desired.pyexasol" $script:PyexasolVersion
}

# Resolve-ExakitInstallVersions - decide which version of each Component this
# install gets. An explicit env override always wins; the policy decides where
# the rest comes from. Resolution never fails: each tier degrades into the next,
# and the recorded desired.versions_source says which one answered.
function Resolve-ExakitInstallVersions {
    if ($script:VersionPolicy -eq "latest") {
        # The escape hatch: newest of every Component, resolved upstream.
        $script:VersionsSourceUsed = "latest"
        if (-not $script:NanoTag) {
            $script:NanoTag = Get-ExakitLatestDockerTag
            if (-not $script:NanoTag) { $script:NanoTag = $script:NanoTagFallback }
        }
        if (-not $script:ExapumpVersion) {
            $script:ExapumpVersion = Get-ExakitLatestGithubRelease $script:ExapumpRepo
            if (-not $script:ExapumpVersion) { $script:ExapumpVersion = $script:ExapumpVersionFallback }
        }
        if (-not $script:McpVersion) {
            $script:McpVersion = Get-ExakitLatestPypiVersion $script:McpPackage
            if (-not $script:McpVersion) { $script:McpVersion = $script:McpVersionFallback }
        }
        if (-not $script:PyexasolVersion) {
            $script:PyexasolVersion = Get-ExakitLatestPypiVersion $script:PyexasolPackage
            if (-not $script:PyexasolVersion) { $script:PyexasolVersion = $script:PyexasolVersionFallback }
        }
        Set-ExakitDesiredVersions
        return
    }
    if ($script:VersionPolicy -ne "manifest") {
        # No network at all: the last-known-good constants only.
        $script:VersionsSourceUsed = "fallback"
        if (-not $script:NanoTag) { $script:NanoTag = $script:NanoTagFallback }
        if (-not $script:ExapumpVersion) { $script:ExapumpVersion = $script:ExapumpVersionFallback }
        if (-not $script:McpVersion) { $script:McpVersion = $script:McpVersionFallback }
        if (-not $script:PyexasolVersion) { $script:PyexasolVersion = $script:PyexasolVersionFallback }
        Set-ExakitDesiredVersions
        return
    }

    # The versions manifest: one TTL-gated fetch, then read. A fresh install picks
    # up the currently advertised set; an offline one silently uses the cached
    # copy, the copy that shipped with this kit, or the constants above.
    Update-ExakitVersionsCache | Out-Null
    Resolve-ExakitVersionsDoc | Out-Null
    $script:VersionsSourceUsed = Get-ExakitVersionsSource
    if (-not $script:NanoTag) {
        $script:NanoTag = Get-ExakitVersionsValue -Path "components.nano.version"
        if (-not $script:NanoTag) { $script:NanoTag = $script:NanoTagFallback }
    }
    if (-not $script:ExapumpVersion) {
        $script:ExapumpVersion = Get-ExakitVersionsValue -Path "components.exapump.version"
        if (-not $script:ExapumpVersion) { $script:ExapumpVersion = $script:ExapumpVersionFallback }
    }
    if (-not $script:McpVersion) {
        $script:McpVersion = Get-ExakitVersionsValue -Path "components.mcp.version"
        if (-not $script:McpVersion) { $script:McpVersion = $script:McpVersionFallback }
    }
    if (-not $script:PyexasolVersion) {
        $script:PyexasolVersion = Get-ExakitVersionsValue -Path "components.pyexasol.version"
        if (-not $script:PyexasolVersion) { $script:PyexasolVersion = $script:PyexasolVersionFallback }
    }
    Write-ExakitLog "INFO" "versions resolved from the manifest ($($script:VersionsSourceUsed))"
    Set-ExakitDesiredVersions
}

function Test-ExakitStepDone {
    param([Parameter(Mandatory)][string]$Step)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { return $false }
    $steps = Get-ManifestValue -Manifest $doc -Path "steps_completed"
    if ($null -eq $steps) { return $false }
    return ([array]$steps) -contains $Step
}

# mark_step equivalent (idempotent; does not touch a rollback stack - Windows
# path has no equivalent to bash's rollback registration).
function Set-ExakitStepDone {
    param([Parameter(Mandatory)][string]$Step)
    $doc = Read-ExakitManifest
    if ($null -eq $doc) { Fail "Failed to record step ${Step}: no manifest at $script:ManifestPath" }
    $steps = Get-ManifestValue -Manifest $doc -Path "steps_completed"
    $steps = [array]$steps
    if ($steps -notcontains $Step) { $steps += $Step }
    Set-ManifestValue -Manifest $doc -Path "steps_completed" -Value $steps
    Save-ExakitManifest $doc
    Write-ExakitLog "STEP" "completed: $Step"
}

# Get-ExakitStepArtifactState <step> - returns "present", "missing" or "unknown".
# Peer of step_artifact_state in common.sh.
#
# The tick in steps_completed records that a step RAN once, not that what it
# produced is still on disk. A machine turned up with a completed launcher step
# and no launcher binary, and every re-run then skipped that step and failed the
# deployment step that needs it - the one step that could have repaired the
# install was the one being skipped. Begin-ExakitStep consults this so a
# completed step can be re-run when its artifact is gone.
#
# Three rules hold this function together:
#
#   1. "unknown" NEVER overrides the manifest. There is no cheap way to prove a
#      database container is deployed, and re-running the runtime step on a guess
#      would stop a working database - far worse than the bug this fixes. A wrong
#      "missing" is destructive; a wrong "unknown" just leaves today's behaviour
#      in place. Anything not cheaply provable is "unknown".
#   2. FILE TESTS ONLY. This runs once per step on every install, so no network,
#      no PyPI, no GitHub and above all nothing that could wake or probe Docker.
#   3. "present" means what the NEXT step will actually resolve.
#   4. EXISTING IS NOT ENOUGH - it must also be non-empty. A 0-byte file is
#      exactly what an interrupted or out-of-space install leaves behind, and it
#      is not a runnable shim or binary, so the next step would fail on it just
#      as surely as on an absent one. Every branch that judges a file pairs the
#      existence test with a length test. (The shell twin's rule 4 says the same
#      of `[ -x ]`, which is true of a 0-byte file with mode 755.)
function Get-ExakitStepArtifactState {
    param([Parameter(Mandatory)][string]$Step)
    if ($Step -eq "exakit_helper") {
        $shim = Join-Path $script:BinDir "exakit.cmd"
        if ((Test-Path -LiteralPath $shim -PathType Leaf) -and ((Get-Item -LiteralPath $shim).Length -gt 0)) { return "present" }
        return "missing"
    }
    if ($Step -eq "exapump") {
        # The install records the exact path it resolved. No record means an
        # older install (or a soft failure) we cannot judge: "unknown".
        $recorded = Get-ExakitManifestValue "components.exapump.path"
        if (-not $recorded) { return "unknown" }
        if ((Test-Path -LiteralPath $recorded -PathType Leaf) -and ((Get-Item -LiteralPath $recorded).Length -gt 0)) { return "present" }
        return "missing"
    }
    # runtime (the Nano container), mcp, pyexasol - and "launcher", which is a
    # macOS-only step with no Windows peer: nothing a file test can settle
    # without risking a destructive false "missing". See rule 1 above.
    return "unknown"
}

# Begin-ExakitStep <name> <description> - announces a step, returns $false
# (caller should skip) if already done AND what it installed is still there.
#
# A step is skipped only when the manifest tick and the disk agree. When the tick
# says done but Get-ExakitStepArtifactState proves the artifact is gone, the step
# is announced and run again - that is what makes "re-running the installer is
# safe and resumes" (AGENTS.md) true even after something removed an artifact
# from under a completed install.
function Begin-ExakitStep {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Description)
    $script:ExakitActiveLabel = $Description   # spinner label for Invoke-ExakitLogged in this step
    $rerun = $false
    if (Test-ExakitStepDone $Name) {
        # "unknown" (and "present") keep the manifest's answer: only a proven
        # "missing" is allowed to override the tick.
        if ((Get-ExakitStepArtifactState $Name) -eq "missing") {
            $rerun = $true
        } else {
            Ok "$Description - already done, skipping"
            return $false
        }
    }
    Write-Host ""
    if ($script:UiFancy) {
        Write-Host ("  {0}{1}{2} {3}{4}{5}" -f $script:UiAccent, $script:UiArrow, $script:UiReset, $script:UiBold, $Description, $script:UiReset)
    } else {
        Write-Host ("  {0} {1}" -f $script:UiArrow, $Description) -ForegroundColor Blue
    }
    Write-ExakitLog "STEP" $Description
    if ($rerun) {
        Info "Recorded as done, but what it installed is missing - running it again"
    }
    return $true
}

# Set-ExakitCmdShim - (re)write the `exakit` command in the bin directory.
#
# The bare command must be ONLY this .cmd shim: when an exakit.ps1 also sits on
# PATH, PowerShell resolves the .ps1 first, which routes around the shim's
# -ExecutionPolicy Bypass and fails on default-policy systems. The shim therefore
# targets the kit's copy by absolute path. Both the installer and the kit
# self-update write it, so the content lives here rather than in two places.
function Get-ExakitCmdShimContent {
    param([Parameter(Mandatory)][string]$PsTarget)
    return "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"$PsTarget`" %*`r`n"
}

function Set-ExakitCmdShim {
    param([Parameter(Mandatory)][string]$PsTarget)
    New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
    Remove-Item -Force (Join-Path $script:BinDir "exakit.ps1") -ErrorAction SilentlyContinue
    $shimPath = Join-Path $script:BinDir "exakit.cmd"
    Set-Content -Path $shimPath -Value (Get-ExakitCmdShimContent -PsTarget $PsTarget) -NoNewline
    return $shimPath
}

# Test-ExakitCmdShimCurrent - is the installed shim the one this kit would write?
#
# The twin of the bash side's copy comparison, and needed for the same reason: the
# exakit_helper step flag records "installed", not "current", so a re-run over an
# older install skips the step with the flag already set. Windows gets off lighter
# because the shim only points AT the kit copy, which install.ps1 has just
# replaced - but a shim written by an older kit, or aimed at a path that has since
# moved, still has to be rewritten.
function Test-ExakitCmdShimCurrent {
    param([Parameter(Mandatory)][string]$PsTarget)
    $shimPath = Join-Path $script:BinDir "exakit.cmd"
    if (-not (Test-Path $shimPath)) { return $false }
    $actual = Get-Content -Path $shimPath -Raw -ErrorAction SilentlyContinue
    return ($actual -eq (Get-ExakitCmdShimContent -PsTarget $PsTarget))
}

# ---------------------------------------------------------------------------
# After-command update notice
# ---------------------------------------------------------------------------
# One dim line on stderr, after an unrelated command, when the maintainers have
# flagged a pending change as recommended or critical. Everything about it is
# deliberately conservative: a normal bump never interrupts anyone, the notice
# appears at most once a day, it never speaks unless stderr is a terminal, and
# EXAKIT_NO_UPDATE_NOTICE=1 silences it for good.
#
# Twin of exakit_notice_after_command in setup/lib/common.sh, including the state
# file, so the once-a-day budget is the same file on both platforms.
$script:NoticeState = if ($env:EXAKIT_NOTICE_STATE) { $env:EXAKIT_NOTICE_STATE } else { Join-Path $script:CacheDir "notice-state.json" }
# 0 = after every command; see the note on EXAKIT_NOTICE_INTERVAL in common.sh.
$script:NoticeInterval = 0
if ($env:EXAKIT_NOTICE_INTERVAL -match '^[0-9]+$') { $script:NoticeInterval = [int]$env:EXAKIT_NOTICE_INTERVAL }

# The twin of the bash notice plan cache. Working out WHAT to say costs a live
# probe per component; the answer barely changes, so it is computed occasionally and
# printed from a cached plan. See the note on EXAKIT_NOTICE_PLAN in common.sh for
# what the cache can and cannot notice.
$script:NoticePlanPath = Join-Path $script:CacheDir "notice-plan"
if ($env:EXAKIT_NOTICE_PLAN) { $script:NoticePlanPath = $env:EXAKIT_NOTICE_PLAN }
$script:NoticePlanTtl = 900
if ($env:EXAKIT_NOTICE_PLAN_TTL -match '^[0-9]+$') { $script:NoticePlanTtl = [int]$env:EXAKIT_NOTICE_PLAN_TTL }

# Content, not timestamps: an update that rewrote the manifest in the same second
# the plan was written must still retire it.
function Get-ExakitNoticeSignature {
    # The kit's own copy of the document counts too: it is the tier that answers when
    # there is no cache, and a self-update replaces it.
    $baked = Join-Path $script:ExakitHome "kit\versions.json"
    $parts = @()
    foreach ($file in @($script:ManifestPath, $script:VersionsCachePath, $baked)) {
        if ($file -and (Test-Path $file)) {
            try {
                $parts += (Get-FileHash -Path $file -Algorithm MD5 -ErrorAction Stop).Hash
            } catch {
                $parts += ""
            }
        } else {
            $parts += ""
        }
    }
    return ($parts -join ":")
}

function Get-ExakitNoticePlanField {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-Path $script:NoticePlanPath)) { return "" }
    foreach ($line in (Get-Content -Path $script:NoticePlanPath -ErrorAction SilentlyContinue)) {
        if ($line.StartsWith("$Name=")) { return $line.Substring($Name.Length + 1) }
    }
    return ""
}

function Test-ExakitNoticePlanFresh {
    if (-not (Test-Path $script:NoticePlanPath)) { return $false }
    if ((Get-ExakitNoticePlanField -Name "sig") -ne (Get-ExakitNoticeSignature)) { return $false }
    $at = Get-ExakitNoticePlanField -Name "computed_at"
    if ($at -notmatch '^[0-9]+$') { return $false }
    $now = [int][double]::Parse((Get-Date -UFormat %s))
    return (($now - [int]$at) -lt $script:NoticePlanTtl)
}

function Write-ExakitNoticePlan {
    param([string[]]$Light, [string]$LightWorst, [string[]]$Heavy, [string]$HeavyWorst)
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:NoticePlanPath) | Out-Null
        $now = [int][double]::Parse((Get-Date -UFormat %s))
        $lines = @(
            "computed_at=$now",
            "sig=$(Get-ExakitNoticeSignature)",
            "light=$($Light -join ', ')",
            "light_worst=$LightWorst",
            "heavy=$($Heavy -join ', ')",
            "heavy_worst=$HeavyWorst"
        )
        Set-Content -Path $script:NoticePlanPath -Value $lines
    } catch { }
}

# Get-ExakitNoticeStillBehind - the names from a cached candidate list that are
# genuinely still behind.
#
# The advertised version travels with each candidate, so this needs no document and
# no severity lookup: probe what is installed, compare, drop whatever caught up. A
# plan written while a component was mid-install used to keep announcing an update
# the user had already taken, and contradicted `exakit update-check` seconds later.
function Get-ExakitNoticeStillBehind {
    param([string]$Entries)
    if (-not $Entries) { return @() }
    $survivors = @()
    foreach ($entry in ($Entries -split ",")) {
        $trimmed = $entry.Trim()
        if (-not $trimmed) { continue }
        $name = $trimmed
        $want = ""
        if ($trimmed.Contains(":")) {
            $name = $trimmed.Substring(0, $trimmed.IndexOf(":"))
            $want = $trimmed.Substring($trimmed.IndexOf(":") + 1)
        }
        if (-not $want) {
            # A plan from before versions travelled with the names: keep it rather
            # than silently dropping a real pending update.
            $survivors += $name
            continue
        }
        $now = Get-ExakitComponentCurrent $name
        if (-not $now -or $now -eq "unknown" -or $now -eq $want) { continue }
        # "Caught up" is not only "landed on exactly the advertised version" - an
        # install that overshot it has nothing pending either. Testing equality
        # alone kept such a component alive as a candidate, so a cached plan went
        # on announcing an update on every command with nothing able to clear it.
        if (Test-ExakitVersionNewer -Latest $now -Current $want) { continue }
        $survivors += $name
    }
    return $survivors
}

# Printing is shared by the freshly-computed and the cached path.# Printing is shared by the freshly-computed and the cached path.
function Write-ExakitNoticeLines {
    param([string[]]$Light, [string]$LightWorst, [string[]]$Heavy, [string]$HeavyWorst)
    if ($Light.Count -eq 0 -and $Heavy.Count -eq 0) { return }
    $dim = $script:UiDim
    $reset = $script:UiReset
    [Console]::Error.WriteLine("")
    if ($Light.Count -gt 0) {
        $word = Get-ExakitNoticeWord $LightWorst
        [Console]::Error.WriteLine("$dim$word update is available for $($Light -join ', ') - apply in seconds:  exakit update$reset")
    }
    if ($Heavy.Count -gt 0) {
        # Never "run update now" for the runtime: it stops the database, so the user
        # picks the moment after seeing what it involves.
        $word = Get-ExakitNoticeWord $HeavyWorst
        [Console]::Error.WriteLine("$dim$word update is available for $($Heavy -join ', ') - requires stopping the database, details:  exakit update-check$reset")
    }
    [Console]::Error.WriteLine("${dim}Silence this with EXAKIT_NO_UPDATE_NOTICE=1$reset")
    Set-ExakitNoticeShown
}

function Test-ExakitNoticeDue {
    if (-not (Test-Path $script:NoticeState)) { return $true }
    try {
        $state = Get-Content $script:NoticeState -Raw | ConvertFrom-Json
    } catch {
        return $true
    }
    $last = Get-ManifestValue -Manifest $state -Path "last_shown"
    if (-not ($last -is [int] -or $last -is [long])) { return $true }
    $epoch = [int][double]::Parse((Get-Date -UFormat %s))
    return (($epoch - $last) -ge $script:NoticeInterval)
}

# Atomic, and never a reason for a command to fail: an unwritable cache directory
# just means the notice repeats.
function Set-ExakitNoticeShown {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $script:NoticeState -Parent) | Out-Null
        $epoch = [int][double]::Parse((Get-Date -UFormat %s))
        $tmp = "$($script:NoticeState).tmp.$PID"
        Set-Content -Path $tmp -Value ("{`n  ""last_shown"": $epoch`n}")
        Move-Item -Force $tmp $script:NoticeState
    } catch { }
}

# A notice may never make an unrelated command feel slow. The cache is normally
# warm; when it is not, this is one very short attempt that gives up almost at once.
function Update-ExakitNoticeCache {
    if (Test-ExakitVersionsCacheFresh) { return }
    # Two seconds, once a day, worst case - the bash twin passes the same budget to
    # curl. Silence on failure: the notice simply does not appear.
    try { Update-ExakitVersionsCache -Force -TimeoutSec 2 | Out-Null } catch { }
}

function Get-ExakitNoticeWord {
    param([string]$Severity)
    if ($Severity -eq "critical") { return "A critical" }
    if ($Severity -eq "recommended") { return "A recommended" }
    # A routine bump says nothing about urgency, because it has none to claim.
    return "An"
}

# Show-ExakitUpdateNotice - the whole notice, gates included. Never throws and
# never changes what the command before it reported.
function Show-ExakitUpdateNotice {
    if ($env:EXAKIT_NO_UPDATE_NOTICE -eq "1") { return }
    if ($script:VersionPolicy -ne "manifest") { return }
    # stderr must be a terminal: a notice has no business in a log file, a pipe, or
    # a CI transcript.
    try { if ([Console]::IsErrorRedirected) { return } } catch { return }
    if (-not (Test-Path $script:ManifestPath)) { return }
    if (-not (Test-ExakitNoticeDue)) { return }
    # The component readers live in setup/exakit.ps1; the notice is only ever
    # hooked from that dispatcher, but never assume it when the library is used
    # on its own (the installer dot-sources it too).
    if (-not (Get-Command Get-ExakitComponentAvailable -ErrorAction SilentlyContinue)) { return }
    # Both notice paths now compare versions, and that comparison also lives in
    # the dispatcher. Named in the same gate so a library-only load returns
    # quietly rather than throwing into the catch below.
    if (-not (Get-Command Test-ExakitVersionNewer -ErrorAction SilentlyContinue)) { return }

    try {
        if (Test-ExakitNoticePlanFresh) {
            $cachedLight = @()
            $cachedHeavy = @()
            $lightField = Get-ExakitNoticePlanField -Name "light"
            $heavyField = Get-ExakitNoticePlanField -Name "heavy"
            $cachedLight = Get-ExakitNoticeStillBehind -Entries $lightField
            $cachedHeavy = Get-ExakitNoticeStillBehind -Entries $heavyField
            $cachedLightWorst = Get-ExakitNoticePlanField -Name "light_worst"
            $cachedHeavyWorst = Get-ExakitNoticePlanField -Name "heavy_worst"
            if (-not $cachedLightWorst) { $cachedLightWorst = "normal" }
            if (-not $cachedHeavyWorst) { $cachedHeavyWorst = "normal" }
            Write-ExakitNoticeLines -Light $cachedLight -LightWorst $cachedLightWorst `
                -Heavy $cachedHeavy -HeavyWorst $cachedHeavyWorst
            return
        }
        Update-ExakitNoticeCache
        if (-not (Resolve-ExakitVersionsDoc)) { return }
        # Severity is tracked per group, not once for the whole notice: a routine
        # exapump bump must not be announced as critical just because the runtime
        # happens to have a critical one pending in the same breath.
        $light = @()
        $heavy = @()
        $lightDetail = @()
        $heavyDetail = @()
        $lightWorst = "normal"
        $heavyWorst = "normal"
        foreach ($component in (Get-ExakitUpdateTargets -Target "all")) {
            $actual = Get-ExakitActualTarget $component
            $available = Get-ExakitComponentAvailable $actual
            if (-not $available) { continue }
            $current = Get-ExakitComponentCurrent $actual
            if (-not $current -or $current -eq "unknown" -or $current -eq "not installed") { continue }
            if ($current -eq $available) { continue }
            # Different is not the same as behind. An install that is PAST the
            # advertised version has nothing pending: the kit never moves a
            # component backwards, so `exakit update-check` renders that row as
            # "none" and `exakit update` says "keeping yours". Announcing an
            # update here made the three commands contradict each other, and
            # pointed the user at a command that could not do anything. Skipped
            # before severity is read, so the row cannot colour the group wording.
            if (Test-ExakitVersionNewer -Latest $current -Current $available) { continue }
            # Only what the maintainers flagged. A normal bump waits to be asked
            # about - and an advised rollback counts, which is the point of the flag.
            # Every pending update is announced, whatever its severity. Severity
            # still decides the WORDING, but no longer whether the user hears about
            # it at all: a routine bump that is never mentioned never gets applied.
            $severity = Get-ExakitComponentSeverity $actual
            if (Test-ExakitComponentHeavy $actual) {
                $heavy += $actual
                $heavyDetail += "${actual}:${available}"
                # normal < recommended < critical; normal must not self-promote.
                if ($severity -eq "critical") { $heavyWorst = "critical" }
                elseif ($severity -eq "recommended" -and $heavyWorst -ne "critical") { $heavyWorst = "recommended" }
            } else {
                $light += $actual
                $lightDetail += "${actual}:${available}"
                if ($severity -eq "critical") { $lightWorst = "critical" }
                elseif ($severity -eq "recommended" -and $lightWorst -ne "critical") { $lightWorst = "recommended" }
            }
        }
        # Written even when nothing is pending: "nothing to say" is exactly the
        # answer worth not recomputing on every command.
        Write-ExakitNoticePlan -Light $lightDetail -LightWorst $lightWorst -Heavy $heavyDetail -HeavyWorst $heavyWorst
        Write-ExakitNoticeLines -Light $light -LightWorst $lightWorst -Heavy $heavy -HeavyWorst $heavyWorst
    } catch { }
}

# ---------------------------------------------------------------------------
# Kit self-update (Windows)
# ---------------------------------------------------------------------------
# Update-ExakitSelf - replace the kit copy under the kit home with the current
# contents of the repository, exactly as install.ps1 would fetch it. Twin of
# exakit_update_self in setup/lib/common.sh, with one Windows-specific twist: this
# script is itself running out of the directory being replaced, and Windows will
# not rename a directory whose files are open. When the in-place swap is refused,
# the swap is handed to a detached process that waits for this one to exit (the
# same pattern uninstall uses for the CLI binaries).
#
# Callers pass the versions in, so the library keeps no dependency on the CLI's
# component readers.
function Update-ExakitSelf {
    param([Parameter(Mandatory)][string]$Advertised, [string]$Installed = "")
    $repo = $script:KitRepo
    $kitDir = Join-Path $script:ExakitHome "kit"
    $shown = $Installed
    if (-not $shown) { $shown = "unknown" }
    Info "Updating starter kit $shown -> $Advertised"

    $tmpZip = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-kit-$([guid]::NewGuid().ToString('N')).zip"
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) "exakit-kit-stage-$([guid]::NewGuid().ToString('N'))"
    # main first - that is what install.ps1 fetches, and kit script changes live on
    # main: a tag exists only where a release was cut. The tag URLs stay behind it
    # so a kit installed from a tagged release still updates.
    $refs = @("main", "v$Advertised", "$Advertised")
    $kitRef = ""
    foreach ($ref in $refs) {
        if ($ref -eq "main") { $url = "https://github.com/$repo/archive/refs/heads/main.zip" }
        else { $url = "https://github.com/$repo/archive/refs/tags/$ref.zip" }
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing -TimeoutSec 300
            $kitRef = $ref
            break
        } catch { }
    }
    if (-not $kitRef) {
        Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
        Fail "Could not download the starter kit from github.com/$repo (tried main and the $Advertised tags)."
    }

    try {
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        Expand-Archive -Path $tmpZip -DestinationPath $stage -Force
    } catch {
        Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
        Fail "Could not unpack the starter kit update; existing kit copy was left untouched."
    }
    Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
    # A GitHub archive wraps everything in one <repo>-<ref> directory.
    $staged = Get-ChildItem -Path $stage -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $staged) {
        Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
        Fail "Downloaded starter kit archive was empty; existing kit copy was left untouched."
    }
    $stagedRoot = $staged.FullName

    # versions.json is on this list deliberately: without it the new kit copy has no
    # offline version tier and cannot say what version it is. The eight paths before
    # it are the ones v0.1.0 also validates - none may ever be renamed.
    foreach ($required in @("setup/exakit", "setup/lib/common.sh", "setup/lib/runtime-nano.sh",
                            "setup/lib/runtime-personal.sh", "setup/lib/exapump.sh", "setup/lib/mcp.sh",
                            "setup/exakit.ps1", "setup/lib/exakit-common.ps1", "versions.json")) {
        if (-not (Test-Path (Join-Path $stagedRoot ($required -replace '/', '\')))) {
            Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
            Fail "Downloaded starter kit is incomplete (missing $required); existing kit copy was left untouched."
        }
    }

    # What actually landed is what gets recorded: GitHub's raw endpoint can serve a
    # newer versions.json than the branch archive for a few minutes after a merge.
    $stagedVersion = Get-ExakitKitVersionAt -KitRoot $stagedRoot
    if (-not $stagedVersion) {
        $stagedVersion = $Advertised
    } elseif ($stagedVersion -ne $Advertised -and (Test-ExakitVersionNewer -Latest $Advertised -Current $stagedVersion)) {
        Warn2 "The downloaded kit is $stagedVersion, not the advertised $Advertised - the published manifest is a few minutes ahead of $kitRef. Recording $stagedVersion."
    }

    $backup = "$kitDir.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    $swapped = $false
    try {
        if (Test-Path $kitDir) { Move-Item -Path $kitDir -Destination $backup -ErrorAction Stop }
        Move-Item -Path $stagedRoot -Destination $kitDir -ErrorAction Stop
        $swapped = $true
    } catch {
        # Almost always "the process cannot access the file because it is being used
        # by another process": this very script lives under $kitDir. Restore what we
        # moved and let a detached process finish the job after we exit.
        if (-not (Test-Path $kitDir) -and (Test-Path $backup)) {
            Move-Item -Path $backup -Destination $kitDir -ErrorAction SilentlyContinue
        }
    }

    # The shim lives in the bin directory, which is never locked, and its target
    # path does not change across the swap - so it is safe to write either way.
    Set-ExakitCmdShim -PsTarget (Join-Path $kitDir "setup\exakit.ps1") | Out-Null
    Confirm-ExakitOnPath $script:BinDir

    if ($swapped) {
        Info "Previous kit copy kept at $backup"
        Set-ExakitManifestValue "kit.source" "$repo@$kitRef"
        Set-ExakitManifestValue "kit.version" $stagedVersion
        Ok "exakit updated to $stagedVersion. Database data, credentials, and MCP state were not changed."
        # The kit that just landed describes itself, from the new copy in place.
        [void](Write-ExakitWhatsNew -Version $stagedVersion -Heading "What's new in $stagedVersion")
        return
    }

    Complete-ExakitSelfUpdateDeferred -StagedRoot $stagedRoot -KitDir $kitDir -Backup $backup
    Set-ExakitManifestValue "kit.source" "$repo@$kitRef"
    Set-ExakitManifestValue "kit.version" $stagedVersion
    Ok "exakit $stagedVersion is staged and will be in place the moment this command exits."
    Info "The next `exakit` you run is the new one. Nothing else was changed."
}

# Finish the swap from a short-lived detached PowerShell that first waits for this
# process (and the cmd.exe running exakit.cmd) to exit, so the files this script
# is executing from are no longer open. Same approach as
# Remove-ExakitBinariesDeferred in setup/exakit.ps1.
function Complete-ExakitSelfUpdateDeferred {
    param(
        [Parameter(Mandatory)][string]$StagedRoot,
        [Parameter(Mandatory)][string]$KitDir,
        [Parameter(Mandatory)][string]$Backup
    )
    $waitPids = @($PID)
    try {
        $me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
        if ($me.ParentProcessId) { $waitPids += [int]$me.ParentProcessId }
    } catch { }
    $waitPids = @($waitPids | Sort-Object -Unique)
    $pidList = $waitPids -join ','
    # Single-quote the paths and double any quote they contain, exactly as
    # Remove-ExakitBinariesDeferred does.
    $q1 = $KitDir -replace "'", "''"
    $q2 = $Backup -replace "'", "''"
    $q3 = $StagedRoot -replace "'", "''"
    # Only the directory swap is deferred; the shim was already written by the
    # caller, and its target path is the same before and after.
    $deferred = @"
foreach (`$id in @($pidList)) { try { Wait-Process -Id `$id -Timeout 120 -ErrorAction SilentlyContinue } catch {} }
Start-Sleep -Milliseconds 500
try {
    if (Test-Path '$q1') { Move-Item -Force -Path '$q1' -Destination '$q2' -ErrorAction Stop }
    Move-Item -Force -Path '$q3' -Destination '$q1' -ErrorAction Stop
} catch {
    if (-not (Test-Path '$q1') -and (Test-Path '$q2')) {
        Move-Item -Force -Path '$q2' -Destination '$q1' -ErrorAction SilentlyContinue
    }
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deferred))
    try {
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-WindowStyle", "Hidden", "-EncodedCommand", $encoded) `
            -WindowStyle Hidden | Out-Null
    } catch {
        Fail "Could not stage the kit update for replacement after exit ($_). The existing kit copy is untouched; re-run install.ps1 to refresh it."
    }
}

# ---------------------------------------------------------------------------
# Downloads and verification
# ---------------------------------------------------------------------------
function Get-ExakitFile {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Dest)
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest -Parent) | Out-Null
    Write-ExakitLog "GET" "$Url -> $Dest"
    # Retry transient failures, mirroring the bash side's curl --retry 3
    # --connect-timeout policy: one network blip must not abort the install.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 120
            break
        } catch {
            Remove-Item -Force $Dest -ErrorAction SilentlyContinue
            if ($attempt -ge 3) {
                Fail "Download failed after $attempt attempts: $Url ($_)"
            }
            Warn2 "Download attempt $attempt failed - retrying in $(5 * $attempt)s"
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Get-ExakitSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-UpperInvariantString {
    param([Parameter(Mandatory)]$Value)
    return ([string]$Value).ToUpperInvariant()
}

function Test-ExakitSha256 {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Expected)
    $actual = Get-ExakitSha256 $Path
    if ($actual -ne $Expected.ToLowerInvariant()) {
        Write-Host ("      {0}{1}{2} Checksum mismatch for {3}" -f $script:UiErr, $script:UiCross, $script:UiReset, (Split-Path $Path -Leaf))
        Write-Host ("      {0}{1} expected: {2}{3}" -f $script:UiDim, $script:UiVB, $Expected, $script:UiReset)
        Write-Host ("      {0}{1} actual:   {2}{3}" -f $script:UiDim, $script:UiVB, $actual, $script:UiReset)
        Fail "Refusing to continue with an unverified artifact"
    }
    Ok "Checksum verified: $(Split-Path $Path -Leaf)"
}

# ---------------------------------------------------------------------------
# Credentials (NTFS ACL is the Windows equivalent of chmod 600: strip
# inherited permissions and grant only the current user).
# ---------------------------------------------------------------------------
function Protect-ExakitFile {
    param([Parameter(Mandatory)][string]$Path)
    # ACL APIs are Windows-only; this script only ships for the Windows path,
    # but the guard keeps it from throwing under cross-platform PowerShell 7
    # (e.g. running this file's tests on macOS/Linux during development).
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { return }
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
        "FullControl", "Allow")
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

function New-ExakitPassword {
    $chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".ToCharArray()
    $bytes = New-Object byte[] 24
    # RandomNumberGenerator's static Fill() is .NET 6+/Core-only. Windows
    # PowerShell 5.1 runs on .NET Framework, which only has the classic
    # instance-based Create()+GetBytes() API - use that instead so this
    # works on both.
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

# Written atomically (temp file + rename) so an interrupted run can never
# leave a truncated secret.
function Set-ExakitCredential {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)
    New-Item -ItemType Directory -Force -Path $script:CredsDir | Out-Null
    $target = Join-Path $script:CredsDir $Name
    $tmp = "$target.tmp"
    [System.IO.File]::WriteAllText($tmp, $Value)
    Protect-ExakitFile $tmp
    Move-Item -Force $tmp $target
}

function Get-ExakitCredential {
    param([Parameter(Mandatory)][string]$Name)
    $path = Join-Path $script:CredsDir $Name
    if (-not (Test-Path $path)) { return "" }
    return (Get-Content $path -Raw -ErrorAction SilentlyContinue)
}

# Copy-ExakitAsset - copy a file or directory to $Destination, but skip the
# copy entirely when the source already IS the destination. The Windows
# installer (install.ps1) downloads the kit straight into
# ~\.exasol-starter-kit\kit and runs setup from there, so the "keep a copy of
# the kit next to the state" step would otherwise try to copy a directory
# onto itself and crash ("Cannot overwrite the item ... with itself"). When
# the paths differ (a standalone checkout elsewhere), any stale destination
# is removed first so a re-run can't produce a nested lib\lib copy.
function Copy-ExakitAsset {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path $Source)) { return }
    $srcFull = (Resolve-Path $Source).Path.TrimEnd('\', '/')
    $dstFull = $Destination.TrimEnd('\', '/')
    if (Test-Path $Destination) { $dstFull = (Resolve-Path $Destination).Path.TrimEnd('\', '/') }
    if ([string]::Equals($srcFull, $dstFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return  # already in place (installer ran from the kit copy itself)
    }
    if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
    Copy-Item -Recurse -Force $Source $Destination
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
function Ensure-ExakitOnPath {
    param([Parameter(Mandatory)][string]$Dir)
    $path = $env:Path -split ";"
    if ($path -notcontains $Dir) {
        # Update current session
        $env:Path = "$Dir;$env:Path"
        # Update permanent user-level environment variable
        $userPath = [System.Environment]::GetEnvironmentVariable("PATH", [System.EnvironmentVariableTarget]::User)
        if ($userPath -notlike "$Dir;*" -and $userPath -notlike "*;$Dir;*" -and $userPath -notlike "*;$Dir") {
            $newPath = "$Dir;$userPath"
            [System.Environment]::SetEnvironmentVariable("PATH", $newPath, [System.EnvironmentVariableTarget]::User)
            Ok "Added $Dir to PATH (user environment variable - permanent)"
        } else {
            Ok "Added $Dir to current session PATH"
        }
    }
}

function Confirm-ExakitOnPath {
    param([Parameter(Mandatory)][string]$Dir)
    # Unlike macOS/Linux, %USERPROFILE%\.local\bin is never on the Windows
    # PATH by default, so a hint alone leaves exakit unreachable in every
    # new terminal. Add the directory to the USER PATH (no admin needed,
    # idempotent) the way other user-scope installers (uv, cargo) do.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $userEntries = ($userPath -split ";") | Where-Object { $_ }
    if ($userEntries -notcontains $Dir) {
        try {
            $newUserPath = if ($userPath) { "$userPath;$Dir" } else { $Dir }
            [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
            Ok "Added $Dir to your user PATH (new terminals pick it up automatically)"
        } catch {
            Warn2 "$Dir could not be added to your PATH automatically."
            Write-Host "    Add it in Settings -> System -> About -> Advanced system settings -> Environment Variables,"
            Write-Host "    or run: `$env:Path += `";$Dir`" (current session only)"
        }
    }
    # Make it work in THIS session too (the machine-wide change only
    # affects newly started processes).
    if (($env:Path -split ";") -notcontains $Dir) {
        $env:Path += ";$Dir"
    }
}

# exakit_repo_root equivalent: prefer the copy under EXAKIT_HOME/kit (survives
# the original checkout moving/disappearing), fall back to this script's own
# checkout.
function Get-ExakitRepoRoot {
    $kitCopy = Join-Path $script:ExakitHome "kit"
    if (Test-Path (Join-Path $kitCopy "mcp")) { return $kitCopy }
    $commonDir = Split-Path -Parent $PSCommandPath
    $repoRoot = (Resolve-Path (Join-Path $commonDir "..\..")).Path
    if (Test-Path (Join-Path $repoRoot "mcp")) { return $repoRoot }
    return $null
}

# Install-ExakitSkills - copy the kit's AI skills into the per-user discovery
# folders so CLI agents auto-load them. Idempotent: each run replaces the
# managed copy of every skill, so edits and deletions propagate cleanly.
# Mirrors exakit_install_skills in setup/lib/common.sh.
#   $HOME\.claude\skills\<name>\   - Claude Code
#   $HOME\.agents\skills\<name>\   - Codex, Cursor, other open-standard agents
# Set-ExakitReadonlyAllowlist - make the documented friction-reduction real.
# Merges the read-only allowlist from skills/reducing-agent-prompts.md into
# ~/.claude/settings.json: strictly additive, idempotent, never removes
# anything, and a malformed file is left alone. Twin of
# exakit_apply_readonly_allowlist in common.sh.
function Set-ExakitReadonlyAllowlist {
    # The kit's read-only command surface. Leaving any of these out is what kept
    # the friction real: AGENTS.md tells an agent to discover commands with
    # `exakit catalog` and to check its footing with update-check / mcp-status,
    # and every one of those asked for approval while changing nothing. exapump
    # sql and every mutating command stay absent on purpose - that gate is the
    # trust model.
    $readonly = @(
        "status", "info", "version", "mcp-doctor", "logs", "catalog", "preflight",
        "update-check", "guide", "mcp-status", "mcp-validate", "help"
    )
    # EVERY SPELLING THE AGENT IS TOLD TO USE. A permission rule matches the
    # command text, and AGENTS.md tells agents in as many words that
    # ~/.local/bin is absent from a bare non-interactive PATH and to call the
    # binary by absolute path. So the bare-`exakit` rules covered exactly the
    # invocation the docs steer agents AWAY from, and every "read-only" command
    # kept prompting anyway.
    $prefixes = @("exakit", "~/.local/bin/exakit", "`$HOME/.local/bin/exakit")
    $allow = @()
    foreach ($prefix in $prefixes) {
        foreach ($command in $readonly) { $allow += "Bash($prefix $command`:*)" }
        # Exact forms, NOT "exakit skills:*", because that prefix would also
        # match `exakit skills-install`, which writes this very settings file.
        $allow += "Bash($prefix skills)"
        $allow += "Bash($prefix skills --json)"
    }
    $allow += "mcp__exasol"
    # The deny needs every spelling too, for the opposite reason: a rule that
    # only names the bare form is trivially sidestepped by the absolute path the
    # docs recommend.
    $deny = @($prefixes | ForEach-Object { "Bash($_ uninstall`:*)" })
    $dir = Join-Path $HOME ".claude"
    $path = Join-Path $dir "settings.json"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $doc = $null
    if (Test-Path $path) {
        try { $doc = Get-Content -Raw $path | ConvertFrom-Json } catch { return "SKIP unreadable" }
        if ($null -eq $doc) { return "SKIP unreadable" }
    } else {
        $doc = [pscustomobject]@{}
    }
    if (-not $doc.PSObject.Properties["permissions"]) {
        $doc | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{})
    }
    $permissions = $doc.permissions
    $added = 0
    foreach ($pair in @(@("allow", $allow), @("deny", $deny))) {
        $key = $pair[0]; $wanted = $pair[1]
        if (-not $permissions.PSObject.Properties[$key]) {
            $permissions | Add-Member -NotePropertyName $key -NotePropertyValue @()
        }
        $existing = @($permissions.$key)
        foreach ($entry in $wanted) {
            if ($existing -notcontains $entry) { $existing += $entry; $added++ }
        }
        $permissions.$key = $existing
    }
    if ($added -gt 0) {
        $doc | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
    }
    return "ADDED $added"
}

# ---------------------------------------------------------------------------
# Skills registry
# ---------------------------------------------------------------------------
# Twin of the skills block in common.sh. The registry is the FILESYSTEM, not a
# hardcoded list: every directory under skills\ carrying a SKILL.md is a skill,
# and its identity comes from that file's own frontmatter. Adding a skill stays
# a one-folder change with no code edit on either side.

# Get-ExakitSkillRoots - the per-user discovery folders CLI agents read.
function Get-ExakitSkillRoots {
    return @((Join-Path $HOME ".claude\skills"), (Join-Path $HOME ".agents\skills"))
}

function Get-ExakitSkillsDir {
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { return $null }
    $dir = Join-Path $repoRoot "skills"
    if (-not (Test-Path $dir)) { return $null }
    return $dir
}

# Get-ExakitSkillField - one value out of the YAML frontmatter. Deliberately
# tiny: the frontmatter this reads is the two flat keys the SKILL.md standard
# defines (name, description), so a real YAML parser would be a dependency
# bought for nothing.
function Get-ExakitSkillField {
    param([string]$Path, [string]$Field)
    if (-not (Test-Path $Path)) { return "" }
    # UTF-8 explicitly: 5.1 would otherwise decode these bytes as the system
    # ANSI codepage and corrupt the em dashes every description carries.
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return "" }
    if ($lines[0].Trim() -ne "---") { return "" }
    $key = $Field + ": "
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "---") { break }
        if ($lines[$i].StartsWith($key)) { return $lines[$i].Substring($key.Length) }
    }
    return ""
}

# Get-ExakitSkillSummary - the one-line gist for a list row. The full
# description is written for an AGENT to match on (long, trigger-laden); a
# human scanning a table wants the first sentence, so cut the trigger list and
# then the first sentence, and truncate on a word boundary.
function Get-ExakitSkillSummary {
    param([string]$Description)
    $text = $Description
    if (-not $text) { return "" }
    $idx = $text.IndexOf("Triggers")
    if ($idx -ge 0) { $text = $text.Substring(0, $idx) }
    $idx = $text.IndexOf(". ")
    if ($idx -ge 0) { $text = $text.Substring(0, $idx) }
    # A dangling connector reads as a truncation bug rather than an ellipsis.
    $trailing = '[\s\u2014,:-]+$'
    $text = ($text.Trim() -replace $trailing, '')
    if ($text.Length -le 64) { return $text }
    $out = ""
    foreach ($word in ($text -split ' ')) {
        if (($out.Length + $word.Length + 1) -gt 61) { break }
        if ($out -eq "") { $out = $word } else { $out = $out + " " + $word }
    }
    return (($out -replace $trailing, '') + "...")
}

# Get-ExakitSkillsRegistry - one row per skill. Skills whose frontmatter does
# not parse are skipped here, so they are skipped everywhere (list AND install
# read this one function).
function Get-ExakitSkillsRegistry {
    $dir = Get-ExakitSkillsDir
    if (-not $dir) { return @() }
    $rows = @()
    foreach ($skillDir in (Get-ChildItem -Path $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $md = Join-Path $skillDir.FullName "SKILL.md"
        if (-not (Test-Path $md)) { continue }
        $name = Get-ExakitSkillField -Path $md -Field "name"
        if (-not $name) { continue }
        $desc = Get-ExakitSkillField -Path $md -Field "description"
        $rows += [pscustomobject]@{
            Id      = $skillDir.Name
            Name    = $name
            Summary = (Get-ExakitSkillSummary -Description $desc)
        }
    }
    return $rows
}

# Get-ExakitSkillState - installed (in every discovery root), partial (in
# some), or available (in none). "partial" is worth its own word: it is what a
# half-finished install or a hand-deleted copy looks like, and the remedy
# differs from a clean "never installed".
function Get-ExakitSkillState {
    param([string]$Id)
    $roots = @(Get-ExakitSkillRoots)
    $have = 0
    foreach ($root in $roots) {
        if (Test-Path (Join-Path (Join-Path $root $Id) "SKILL.md")) { $have++ }
    }
    if ($have -eq 0) { return "available" }
    if ($have -eq $roots.Count) { return "installed" }
    return "partial"
}

# Get-ExakitKitSkillNames - which skill directories are OURS to remove. The
# live kit list first; once the kit copy is gone (uninstall order, or a
# hand-deleted checkout), what the install recorded. Enumerating the discovery
# folders is never an option - they also hold skills the user installed
# themselves, and the kit removes only what it placed. A hardcoded name list
# was the old answer here and it aged badly: it named a skill that never
# shipped and knew nothing of the ones added since.
function Get-ExakitKitSkillNames {
    $names = @()
    try {
        $dir = Get-ExakitSkillsDir
        if ($dir) {
            $names = @(Get-ChildItem -Directory $dir -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "SKILL.md") } |
                ForEach-Object { $_.Name })
        }
    } catch { $names = @() }
    if ($names.Count -eq 0) {
        try {
            $recorded = @(Get-ExakitManifestValue "components.skills.installed")
            $names = @($recorded | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        } catch { $names = @() }
    }
    return $names
}

# Show-ExakitSkills - what skills this kit carries and whether each one has
# reached the agents' discovery folders.
function Show-ExakitSkills {
    param([switch]$Json)
    if (-not (Get-ExakitSkillsDir)) {
        Warn2 "No skills\ directory in this kit build - nothing to list."
        return $false
    }
    $rows = @(Get-ExakitSkillsRegistry)
    if ($rows.Count -eq 0) {
        Warn2 "No SKILL.md files found in this kit copy - nothing to list."
        return $false
    }

    $entries = @()
    $pending = 0
    foreach ($row in $rows) {
        $state = Get-ExakitSkillState -Id $row.Id
        if ($state -ne "installed") { $pending++ }
        $entries += [pscustomobject]@{ name = $row.Id; state = $state; summary = $row.Summary }
    }

    if ($Json) {
        Write-Output ([pscustomobject]@{ skills = $entries } | ConvertTo-Json -Depth 4 -Compress)
        return $true
    }

    Write-Host ""
    Start-ExakitPanel "AI skills in this kit"
    foreach ($entry in $entries) {
        Write-ExakitPanelLine ("{0,-26} {1,-10} {2}" -f $entry.name, $entry.state, $entry.summary)
    }
    if ($pending -gt 0) {
        Write-ExakitPanelLine "Install or refresh every skill:  exakit skills-install"
    } else {
        Write-ExakitPanelLine "All installed. Refresh after a kit update:  exakit skills-install"
    }
    Write-ExakitPanelLine "Agents load a skill only when its triggers match your request."
    Complete-ExakitPanel
    Write-Host ""
    return $true
}

function Install-ExakitSkills {
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { Warn2 "Could not locate the kit to find its skills\ directory."; return $false }
    $skillsSrc = Join-Path $repoRoot "skills"
    if (-not (Test-Path $skillsSrc)) { Warn2 "No skills\ directory in this kit build yet - nothing to install."; return $false }

    $installed = 0
    foreach ($skillDir in (Get-ChildItem -Path $skillsSrc -Directory -ErrorAction SilentlyContinue)) {
        if (-not (Test-Path (Join-Path $skillDir.FullName "SKILL.md"))) { continue }
        # Frontmatter that does not parse is skipped HERE as well as in the
        # listing: a skill an agent cannot identify is not one worth copying,
        # and installing what `exakit skills` refuses to show would be a lie.
        if (-not (Get-ExakitSkillField -Path (Join-Path $skillDir.FullName "SKILL.md") -Field "name")) {
            Warn2 "Skipping $($skillDir.Name): its SKILL.md has no readable name in the frontmatter."
            continue
        }
        $name = $skillDir.Name
        foreach ($destRoot in @((Join-Path $HOME ".claude\skills"), (Join-Path $HOME ".agents\skills"))) {
            $dest = Join-Path $destRoot $name
            if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item -Recurse -Force -Path (Join-Path $skillDir.FullName "*") -Destination $dest
        }
        Ok "Installed skill: $name"
        $installed++
    }
    if ($installed -eq 0) { Warn2 "No SKILL.md files found under $skillsSrc - nothing to install."; return $false }
    Info "Skills installed for Claude Code (~\.claude\skills) and open-standard agents (~\.agents\skills)."
    # The read-only allowlist the skill documents, applied for real.
    $applied = Set-ExakitReadonlyAllowlist
    if ($applied -eq "ADDED 0") {
        Info "Read-only command allowlist already present in ~\.claude\settings.json."
    } elseif ($applied -like "ADDED *") {
        Ok "Read-only exakit commands allowlisted in ~\.claude\settings.json (status, info, version, mcp-doctor, logs; uninstall stays gated)."
    } else {
        Warn2 "~\.claude\settings.json could not be merged safely ($applied) - the allowlist in skills/reducing-agent-prompts.md shows what to add by hand."
    }
    Info "Restart or reload your AI client to pick them up."
    return $true
}

# Request-ExakitSkillsInstallOffer - after setup, place the skills where CLI
# agents can find them. Mirrors exakit_maybe_offer_skills_install. Always
# installs - no prompt - so the skills are present without requiring
# interactive confirmation, on both interactive and non-interactive runs.
# Confirm-ExakitRuntimeRunning [-Deploy] - the kit's self-heal for "the
# database is not answering", shared by every command about to speak SQL. A
# container that is merely stopped is started (Install-Nano self-heals both
# halves: it starts an existing container, creates a missing one, and waits
# for ready); a missing one is created only when the caller allows it, and
# otherwise refused with the exact command that fixes it.
# Twin of exakit_ensure_runtime_running in common.sh (the personal runtime is
# macOS-only, so this side only knows Nano).
function Confirm-ExakitRuntimeRunning {
    param([switch]$Deploy)
    if ((Get-ExakitManifestValue "runtime.type") -ne "nano") { return }
    if (-not (Get-Command Get-NanoStatus -ErrorAction SilentlyContinue)) { return }
    if ((Get-NanoStatus) -eq "running") { return }
    $exists = $false
    if (Get-Command Test-NanoContainerExists -ErrorAction SilentlyContinue) {
        $exists = Test-NanoContainerExists
    }
    if ($exists) {
        Info "Self-heal: the database container exists but is not running - starting it"
        Install-Nano
        return
    }
    if ($Deploy) {
        Info "Self-heal: no database container found - creating one"
        Install-Nano
        return
    }
    Fail "No database container found. Create one with: exakit start (or re-run the installer)"
}

# ---------------------------------------------------------------------------
# Marketplace add-ons (twin of the exakit_marketplace_* block in common.sh)
# ---------------------------------------------------------------------------
# Optional tools the kit can install but the setup scripts never do: the user
# picks them from `exakit marketplace` (Space toggles, Enter installs), or
# says yes to the closing offer after an install. Only kit-managed installs
# join the routine update flow, and an add-on that is already on the machine
# (kit-managed or a system install) is never advertised.
#
# Adding a new add-on is three additive changes - NO switch-statement surgery.
# Every registry function (version block, env override, fallback, upstream
# lookup, installed probe, update targets/dispatch) handles registered add-ons
# through a generic default arm driven by this registry:
#   1. Ship its module as setup/lib/<id>.ps1 (+ the .sh twin), defining the
#      functions named below plus its own $script:<X>VersionFallback constant.
#   2. Add a components.<id> block to versions.json: version, severity, and
#      repo (GitHub-release-installed) or package (PyPI-installed).
#   3. Add one entry here.
# The add-on's one-line description is NOT one of those changes: it is the About
# field of its own repository, read through Get-ExakitMarketplaceAddonDescription.
# (CI guards move with it: the expected-components set in versions.yml and the
# COUPLED fallback-constant table in versions-bump.yml.)
function Get-ExakitMarketplaceAddons {
    return @(
        [pscustomobject]@{
            Id          = "dash-server"
            Label       = "dash-server (AI dashboard host)"
            InstallFn   = "Install-DashServer"
            ValidateFn  = "Test-DashServer"
            UpdateFn    = "Update-DashServer"
            VersionFn   = "Get-DashServerInstalledVersion"
            UninstallFn = "Uninstall-DashServer"
            StatusFn    = "Get-DashServerStatus"
            StartFn     = "Start-DashServer"
            StopFn      = "Stop-DashServer"
            AutostartFn = "Get-DashServerAutostartCommand"
            LogFn       = "Get-DashServerLogPath"
            EnvVar      = "EXAKIT_DASH_SERVER_VERSION"
            FallbackVar = "DashServerVersionFallback"
        },
        [pscustomobject]@{
            Id          = "exasol-vscode"
            Label       = "Exasol for VS Code (editor extension)"
            InstallFn   = "Install-ExasolVscode"
            ValidateFn  = "Test-ExasolVscode"
            UpdateFn    = "Update-ExasolVscode"
            VersionFn   = "Get-ExasolVscodeInstalledVersion"
            UninstallFn = "Uninstall-ExasolVscode"
            ApplicableFn = "Test-ExasolVscodeApplicable"
            ReasonFn     = "Get-ExasolVscodeApplicableReason"
            EnvVar      = "EXAKIT_EXASOL_VSCODE_VERSION"
            FallbackVar = "ExasolVscodeVersionFallback"
        },
        [pscustomobject]@{
            Id          = "json-tables"
            Label       = "JSON Tables (JSON into Exasol)"
            InstallFn   = "Install-JsonTables"
            ValidateFn  = "Test-JsonTables"
            UpdateFn    = "Update-JsonTables"
            VersionFn   = "Get-JsonTablesInstalledVersion"
            UninstallFn = "Uninstall-JsonTables"
            ApplicableFn = "Test-JsonTablesApplicable"
            ReasonFn     = "Get-JsonTablesApplicableReason"
            LogFn        = "Get-JsonTablesLogPath"
            EnvVar      = "EXAKIT_JSON_TABLES_VERSION"
            FallbackVar = "JsonTablesVersionFallback"
        }
    )
}

# ---------------------------------------------------------------------------
# Add-on "About" text - fetched from the add-on's own repository, cached here
# ---------------------------------------------------------------------------
# The description the marketplace shows is the About field of the add-on's
# repository. Nothing about the wording is stored in this repository, so the team
# that owns a tool owns its one-liner, in one place, and it cannot drift out of
# sync with what we print.
#
# The cache is what makes a network-backed string safe in front of an
# interactive menu, and it is the same mechanism help.ps1 already uses for the
# help documents: a TTL'd file per id, an .attempt- marker so a failure is not
# retried on every run, an atomic write, and a refusal to fetch over anything
# but HTTPS. Only the rows that actually SHOW a description are fetched.
# Twin of the same block in common.sh.

$script:ExakitAboutUrl = if ($env:EXAKIT_ABOUT_URL) { $env:EXAKIT_ABOUT_URL } else { "https://api.github.com/repos" }
$script:ExakitAboutTtl = if ($env:EXAKIT_ABOUT_TTL) { [int]$env:EXAKIT_ABOUT_TTL } else { 86400 }
$script:ExakitAboutOffline = ($env:EXAKIT_ABOUT_OFFLINE -eq "1")
# Hard ceiling on a cached About line. A repository we do not control decides
# this string's length; nothing downstream should have to cope with an
# unbounded one.
$script:ExakitAboutMaxLen = if ($env:EXAKIT_ABOUT_MAX_LEN) { [int]$env:EXAKIT_ABOUT_MAX_LEN } else { 200 }
# Width of the Description cell, in the table and the checkbox label alike. The
# table's rule is 74 columns and the two leading cells spend 30 of them.
$script:ExakitAboutWidth = if ($env:EXAKIT_ABOUT_WIDTH) { [int]$env:EXAKIT_ABOUT_WIDTH } else { 44 }

function Get-ExakitAboutCacheDir {
    if ($env:EXAKIT_ABOUT_CACHE_DIR) { return $env:EXAKIT_ABOUT_CACHE_DIR }
    return (Join-Path $script:ExakitHome "cache\about")
}

# Get-ExakitAddonDocument <id> - the add-on's help document, read from disk.
#
# help.ps1, when loaded, knows the fetched cache copy and validates it, so
# prefer it (-NoFetch keeps it off the network). But setup-windows-docker.ps1
# does not source help.ps1 - and the closing offer runs from there - so the
# shipped locations are resolved here as well.
function Get-ExakitAddonDocument {
    param([string]$Id)
    if (Get-Command Get-ExakitHelpDocument -ErrorAction SilentlyContinue) {
        $doc = Get-ExakitHelpDocument -Id $Id -NoFetch
        if ($doc) { return $doc }
    }
    $candidates = @()
    $candidates += (Join-Path (Join-Path $script:ExakitHome "cache\help") "$Id.json")
    if ($script:LibDir) {
        $candidates += (Join-Path (Join-Path (Split-Path $script:LibDir -Parent) "help") "$Id.json")
    }
    $candidates += (Join-Path (Join-Path $script:ExakitHome "kit") "setup\help\$Id.json")
    foreach ($path in $candidates) {
        if (Test-Path $path) {
            try { return (Get-Content -Raw -Path $path -Encoding UTF8 | ConvertFrom-Json) } catch { }
        }
    }
    return $null
}

# Get-ExakitAddonRepo <id> - the add-on's repository, as owner/name.
#
# This value is interpolated into a URL, so it is validated as two plain path
# segments and nothing else.
function Get-ExakitAddonRepo {
    param([string]$Id)
    $doc = Get-ExakitAddonDocument $Id
    if (-not $doc) { return "" }
    $repo = [string]$doc.repo
    if ($repo -match '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$') { return $repo }
    return ""
}

function Test-ExakitAboutCacheFresh {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    if ($script:ExakitAboutTtl -le 0) { return $false }
    $age = ((Get-Date) - (Get-Item $Path).LastWriteTime).TotalSeconds
    return ($age -lt $script:ExakitAboutTtl)
}

# Convert-ExakitAboutText <text> - one printable line, filtered ON THE WAY IN.
#
# This is free-form prose from a repository we do not control, printed straight
# into the user's terminal. The help documents get their guarantees from a
# schema; a bare string has none, so the filtering is explicit and happens once,
# before anything reaches the cache: escape sequences removed whole, every
# remaining control character turned into a space (the bare ESC of a
# half-sequence included), whitespace collapsed to one line, length capped on a
# word boundary. Twin of _exakit_about_sanitise / _exakit_about_cap.
function Convert-ExakitAboutText {
    param([string]$Text)
    if (-not $Text) { return "" }
    $esc = [string][char]27
    $bel = [string][char]7
    $clean = $Text
    $clean = [regex]::Replace($clean, "$esc\[[0-9;?]*[A-Za-z]", "")
    $clean = [regex]::Replace($clean, "$esc\]8;;[^$bel$esc]*($bel|$esc\\)", "")
    $clean = [regex]::Replace($clean, "\p{Cc}", " ")
    $clean = [regex]::Replace($clean, "\s+", " ").Trim()
    if ($clean.Length -gt $script:ExakitAboutMaxLen) {
        $clean = $clean.Substring(0, $script:ExakitAboutMaxLen)
        $cut = $clean.LastIndexOf(" ")
        if ($cut -gt 0) { $clean = $clean.Substring(0, $cut) }
    }
    return $clean
}

# Update-ExakitAboutCache <id> - refresh one add-on's cached About line.
# $true when a line was cached; $false for every other outcome (the caller falls
# back, it never fails a screen).
function Update-ExakitAboutCache {
    param([string]$Id)
    if ($script:ExakitAboutOffline) { return $false }
    if ($script:ExakitAboutUrl -notmatch '^https://') { return $false }
    $repo = Get-ExakitAddonRepo $Id
    if (-not $repo) { return $false }
    $cacheDir = Get-ExakitAboutCacheDir
    $cache = Join-Path $cacheDir "$Id.txt"
    if (Test-ExakitAboutCacheFresh $cache) { return $false }
    # The marker is what keeps a rate-limited or offline machine from asking
    # again on every run: it is written BEFORE the request, so the question
    # counts as asked whatever the answer turns out to be.
    $attempt = Join-Path $cacheDir ".attempt-$Id"
    if (Test-ExakitAboutCacheFresh $attempt) { return $false }
    New-Item -ItemType Directory -Force -Path $cacheDir -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType File -Force -Path $attempt -ErrorAction SilentlyContinue | Out-Null
    try {
        $doc = Invoke-RestMethod -Uri "$($script:ExakitAboutUrl)/$repo" -UseBasicParsing -TimeoutSec 5
    } catch { return $false }
    if (-not $doc) { return $false }
    $text = Convert-ExakitAboutText ([string]$doc.description)
    if (-not $text) { return $false }
    $tmp = "$cache.tmp"
    try {
        Set-Content -Path $tmp -Value $text -Encoding UTF8 -ErrorAction Stop
        Move-Item -Force -Path $tmp -Destination $cache -ErrorAction Stop
    } catch {
        Remove-Item -Force $tmp -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

# Get-ExakitMarketplaceAddonDescription <id> - the one-liner a screen shows.
# Always answers something; the chain degrades instead of blanking a column:
#   1. a cached About younger than the TTL     - the common case, no network
#   2. a fresh fetch                           - one request, timeout bounded
#   3. a STALE cached About, any age           - old wording beats no wording
#   4. the help document's own tagline         - on disk, so this is the answer
#                                                offline and when rate-limited
#   5. a pointer at the help screen            - only if even that is missing
function Get-ExakitMarketplaceAddonDescription {
    param([string]$Id)
    $cache = Join-Path (Get-ExakitAboutCacheDir) "$Id.txt"
    if (-not (Test-ExakitAboutCacheFresh $cache)) { Update-ExakitAboutCache $Id | Out-Null }
    if (Test-Path $cache) {
        $text = ""
        try { $text = ((Get-Content -Path $cache -Encoding UTF8 -TotalCount 1) | Out-String).Trim() } catch { }
        if ($text) { return $text }
    }
    $doc = Get-ExakitAddonDocument $Id
    if ($doc -and $doc.tagline) {
        # A tagline is written as a help-screen header and ends in a period; a
        # table cell does not.
        return ([string]$doc.tagline).TrimEnd(".")
    }
    return "Details: exakit help $Id"
}

# Format-ExakitAboutWrap <text> [width] [pad] - the text in full, folded onto as
# many lines as it needs. Continuation lines carry their own indent, because the
# whole cell is printed through one Write-Host with the table's own prefix.
#
# This is the table's renderer: an About is written for a repository page, not
# for a 44-column cell, and truncating it threw away the half that explained
# what the tool was for. Word-wrapped, never mid-word: a word longer than the
# width gets a line of its own and is allowed to overhang.
# Twin of exakit_about_wrap in common.sh.
function Format-ExakitAboutWrap {
    param([string]$Text, [int]$Width = 0, [string]$Pad = "")
    if ($Width -le 0) { $Width = $script:ExakitAboutWidth }
    if ($Width -lt 8) { return $Text }
    if (-not $Text) { return "" }
    $lines = New-Object System.Collections.Generic.List[string]
    $line = ""
    foreach ($word in ($Text -split '\s+')) {
        if (-not $word) { continue }
        if (-not $line) { $line = $word }
        elseif (($line.Length + 1 + $word.Length) -le $Width) { $line = "$line $word" }
        else { [void]$lines.Add($line); $line = $word }
    }
    if ($line) { [void]$lines.Add($line) }
    if ($lines.Count -eq 0) { return "" }
    $out = $lines[0]
    for ($i = 1; $i -lt $lines.Count; $i++) { $out = "$out`n$Pad$($lines[$i])" }
    return $out
}

# Update-ExakitMarketplaceAboutCache - fill the cache for the rows that will
# show a description, before a screen is drawn. Twin of
# _exakit_marketplace_warm_about.
function Update-ExakitMarketplaceAboutCache {
    foreach ($addon in (Get-ExakitMarketplaceAddons)) {
        if (-not (Test-ExakitAddonOfferable $addon.Id)) { continue }
        if (Test-ExakitMarketplaceAddonPresent $addon.Id) { continue }
        if (-not (Get-Command $addon.InstallFn -ErrorAction SilentlyContinue)) { continue }
        Update-ExakitAboutCache $addon.Id | Out-Null
    }
}

# The registry row for one id, or $null - the gate every generic registry arm
# runs first, so an unknown name still reads as "unknown component" everywhere.
function Get-ExakitMarketplaceAddon {
    param([string]$Id)
    if (-not $Id) { return $null }
    return (Get-ExakitMarketplaceAddons | Where-Object { $_.Id -eq $Id } | Select-Object -First 1)
}

# KIT-MANAGED install only: the component answers for itself
# (Get-ExakitComponentCurrent probes the actual install and returns nothing
# for a provably absent one). This is what gates the update flow - the kit
# only ever updates what it manages. Get-ExakitComponentCurrent lives in
# exakit.ps1; the setup script reaches the module probe directly instead.
function Test-ExakitMarketplaceAddonInstalled {
    param([Parameter(Mandatory)][string]$Id)
    if (Get-Command Get-ExakitComponentCurrent -ErrorAction SilentlyContinue) {
        return [bool](Get-ExakitComponentCurrent $Id)
    }
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and (Get-Command $addon.VersionFn -ErrorAction SilentlyContinue)) {
        return [bool](& $addon.VersionFn)
    }
    return $false
}

# Is the tool already on this machine OUTSIDE the kit? A same-named command on
# PATH that is not the kit's own launcher counts. The kit never offers,
# updates or uninstalls such an install - it only stops advertising a tool
# the user already has.
function Test-ExakitAddonSystemPresent {
    param([Parameter(Mandatory)][string]$Id)
    $found = Get-Command $Id -ErrorAction SilentlyContinue
    if (-not $found -or -not $found.Source) { return $false }
    # The kit's own launcher on PATH is a kit install, not a system one.
    $dir = Split-Path -Parent $found.Source
    try {
        if ((Resolve-Path $dir -ErrorAction Stop).Path -eq (Resolve-Path $script:BinDir -ErrorAction Stop).Path) { return $false }
    } catch { }
    return $true
}

# Installed by the kit OR already on the system. "Present" is what the offer,
# the menu and the discovery lines key on: a tool the user has, from anywhere,
# is never advertised.
function Test-ExakitMarketplaceAddonPresent {
    param([Parameter(Mandatory)][string]$Id)
    if (Test-ExakitMarketplaceAddonInstalled $Id) { return $true }
    return (Test-ExakitAddonSystemPresent $Id)
}

# Does this add-on make sense on THIS machine at all? An add-on that extends
# something the user does not have (the VS Code extension without VS Code) is
# not "available then failing" - it is simply not on offer. A registry entry
# with no ApplicableFn is applicable. Twin of _exakit_addon_applicable.
function Test-ExakitAddonApplicable {
    param([Parameter(Mandatory)][string]$Id)
    $addon = Get-ExakitMarketplaceAddon $Id
    if (-not $addon) { return $true }
    if (-not $addon.PSObject.Properties["ApplicableFn"]) { return $true }
    if (-not (Get-Command $addon.ApplicableFn -ErrorAction SilentlyContinue)) { return $true }
    # The probe belongs to the add-on module and can throw: it shells out to a
    # code CLI, inspects a platform, reads a path. A read-only screen asking
    # "could this be installed here?" must not die because one module's probe
    # blew up - `exakit version` listed only installed add-ons before, so no
    # caller ever exercised this path for an add-on that was absent. Treat an
    # exploding probe as "cannot tell, so do not offer it".
    try { return [bool](& $addon.ApplicableFn) } catch { return $false }
}

function Get-ExakitAddonApplicableReason {
    param([Parameter(Mandatory)][string]$Id)
    $addon = Get-ExakitMarketplaceAddon $Id
    if ($addon -and $addon.PSObject.Properties["ReasonFn"] -and
        (Get-Command $addon.ReasonFn -ErrorAction SilentlyContinue)) { return (& $addon.ReasonFn) }
    return ""
}

# Should this add-on appear at all? Only an add-on that is BOTH absent and
# inapplicable is hidden. Anything actually on the machine stays visible: a kit
# install so it can still be updated or removed (even if the host app
# disappeared afterwards), and a system install so the screen can say it is
# already covered. Twin of _exakit_addon_offerable.
function Test-ExakitAddonOfferable {
    param([Parameter(Mandatory)][string]$Id)
    if (Test-ExakitMarketplaceAddonPresent $Id) { return $true }
    return (Test-ExakitAddonApplicable $Id)
}

function Get-ExakitMarketplaceInstalledAddons {
    $installed = @()
    foreach ($addon in Get-ExakitMarketplaceAddons) {
        if (Test-ExakitMarketplaceAddonInstalled $addon.Id) { $installed += $addon.Id }
    }
    return $installed
}

# True while at least one add-on is not on this machine yet (neither
# kit-managed nor a system install). Drives the discovery one-liners and the
# closing offer.
function Test-ExakitMarketplaceHasPending {
    foreach ($addon in Get-ExakitMarketplaceAddons) {
        if (-not (Test-ExakitAddonOfferable $addon.Id)) { continue }
        if (-not (Test-ExakitMarketplaceAddonPresent $addon.Id)) { return $true }
    }
    return $false
}

# One dim line under the update-check table while something in the marketplace
# is still on offer. It advertises, it never acts.
function Write-ExakitMarketplaceDiscoveryLine {
    $pending = @()
    foreach ($addon in Get-ExakitMarketplaceAddons) {
        if (-not (Test-ExakitAddonOfferable $addon.Id)) { continue }
        if (-not (Test-ExakitMarketplaceAddonPresent $addon.Id)) { $pending += $addon.Id }
    }
    if ($pending.Count -eq 0) { return }
    Write-Host "    Optional add-ons are available ($($pending -join ', ')) - browse them with: exakit marketplace" -ForegroundColor DarkGray
}

# The marketplace menu body, wearing the kit's two established looks:
#   1. the STATE, as the same aligned table Invoke-CmdUpdateCheck prints
#      (Add-on / Status / Version / Action, one row per add-on);
#   2. the SELECTION, as the same tree-checkbox the data-load menu uses: a
#      group row with the add-ons hanging off UiTee/UiCorner connectors,
#      Space toggles, Enter installs, Cancel as the exclusive default.
# Only installable add-ons become menu rows - everything else is answered by
# the table. Non-interactive runs answer with EXAKIT_MARKETPLACE_ADDONS: a csv
# of ids, "all", or "none". Twin of exakit_marketplace_menu in common.sh.
function Show-ExakitMarketplaceMenu {
    $rows = @()      # each: @{ Id = <id or $null when not selectable>; Label = <menu child>; Table = <state row> }
    foreach ($addon in Get-ExakitMarketplaceAddons) {
        # Not applicable here and not installed: not an option on this machine,
        # so it is not shown at all - no row, no table line.
        if (-not (Test-ExakitAddonOfferable $addon.Id)) { continue }
        # Every add-on gets BOTH a table row and a menu row. The menu row for a
        # state that cannot be installed is a disabled row ("!" prefix): shown,
        # dimmed, unselectable, saying why. That is what lets the table drop its
        # Status and Action columns without hiding anything - a first-time user
        # reads three columns of catalogue, and anyone re-running the command
        # still sees why a row is not on offer, in the menu where they are
        # looking. The Description column carries the state for a row that is
        # not simply available, because the all-covered path returns before the
        # menu is ever drawn and the table is then the only output.
        if (Test-ExakitMarketplaceAddonInstalled $addon.Id) {
            $ver = ""
            if (Get-Command Get-ExakitComponentCurrent -ErrorAction SilentlyContinue) { $ver = Get-ExakitComponentCurrent $addon.Id }
            elseif (Get-Command $addon.VersionFn -ErrorAction SilentlyContinue) { $ver = & $addon.VersionFn }
            if (-not $ver) { $ver = "?" }
            $rows += @{ Id = $null; Label = "$($addon.Id) - already installed"
                Table = ("{0,-14} {1,-14} {2}" -f $addon.Id, $ver, "Installed. Update: exakit update $($addon.Id)") }
        } elseif (Test-ExakitAddonSystemPresent $addon.Id) {
            # The user already has the tool from somewhere else - covered, and
            # the kit does not manage it.
            $rows += @{ Id = $null; Label = "$($addon.Id) - already on this system"
                Table = ("{0,-14} {1,-14} {2}" -f $addon.Id, "-", "Already on this system, managed outside the kit") }
        } elseif (-not (Get-Command $addon.InstallFn -ErrorAction SilentlyContinue)) {
            $rows += @{ Id = $null; Label = "$($addon.Id) - not in this kit copy"
                Table = ("{0,-14} {1,-14} {2}" -f $addon.Id, "-", "Not in this kit copy. Run: exakit update exakit") }
        } else {
            $advertised = ""
            if (Get-Command Get-ExakitComponentAvailable -ErrorAction SilentlyContinue) { $advertised = Get-ExakitComponentAvailable $addon.Id }
            if (-not $advertised) { $advertised = "unknown" }
            # Only an installable row shows a description, and only a run that
            # will actually DRAW one resolves it: a scripted answer
            # (EXAKIT_MARKETPLACE_ADDONS) installs without a table, so an agent
            # or a CI job never pays for the lookup.
            $cell = ""
            if (-not $env:EXAKIT_MARKETPLACE_ADDONS) {
                # The table carries the About IN FULL, folded onto as many lines
                # as it needs. Nothing truncates it.
                $cell = Format-ExakitAboutWrap (Get-ExakitMarketplaceAddonDescription $addon.Id) $script:ExakitAboutWidth (" " * 32)
            }
            # The label NAMES the row, it does not re-explain it: the full text is
            # in the table directly above, and the checkbox layer truncates every
            # menu row to exactly one terminal line (its redraw depends on that).
            $rows += @{ Id = $addon.Id; Label = $addon.Id
                Table = ("{0,-14} {1,-14} {2}" -f $addon.Id, $advertised, $cell) }
        }
    }

    # The env answer wins over any menu, so agents and CI never need a TTY.
    if ($env:EXAKIT_MARKETPLACE_ADDONS) {
        $answer = ("" + $env:EXAKIT_MARKETPLACE_ADDONS).ToLower().Replace(" ", "")
        if ($answer -eq "none") { Info "EXAKIT_MARKETPLACE_ADDONS=none - installing nothing."; return }
        $picked = @()
        if ($answer -eq "all") {
            foreach ($row in $rows) { if ($row.Id) { $picked += $row.Id } }
        } else {
            $known = @(Get-ExakitMarketplaceAddons | ForEach-Object { $_.Id })
            foreach ($token in ($answer -split ",")) {
                if (-not $token) { continue }
                if ($rows | Where-Object { $_.Id -eq $token }) { $picked += $token }
                elseif ($known -contains $token -and -not (Test-ExakitAddonApplicable $token)) {
                    $why = Get-ExakitAddonApplicableReason $token
                    Fail ("$token is not available on this machine" + $(if ($why) { ": $why" } else { "" }))
                }
                elseif ($known -contains $token) { Info "$token is already present - a kit-managed one updates with: exakit update $token" }
                else { Fail "Unknown marketplace add-on in EXAKIT_MARKETPLACE_ADDONS: '$token' (known: $($known -join ' '))" }
            }
        }
        if ($picked.Count -eq 0) { Info "Nothing to install - every requested add-on is already present."; return }
        Invoke-ExakitMarketplaceApply -Ids $picked
        return
    }

    # The state table - same shape as the update-check table, so the two
    # screens read as one family.
    Write-Host ""
    Write-Host "  Marketplace add-ons"
    Write-Host ("  " + ("-" * 74))
    Write-Host ("  {0,-14} {1,-14} {2}" -f "Add-on", "Version", "Description")
    foreach ($row in $rows) { Write-Host ("  " + $row.Table) }
    Write-Host ""

    $selectable = @($rows | Where-Object { $_.Id })
    if ($selectable.Count -eq 0) {
        Info "Everything available is already covered. Updates: exakit update-check"
        return
    }

    # The selection - same tree the data-load menu draws: a group row with the
    # add-ons hanging off connectors (UiTee/UiCorner from the ui palette;
    # ASCII in plain mode), the available add-ons pre-selected so Enter alone
    # installs what is on offer, and Cancel as the exclusive opt-out. A
    # non-interactive run keeps the pre-selected defaults, exactly like the
    # data-load menu (EXAKIT_MARKETPLACE_ADDONS=none is the scripted opt-out).
    # Mirrors exakit_marketplace_menu in common.sh.
    $tee = $script:UiTee; $corner = $script:UiCorner
    $menuLabels = New-Object System.Collections.Generic.List[string]
    $menuIds = New-Object System.Collections.Generic.List[string]
    [void]$menuLabels.Add("Available add-ons")
    [void]$menuIds.Add("__group__")
    # Children in two passes: installable rows first, so the group's child range
    # (2 .. selectable+1) stays contiguous, then the disabled rows. The corner
    # connector belongs to the last child overall, whichever pass produced it.
    $disabled = @($rows | Where-Object { -not $_.Id -and $_.Label })
    $children = $selectable.Count + $disabled.Count
    $child = 0
    foreach ($row in $selectable) {
        $child += 1
        $conn = if ($child -eq $children) { $corner } else { $tee }
        [void]$menuLabels.Add("$conn $($row.Label)")
        [void]$menuIds.Add($row.Id)
    }
    foreach ($row in $disabled) {
        $child += 1
        $conn = if ($child -eq $children) { $corner } else { $tee }
        # "!" first: the checkbox menu tests the label's first character.
        [void]$menuLabels.Add("!$conn $($row.Label)")
        [void]$menuIds.Add("__disabled__")
    }
    [void]$menuLabels.Add("Cancel (install nothing)")
    [void]$menuIds.Add("__cancel__")
    $cancelIdx = $menuLabels.Count
    # Default: the group AND every available add-on pre-selected - the same
    # posture as the data-load menu, where Enter alone acts on what is on
    # offer and Cancel is the explicit opt-out.
    $defaults = @(1..($selectable.Count + 1))
    $selection = Read-ExakitCheckboxMenu -Title "Select add-ons to install" `
        -Options $menuLabels.ToArray() -Defaults $defaults -ExclusiveIndex $cancelIdx `
        -GroupParent 1 -GroupFirst 2 -GroupLast ($selectable.Count + 1) -GroupMode "all"
    if ($selection -contains $cancelIdx) {
        Info "Marketplace closed - nothing was installed."
        return
    }
    $picked = @()
    foreach ($idx in $selection) {
        if ($idx -ge 1 -and $idx -lt $cancelIdx -and -not $menuIds[$idx - 1].StartsWith("__")) { $picked += $menuIds[$idx - 1] }
    }
    if ($picked.Count -eq 0) { Info "Nothing selected - nothing was installed."; return }
    Invoke-ExakitMarketplaceApply -Ids $picked
}

# Install each picked add-on in turn. One failure does not strand the rest.
function Invoke-ExakitMarketplaceApply {
    param([Parameter(Mandatory)][string[]]$Ids)
    $failed = 0
    foreach ($id in $Ids) {
        $addon = Get-ExakitMarketplaceAddon $id
        if (-not $addon) { continue }
        Info "Installing add-on: $id"
        $installed = $false
        try {
            $installed = & $addon.InstallFn
        } catch {
            Warn2 "$id installer reported: $_"
            $installed = $false
        }
        if ($installed) {
            if ($addon.ValidateFn -and (Get-Command $addon.ValidateFn -ErrorAction SilentlyContinue)) {
                try { & $addon.ValidateFn } catch { Warn2 "$id validation reported: $_" }
            }
            Ok "$id installed - it now updates with: exakit update (or exakit update $id)"
        } else {
            Warn2 "$id did not finish installing - retry with: exakit marketplace (or exakit update $id)"
            $failed += 1
        }
    }
    if ($failed -gt 0) { Fail "$failed add-on(s) did not finish installing." }
}

# Request-ExakitMarketplaceOffer - the closing moment of an install:
# everything ran, the panel is on screen, and this asks ONE question - add
# optional tools now, or maybe later? Dynamic by design: an add-on already on
# the machine is not on offer, when nothing is left the question disappears,
# a run with soft failures gets the one-line hint instead of a victory lap,
# and a non-interactive run also gets the hint - unless
# EXAKIT_MARKETPLACE_ADDONS pre-answers, which installs without asking.
# Twin of exakit_marketplace_offer in common.sh.
function Request-ExakitMarketplaceOffer {
    if (-not (Test-ExakitMarketplaceHasPending)) { return }
    # Fill the About cache now, while the gate question below is still being
    # read: this is the one screen where the cache is reliably cold (a machine
    # minutes old), and the table it feeds does not exist yet.
    Update-ExakitMarketplaceAboutCache

    # A scripted answer wins over any prompt (same contract as the menu).
    if ($env:EXAKIT_MARKETPLACE_ADDONS) {
        Show-ExakitMarketplaceMenu
        return
    }

    # "Done and working" must be true before it is said: a run that recorded
    # soft failures points at the marketplace without the celebration.
    $softFailed = $false
    $softState = Get-Variable -Scope Script -Name ExakitSoftFailed -ErrorAction SilentlyContinue
    if ($softState -and $softState.Value -and $softState.Value.Count -gt 0) { $softFailed = $true }
    $interactive = ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
    if ($softFailed -or -not $interactive) {
        Info "Optional add-ons (dashboards & more): exakit marketplace"
        return
    }

    # One gate question first - the same cursor menu every other kit choice
    # uses, no typing: Yes is pre-ticked, No is the exclusive opt-out. Only a
    # Yes opens the marketplace selection itself (where the available add-ons
    # come pre-selected, so Enter installs them and Cancel still backs out).
    Write-Host ""
    Ok "Your starter kit is ready to use."
    Info ("The marketplace has add-ons that extend what you can do with Exasol:`n" +
          "      dashboards, editor integration, extra data formats, with more added`n" +
          "      over time.")
    $gate = Read-ExakitCheckboxMenu -Title "Browse it now?" `
        -Options @("Yes, open the marketplace", "No, maybe later") `
        -Defaults @(1) -ExclusiveIndex 2
    if ($gate -contains 1) {
        try { Show-ExakitMarketplaceMenu } catch { Warn2 "The marketplace did not finish cleanly: $_" }
        Info "Browse again any time with: exakit marketplace"
    } else {
        Info "Maybe later - browse any time with: exakit marketplace"
    }
}

function Request-ExakitSkillsInstallOffer {
    $repoRoot = Get-ExakitRepoRoot
    if (-not $repoRoot) { return }
    $skillsSrc = Join-Path $repoRoot "skills"
    if (-not (Test-Path $skillsSrc)) { return }
    $hasSkill = Get-ChildItem -Path $skillsSrc -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName "SKILL.md") }
    if (-not $hasSkill) { return }
    if (-not (Install-ExakitSkills)) {
        Warn2 "Skills install did not finish cleanly. Retry any time with: exakit skills-install"
    }
}

# connection_panel equivalent - printed at the end of setup and via `exakit info`.
function Show-ExakitConnectionPanel {
    if (-not (Test-Path $script:ManifestPath)) { Warn2 "No installation found ($script:ManifestPath missing)"; return }
    $type    = Get-ExakitManifestValue "runtime.type"
    $dsn     = Get-ExakitManifestValue "runtime.dsn"
    $user    = Get-ExakitManifestValue "runtime.user"
    $pwFile  = Get-ExakitManifestValue "runtime.password_file"
    $mcpUser = Get-ExakitManifestValue "components.mcp_server.connection.user"
    $mcpPwf  = Get-ExakitManifestValue "components.mcp_server.connection.password_file"
    $exapumpPath    = Get-ExakitManifestValue "components.exapump.path"
    $exapumpProfile = Get-ExakitManifestValue "components.exapump.profile"
    $mcpConfigs     = Get-ExakitManifestValue "components.mcp_server.configs"

    Write-Host ""
    Start-ExakitPanel "Connection details"
    Write-ExakitPanelLine ("Runtime:      {0}" -f $(if ($type) { $type } else { 'unknown' }))
    Write-ExakitPanelLine ("DSN:          {0}" -f $(if ($dsn) { $dsn } else { 'unknown' }))
    Write-ExakitPanelLine ("Admin user:   {0}" -f $(if ($user) { $user } else { 'sys' }))
    if ($pwFile) { Write-ExakitPanelLine "Admin pass:   stored in $(Get-ExakitTilde $pwFile)" }
    if ($mcpUser) { Write-ExakitPanelLine "MCP user:     $mcpUser" }
    if ($mcpPwf)  { Write-ExakitPanelLine "MCP pass:     stored in $(Get-ExakitTilde $mcpPwf)" }
    Write-ExakitPanelLine "TLS:          enabled (self-signed certificate)"
    if ($exapumpPath) { Write-ExakitPanelLine "exapump:      $(Get-ExakitTilde $exapumpPath) (profile: $exapumpProfile)" }
    # Stdio MCP configs live inside each AI client's own config file, not in
    # the kit's mcp/ dir (that holds only pre-edit backups) - mirrors common.sh.
    if ($mcpConfigs) {
        Write-ExakitPanelLine "MCP configs:  in each AI client's config (list: exakit mcp-status)"
        Write-ExakitPanelLine "MCP backups:  $(Get-ExakitTilde $script:McpDir)"
    }
    Write-ExakitPanelLine "Manifest:     $(Get-ExakitTilde $script:ManifestPath)"
    Write-ExakitPanelLine "Logs:         $(Get-ExakitTilde $script:LogDir)"
    # The two downloads are always true: anyone can fetch them. The VS Code
    # extension is a marketplace add-on, so it is named only when it is actually
    # on this machine - otherwise the row would advertise a SQL client the reader
    # may not have, and on a machine without VS Code cannot get. It has to be
    # named somewhere, though: the "Add-ons:" row prints only while something is
    # still pending. Mirrors connection_panel in common.sh.
    if (Test-ExakitMarketplaceAddonInstalled "exasol-vscode") {
        Write-ExakitPanelLine "SQL client:   VS Code (Exasol extension), DBeaver or DbVisualizer"
    } else {
        Write-ExakitPanelLine "SQL client:   DBeaver or DbVisualizer"
    }
    # One line, only while something is still on offer: the marketplace is the
    # optional layer on top of a finished install, so this is where it is
    # discovered - never during the install itself. Mirrors connection_panel.
    if (Test-ExakitMarketplaceHasPending) {
        Write-ExakitPanelLine "Add-ons:      optional tools (dashboards & more): exakit marketplace"
    }
    Complete-ExakitPanel
    Write-Host ""
}
