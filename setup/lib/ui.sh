# ui.sh — shared visual layer for the installer (bash side).
#
# This is the single source of truth for how the installer LOOKS: colors,
# glyphs, the spinner, the progress bar, the boxed plan, and the boxed
# success panel. setup/lib/ui.ps1 is its function-for-function PowerShell
# twin — every glyph, colour, and animation here has a documented mirror
# there so the install flow looks identical on macOS, Linux/WSL, and Windows.
#
# Design rules:
#   * Fancy output (colour + Unicode + animation) is used ONLY on an
#     interactive UTF-8 terminal. Piped / redirected / CI / non-UTF-8
#     output falls back to plain ASCII, one line per event — safe for logs.
#   * No sub-second timers, no bash-4-only features: this must run on the
#     stock macOS bash 3.2.
#
# Nothing here writes to the log file; callers still use info/ok/warn for
# that. This layer is purely presentation.

# --- capability detection ---------------------------------------------------
# UI_FANCY=1 only when stdout is an interactive UTF-8 terminal that wants
# colour. Everything downstream keys off this one flag.
UI_FANCY=0
ui_detect() {
    UI_FANCY=0
    [ -t 1 ] || return 0                      # not a terminal (piped/CI/log)
    [ -z "${NO_COLOR:-}" ] || return 0        # user opted out of colour
    [ "${TERM:-}" != "dumb" ] || return 0     # dumb terminal
    [ "${EXAKIT_NO_FANCY:-0}" != "1" ] || return 0   # explicit override
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]*) UI_FANCY=1 ;;         # UTF-8 locale → glyphs render
    esac
    return 0
}
ui_detect

# --- palette & glyphs -------------------------------------------------------
if [ "$UI_FANCY" = 1 ]; then
    UI_RESET=$'\033[0m';  UI_BOLD=$'\033[1m';  UI_DIM=$'\033[2m'
    UI_ACCENT=$'\033[38;5;35m'                 # Exasol green accent
    UI_GREEN=$'\033[38;5;77m'                  # brand green for the wordmark X
    UI_FG=$'\033[39m'                          # default fg (adapts to light/dark)
    UI_OK=$'\033[1;32m';  UI_WARN=$'\033[1;33m';  UI_ERR=$'\033[1;31m'
    UI_INFO=$'\033[1;34m';  UI_ASK=$'\033[1;36m'
    UI_TICK='✓';  UI_CROSS='✗';  UI_BULLET='•';  UI_ARROW='▸'
    UI_HR='─';  UI_TL='╭';  UI_TR='╮';  UI_BL='╰';  UI_BR='╯';  UI_VB='│'
    UI_TEE='├─';  UI_CORNER='└─'
    UI_BAR_FULL='█';  UI_BAR_EMPTY='░'
else
    UI_RESET='';  UI_BOLD='';  UI_DIM='';  UI_ACCENT=''
    UI_GREEN='';  UI_FG=''
    UI_OK='';  UI_WARN='';  UI_ERR='';  UI_INFO='';  UI_ASK=''
    UI_TICK='[ok]';  UI_CROSS='[x]';  UI_BULLET='-';  UI_ARROW='>'
    UI_HR='-';  UI_TL='+';  UI_TR='+';  UI_BL='+';  UI_BR='+';  UI_VB='|'
    UI_TEE='|-';  UI_CORNER='`-'
    UI_BAR_FULL='#';  UI_BAR_EMPTY='.'
fi

# Spinner frames (braille). Indexed array works on bash 3.2.
UI_SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# EXASOL wordmark (ANSI Shadow style). Shown only in fancy mode; the plain
# fallback prints a plain-text title instead. Split into segments so the "X"
# carries the logo's two-tone look: the left strokes and the crossing peak are
# Exasol green (UI_GREEN); the rest of the wordmark and the X's right strokes
# stay the terminal's default colour (UI_FG) so it reads on light or dark.
# The segments are mirrored byte-for-byte in setup/lib/ui.ps1.
UI_WM_E=('███████╗' '██╔════╝' '█████╗  ' '██╔══╝  ' '███████╗' '╚══════╝')
UI_WM_XL=('██╗ ' '╚██╗' ' ╚███' ' ██╔' '██╔╝' '╚═╝ ')
UI_WM_XR=(' ██╗' '██╔╝' '╔╝ ' '██╗ ' ' ██╗' ' ╚═╝')
UI_WM_R=(
' █████╗ ███████╗ ██████╗ ██╗'
'██╔══██╗██╔════╝██╔═══██╗██║'
'███████║███████╗██║   ██║██║'
'██╔══██║╚════██║██║   ██║██║'
'██║  ██║███████║╚██████╔╝███████╗'
'╚═╝  ╚═╝╚══════╝ ╚═════╝ ╚══════╝'
)

# Inner width of boxes (plan / panel), in visible columns.
UI_BOX_W="${UI_BOX_W:-58}"

# --- primitive helpers ------------------------------------------------------

# ui_tilde <path> — shorten $HOME to ~ so panels don't balloon to the full
# home path width. Leaves non-home paths untouched.
ui_tilde() {
    case "$1" in
        "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
        "$HOME")   printf '~' ;;
        *)         printf '%s' "$1" ;;
    esac
}

# ui_repeat <char> <count> — echo <char> <count> times (no trailing newline).
ui_repeat() {
    _uir_out=''
    _uir_i=0
    while [ "$_uir_i" -lt "$2" ]; do _uir_out="$_uir_out$1"; _uir_i=$((_uir_i + 1)); done
    printf '%s' "$_uir_out"
}

# ui_link <url> [text] — a terminal hyperlink (OSC 8): clickable text that
# opens <url>. Falls back to plain text (or the URL) when stdout is not an
# interactive terminal (piped, CI, logs), so nothing leaks escape codes into
# a captured value. Most modern terminals (iTerm2, the macOS Terminal on
# recent macOS, GNOME Terminal, Windows Terminal, VS Code) render it; older
# ones that don't simply show the visible text.
ui_link() {
    _ul_url="$1"
    _ul_text="${2:-$1}"
    # Gate on UI_FANCY only, not a fresh `-t 1`: ui_link is meant to be called
    # inside $(...) when building panel lines, where its own stdout is a pipe.
    # UI_FANCY was set at load time from the real terminal, so it is the right
    # signal for "this session renders rich output".
    if [ "${UI_FANCY:-0}" = 1 ]; then
        printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$_ul_url" "$_ul_text"
    else
        printf '%s' "$_ul_text"
    fi
}

# _ui_visible_len <string> — character length ignoring escape sequences, so a
# line carrying colour (CSI) or hyperlink (OSC 8) codes still lines up inside a
# panel box. Strips CSI `ESC [ … m` and OSC 8 `ESC ] 8 ; ; … (BEL|ESC\)`.
_ui_visible_len() {
    # One -e per terminator, never a BRE alternation. `\|` is a GNU sed
    # extension: BSD sed (macOS, the platform this kit targets first) does not
    # support it, so the OSC 8 branch silently matched nothing there and this
    # returned the RAW byte length. A two-link line measured 124 instead of 37,
    # which made it the widest line in ui_panel_end's first pass -- drawing the
    # box to 124 columns -- and left its own padding at ~0 in the second, so its
    # right border closed early. Every hyperlinked panel line was affected.
    _uvl_clean="$(printf '%s' "$1" | LC_ALL=C sed \
        -e 's/'"$(printf '\033')"'\[[0-9;]*m//g' \
        -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*'"$(printf '\007')"'//g' \
        -e 's/'"$(printf '\033')"']8;;[^'"$(printf '\007\033')"']*'"$(printf '\033')"'\\//g')"
    printf '%s' "${#_uvl_clean}"
}

# ui_banner <title> <subtitle> — the top-of-install wordmark block.
# Fancy mode draws the EXASOL block-letter wordmark above the title; the
# plain fallback prints the title as text (block glyphs can't render there).
ui_banner() {
    printf '\n'
    if [ "$UI_FANCY" = 1 ]; then
        _uib_i=0
        while [ "$_uib_i" -lt 6 ]; do
            printf '  %s%s%s%s%s%s%s\n' \
                "$UI_BOLD$UI_FG" "${UI_WM_E[$_uib_i]}" \
                "$UI_GREEN" "${UI_WM_XL[$_uib_i]}" \
                "$UI_FG" "${UI_WM_XR[$_uib_i]}${UI_WM_R[$_uib_i]}" \
                "$UI_RESET"
            _uib_i=$((_uib_i + 1))
        done
        printf '\n'
    fi
    printf '  %s%s%s\n' "$UI_BOLD" "${1:-Exasol Personal Local Starter Kit}" "$UI_RESET"
    [ -n "${2:-}" ] && printf '  %s%s%s\n' "$UI_DIM" "$2" "$UI_RESET"
    printf '\n'
}

# ui_rule — a full-width accent divider (box inner width).
ui_rule() {
    printf '  %s%s%s\n' "$UI_DIM" "$(ui_repeat "$UI_HR" "$UI_BOX_W")" "$UI_RESET"
}

# ui_box_top <title> / ui_box_line <text> / ui_box_bottom — a titled frame.
ui_box_top() {
    _uibt_title=" $1 "
    _uibt_fill=$((UI_BOX_W - ${#_uibt_title} - 1))
    [ "$_uibt_fill" -lt 0 ] && _uibt_fill=0
    printf '  %s%s%s%s%s%s%s\n' \
        "$UI_ACCENT" "$UI_TL$UI_HR" "$UI_RESET$UI_BOLD$_uibt_title$UI_RESET" \
        "$UI_ACCENT" "$(ui_repeat "$UI_HR" "$_uibt_fill")" "$UI_TR" "$UI_RESET"
}
ui_box_line() {
    # Inner width (between the verticals) is exactly UI_BOX_W: one leading
    # space, the text, right-padding, one trailing space. Note ${#text}
    # counts bytes, so keep box content ASCII (labels/paths) to stay aligned.
    _uibl_text="$1"
    _uibl_pad=$((UI_BOX_W - ${#_uibl_text} - 2))
    [ "$_uibl_pad" -lt 0 ] && _uibl_pad=0
    printf '  %s %s%s %s\n' \
        "$UI_ACCENT$UI_VB$UI_RESET" "$_uibl_text" \
        "$(ui_repeat ' ' "$_uibl_pad")" "$UI_ACCENT$UI_VB$UI_RESET"
}
ui_box_bottom() {
    printf '  %s%s%s%s\n' \
        "$UI_ACCENT" "$UI_BL" "$(ui_repeat "$UI_HR" "$UI_BOX_W")" "$UI_BR$UI_RESET"
}

# --- auto-width panel -------------------------------------------------------
# Like the box above, but sizes itself to the longest buffered line — use it
# for content with long values (paths, DSNs) that a fixed width would break.
#   ui_panel_begin "Title"; ui_panel_line "a"; ui_panel_line "b"; ui_panel_end
_UI_PANEL_TITLE=''
_UI_PANEL_BUF=''
ui_panel_begin() { _UI_PANEL_TITLE="${1:-}"; _UI_PANEL_BUF=''; }
ui_panel_line() {
    if [ -z "$_UI_PANEL_BUF" ]; then _UI_PANEL_BUF="$1"
    else _UI_PANEL_BUF="$_UI_PANEL_BUF
$1"; fi
}
ui_panel_end() {
    _uipe_w=$(( ${#_UI_PANEL_TITLE} + 1 ))
    _uipe_oifs=$IFS; IFS='
'
    for _uipe_l in $_UI_PANEL_BUF; do
        _uipe_ll=$(_ui_visible_len "$_uipe_l")
        [ "$_uipe_ll" -gt "$_uipe_w" ] && _uipe_w=$_uipe_ll
    done
    IFS=$_uipe_oifs
    _uipe_w=$(( _uipe_w + 2 ))                  # breathing room on the right
    # top border with inset title
    _uipe_title=" $_UI_PANEL_TITLE "
    _uipe_fill=$(( _uipe_w - ${#_uipe_title} - 1 ))
    [ "$_uipe_fill" -lt 0 ] && _uipe_fill=0
    printf '  %s%s%s%s%s%s%s\n' \
        "$UI_ACCENT" "$UI_TL$UI_HR" "$UI_RESET$UI_BOLD$_uipe_title$UI_RESET" \
        "$UI_ACCENT" "$(ui_repeat "$UI_HR" "$_uipe_fill")" "$UI_TR" "$UI_RESET"
    # content lines, each padded to the inner width
    _uipe_oifs=$IFS; IFS='
'
    for _uipe_l in $_UI_PANEL_BUF; do
        _uipe_pad=$(( _uipe_w - $(_ui_visible_len "$_uipe_l") - 2 ))
        [ "$_uipe_pad" -lt 0 ] && _uipe_pad=0
        printf '  %s %s%s %s\n' \
            "$UI_ACCENT$UI_VB$UI_RESET" "$_uipe_l" \
            "$(ui_repeat ' ' "$_uipe_pad")" "$UI_ACCENT$UI_VB$UI_RESET"
    done
    IFS=$_uipe_oifs
    printf '  %s%s%s%s\n' \
        "$UI_ACCENT" "$UI_BL" "$(ui_repeat "$UI_HR" "$_uipe_w")" "$UI_BR$UI_RESET"
}

# ui_rule — a dim full-width divider, with a blank line either side.
#
# For the seam between two parts of a run: the install is finished and something
# else is being asked. Sized to the terminal so it reads as a break rather than
# as content. ⇄ twin: Write-ExakitRule in ui.ps1.
ui_rule() {
    _uir_w="$(_ui_term_cols 2>/dev/null || echo 80)"
    _uir_w=$(( _uir_w - 4 ))
    [ "$_uir_w" -gt 76 ] && _uir_w=76
    [ "$_uir_w" -ge 8 ] || _uir_w=8
    printf '\n  %s%s%s\n\n' "${UI_DIM:-}" "$(ui_repeat "${UI_HR:--}" "$_uir_w")" "${UI_RESET:-}"
}

# --- spinner / step animation ----------------------------------------------
# Model: ui_step_start prints (or animates) a "working" line; the step body
# runs with its chatter sent to the log; ui_step_ok / ui_step_fail replaces
# the line with a final status + elapsed time.

_UI_SPIN_PID=''
_UI_STEP_T0=''
_UI_STEP_LABEL=''
# ONE animation at a time. There is a single line being redrawn, so a second
# request to animate is a no-op rather than a second painter: two loops writing
# \r to the same row produce a flicker, and the first one's pid is lost the
# moment the second overwrites _UI_SPIN_PID.
#
# This is what lets a progress line survive the work underneath it. A dataset
# load paints its own bar and then calls exapump through run_logged, which asks
# for a spinner of its own; without the counter, run_logged's ui_spin_end would
# kill the bar after the first file. Counted rather than flagged, because the
# nesting can be more than one deep.
_UI_SPIN_NESTED=0

# ui_spin_begin <label> — start ONLY the animated spinner (prints no line of
# its own). No-op unless we are on an interactive fancy terminal *right now*:
# it re-checks `-t 1` at call time so a spinner can never leak into a
# $(command substitution) capture, even when UI_FANCY was 1 at load time.
ui_spin_begin() {
    # Something is already animating this line: take a reference, draw nothing.
    if [ -n "${_UI_SPIN_PID:-}" ]; then
        _UI_SPIN_NESTED=$(( _UI_SPIN_NESTED + 1 ))
        return 0
    fi
    [ "$UI_FANCY" = 1 ] || return 0
    [ -t 1 ] || return 0
    _UI_STEP_LABEL="$1"
    _UI_STEP_T0="$(date +%s 2>/dev/null || echo 0)"
    printf '\033[?25l'                          # hide cursor
    (
        _i=0
        while :; do
            _f="${UI_SPIN_FRAMES[$_i]}"
            _now="$(date +%s 2>/dev/null || echo 0)"
            _el=$((_now - _UI_STEP_T0))
            printf '\r  %s%s%s %s %s(%ss)%s\033[K' \
                "$UI_ACCENT" "$_f" "$UI_RESET" "$_UI_STEP_LABEL" \
                "$UI_DIM" "$_el" "$UI_RESET"
            _i=$(((_i + 1) % 10))
            sleep 0.08
        done
    ) &
    _UI_SPIN_PID=$!
}

# ui_spin_end — stop the spinner and clear its line, printing no status line
# (the caller's own info/ok lines carry the message).
ui_spin_end() {
    # Give back a reference taken while something else owned the line; only the
    # call that actually started the animation stops it.
    if [ "${_UI_SPIN_NESTED:-0}" -gt 0 ]; then
        _UI_SPIN_NESTED=$(( _UI_SPIN_NESTED - 1 ))
        return 0
    fi
    _ui_step_stop_spinner
}

# ui_step_start <label> — begin a visible step: an animated spinner in fancy
# mode, or a plain "> label…" line otherwise. Pair with ui_step_ok/_fail.
ui_step_start() {
    if [ "$UI_FANCY" = 1 ] && [ -t 1 ]; then
        ui_spin_begin "$1"
    else
        _UI_STEP_LABEL="$1"
        _UI_STEP_T0="$(date +%s 2>/dev/null || echo 0)"
        printf '  %s %s…\n' "$UI_ARROW" "$1"
    fi
}

_ui_step_stop_spinner() {
    [ -n "$_UI_SPIN_PID" ] || return 0
    kill "$_UI_SPIN_PID" 2>/dev/null
    wait "$_UI_SPIN_PID" 2>/dev/null
    _UI_SPIN_PID=''
    printf '\r\033[K\033[?25h'                   # clear spinner line, restore cursor
}

_ui_step_elapsed() {
    _now="$(date +%s 2>/dev/null || echo 0)"
    _el=$((_now - _UI_STEP_T0))
    [ "$_el" -lt 1 ] && { printf '<1s'; return; }
    printf '%ss' "$_el"
}

# ui_step_ok <label> [detail]
ui_step_ok() {
    _ui_step_stop_spinner
    _uiso_detail=''
    [ -n "${2:-}" ] && _uiso_detail=" ${UI_DIM}${2}${UI_RESET}"
    if [ "$UI_FANCY" = 1 ]; then
        printf '  %s%s%s %s%s %s(%s)%s\n' \
            "$UI_OK" "$UI_TICK" "$UI_RESET" "$1" "$_uiso_detail" \
            "$UI_DIM" "$(_ui_step_elapsed)" "$UI_RESET"
    else
        printf '  %s %s%s\n' "$UI_TICK" "$1" "${2:+ ($2)}"
    fi
}

# ui_step_fail <label> [detail]
ui_step_fail() {
    _ui_step_stop_spinner
    if [ "$UI_FANCY" = 1 ]; then
        printf '  %s%s%s %s%s\n' \
            "$UI_ERR" "$UI_CROSS" "$UI_RESET" "$1" "${2:+ ${UI_DIM}$2${UI_RESET}}"
    else
        printf '  %s %s%s\n' "$UI_CROSS" "$1" "${2:+ ($2)}"
    fi
}

# Restore the cursor if we died mid-spin. NOT wired to a trap here on
# purpose: the installer owns `trap ... EXIT` (exakit_on_failure), which
# calls this itself, so a trap here would clobber the installer's cleanup.
ui_restore_cursor() { [ "$UI_FANCY" = 1 ] && printf '\033[?25h'; return 0; }

# --- the progress line -----------------------------------------------------
# ui_progress_creep <pct> <ceiling> <seconds> <elapsed-in-segment> — where
# the bar should sit RIGHT NOW, between the stage the job last reported and
# the one it will report next.
#
# A milestone-only bar stands still for as long as the job is quiet, and every
# job the kit runs is quiet for its longest stretch. So the milestones stay
# the truth -- the bar never claims a stage that has not been reached -- and the
# time between them is filled in at the pace that stage usually takes. The creep is
# capped one point BELOW the next milestone, so arriving at it is still something
# you see happen, and a stage that runs long simply waits there instead of
# walking into the next one's territory.
ui_progress_creep() {
    _upc_span=$(( $2 - $1 ))
    if [ "$_upc_span" -le 0 ] || [ "$3" -le 0 ]; then
        printf '%s\n' "$1"
        return 0
    fi
    _upc_step=$(( _upc_span * $4 / $3 ))
    [ "$_upc_step" -gt $(( _upc_span - 1 )) ] && _upc_step=$(( _upc_span - 1 ))
    [ "$_upc_step" -lt 0 ] && _upc_step=0
    printf '%s\n' "$(( $1 + _upc_step ))"
}

UI_PROGRESS_EIGHTHS=' ▏▎▍▌▋▊▉'

# ui_progress_line <pct> <phase> <elapsed-seconds> <frame> <columns> — the
# progress line.
#
# Laid out in four cells across the terminal's own width, so the bar starts at
# the same column whatever the phase is called and nothing shuffles sideways as
# the text changes underneath it:
#
#   45% phase text · 40% bar · 7% percentage · 8% elapsed
#
# The phase leads because it is the part a reader is actually reading; the
# numbers trail because they are the part they glance at. A braille head sits in
# front of the whole thing: the bar can legitimately sit still (a slow step holds its
# position on purpose), and the head is
# what says the run is alive while it does.
#
# One bar for every long job the kit runs: the local deployment, a bundled
# dataset, a folder of files, an add-on install. Twin: Write-ExakitProgressLine.
ui_progress_line() {
    _upl_pct="$1"; _upl_phase="$2"; _upl_el="$3"; _upl_frame="${4:-0}"; _upl_cols="${5:-80}"

    # The gutter the rest of the step's lines use, plus the head and its space,
    # and ONE COLUMN LEFT UNWRITTEN. A line that fills the last cell sets the
    # terminal's pending-wrap flag, and the next \r lands a row lower — which on
    # a wide terminal showed up as a clipped "(19s" with its bracket eaten.
    _upl_avail=$(( _upl_cols - 6 - 2 - 1 ))
    # Capped, because the cells are proportions and a very wide terminal turns
    # the 45% text cell into sixty columns of nothing between the phase and the
    # bar. Past this width the line stays put and the screen gets wider around
    # it, which is what a reader wants from a line they are watching.
    [ "$_upl_avail" -le 112 ] || _upl_avail=112
    [ "$_upl_avail" -ge 24 ] || _upl_avail=24
    #   30% phase · 40% bar · 10% percentage · 10% elapsed
    # The remaining tenth is the gap between the phase and the bar. Spending it
    # there rather than widening a cell is what stops a long phase from butting
    # against the bar while a short one leaves the two looking unrelated.
    _upl_tw=$(( _upl_avail * 30 / 100 ))
    _upl_bw=$(( _upl_avail * 40 / 100 ))
    _upl_nw=$(( _upl_avail * 10 / 100 ))
    _upl_ew=$(( _upl_avail * 10 / 100 ))
    _upl_gap=$(( _upl_avail - _upl_tw - _upl_bw - _upl_nw - _upl_ew ))
    [ "$_upl_gap" -ge 1 ] || _upl_gap=1
    # Floors, because a cell that cannot hold its content is worse than a
    # narrower neighbour: "100%" needs four columns and "(120s)" needs six. The
    # text cell pays for them, since it is the only one that can be shortened
    # without losing information the others carry exactly.
    [ "$_upl_nw" -ge 5 ] || { _upl_tw=$(( _upl_tw - (5 - _upl_nw) )); _upl_nw=5; }
    [ "$_upl_ew" -ge 7 ] || { _upl_tw=$(( _upl_tw - (7 - _upl_ew) )); _upl_ew=7; }
    [ "$_upl_bw" -ge 8 ] || _upl_bw=8
    [ "$_upl_tw" -ge 8 ] || _upl_tw=8

    # The phase, truncated to its cell MINUS ONE: a phase long enough to fill
    # the cell would otherwise run straight into the bar with no gap between
    # them, which is what a narrow terminal does to every long phase there is.
    # _ui_fit_row measures what the reader SEES, so a phase carrying an escape
    # sequence is not cut by byte count.
    _upl_text="$(_ui_fit_row "$_upl_phase" 0 $(( _upl_tw - 1 )))"
    _upl_pad=$(( _upl_tw - $(_ui_visible_len "$_upl_text") ))
    [ "$_upl_pad" -ge 0 ] || _upl_pad=0

    # Eighths across the whole bar, from integer percent: at forty cells one
    # percent is three eighths, so every step of the creep moves something.
    if [ "${UI_FANCY:-0}" = 1 ]; then
        _upl_units=$(( _upl_pct * _upl_bw * 8 / 100 ))
        _upl_full=$(( _upl_units / 8 ))
        _upl_rem=$(( _upl_units % 8 ))
        [ "$_upl_full" -gt "$_upl_bw" ] && { _upl_full="$_upl_bw"; _upl_rem=0; }
        _upl_head=""
        if [ "$_upl_full" -lt "$_upl_bw" ] && [ "$_upl_rem" -gt 0 ]; then
            _upl_head="$(printf '%s' "$UI_PROGRESS_EIGHTHS" | cut -c $((_upl_rem + 1)))"
        fi
        _upl_empty=$(( _upl_bw - _upl_full ))
        [ -n "$_upl_head" ] && _upl_empty=$(( _upl_empty - 1 ))
        [ "$_upl_empty" -ge 0 ] || _upl_empty=0
        _upl_bar="${UI_ACCENT:-}$(ui_repeat "${UI_BAR_FULL:-#}" "$_upl_full")${UI_DIM:-}${_upl_head}$(ui_repeat "${UI_BAR_EMPTY:-.}" "$_upl_empty")${UI_RESET:-}"
        _upl_spin="${UI_SPIN_FRAMES[$(( _upl_frame % 10 ))]}"
    else
        _upl_full=$(( _upl_pct * _upl_bw / 100 ))
        [ "$_upl_full" -gt "$_upl_bw" ] && _upl_full="$_upl_bw"
        _upl_bar="$(ui_repeat "${UI_BAR_FULL:-#}" "$_upl_full")$(ui_repeat "${UI_BAR_EMPTY:-.}" $(( _upl_bw - _upl_full )))"
        _upl_spin='>'
    fi

    printf '\r      %s%s%s %s%s%s%s%s%*s%%%s%s%*s%s\033[K' \
        "${UI_ACCENT:-}" "$_upl_spin" "${UI_RESET:-}" \
        "$_upl_text" "$(ui_repeat ' ' $(( _upl_pad + _upl_gap )))" \
        "$_upl_bar" \
        "${UI_BOLD:-}" "" $(( _upl_nw - 1 )) "$_upl_pct" "${UI_RESET:-}" \
        "${UI_DIM:-}" "$_upl_ew" "($_upl_el""s)" "${UI_RESET:-}"
}

# ui_progress_animate <state-file> <t0> — redraw the progress line five
# times a second from whatever the collector last wrote, so the elapsed counter
# keeps moving through the launcher's long silences (13s between messages on a
# warm cache, minutes on a cold one).
#
# It runs in the UI layer's single spinner slot (_UI_SPIN_PID), so the
# installer's existing EXIT trap -- which calls ui_spin_end and
# ui_restore_cursor -- stops it and gives the cursor back if the run is
# interrupted or dies mid-deploy. Only one animation is ever on screen, so the
# slot is free while this runs.
ui_progress_animate() {
    _upa_shown=0
    _upa_frame=0
    # Measured ONCE. _ui_term_cols forks stty or tput, and this loop runs five
    # times a second for as long as the deploy takes; a terminal resized mid
    # deploy keeps the width it started with, which is a fair trade for not
    # forking a process per frame.
    _upa_cols="$(_ui_term_cols 2>/dev/null || echo 80)"
    while :; do
        _upa_state=""
        read -r _upa_state < "$1" 2>/dev/null || true
        # A read that caught the file mid-write has no phase yet: skip the frame
        # rather than paint a half-written one.
        case "$_upa_state" in
            *"|"*"|"*"|"*"|"*)
                _upa_now="$(date +%s 2>/dev/null || echo 0)"
                # pct|ceiling|seconds|segment-start|label
                _upa_rest="${_upa_state#*|}"
                _upa_pct="${_upa_state%%|*}"
                _upa_ceil="${_upa_rest%%|*}"; _upa_rest="${_upa_rest#*|}"
                _upa_secs="${_upa_rest%%|*}"; _upa_rest="${_upa_rest#*|}"
                _upa_t0="${_upa_rest%%|*}"
                _upa_label="${_upa_rest#*|}"
                _upa_at="$(ui_progress_creep "$_upa_pct" "$_upa_ceil" \
                    "$_upa_secs" "$(( _upa_now - _upa_t0 ))")"
                # The bar never walks backwards. A milestone can arrive BELOW
                # where the creep has already reached (the launcher emits
                # "starting deployment" twenty seconds into a segment whose
                # ceiling is higher); the new segment is adopted, the position is
                # not given up.
                [ "$_upa_at" -lt "$_upa_shown" ] && _upa_at="$_upa_shown"
                _upa_shown="$_upa_at"
                ui_progress_line "$_upa_at" "$_upa_label" \
                    "$(( _upa_now - $2 ))" "$_upa_frame" "$_upa_cols"
                _upa_frame=$(( _upa_frame + 1 ))
                ;;
        esac
        sleep 0.2
    done
}

# --- driving the bar --------------------------------------------------------
# The animator reads its position from a FILE, because the thing doing the work
# usually cannot reach the animator's variables: a pipeline's right-hand side, a
# subshell, a loop whose output is captured. One short line, rewritten whenever
# the job reaches a new stage:
#
#   pct|ceiling|seconds|segment-start|phase
#
# pct is where the job actually is, ceiling is where the NEXT stage sits, and
# seconds is how long this stage usually takes -- which is what lets the bar
# keep moving between the two without ever claiming the next stage. See
# ui_progress_creep.

# ui_progress_state <file> <pct> <ceiling> <seconds> <phase> — the job has
# reached a new stage. The segment's own clock starts now.
ui_progress_state() {
    printf '%s|%s|%s|%s|%s\n' "$2" "$3" "$4" \
        "$(date +%s 2>/dev/null || echo 0)" "$5" > "$1"
}

# ui_progress_begin <file> <t0> — start painting, in the UI layer's single
# animation slot (_UI_SPIN_PID), so the installer's existing EXIT trap stops it
# and gives the cursor back if the run is interrupted or dies mid-job.
#
# Live only on an interactive fancy terminal, checked HERE rather than at load
# time so a redrawing line can never leak into a capture or a log. Returns 1 when
# it did not start, which is the caller's cue to narrate in plain lines instead.
ui_progress_begin() {
    [ "${UI_FANCY:-0}" = 1 ] || return 1
    [ -t 1 ] || return 1
    printf '\033[?25l'
    ui_progress_animate "$1" "$2" &
    _UI_SPIN_PID=$!
    return 0
}

# ui_progress_phase <file> <phase> — change the words without touching the
# position or restarting the segment's clock. For a stage that reports what it
# has finished while the bar keeps creeping on its own (concurrent uploads
# landing one by one). ⇄ twin: Set-ExakitProgressPhase in ui.ps1.
ui_progress_phase() {
    _upp_state=""
    read -r _upp_state < "$1" 2>/dev/null || return 0
    case "$_upp_state" in
        *"|"*"|"*"|"*"|"*)
            printf '%s|%s\n' "$(printf '%s' "$_upp_state" | cut -d'|' -f1-4)" "$2" > "$1"
            ;;
    esac
}

# ui_progress_end — stop it and clear the line. Same call as ui_spin_end; named
# for symmetry so a caller never has to know which of the two it started.
ui_progress_end() { ui_spin_end; }

# --- progress bar (determinate) --------------------------------------------
# ui_progress <current> <total> <label> — redraws in place; caller prints a
# newline (or calls ui_step_ok) when done.
ui_progress() {
    _uip_cur="$1"; _uip_tot="$2"; _uip_label="${3:-}"
    [ "$_uip_tot" -gt 0 ] 2>/dev/null || _uip_tot=1
    _uip_w=20
    _uip_filled=$(( _uip_cur * _uip_w / _uip_tot ))
    [ "$_uip_filled" -gt "$_uip_w" ] && _uip_filled="$_uip_w"
    _uip_pct=$(( _uip_cur * 100 / _uip_tot ))
    if [ "$UI_FANCY" = 1 ]; then
        printf '\r  %s%s%s%s %s%3s%%%s %s\033[K' \
            "$UI_ACCENT" "$(ui_repeat "$UI_BAR_FULL" "$_uip_filled")" \
            "$UI_DIM" "$(ui_repeat "$UI_BAR_EMPTY" $((_uip_w - _uip_filled)))$UI_RESET" \
            "$UI_BOLD" "$_uip_pct" "$UI_RESET" "$_uip_label"
    else
        printf '  [%s%s] %s%%  %s\n' \
            "$(ui_repeat "$UI_BAR_FULL" "$_uip_filled")" \
            "$(ui_repeat "$UI_BAR_EMPTY" $((_uip_w - _uip_filled)))" \
            "$_uip_pct" "$_uip_label"
    fi
}

# ui_bar <pct> [width] — the bar on its own, as a STRING.
#
# ui_progress above owns a whole line and redraws it. This one owns nothing: it
# is for embedding a bar inside a label somebody else paints — the dataset load
# hands it to run_logged's spinner, so the animation, the bar, the percentage
# and the current file are one line instead of four competing for it.
# ⇄ twin: Get-ExakitBar in ui.ps1.
ui_bar() {
    _uib_w="${2:-20}"
    _uib_filled=$(( $1 * _uib_w / 100 ))
    [ "$_uib_filled" -gt "$_uib_w" ] && _uib_filled="$_uib_w"
    [ "$_uib_filled" -lt 0 ] && _uib_filled=0
    printf '%s%s%s%s%s' \
        "${UI_ACCENT:-}" "$(ui_repeat "${UI_BAR_FULL:-#}" "$_uib_filled")" \
        "${UI_DIM:-}" "$(ui_repeat "${UI_BAR_EMPTY:-.}" $((_uib_w - _uib_filled)))" \
        "${UI_RESET:-}"
}

# --- direct-invocation render entry points ----------------------------------
# When this file is EXECUTED (not sourced), it exposes render helpers so a
# POSIX-sh caller (install.sh, which can't source a bash lib) can reuse this
# exact banner + palette. The guard means sourcing never triggers this.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        __render_install_plan)
            # Banner only: the old "Installation plan" panel repeated internals
            # (kit copy path, component list) users don't act on. Whether this
            # machine can run the kit is answered by the compatibility checks
            # that follow, which fail or warn explicitly.
            ui_banner "Personal Local Starter Kit"
            printf '\n'
            ;;
    esac
fi
