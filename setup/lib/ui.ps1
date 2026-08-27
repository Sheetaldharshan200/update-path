# ui.ps1 - shared visual layer for the installer (Windows / PowerShell path).
#
# Function-for-function twin of setup/lib/ui.sh: the EXASOL wordmark banner,
# colour palette, status glyphs, an animated braille spinner with elapsed
# timing, a progress bar, and auto-width panels. The wordmark lines and glyphs
# are byte-identical to ui.sh so the banner is the same on macOS, Linux/WSL,
# and Windows.
#
# Targets Windows PowerShell 5.1 and PowerShell 7+ (no ternary, no ??). Dot-
# sourced by exakit-common.ps1 and by install.ps1.
#
# Design rules mirror ui.sh:
#   * Fancy output (colour + Unicode + animation) is used ONLY on an
#     interactive terminal with VT/ANSI enabled; redirected / non-interactive
#     output falls back to plain ASCII with no escapes.
#   * The command execution in Invoke-ExakitLogged is NOT restructured to add
#     the spinner - the spinner animates in a background runspace, so a broken
#     spinner can never break an install.

$script:UiEsc = [char]27

# --- console + capability detection -----------------------------------------
# Force UTF-8 output so the wordmark/box glyphs render, and try to turn on
# ANSI/VT processing (needed for colour on Windows PowerShell 5.1 conhost).
# Sets $script:UiFancy. Safe to call more than once.
function Initialize-ExakitConsole {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    # $OutputEncoding encodes what PowerShell pipes INTO native commands'
    # stdin, so it must be a BOM-LESS UTF-8: the static [Text.Encoding]::UTF8
    # instance emits a U+FEFF preamble, which Windows PowerShell 5.1's pipe
    # writer prepends to the piped stream. Exasol rejects U+FEFF in SQL text
    # ("character is not allowed within unquoted identifier"). Note this alone
    # does NOT make stdin-piping SQL safe on 5.1 - its pipe writer adds a
    # second BOM of its own regardless of $OutputEncoding (observed under the
    # system-wide UTF-8 codepage 65001) - which is why SQL files are fed to
    # exapump as raw bytes instead (see Invoke-ExapumpSqlFileCapture).
    try { $global:OutputEncoding    = New-Object System.Text.UTF8Encoding $false } catch { }

    $vt = $false
    try {
        if (-not ("Exakit.Vt" -as [type])) {
            Add-Type -Namespace Exakit -Name Vt -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool GetConsoleMode(System.IntPtr h, out uint mode);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool SetConsoleMode(System.IntPtr h, uint mode);
'@ | Out-Null
        }
        $h = [Exakit.Vt]::GetStdHandle(-11)   # STD_OUTPUT_HANDLE
        $mode = [uint32]0
        if ([Exakit.Vt]::GetConsoleMode($h, [ref]$mode)) {
            $mode = $mode -bor 0x0004          # ENABLE_VIRTUAL_TERMINAL_PROCESSING
            $vt = [Exakit.Vt]::SetConsoleMode($h, $mode)
        }
    } catch { $vt = $false }

    $script:UiVt = $vt
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { $redirected = $false }
    $script:UiFancy = ($vt -and -not $redirected -and -not $env:NO_COLOR -and $env:EXAKIT_NO_FANCY -ne "1")
    Set-ExakitPalette
}

# --- palette & glyphs -------------------------------------------------------
function Set-ExakitPalette {
    $e = $script:UiEsc
    if ($script:UiFancy) {
        $script:UiReset="${e}[0m"; $script:UiBold="${e}[1m"; $script:UiDim="${e}[2m"
        $script:UiAccent="${e}[38;5;35m"
        $script:UiGreen="${e}[38;5;77m"; $script:UiFg="${e}[39m"
        $script:UiOk="${e}[1;32m"; $script:UiWarn="${e}[1;33m"; $script:UiErr="${e}[1;31m"
        $script:UiInfo="${e}[1;34m"; $script:UiAsk="${e}[1;36m"
    } else {
        $script:UiReset=""; $script:UiBold=""; $script:UiDim=""; $script:UiAccent=""
        $script:UiGreen=""; $script:UiFg=""
        $script:UiOk=""; $script:UiWarn=""; $script:UiErr=""; $script:UiInfo=""; $script:UiAsk=""
    }
    # Glyphs rely on the UTF-8 console set above; fall back to ASCII when we
    # could not establish a fancy terminal at all.
    if ($script:UiFancy) {
        $script:UiTick="✓"; $script:UiCross="✗"; $script:UiBullet="•"; $script:UiArrow="▸"
        $script:UiHr="─"; $script:UiTL="╭"; $script:UiTR="╮"; $script:UiBL="╰"; $script:UiBR="╯"; $script:UiVB="│"
        $script:UiTee="├─"; $script:UiCorner="└─"
        $script:UiBarFull="█"; $script:UiBarEmpty="░"
        # Eighths of a block: the frontier cell of a progress bar, so a forty-cell
        # bar has 320 positions instead of 40 and every percent shows on screen.
        # Index 0 is a space - an empty frontier when there is no fraction to
        # draw, which keeps the dim remainder unbroken. Twin of
        # UI_PROGRESS_EIGHTHS in ui.sh; the glyphs live HERE because this is the
        # one .ps1 with a BOM (see ps-encoding-guard).
        $script:UiProgressEighths = @(' ','▏','▎','▍','▌','▋','▊','▉')
    } else {
        $script:UiTick="+"; $script:UiCross="x"; $script:UiBullet="-"; $script:UiArrow=">"
        $script:UiHr="-"; $script:UiTL="+"; $script:UiTR="+"; $script:UiBL="+"; $script:UiBR="+"; $script:UiVB="|"
        $script:UiTee="|-"; $script:UiCorner='`-'
        $script:UiBarFull="#"; $script:UiBarEmpty="."
        $script:UiProgressEighths = @(' ',' ',' ',' ',' ',' ',' ',' ')
    }
}

# EXASOL wordmark (ANSI Shadow) - segments mirror ui.sh's UI_WM_* so the "X"
# gets the logo's two-tone look (green left strokes + crossing peak; the rest
# in the terminal's default colour).
$script:UiWmE  = @('███████╗','██╔════╝','█████╗  ','██╔══╝  ','███████╗','╚══════╝')
$script:UiWmXL = @('██╗ ','╚██╗',' ╚███',' ██╔','██╔╝','╚═╝ ')
$script:UiWmXR = @(' ██╗','██╔╝','╔╝ ','██╗ ',' ██╗',' ╚═╝')
$script:UiWmR  = @(
' █████╗ ███████╗ ██████╗ ██╗',
'██╔══██╗██╔════╝██╔═══██╗██║',
'███████║███████╗██║   ██║██║',
'██╔══██║╚════██║██║   ██║██║',
'██║  ██║███████║╚██████╔╝███████╗',
'╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝'
)

$script:UiBoxW = 58

# Initialise on load so callers can use the palette immediately.
Initialize-ExakitConsole

# --- primitive helpers ------------------------------------------------------
function Get-ExakitTilde([string]$Path) {
    if (-not $Path) { return $Path }
    $h = $HOME
    if ($h -and $Path.StartsWith($h)) { return "~" + $Path.Substring($h.Length) }
    return $Path
}

# Write-ExakitBanner <title> <subtitle>
function Write-ExakitBanner {
    param([string]$Title = "Exasol Personal Local Starter Kit", [string]$Subtitle = "")
    Write-Host ""
    if ($script:UiFancy) {
        for ($i = 0; $i -lt 6; $i++) {
            Write-Host ("  {0}{1}{2}{3}{4}{5}{6}" -f `
                ($script:UiBold + $script:UiFg), $script:UiWmE[$i], `
                $script:UiGreen, $script:UiWmXL[$i], `
                $script:UiFg, ($script:UiWmXR[$i] + $script:UiWmR[$i]), `
                $script:UiReset)
        }
        Write-Host ""
    }
    Write-Host ("  {0}{1}{2}" -f $script:UiBold, $Title, $script:UiReset)
    if ($Subtitle) { Write-Host ("  {0}{1}{2}" -f $script:UiDim, $Subtitle, $script:UiReset) }
    Write-Host ""
}

# --- fixed-width box --------------------------------------------------------
function Write-ExakitBoxTop([string]$Title) {
    $t = " $Title "
    $fill = $script:UiBoxW - $t.Length - 1
    if ($fill -lt 0) { $fill = 0 }
    Write-Host ("  {0}{1}{2}{3}{4}{5}{6}" -f `
        $script:UiAccent, ($script:UiTL + $script:UiHr), ($script:UiReset + $script:UiBold + $t + $script:UiReset), `
        $script:UiAccent, ($script:UiHr * $fill), $script:UiTR, $script:UiReset)
}
function Write-ExakitBoxLine([string]$Text) {
    $pad = $script:UiBoxW - $Text.Length - 2
    if ($pad -lt 0) { $pad = 0 }
    Write-Host ("  {0} {1}{2} {3}" -f `
        ($script:UiAccent + $script:UiVB + $script:UiReset), $Text, (" " * $pad), `
        ($script:UiAccent + $script:UiVB + $script:UiReset))
}
function Write-ExakitBoxBottom {
    Write-Host ("  {0}{1}{2}{3}" -f $script:UiAccent, $script:UiBL, ($script:UiHr * $script:UiBoxW), ($script:UiBR + $script:UiReset))
}

# --- auto-width panel (sizes to the longest line) ---------------------------
$script:UiPanelTitle = ""
# Write-ExakitLink <url> [text] - a terminal hyperlink (OSC 8): clickable text
# that opens <url>. Falls back to plain text when the session is not rendering
# rich output. Windows Terminal, VS Code's terminal, and modern PowerShell
# hosts render it; older consoles show the visible text.
function Write-ExakitLink {
    param([Parameter(Mandatory)][string]$Url, [string]$Text = "")
    if (-not $Text) { $Text = $Url }
    if ($script:UiFancy) {
        return ([char]27 + "]8;;" + $Url + [char]27 + "\" + $Text + [char]27 + "]8;;" + [char]27 + "\")
    }
    return $Text
}

# Get-ExakitVisibleLength <string> - character length ignoring escape sequences
# (CSI colour + OSC 8 hyperlink), so a panel line carrying either still lines up.
function Get-ExakitVisibleLength {
    param([AllowEmptyString()][string]$Text)
    $esc = [char]27
    $clean = [regex]::Replace($Text, [regex]::Escape($esc) + "\[[0-9;]*m", "")
    $clean = [regex]::Replace($clean, [regex]::Escape($esc) + "\]8;;[^" + [regex]::Escape($esc) + [char]7 + "]*(" + [char]7 + "|" + [regex]::Escape($esc) + "\\)", "")
    return $clean.Length
}

$script:UiPanelLines = @()
function Start-ExakitPanel([string]$Title) { $script:UiPanelTitle = $Title; $script:UiPanelLines = @() }
function Write-ExakitPanelLine([string]$Text) { $script:UiPanelLines += $Text }
function Complete-ExakitPanel {
    $w = $script:UiPanelTitle.Length + 1
    foreach ($l in $script:UiPanelLines) { $ll = Get-ExakitVisibleLength $l; if ($ll -gt $w) { $w = $ll } }
    $w = $w + 2
    $t = " $($script:UiPanelTitle) "
    $fill = $w - $t.Length - 1
    if ($fill -lt 0) { $fill = 0 }
    Write-Host ("  {0}{1}{2}{3}{4}{5}{6}" -f `
        $script:UiAccent, ($script:UiTL + $script:UiHr), ($script:UiReset + $script:UiBold + $t + $script:UiReset), `
        $script:UiAccent, ($script:UiHr * $fill), $script:UiTR, $script:UiReset)
    foreach ($l in $script:UiPanelLines) {
        $pad = $w - (Get-ExakitVisibleLength $l) - 2
        if ($pad -lt 0) { $pad = 0 }
        Write-Host ("  {0} {1}{2} {3}" -f `
            ($script:UiAccent + $script:UiVB + $script:UiReset), $l, (" " * $pad), `
            ($script:UiAccent + $script:UiVB + $script:UiReset))
    }
    Write-Host ("  {0}{1}{2}{3}" -f $script:UiAccent, $script:UiBL, ($script:UiHr * $w), ($script:UiBR + $script:UiReset))
}

# --- spinner (background runspace) ------------------------------------------
# The spinner animates in a separate runspace writing directly to the console.
# The foreground keeps running the real command (its output goes to the log,
# not the console), so there is a single console writer during the spin. If
# anything about the runspace misbehaves it is swallowed - never fatal.
$script:UiSpinPs = $null
$script:UiSpinRs = $null
$script:UiSpinFlag = $null

# Write-ExakitRule - a dim full-width divider, with a blank line either side.
#
# For the seam between two parts of a run: the install is finished and something
# else is being asked. Sized to the console so it reads as a break rather than as
# content. Twin of ui_rule in ui.sh.
function Write-ExakitRule {
    $width = 76
    try { $width = [Console]::WindowWidth - 4 } catch { $width = 76 }
    if ($width -gt 76) { $width = 76 }
    if ($width -lt 8) { $width = 8 }
    Write-Host ""
    Write-Host ("  {0}{1}{2}" -f $script:UiDim, ($script:UiHr * $width), $script:UiReset)
    Write-Host ""
}

# ONE animation at a time. There is a single line being redrawn, so a second
# request to animate is a no-op rather than a second painter. This is what lets a
# progress line survive the work underneath it: a dataset load paints its own bar
# and then calls exapump through Invoke-ExakitLogged, which asks for a spinner of
# its own; without the counter that call's Stop would kill the bar after the
# first file. Twin of _UI_SPIN_NESTED in ui.sh.
$script:UiSpinNested = 0

function Start-ExakitSpinner([string]$Label) {
    if ($null -ne $script:UiSpinFlag) { $script:UiSpinNested++; return }
    if (-not $script:UiFancy) { return }
    try {
        $script:UiSpinFlag = [hashtable]::Synchronized(@{ Run = $true; Label = $Label; T0 = (Get-Date) })
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('flag', $script:UiSpinFlag)
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
            $e = [char]27
            $i = 0
            while ($flag.Run) {
                $el = [int]((Get-Date) - $flag.T0).TotalSeconds
                [Console]::Write("`r  ${e}[38;5;35m$($frames[$i])${e}[0m $($flag.Label) ${e}[2m(${el}s)${e}[0m${e}[K")
                $i = ($i + 1) % 10
                Start-Sleep -Milliseconds 90
            }
        })
        [Console]::Write("$($script:UiEsc)[?25l")   # hide cursor
        $script:UiSpinPs = $ps
        $script:UiSpinRs = $rs
        [void]$ps.BeginInvoke()
    } catch {
        $script:UiSpinFlag = $null; $script:UiSpinPs = $null; $script:UiSpinRs = $null
    }
}

function Stop-ExakitSpinner {
    # Give back a reference taken while something else owned the line; only the
    # call that actually started the animation stops it.
    if ($script:UiSpinNested -gt 0) { $script:UiSpinNested--; return }
    if ($null -eq $script:UiSpinFlag) { return }
    try { $script:UiSpinFlag.Run = $false; Start-Sleep -Milliseconds 110 } catch { }
    try { if ($script:UiSpinPs) { $script:UiSpinPs.Stop(); $script:UiSpinPs.Dispose() } } catch { }
    try { if ($script:UiSpinRs) { $script:UiSpinRs.Close(); $script:UiSpinRs.Dispose() } } catch { }
    $script:UiSpinPs = $null; $script:UiSpinRs = $null; $script:UiSpinFlag = $null
    try { [Console]::Write("`r$($script:UiEsc)[K$($script:UiEsc)[?25h") } catch { }  # clear line, restore cursor
}

function Restore-ExakitCursor { if ($script:UiFancy) { try { [Console]::Write("$($script:UiEsc)[?25h") } catch { } } }

# --- progress bar (determinate) ---------------------------------------------
function Write-ExakitProgress([int]$Current, [int]$Total, [string]$Label = "") {
    if ($Total -le 0) { $Total = 1 }
    $wide = 20
    $filled = [int]($Current * $wide / $Total)
    if ($filled -gt $wide) { $filled = $wide }
    $pct = [int]($Current * 100 / $Total)
    if ($script:UiFancy) {
        [Console]::Write(("`r  {0}{1}{2}{3} {4}{5,3}%{6} {7}{8}" -f `
            $script:UiAccent, ($script:UiBarFull * $filled), $script:UiDim, `
            (($script:UiBarEmpty * ($wide - $filled)) + $script:UiReset), `
            $script:UiBold, $pct, $script:UiReset, $Label, "$($script:UiEsc)[K"))
    } else {
        Write-Host ("  [{0}{1}] {2}%  {3}" -f ($script:UiBarFull * $filled), ($script:UiBarEmpty * ($wide - $filled)), $pct, $Label)
    }
}

# Start-ExakitProgress / Set-ExakitProgress / Stop-ExakitProgress - the bar that
# every long job the kit runs drives.
#
# The spinner's runspace already reads its state live out of a synchronized
# hashtable, so the state goes in there rather than into a file the way the bash
# twin needs. Milestones are the truth - Pct is where the job actually is - and
# the runspace fills the gap to Ceiling at the pace Secs says the stage takes,
# capped one point below it. A stage that overruns waits rather than walking into
# the next one's territory. Twin of ui_progress_begin / ui_progress_state /
# ui_progress_end in ui.sh.
function Start-ExakitProgress {
    param([int]$Pct = 0, [int]$Ceiling = 1, [int]$Secs = 2, [string]$Phase = "")
    if ($null -ne $script:UiSpinFlag) { $script:UiSpinNested++; return $false }
    if (-not $script:UiFancy) { return $false }
    try {
        $now = Get-Date
        $script:UiSpinFlag = [hashtable]::Synchronized(@{
            Run = $true; Label = $Phase; T0 = $now
            Pct = $Pct; Ceiling = $Ceiling; Secs = $Secs; SegT0 = $now; Shown = 0
            Cols = 80
        })
        try { $script:UiSpinFlag.Cols = [Console]::WindowWidth } catch { }
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $rs.SessionStateProxy.SetVariable('flag', $script:UiSpinFlag)
        $rs.SessionStateProxy.SetVariable('pal', @{
            Accent = $script:UiAccent; Dim = $script:UiDim; Reset = $script:UiReset
            Bold = $script:UiBold; Full = $script:UiBarFull; Empty = $script:UiBarEmpty
            Eighths = $script:UiProgressEighths; Esc = $script:UiEsc
        })
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
            $i = 0
            while ($flag.Run) {
                $avail = $flag.Cols - 9
                if ($avail -gt 112) { $avail = 112 }
                if ($avail -lt 24) { $avail = 24 }
                $tw = [int]($avail * 30 / 100); $bw = [int]($avail * 40 / 100)
                $nw = [int]($avail * 10 / 100); $ew = [int]($avail * 10 / 100)
                $gap = $avail - $tw - $bw - $nw - $ew
                if ($gap -lt 1) { $gap = 1 }
                if ($nw -lt 5) { $tw -= (5 - $nw); $nw = 5 }
                if ($ew -lt 7) { $tw -= (7 - $ew); $ew = 7 }
                if ($bw -lt 8) { $bw = 8 }
                if ($tw -lt 8) { $tw = 8 }

                # Where the bar sits right now: the milestone, plus as much of
                # the way to the next one as the clock has earned.
                $pct = $flag.Pct
                $span = $flag.Ceiling - $pct
                if ($span -gt 0 -and $flag.Secs -gt 0) {
                    $inSeg = [int]((Get-Date) - $flag.SegT0).TotalSeconds
                    $step = [int]($span * $inSeg / $flag.Secs)
                    if ($step -gt ($span - 1)) { $step = $span - 1 }
                    if ($step -lt 0) { $step = 0 }
                    $pct = $pct + $step
                }
                if ($pct -lt $flag.Shown) { $pct = $flag.Shown }
                $flag.Shown = $pct

                $text = "$($flag.Label)"
                if ($text.Length -gt ($tw - 1)) { $text = $text.Substring(0, $tw - 2) + "…" }
                $text = $text.PadRight($tw + $gap)
                $units = [int]($pct * $bw * 8 / 100)
                $full = [int]($units / 8); $rem = $units % 8
                if ($full -gt $bw) { $full = $bw; $rem = 0 }
                $head = ""
                if ($full -lt $bw -and $rem -gt 0) { $head = $pal.Eighths[$rem] }
                $empty = $bw - $full - $head.Length
                if ($empty -lt 0) { $empty = 0 }
                $bar = $pal.Accent + ($pal.Full * $full) + $pal.Dim + $head + ($pal.Empty * $empty) + $pal.Reset
                $el = [int]((Get-Date) - $flag.T0).TotalSeconds
                [Console]::Write("`r      $($pal.Accent)$($frames[$i])$($pal.Reset) $text$bar$($pal.Bold)$(("$pct%").PadLeft($nw))$($pal.Reset)$($pal.Dim)$(("($el" + "s)").PadLeft($ew))$($pal.Reset)$($pal.Esc)[K")
                $i = ($i + 1) % 10
                Start-Sleep -Milliseconds 200
            }
        })
        [Console]::Write("$($script:UiEsc)[?25l")
        $script:UiSpinPs = $ps
        $script:UiSpinRs = $rs
        [void]$ps.BeginInvoke()
        return $true
    } catch {
        $script:UiSpinFlag = $null; $script:UiSpinPs = $null; $script:UiSpinRs = $null
        return $false
    }
}

# Set-ExakitProgress - the job has reached a new stage. The segment's clock
# starts now, which is what the creep measures against.
function Set-ExakitProgress {
    param([int]$Pct, [int]$Ceiling, [int]$Secs, [string]$Phase)
    if ($null -eq $script:UiSpinFlag) { return }
    try {
        $script:UiSpinFlag.Pct = $Pct
        $script:UiSpinFlag.Ceiling = $Ceiling
        $script:UiSpinFlag.Secs = $Secs
        $script:UiSpinFlag.SegT0 = Get-Date
        $script:UiSpinFlag.Label = $Phase
    } catch { }
}

function Stop-ExakitProgress { Stop-ExakitSpinner }

# Write-ExakitProgressLine <pct> <phase> <elapsed> <frame> <cols> - the progress
# line every long job the kit runs shares.
#
# Four cells across the console's own width:
#
#   30% phase - 40% bar - 10% percentage - 10% elapsed, and a tenth as the gap
#
# The phase leads because it is what a reader is actually reading; the numbers
# trail because they are what they glance at. The bar starts at the same column
# whatever the phase is called. One column is left unwritten: a line that fills
# the last cell sets the terminal's pending-wrap flag and the next carriage
# return lands a row lower. Capped, because the cells are proportions and a very
# wide console turns the phase cell into dead air.
# Twin of ui_progress_line in ui.sh.
function Write-ExakitProgressLine {
    param(
        [int]$Pct, [string]$Phase, [int]$Elapsed, [int]$Frame = 0, [int]$Cols = 80
    )
    $avail = $Cols - 6 - 2 - 1
    if ($avail -gt 112) { $avail = 112 }
    if ($avail -lt 24) { $avail = 24 }
    $tw = [int]($avail * 30 / 100)
    $bw = [int]($avail * 40 / 100)
    $nw = [int]($avail * 10 / 100)
    $ew = [int]($avail * 10 / 100)
    $gap = $avail - $tw - $bw - $nw - $ew
    if ($gap -lt 1) { $gap = 1 }
    # Floors: a cell that cannot hold "100%" or "(120s)" is worse than a
    # narrower neighbour, and the phase is the only cell that can be shortened
    # without losing something the others carry exactly.
    if ($nw -lt 5) { $tw -= (5 - $nw); $nw = 5 }
    if ($ew -lt 7) { $tw -= (7 - $ew); $ew = 7 }
    if ($bw -lt 8) { $bw = 8 }
    if ($tw -lt 8) { $tw = 8 }

    # Truncated to its cell MINUS ONE, so a long phase keeps a gap before the bar.
    $text = $Phase
    if ($text.Length -gt ($tw - 1)) { $text = $text.Substring(0, $tw - 2) + "…" }
    $text = $text.PadRight($tw + $gap)

    if ($script:UiFancy) {
        $units = [int]($Pct * $bw * 8 / 100)
        $full = [int]($units / 8)
        $rem = $units % 8
        if ($full -gt $bw) { $full = $bw; $rem = 0 }
        $head = ""
        if ($full -lt $bw -and $rem -gt 0) { $head = $script:UiProgressEighths[$rem] }
        $empty = $bw - $full - $head.Length
        if ($empty -lt 0) { $empty = 0 }
        $bar = $script:UiAccent + ($script:UiBarFull * $full) + $script:UiDim + $head +
               ($script:UiBarEmpty * $empty) + $script:UiReset
        $frames = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
        $spin = $frames[$Frame % 10]
    } else {
        $full = [int]($Pct * $bw / 100)
        if ($full -gt $bw) { $full = $bw }
        $bar = ($script:UiBarFull * $full) + ($script:UiBarEmpty * ($bw - $full))
        $spin = ">"
    }
    $num = ("{0}%" -f $Pct).PadLeft($nw)
    $el = ("({0}s)" -f $Elapsed).PadLeft($ew)
    [Console]::Write("`r      {0}{1}{2} {3}{4}{5}{6}{7}{8}{9}{10}{11}[K" -f
        $script:UiAccent, $spin, $script:UiReset, $text, $bar,
        $script:UiBold, $num, $script:UiReset, $script:UiDim, $el, $script:UiReset,
        $script:UiEsc)
}

# Get-ExakitBar <pct> [width] - the bar on its own, as a STRING.
#
# Write-ExakitProgress above owns a whole line and redraws it. This one owns
# nothing: it is for embedding a bar inside a label somebody else paints - the
# dataset load hands it to the spinner, so the animation, the bar, the
# percentage and the current file are one line instead of four competing for it.
# Twin of ui_bar in ui.sh.
function Get-ExakitBar {
    param([int]$Pct, [int]$Width = 20)
    $filled = [int]($Pct * $Width / 100)
    if ($filled -gt $Width) { $filled = $Width }
    if ($filled -lt 0) { $filled = 0 }
    return ("{0}{1}{2}{3}{4}" -f $script:UiAccent, ($script:UiBarFull * $filled),
        $script:UiDim, ($script:UiBarEmpty * ($Width - $filled)), $script:UiReset)
}

# Render the install banner + plan (used by install.ps1 after download).
function Write-ExakitInstallPlan {
    param([string]$Platform, [string]$Database, [string]$KitDir, [string]$StateDir)
    # Banner only: the old "Installation plan" panel repeated internals users
    # don't act on. Whether this machine can run the kit is answered by the
    # compatibility checks that follow, which fail or warn explicitly.
    Write-ExakitBanner "Personal Local Starter Kit"
    Write-Host ""
}
