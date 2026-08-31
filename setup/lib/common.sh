#!/usr/bin/env bash
# common.sh — shared helpers for the Exasol Personal Local Starter Kit.
#
# Sourced by setup-*.sh, exakit, and upgrade scripts. Not meant to be executed
# directly. Compatible with bash 3.2 (macOS default).
#
# Provides:
#   - structured logging (console + log file under ~/.exasol-starter-kit/logs)
#   - install manifest read/write (~/.exasol-starter-kit/manifest.json)
#   - step tracking for idempotent re-runs
#   - rollback registration and failure handling
#   - component version resolution (latest by default, overridable via env)
#   - download + SHA-256 verification helpers

# ---------------------------------------------------------------------------
# Shared visual layer (banner, boxes, spinner, colour palette)
# ---------------------------------------------------------------------------
# ui.sh owns how the installer LOOKS. Source it first so info/ok/begin_step/
# connection_panel below can use its glyphs and palette. If it is somehow
# absent, install no-op stubs so nothing here breaks under `set -u`.
_exakit_common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _exakit_common_dir=''
[ -n "$_exakit_common_dir" ] && [ -f "$_exakit_common_dir/ui.sh" ] && . "$_exakit_common_dir/ui.sh"
if ! command -v ui_spin_begin >/dev/null 2>&1; then
    UI_FANCY=0; UI_RESET=''; UI_BOLD=''; UI_DIM=''; UI_ACCENT=''
    UI_INFO=''; UI_OK=''; UI_WARN=''; UI_ERR=''; UI_ASK=''
    UI_TICK='[ok]'; UI_CROSS='[x]'; UI_ARROW='>'; UI_BULLET='-'
    ui_spin_begin() { :; }; ui_spin_end() { :; }; ui_restore_cursor() { :; }
    ui_banner()     { printf '\n  %s\n' "${1:-Exasol Personal Local Starter Kit}"; [ -n "${2:-}" ] && printf '  %s\n' "$2"; printf '\n'; }
    ui_panel_begin() { printf '\n  -- %s --\n' "${1:-}"; }
    ui_panel_line()  { printf '   %s\n' "$1"; }
    ui_panel_end()   { printf '\n'; }
fi

# ---------------------------------------------------------------------------
# State locations
# ---------------------------------------------------------------------------
EXAKIT_HOME="${EXAKIT_HOME:-$HOME/.exasol-starter-kit}"
EXAKIT_LOG_DIR="$EXAKIT_HOME/logs"
EXAKIT_CACHE_DIR="$EXAKIT_HOME/cache"
EXAKIT_MANIFEST="$EXAKIT_HOME/manifest.json"
EXAKIT_MCP_DIR="$EXAKIT_HOME/mcp"
EXAKIT_CREDS_DIR="$EXAKIT_HOME/credentials"
# Where an approved query is saved so it can be re-run tomorrow. The skill's
# closing step ("make it rerunnable") names this directory by name, so it has to
# exist: telling an agent to write into a path nothing creates turns the last
# step of the trust loop into an mkdir it has to guess at.
EXAKIT_WORKFLOWS_DIR="$EXAKIT_HOME/workflows"
EXAKIT_BIN_DIR="${EXAKIT_BIN_DIR:-$HOME/.local/bin}"
EXAKIT_MANAGED_PYTHON_VERSION="${EXAKIT_MANAGED_PYTHON_VERSION:-3.12}"
EXAKIT_MCP_READONLY_USER="${EXAKIT_MCP_READONLY_USER:-mcp_readonly}"
EXAKIT_MCP_READONLY_SCHEMAS="${EXAKIT_MCP_READONLY_SCHEMAS:-STARTER_KIT}"

# ---------------------------------------------------------------------------
# Component version policy
# ---------------------------------------------------------------------------
# manifest (default) — take the version set the maintainers tested together,
#                      from versions.json (see below).
# latest             — resolve each Component independently from its upstream
#                      (GitHub releases, PyPI, Docker Hub). The escape hatch for
#                      anyone who wants the newest of everything.
# anything else       — install the *_FALLBACK versions below and touch no
#                      network at all.
EXAKIT_VERSION_POLICY="${EXAKIT_VERSION_POLICY:-manifest}"
EXAKIT_PERSONAL_VERSION="${EXAKIT_PERSONAL_VERSION:-}"
EXAKIT_NANO_TAG="${EXAKIT_NANO_TAG:-}"
EXAKIT_EXAPUMP_VERSION="${EXAKIT_EXAPUMP_VERSION:-}"
EXAKIT_MCP_PACKAGE="${EXAKIT_MCP_PACKAGE:-exasol-mcp-server}"
EXAKIT_MCP_VERSION="${EXAKIT_MCP_VERSION:-}"
EXAKIT_PYEXASOL_VERSION="${EXAKIT_PYEXASOL_VERSION:-}"

# Last-known-good fallbacks are used only when a latest-version lookup is not
# possible (offline install, API rate limit, private mirror). Successful latest
# resolutions are recorded in the manifest so later updates compare against the
# version that was actually installed.
EXAKIT_PERSONAL_VERSION_FALLBACK="${EXAKIT_PERSONAL_VERSION_FALLBACK:-2.2.0}"
EXAKIT_NANO_TAG_FALLBACK="${EXAKIT_NANO_TAG_FALLBACK:-2026.2.0-nano.3}"
EXAKIT_EXAPUMP_VERSION_FALLBACK="${EXAKIT_EXAPUMP_VERSION_FALLBACK:-0.12.0}"
EXAKIT_MCP_VERSION_FALLBACK="${EXAKIT_MCP_VERSION_FALLBACK:-2.1.0}"
EXAKIT_PYEXASOL_VERSION_FALLBACK="${EXAKIT_PYEXASOL_VERSION_FALLBACK:-2.3.2}"
# Marketplace add-ons (dash-server, ...) carry their own version constants in
# their module files — they are not part of the install flow, so nothing here
# needs to know them.

EXAKIT_PERSONAL_REPO="exasol/exasol-personal"
EXAKIT_EXAPUMP_REPO="exasol-labs/exapump"
EXAKIT_NANO_IMAGE="exasol/nano"
EXAKIT_KIT_REPO="${EXAKIT_KIT_REPO:-${EXAKIT_REPO:-krishna-exasol/update-path}}"
EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT="${EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT:-5}"
EXAKIT_VERSION_LOOKUP_MAX_TIME="${EXAKIT_VERSION_LOOKUP_MAX_TIME:-12}"

# The versions manifest (versions.json at the root of the kit repository on
# main) is the maintainer-edited record of the version set that was tested
# together. It is fetched over plain HTTPS from GitHub's raw endpoint — the same
# trust domain that already serves install.sh — and cached under the kit home.
# Nothing is collected on our side: the request carries a User-Agent header and
# no query string, and no third party is involved.
EXAKIT_VERSIONS_URL="${EXAKIT_VERSIONS_URL:-https://raw.githubusercontent.com/${EXAKIT_KIT_REPO}/main/versions.json}"
# The public install entry point, which is NOT the raw repository URL: someone
# reinstalling months from now should be sent to the address the product
# publishes, not to a branch of whichever repository built their copy.
EXAKIT_INSTALL_URL="${EXAKIT_INSTALL_URL:-https://www.exasol.com/install/starter-kit.sh}"
EXAKIT_VERSIONS_TTL="${EXAKIT_VERSIONS_TTL:-86400}"
# How long a FAILED versions fetch is remembered, so a network that cannot
# reach the manifest is asked once rather than once per command. Deliberately
# far shorter than the TTL: a machine that comes back online should pick the
# manifest up within minutes, not tomorrow.
EXAKIT_VERSIONS_RETRY_COOLDOWN="${EXAKIT_VERSIONS_RETRY_COOLDOWN:-900}"
EXAKIT_VERSIONS_CACHE="${EXAKIT_VERSIONS_CACHE:-$EXAKIT_CACHE_DIR/versions.json}"
# Schema the client understands. A document that announces a higher number is
# treated as unavailable (the resolution chain falls back) rather than guessed
# at — a newer kit knows how to read it.
EXAKIT_VERSIONS_SCHEMA=1
# Which tier of the chain actually answered, recorded as desired.versions_source
# so a support question ("where did this version come from?") has an answer.
EXAKIT_VERSIONS_SOURCE_USED=""

# Marketplace add-on "About" text. The one-line description the marketplace
# shows for an add-on is NOT stored in this repository: it is the About field of
# the add-on's own repository, fetched once and cached, so the tool that owns
# the wording owns it in exactly one place. The cache is what makes that safe to
# do in front of an interactive menu -- see exakit_marketplace_addon_description
# for the full resolution order, including what happens with no network at all.
EXAKIT_ABOUT_URL="${EXAKIT_ABOUT_URL:-https://api.github.com/repos}"
EXAKIT_ABOUT_TTL="${EXAKIT_ABOUT_TTL:-86400}"
EXAKIT_ABOUT_CACHE_DIR="${EXAKIT_ABOUT_CACHE_DIR:-$EXAKIT_CACHE_DIR/about}"
EXAKIT_ABOUT_OFFLINE="${EXAKIT_ABOUT_OFFLINE:-0}"
# Hard ceiling on a cached About line, in bytes. A repository we do not control
# decides this string's length; nothing downstream should have to cope with an
# unbounded one.
EXAKIT_ABOUT_MAX_LEN="${EXAKIT_ABOUT_MAX_LEN:-200}"
# Width of the Description cell, in the table and in the checkbox label alike.
# The table's rule is 74 columns and the two leading cells spend 30 of them.
EXAKIT_ABOUT_WIDTH="${EXAKIT_ABOUT_WIDTH:-44}"

EXAKIT_DB_PORT="${EXAKIT_DB_PORT:-8563}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
exakit_init_logging() {
    mkdir -p "$EXAKIT_LOG_DIR"
    if [ -z "${EXAKIT_LOG_FILE:-}" ]; then
        EXAKIT_LOG_FILE="$EXAKIT_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
        : > "$EXAKIT_LOG_FILE"
        chmod 600 "$EXAKIT_LOG_FILE"
    fi
    export EXAKIT_LOG_FILE
}

_exakit_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_exakit_log_file() {
    [ -n "${EXAKIT_LOG_FILE:-}" ] || return 0
    # Best-effort: the log directory may already be gone (e.g. during
    # `uninstall`, which deletes the kit home). A failed redirection-open is
    # reported to the *group's* stderr before a trailing `2>/dev/null` on the
    # printf would apply, so redirect at the group level and also skip early if
    # the directory is missing. Never let logging fail a command.
    [ -d "$(dirname "$EXAKIT_LOG_FILE")" ] || return 0
    { printf '%s %s\n' "$(_exakit_ts)" "$*" >> "$EXAKIT_LOG_FILE"; } 2>/dev/null || return 0
}

# Glyphs/colours come from the shared palette (ui.sh): bold + Unicode on an
# interactive UTF-8 terminal, plain ASCII with no escapes when piped/CI/log.
# Three visual levels under the banner: step headers (2-space, begin_step),
# actions (4-space dim bullet: info/prompts), and outcomes nested under their
# action (6-space: ✓ ok, ! warn, ✗ error — plus contained tool output). The
# nesting is what makes a step read as "action → what happened".
# EXAKIT_QUIET_DETAIL=1 — a caller is narrating a whole job on ONE line (an
# add-on install, a dataset load), so the steps underneath report to the LOGFILE
# instead of the screen. Gated here rather than at every call site: the chatter
# comes from a dozen places in four modules, and a gate per line is a gate
# somebody forgets. warn/error are deliberately NOT gated — a job that says
# nothing while it works must still say something when it goes wrong.
info() {
    [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ] || \
        printf '    %s%s%s %s\n' "${UI_DIM:-}" "${UI_BULLET:--}" "${UI_RESET:-}" "$*"
    _exakit_log_file "INFO  $*"
}
ok() {
    [ "${EXAKIT_QUIET_DETAIL:-0}" = 1 ] || \
        printf '      %s%s%s %s\n' "${UI_OK:-}" "${UI_TICK:-[ok]}" "${UI_RESET:-}" "$*"
    _exakit_log_file "OK    $*"
}
# ok_step / info_step — the lines a one-line step keeps.
#
# A step that narrates itself on one line sets EXAKIT_QUIET_DETAIL, which gates
# every info/ok underneath it to the logfile. That is the right default: the
# spinner is already saying what is happening. But each step still has one or
# two facts worth leaving on screen -- the profile name someone will type again,
# the path to a Python that is now on disk -- and they are printed from inside
# the same functions being quieted. These two say it anyway.
#
# The flag is saved and restored rather than cleared, so a step nested inside
# another quiet caller (an add-on install, a data load) does not tear a hole in
# ITS one-line narration either. ⇄ twins: OkStep/InfoStep in exakit-common.ps1.
ok_step() {
    _oks_prev="${EXAKIT_QUIET_DETAIL:-0}"
    EXAKIT_QUIET_DETAIL=0
    ok "$@"
    EXAKIT_QUIET_DETAIL="$_oks_prev"
}
info_step() {
    _ifs_prev="${EXAKIT_QUIET_DETAIL:-0}"
    EXAKIT_QUIET_DETAIL=0
    info "$@"
    EXAKIT_QUIET_DETAIL="$_ifs_prev"
}
warn() { printf '      %s!%s %s\n'  "${UI_WARN:-}" "${UI_RESET:-}" "$*" >&2;        _exakit_log_file "WARN  $*"; }
error(){ printf '      %s%s%s %s\n' "${UI_ERR:-}"  "${UI_CROSS:-[x]}" "${UI_RESET:-}" "$*" >&2; _exakit_log_file "ERROR $*"; }

# Menu rendering: options nest under the "Choose ..." action line with the
# number in the accent colour; the how-to-answer hint is a dim afterthought.
# usage: ui_menu_option <number> <label>; ui_menu_hint <text>
ui_menu_option() { printf '      %s%s.%s %s\n' "${UI_ACCENT:-}" "$1" "${UI_RESET:-}" "$2"; }
ui_menu_hint()   { printf '      %s%s%s\n' "${UI_DIM:-}" "$1" "${UI_RESET:-}"; }

# _ui_term_cols — the terminal's width, or a sane default. COLUMNS is not
# exported to scripts, and `tput cols` is a TRAP inside command substitution:
# its stdout is a pipe there, so it cannot ioctl the terminal and silently
# answers 80 — which made the menu miscount wrapped rows on any terminal that
# was not 80 columns and climb over the lines above it. `stty size` reads the
# terminal through stdin instead, which /dev/tty provides regardless of where
# stdout points.
_ui_term_cols() {
    _utc="${COLUMNS:-}"
    if [ -z "$_utc" ]; then
        set -- $(stty size < /dev/tty 2>/dev/null || true)
        _utc="${2:-}"
    fi
    [ -n "$_utc" ] || _utc="$(tput cols 2>/dev/null || true)"
    case "$_utc" in ''|*[!0-9]*) _utc=80 ;; esac
    [ "$_utc" -ge 20 ] || _utc=80
    printf '%s\n' "$_utc"
}

# _ui_fit_row <text> <chrome-cols> <terminal-cols> — the text, truncated so
# chrome + text CANNOT exceed one terminal line. The redraw arithmetic is only
# exact when every row is exactly one line: truncation makes that true by
# construction, instead of trusting width detection, locales and wrap rules to
# all agree. (bash counts characters here; in a non-UTF-8 locale it counts
# bytes, which only ever truncates EARLIER — still one line, never two.)
_ui_fit_row() {
    _ufr_text="$1"; _ufr_chrome="$2"; _ufr_cols="$3"
    if [ $(( ${#_ufr_text} + _ufr_chrome )) -gt "$_ufr_cols" ]; then
        _ufr_keep=$(( _ufr_cols - _ufr_chrome - 1 ))
        [ "$_ufr_keep" -gt 0 ] || _ufr_keep=1
        # bash substring, not `cut -c`: BSD cut counts bytes and can split a
        # multibyte character in half at the boundary.
        printf '%s…\n' "${_ufr_text:0:$_ufr_keep}"
        return 0
    fi
    printf '%s\n' "$_ufr_text"
}

# _ui_wrapped_lines <visible-columns> <terminal-columns> — how many terminal
# LINES a row of that width occupies. A row wider than the terminal wraps, and
# a redraw that assumed one line per row would leave the overflow on screen
# forever (every keypress stacking another stale copy). Menus therefore count
# what they actually drew instead of counting their rows.
_ui_wrapped_lines() {
    _uwl_w="$1"; _uwl_cols="$2"
    [ "$_uwl_w" -gt 0 ] 2>/dev/null || { printf '1\n'; return 0; }
    printf '%s\n' "$(( (_uwl_w + _uwl_cols - 1) / _uwl_cols ))"
}

# --- checkbox multi-select ---------------------------------------------------
# _ui_checkbox_toggle <selected_csv> <count> <input> — pure selection logic.
# Toggles the 1-based indices named in <input> (numbers separated by spaces or
# commas; "all" selects everything) in or out of <selected_csv>, echoing the
# new csv. Non-numeric or out-of-range tokens are ignored.
_ui_checkbox_toggle() {
    _ct_sel="$1"
    _ct_n="$2"
    _ct_in="$(printf '%s' "$3" | tr ',' ' ')"
    case " $_ct_in " in
        *" all "*|*" ALL "*|*" All "*)
            _ct_sel=""
            _ct_i=1
            while [ "$_ct_i" -le "$_ct_n" ]; do
                _ct_sel="${_ct_sel:+$_ct_sel,}$_ct_i"
                _ct_i=$((_ct_i + 1))
            done
            printf '%s' "$_ct_sel"
            return 0
            ;;
    esac
    for _ct_tok in $_ct_in; do
        case "$_ct_tok" in ''|*[!0-9]*) continue ;; esac
        [ "$_ct_tok" -ge 1 ] && [ "$_ct_tok" -le "$_ct_n" ] || continue
        case ",$_ct_sel," in
            *",$_ct_tok,"*)
                _ct_sel="$(printf ',%s,' "$_ct_sel" | sed "s/,$_ct_tok,/,/")"
                _ct_sel="${_ct_sel#,}"
                _ct_sel="${_ct_sel%,}"
                ;;
            *) _ct_sel="${_ct_sel:+$_ct_sel,}$_ct_tok" ;;
        esac
    done
    printf '%s' "$_ct_sel"
}

# ui_checkbox_menu <title> <defaults_csv> <label> [label ...] — multi-select
# rendered as checkboxes with a movable cursor: ↑/↓ (or j/k) move, Space
# toggles the highlighted option, Enter confirms and moves to the next step
# ("a" selects all). At least one option must stay selected (Enter on an
# empty selection re-asks). In fancy mode the block redraws in place so
# toggling feels live; plain mode reprints below. Non-interactive runs (and
# EOF on the input) keep the defaults and say so. The confirmed selection
# lands in EXAKIT_CHECKBOX_SELECTION as an ascending csv of 1-based indices.
#
# EXAKIT_CHECKBOX_EXCLUSIVE (optional, cleared after each call): 1-based index
# of an option that cannot be combined with the others — think "Skip".
# Selecting it clears every other choice; selecting any other choice clears it.
# "a" (select all) selects all non-exclusive options.
#
# EXAKIT_CHECKBOX_GROUP (optional, cleared after each call):
# "parent:first:last[:mode]" — row <parent> is a group checkbox whose children
# are rows <first>..<last> (header and disabled rows in that range are skipped).
# Toggling the parent ON selects every child; toggling it OFF clears them all.
# Toggling a child re-derives the parent:
#   mode "any" (default) — checked while ANY child is checked. The parent reads
#                          as a group header, e.g. "Sample datasets".
#   mode "all"           — checked only while EVERY child is checked, so the
#                          parent reads as a MASTER toggle: pick it and you get
#                          everything, untick any one row and it releases.
#                          Used by "EVERYTHING" in the uninstall menu.
EXAKIT_CHECKBOX_SELECTION=""
EXAKIT_CHECKBOX_EXCLUSIVE=""
EXAKIT_CHECKBOX_GROUP=""
# Published by ui_checkbox_menu for the group helpers: the rows that can
# actually be checked (headers and disabled rows excluded).
_UI_CHECKBOX_SELECTABLE=""

# _ui_checkbox_apply_group <selected_csv> <toggled_idx> <group_spec> — pure
# post-toggle parent/child rule, echoing the adjusted csv.
# _ui_checkbox_group_children <first> <last> — the SELECTABLE rows in a group's
# range. Header and disabled rows sit inside the range (a group can span a small
# tree) but can never be checked, so a select-all must skip them and an
# all-children rule must not wait for them. _UI_CHECKBOX_SELECTABLE is published
# by ui_checkbox_menu; empty means "every row is selectable" (pure callers, and
# the unit tests, can set it themselves).
_ui_checkbox_group_children() {
    _cgc_out=""
    _cgc_i="$1"
    while [ "$_cgc_i" -le "$2" ]; do
        if [ -z "${_UI_CHECKBOX_SELECTABLE:-}" ]; then
            _cgc_out="$_cgc_out $_cgc_i"
        else
            case " ${_UI_CHECKBOX_SELECTABLE} " in
                *" $_cgc_i "*) _cgc_out="$_cgc_out $_cgc_i" ;;
            esac
        fi
        _cgc_i=$((_cgc_i + 1))
    done
    printf '%s' "${_cgc_out# }"
}

_ui_checkbox_apply_group() {
    _cg_sel="$1"; _cg_toggled="$2"; _cg_spec="$3"
    [ -n "$_cg_spec" ] || { printf '%s' "$_cg_sel"; return 0; }
    _cg_parent="${_cg_spec%%:*}"
    _cg_rest="${_cg_spec#*:}"
    _cg_first="${_cg_rest%%:*}"
    _cg_rest="${_cg_rest#*:}"
    _cg_last="${_cg_rest%%:*}"
    # Optional 4th field: "all" makes the parent a MASTER toggle — checked only
    # while EVERY child is checked, so unticking any one of them unticks it.
    # Default "any" (the parent is a group header: checked while any child is).
    case "$_cg_spec" in
        *:*:*:*) _cg_mode="${_cg_spec##*:}" ;;
        *)       _cg_mode="any" ;;
    esac
    _cg_children="$(_ui_checkbox_group_children "$_cg_first" "$_cg_last")"
    if [ "$_cg_toggled" = "$_cg_parent" ]; then
        # Parent toggled: rebuild the child range to match the parent's state.
        case ",$_cg_sel," in
            *",$_cg_parent,"*) _cg_parent_on=1 ;;
            *) _cg_parent_on=0 ;;
        esac
        _cg_out=""
        for _cg_tok in $(printf '%s' "$_cg_sel" | tr ',' ' '); do
            if [ "$_cg_tok" -ge "$_cg_first" ] && [ "$_cg_tok" -le "$_cg_last" ]; then
                continue
            fi
            _cg_out="${_cg_out:+$_cg_out,}$_cg_tok"
        done
        if [ "$_cg_parent_on" = 1 ]; then
            for _cg_i in $_cg_children; do
                _cg_out="${_cg_out:+$_cg_out,}$_cg_i"
            done
        fi
        printf '%s' "$_cg_out"
        return 0
    fi
    if [ "$_cg_toggled" -ge "$_cg_first" ] && [ "$_cg_toggled" -le "$_cg_last" ]; then
        # Child toggled: re-derive the parent from the children.
        _cg_on=0
        if [ "$_cg_mode" = "all" ]; then
            _cg_on=1
            for _cg_i in $_cg_children; do
                case ",$_cg_sel," in
                    *",$_cg_i,"*) ;;
                    *) _cg_on=0; break ;;
                esac
            done
        else
            for _cg_i in $_cg_children; do
                case ",$_cg_sel," in *",$_cg_i,"*) _cg_on=1; break ;; esac
            done
        fi
        _cg_out=""
        for _cg_tok in $(printf '%s' "$_cg_sel" | tr ',' ' '); do
            [ "$_cg_tok" = "$_cg_parent" ] && continue
            _cg_out="${_cg_out:+$_cg_out,}$_cg_tok"
        done
        [ "$_cg_on" = 1 ] && _cg_out="${_cg_out:+$_cg_out,}$_cg_parent"
        printf '%s' "$_cg_out"
        return 0
    fi
    printf '%s' "$_cg_sel"
}

# _ui_checkbox_apply_exclusive <selected_csv> <toggled_idx> <exclusive_idx> —
# pure post-toggle rule, echoing the adjusted csv.
_ui_checkbox_apply_exclusive() {
    _ce_sel="$1"; _ce_toggled="$2"; _ce_excl="$3"
    [ -n "$_ce_excl" ] || { printf '%s' "$_ce_sel"; return 0; }
    if [ "$_ce_toggled" = "$_ce_excl" ]; then
        # The exclusive option was just toggled: if it landed selected, it
        # becomes the only selection.
        case ",$_ce_sel," in
            *",$_ce_excl,"*) printf '%s' "$_ce_excl" ;;
            *) printf '%s' "$_ce_sel" ;;
        esac
        return 0
    fi
    # Any other toggle drops the exclusive option from the selection.
    _ce_sel="$(printf ',%s,' "$_ce_sel" | sed "s/,$_ce_excl,/,/")"
    _ce_sel="${_ce_sel#,}"; _ce_sel="${_ce_sel%,}"
    printf '%s' "$_ce_sel"
}

ui_checkbox_menu() {
    _cb_title="$1"
    _cb_defaults="$2"
    shift 2
    _cb_sel="$_cb_defaults"
    _cb_n=$#
    _cb_labels=("$@")
    info "$_cb_title"

    # A label starting with "#" is a GROUP HEADER: rendered as a plain caption
    # (no checkbox), never selectable, and skipped by the cursor. Headers let a
    # menu show a small tree — e.g. "Sample datasets" with the individual
    # datasets indented beneath it — while selection indices stay flat.
    # A label starting with "!" is a DISABLED row: rendered as a dimmed,
    # unchecked checkbox (the label should say why — e.g. "· not installed"),
    # never selectable, skipped by the cursor, and excluded from "a". Disabled
    # rows let a menu show the full set of options while only the applicable
    # ones can be chosen.
    _cb_is_header() {
        case "${_cb_labels[$(($1 - 1))]}" in "#"*) return 0 ;; *) return 1 ;; esac
    }
    _cb_is_disabled() {
        case "${_cb_labels[$(($1 - 1))]}" in "!"*) return 0 ;; *) return 1 ;; esac
    }
    _cb_step() { # _cb_step <dir:+1|-1> — move the cursor, skipping headers/disabled
        _cb_steps=0
        while [ "$_cb_steps" -lt "$_cb_n" ]; do
            _cb_cur=$((_cb_cur + $1))
            [ "$_cb_cur" -lt 1 ] && _cb_cur=$_cb_n
            [ "$_cb_cur" -gt "$_cb_n" ] && _cb_cur=1
            if ! _cb_is_header "$_cb_cur" && ! _cb_is_disabled "$_cb_cur"; then
                return 0
            fi
            _cb_steps=$((_cb_steps + 1))
        done
    }
    _cb_cur=0
    _cb_step 1                                            # first selectable row

    # Publish the checkable rows for the group helpers: a select-all must skip
    # headers and disabled rows, and an all-children rule must not wait on them.
    _UI_CHECKBOX_SELECTABLE=""
    _cb_i=1
    while [ "$_cb_i" -le "$_cb_n" ]; do
        if ! _cb_is_header "$_cb_i" && ! _cb_is_disabled "$_cb_i"; then
            _UI_CHECKBOX_SELECTABLE="${_UI_CHECKBOX_SELECTABLE:+$_UI_CHECKBOX_SELECTABLE }$_cb_i"
        fi
        _cb_i=$((_cb_i + 1))
    done

    # The keyboard hint has to describe what the keys actually DO. On an
    # either/or menu — exactly two selectable rows, one of them exclusive —
    # Space does not toggle anything a reader would call a toggle: it moves the
    # tick from one answer to the other, which is choosing. "Toggle" invited
    # people to switch both off (Enter then silently refuses, because at least
    # one selection is required) or to read two answers to one question as two
    # independent switches. A real multi-select keeps "toggle", which is exactly
    # what Space does there.
    #
    # Derived from the menu's shape rather than set per call site, so a new
    # either/or menu gets the right hint without anyone remembering to ask.
    _cb_sel_n=0
    for _cb_s in $_UI_CHECKBOX_SELECTABLE; do _cb_sel_n=$((_cb_sel_n + 1)); done
    if [ -n "${EXAKIT_CHECKBOX_EXCLUSIVE:-}" ] && [ "$_cb_sel_n" -eq 2 ]; then
        _cb_space='Space to select'
    else
        _cb_space='Space to toggle'
    fi

    _cb_tty="$(_exakit_prompt_tty)"
    if [ -z "$_cb_tty" ]; then
        EXAKIT_CHECKBOX_SELECTION="$_cb_defaults"
        EXAKIT_CHECKBOX_EXCLUSIVE=""
        EXAKIT_CHECKBOX_GROUP=""
        _UI_CHECKBOX_SELECTABLE=""
        _cb_i=1
        for _cb_label in "$@"; do
            case ",$_cb_defaults," in *",$_cb_i,"*) ok "$_cb_label (selected by default)" ;; esac
            _cb_i=$((_cb_i + 1))
        done
        return 0
    fi
    # Checked mark: the palette tick in fancy mode; plain "x" otherwise (the
    # plain-palette tick is the multi-char "[ok]", which would double-bracket).
    if [ "${UI_FANCY:-0}" = 1 ]; then _cb_mark="${UI_TICK:-x}"; else _cb_mark="x"; fi
    _cb_first=1
    _cb_drawn=0
    while :; do
        if [ "$_cb_first" -ne 1 ] && [ "$UI_FANCY" = 1 ]; then
            # Up by the lines the LAST frame really occupied, not by the row
            # count: a label wider than the terminal wraps onto a second line,
            # and moving up one-per-row would leave every frame's overflow
            # behind (the stale rows stack with each keypress).
            printf '\033[%dA\033[0J' "$_cb_drawn"
        fi
        _cb_first=0
        _cb_cols="$(_ui_term_cols)"
        _cb_drawn=0
        _cb_i=1
        for _cb_label in "$@"; do
            if _cb_is_header "$_cb_i"; then
                _cb_text="$(_ui_fit_row "${_cb_label#\#}" 4 "$_cb_cols")"
                printf '    %s%s%s\n' "${UI_ACCENT:-}" "$_cb_text" "${UI_RESET:-}"
                _cb_drawn=$((_cb_drawn + $(_ui_wrapped_lines $((4 + ${#_cb_text})) "$_cb_cols")))
                _cb_i=$((_cb_i + 1))
                continue
            fi
            if _cb_is_disabled "$_cb_i"; then
                _cb_text="$(_ui_fit_row "${_cb_label#\!}" 10 "$_cb_cols")"
                printf '      %s[ ] %s%s\n' "${UI_DIM:-}" "$_cb_text" "${UI_RESET:-}"
                _cb_drawn=$((_cb_drawn + $(_ui_wrapped_lines $((10 + ${#_cb_text})) "$_cb_cols")))
                _cb_i=$((_cb_i + 1))
                continue
            fi
            if [ "$_cb_i" -eq "$_cb_cur" ]; then
                if [ "${UI_FANCY:-0}" = 1 ]; then _cb_ptr="${UI_ACCENT:-}❯${UI_RESET:-}"; else _cb_ptr=">"; fi
            else
                _cb_ptr=" "
            fi
            # Chrome: four leading spaces, the pointer, a space, and the
            # checkbox. The CHECKED box is "[<mark>] " whose mark is a palette
            # glyph of ANY width ("✓" is one column, the plain "[ok]" is four),
            # so the chrome is computed from the mark, not assumed — a row is
            # truncated against the wider of its two states, or toggling it
            # would change how many lines it occupies.
            _cb_chrome=$((9 + ${#_cb_mark}))
            [ "$_cb_chrome" -lt 10 ] && _cb_chrome=10
            _cb_text="$(_ui_fit_row "$_cb_label" "$_cb_chrome" "$_cb_cols")"
            case ",$_cb_sel," in
                *",$_cb_i,"*)
                    printf '    %s %s[%s]%s %s\n' \
                        "$_cb_ptr" "${UI_OK:-}" "$_cb_mark" "${UI_RESET:-}" "$_cb_text"
                    ;;
                *)
                    printf '    %s [ ] %s\n' "$_cb_ptr" "$_cb_text"
                    ;;
            esac
            _cb_drawn=$((_cb_drawn + $(_ui_wrapped_lines $((_cb_chrome + ${#_cb_text})) "$_cb_cols")))
            _cb_i=$((_cb_i + 1))
        done
        _cb_hint="$(_ui_fit_row "↑/↓ to move · $_cb_space · Enter to confirm" 6 "$_cb_cols")"
        ui_menu_hint "$_cb_hint"
        _cb_drawn=$((_cb_drawn + $(_ui_wrapped_lines $((6 + ${#_cb_hint})) "$_cb_cols")))
        # One raw keypress, no echo. Enter arrives as an empty read; IFS= keeps
        # a Space keypress from being stripped to an empty string.
        if [ "$_cb_tty" = "/dev/tty" ]; then
            IFS= read -rsn1 _cb_key < /dev/tty || { _cb_sel="$_cb_defaults"; break; }
        else
            IFS= read -rsn1 _cb_key || { _cb_sel="$_cb_defaults"; break; }
        fi
        case "$_cb_key" in
            "")                                          # Enter → confirm, next step
                [ -n "$_cb_sel" ] && break
                continue                                 # at least one selection required
                ;;
            " ")                                         # Space → toggle highlighted
                _cb_sel="$(_ui_checkbox_toggle "$_cb_sel" "$_cb_n" "$_cb_cur")"
                _cb_sel="$(_ui_checkbox_apply_group "$_cb_sel" "$_cb_cur" "$EXAKIT_CHECKBOX_GROUP")"
                _cb_sel="$(_ui_checkbox_apply_exclusive "$_cb_sel" "$_cb_cur" "$EXAKIT_CHECKBOX_EXCLUSIVE")"
                ;;
            "$(printf '\033')")                          # arrows: ESC [ A / ESC [ B
                if [ "$_cb_tty" = "/dev/tty" ]; then
                    IFS= read -rsn2 -t 1 _cb_seq < /dev/tty || _cb_seq=""
                else
                    IFS= read -rsn2 -t 1 _cb_seq || _cb_seq=""
                fi
                case "$_cb_seq" in
                    '[A') _cb_step -1 ;;
                    '[B') _cb_step 1 ;;
                esac
                ;;
            k|K) _cb_step -1 ;;
            j|J) _cb_step 1 ;;
            a|A)
                # "all" means all real choices: never headers, never disabled
                # rows, never the exclusive option.
                _cb_sel=""
                _cb_i=1
                while [ "$_cb_i" -le "$_cb_n" ]; do
                    if ! _cb_is_header "$_cb_i" && ! _cb_is_disabled "$_cb_i" && [ "$_cb_i" != "$EXAKIT_CHECKBOX_EXCLUSIVE" ]; then
                        _cb_sel="${_cb_sel:+$_cb_sel,}$_cb_i"
                    fi
                    _cb_i=$((_cb_i + 1))
                done
                ;;
        esac
    done
    EXAKIT_CHECKBOX_SELECTION="$(printf '%s' "$_cb_sel" | tr ',' '\n' | sort -n | paste -sd, -)"
    EXAKIT_CHECKBOX_EXCLUSIVE=""
    EXAKIT_CHECKBOX_GROUP=""
    _UI_CHECKBOX_SELECTABLE=""
    return 0
}

# exakit_copy_clipboard — best-effort: stdin -> the system clipboard, across
# macOS (pbcopy), Wayland (wl-copy), X11 (xclip/xsel), and WSL (clip.exe).
# Returns 1 when no clipboard tool is available.
exakit_copy_clipboard() {
    if command -v pbcopy >/dev/null 2>&1; then pbcopy
    elif command -v wl-copy >/dev/null 2>&1; then wl-copy
    elif command -v xclip >/dev/null 2>&1; then xclip -selection clipboard
    elif command -v xsel >/dev/null 2>&1; then xsel --clipboard --input
    elif command -v clip.exe >/dev/null 2>&1; then clip.exe
    else
        return 1
    fi
}

# --- containing third-party output ------------------------------------------
# We can style only our own lines; a tool we invoke (e.g. the Exasol launcher)
# prints whatever it likes. Rather than let that blend into our output, frame it:
# foreign_note prints a dim marker line, and exakit_stream_foreign pipes a
# command's output through a dim, indented gutter so it reads as "not ours" —
# while the full, unmodified text still goes to the log.
foreign_note() { printf '      %s%s %s%s\n' "${UI_DIM:-}" "${UI_HR:--}" "$*" "${UI_RESET:-}"; }
exakit_stream_foreign() {
    while IFS= read -r _sf_line || [ -n "$_sf_line" ]; do
        [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_sf_line" >> "$EXAKIT_LOG_FILE"
        printf '      %s%s %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$_sf_line" "${UI_RESET:-}"
    done
}

# Sensitive temp files (they hold plaintext credentials) are tracked here so
# they are ALWAYS removed — including on die/exit/interrupt, not only on the
# happy path. Callers register the file right after creating it; die() and the
# EXIT handler both sweep, so no failure path can leave credentials on disk.
EXAKIT_SENSITIVE_TMP=""
exakit_track_sensitive_tmp() { EXAKIT_SENSITIVE_TMP="$EXAKIT_SENSITIVE_TMP $1"; }
exakit_sweep_sensitive_tmp() {
    [ -n "${EXAKIT_SENSITIVE_TMP:-}" ] || return 0
    rm -f $EXAKIT_SENSITIVE_TMP 2>/dev/null
    EXAKIT_SENSITIVE_TMP=""
}

# --- failure notes ----------------------------------------------------------
# A step that fails is run inside a subshell (see exakit_soft_step), so it
# cannot hand its reason back in a shell variable — the subshell's exports die
# with it. The reason goes to a file instead, which is the one channel that
# crosses that boundary, and the closing summary reads it back so it can say
# WHY a component is missing instead of only that it is.
exakit_failure_note_file() {
    printf '%s\n' "${EXAKIT_FAILURE_NOTE:-$EXAKIT_HOME/.last-failure}"
}

# exakit_note_failure <reason> — record why the step now running gave up.
# Never fails: a note is a nicety, and losing it must not turn a soft failure
# into a hard one.
exakit_note_failure() {
    _nf_file="$(exakit_failure_note_file)"
    [ -d "$(dirname "$_nf_file")" ] || return 0
    # Line 1 stays the reason, byte for byte: every existing reader takes
    # `head -n 1`. Line 2 is when it happened, because a note with no date
    # cannot be told from a current one -- and an undated note that outlived its
    # cause is exactly how a healthy machine came to look broken.
    { printf '%s\n%s\n' "$*" "$(_exakit_ts)" > "$_nf_file"; } 2>/dev/null || true
    return 0
}

# exakit_take_failure_note — print the pending reason and clear it, so the next
# step cannot inherit the previous one's explanation.
exakit_take_failure_note() {
    _tf_file="$(exakit_failure_note_file)"
    [ -f "$_tf_file" ] || return 0
    head -n 1 "$_tf_file" 2>/dev/null
    rm -f "$_tf_file" 2>/dev/null
    return 0
}

exakit_clear_failure_note() {
    rm -f "$(exakit_failure_note_file)" 2>/dev/null
    return 0
}

# reject <message> — refuse BAD INPUT and stop, without recording a failure note.
#
# The distinction matters to `exakit status --json`, which surfaces the note as
# `last_failure` — a field meant for "a step of your install did not finish". A
# rejected SQL statement is not that: it is the user (or the agent) being told to
# type something else, and recording it left a stale "failure" hanging off an
# otherwise healthy machine until something else overwrote it. Exit 2, the same
# code an unknown subcommand uses, because both mean "your input was wrong".
reject() {
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" "$*" "${UI_RESET:-}" >&2
    _exakit_log_file "REJECT $*"
    exit 2
}

# Fatal error, rendered as a small "card": a prominent ✗ header, then a dim
# gutter line pointing at the log — consistent shape for every failure.
die() {
    exakit_sweep_sensitive_tmp
    # A table is animating and this is the inside of one of its subshells:
    # printing here would land in a frame that is still being repainted, and the
    # animator's next cursor-up would clear the message away with it. Leave the
    # reason in a file and let the shell that owns the table say it once the
    # table has stopped -- the same reason row state lives in a file.
    if [ -n "${EXAKIT_DEFER_ERRORS:-}" ]; then
        exakit_note_failure "$*"
        printf 'fatal|%s\n' "$*" >> "$EXAKIT_DEFER_ERRORS" 2>/dev/null
        _exakit_log_file "FATAL $*"
        exit 1
    fi
    # Nothing is deferring: stop any animation first, or the message below is
    # wiped off the screen by the next frame before anyone can read it.
    command -v ui_animation_stop >/dev/null 2>&1 && ui_animation_stop
    exakit_note_failure "$*"
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" "$*" "${UI_RESET:-}" >&2
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf '    %s%s Log: %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$EXAKIT_LOG_FILE" "${UI_RESET:-}" >&2
    fi
    _exakit_log_file "FATAL $*"
    exit 1
}

# Run a command, sending its output to the log file only. While it runs (and
# only on an interactive terminal), show a spinner labelled with the current
# step — this is the single hook that animates every silent, long-running
# operation. run_logged never reads stdin, so the spinner is always safe;
# interactive prompts use a separate /dev/tty path and are untouched.
# exakit_explain_db_error <text> — the error-translation layer for the three
# database faults every agent and every new user hits first. The engine's own
# messages are precise but remedy-free ("Connection refused", "syntax error,
# unexpected FETCH_", "object X not found"); each match here appends the one
# line that names the fix. Callers pass whatever output they captured; unknown
# errors print nothing extra, so this can never make a message worse.
exakit_explain_db_error() {
    case "$1" in
        *"onnection refused"*|*"Errno 61"*|*"Errno 111"*|*"could not connect"*|*"Could not connect"*)
            warn "That is the database not answering — it is stopped or unreachable. Start it with: exakit start (then check: exakit status)"
            ;;
    esac
    case "$1" in
        *"unexpected FETCH_"*|*"unexpected TOP_"*|*"FETCH FIRST"*)
            warn "Exasol pages result sets with LIMIT <n> (optionally OFFSET) — not FETCH FIRST or TOP. Rewrite the query with LIMIT."
            ;;
    esac
    case "$1" in
        *"not found"*)
            case "$1" in
                *object*|*table*|*column*|*schema*|*view*)
                    warn "A named object does not exist as written. Check the spelling and the schema qualifier — describe it first (MCP: describe_exasol_table_or_view; SQL: DESCRIBE <schema>.<table>)."
                    ;;
            esac
            ;;
    esac
    # A write refused for lack of privilege is the read-only guardrail doing its
    # job, and the tempting next move — re-run it through `exapump -p
    # starter-kit`, which connects as admin — is the one thing that breaks the
    # trust model. Say so where the error appears, not only in the docs.
    case "$1" in
        *"insufficient privileges"*|*"42500"*)
            warn "That write was refused by the DATABASE: the MCP user is read-only by design, and this is the guardrail working as intended."
            warn "Do NOT re-run it through 'exapump -p starter-kit' — that profile is the ADMIN user and is not sandboxed. If a write is genuinely wanted, say so and let the user decide."
            ;;
    esac
    return 0
}

# exakit_explain_uv_python_error <text> — the managed-Python fault that makes a
# component install fail for a reason no component can fix. uv caches its own
# CPython builds; a truncated or partially-written cache entry answers every
# `uv venv --python <ver>` with an unparseable response, so the component's own
# remedy ("retry this command") loops forever while the actual repair — one uv
# command — is never named. The cause is always in the log; this puts the fix
# next to it.
exakit_explain_last_log_error() {
    # run_logged sends command output to the logfile, not to a variable, so the
    # only place a failed step's real cause exists is the tail of that file.
    [ -n "${EXAKIT_LOG_FILE:-}" ] && [ -r "${EXAKIT_LOG_FILE:-}" ] || return 0
    _elle_tail="$(tail -n 25 "$EXAKIT_LOG_FILE" 2>/dev/null || true)"
    [ -n "$_elle_tail" ] || return 0
    exakit_explain_uv_python_error "$_elle_tail"
    return 0
}

exakit_explain_uv_python_error() {
    case "$1" in
        *"returned an invalid response"*|*"EOF while parsing"*|*"Querying Python at"*)
            warn "That is uv's managed Python installation being corrupt, not a fault in this component — retrying the same command will fail identically."
            warn "Repair it first:  uv python install ${EXAKIT_MANAGED_PYTHON_VERSION:-3.12} --reinstall"
            ;;
    esac
    return 0
}

run_logged() {
    _exakit_log_file "CMD   $*"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-working}"
        "$@" >> "$EXAKIT_LOG_FILE" 2>&1
        _run_logged_rc=$?
        ui_spin_end
        return $_run_logged_rc
    else
        "$@"
    fi
}

# Ask a yes/no question. Reads from /dev/tty so it works when the script
# itself is piped (curl | bash). Non-interactive runs take the default.
# usage: confirm "Question?" [y|n]
confirm() {
    _question="$1"
    _default="${2:-y}"
    # A usable tty is one we can actually open, not one that merely exists.
    _tty="$(_exakit_prompt_tty)"
    if [ -z "$_tty" ]; then
        [ "$_default" = "y" ]
        return
    fi
    if [ "$_default" = "y" ]; then _hint="[Y/n]"; else _hint="[y/N]"; fi
    printf '    %s?%s %s %s%s%s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" "${UI_DIM:-}" "$_hint" "${UI_RESET:-}"
    if [ "$_tty" = "/dev/tty" ]; then read -r _answer < /dev/tty; else read -r _answer; fi
    _answer="${_answer:-$_default}"
    case "$_answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# Like confirm(), but an environment variable can pre-answer the question so an
# agent-driven or scripted install (no tty) honours the user's choice instead of
# silently taking the default. usage: confirm_env VAR "Question?" [y|n]
#   VAR = 1|y|yes  -> yes, skip the prompt
#   VAR = 0|n|no   -> no,  skip the prompt
#   VAR unset/other-> fall back to confirm() (tty prompt, else the default)
confirm_env() {
    _ce_var="$1"
    _ce_question="$2"
    _ce_default="${3:-y}"
    _ce_val="${!_ce_var:-}"
    case "$_ce_val" in
        1|y|Y|yes|YES|Yes) return 0 ;;
        0|n|N|no|NO|No)    return 1 ;;
        *) confirm "$_ce_question" "$_ce_default" ;;
    esac
}

_exakit_prompt_tty() {
    if [ -t 0 ]; then
        printf 'stdin\n'
    elif (: < /dev/tty) 2>/dev/null; then
        printf '/dev/tty\n'
    fi
}

prompt_text() {
    _question="$1"
    _default="${2:-}"
    _tty="$(_exakit_prompt_tty)"
    if [ -z "$_tty" ]; then
        printf '%s\n' "$_default"
        return 0
    fi
    if [ -n "$_default" ]; then
        printf '    %s?%s %s %s[%s]%s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" "${UI_DIM:-}" "$_default" "${UI_RESET:-}" >&2
    else
        printf '    %s?%s %s ' "${UI_ASK:-}" "${UI_RESET:-}" "$_question" >&2
    fi
    if [ "$_tty" = "/dev/tty" ]; then read -r _answer < /dev/tty; else read -r _answer; fi
    printf '%s\n' "${_answer:-$_default}"
}

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------
require_python3() {
    _exakit_has_system_python3 && return 0
    exakit_ensure_uv || die "A Python runtime is required, and the automatic uv bootstrap failed."
}

# Minimum Python for the kit's own tooling. 3.11 is the floor because the MCP
# client-config code parses TOML via the stdlib's tomllib (added in 3.11); an
# older system interpreter (macOS ships 3.9) made MCP client setup fail during
# install. The PowerShell twin (Test-ExakitSystemPythonForMcp) applies the
# same gate.
EXAKIT_MIN_PYTHON="3.11"
_EXAKIT_SYSTEM_PY_OK=""

# A system python3 is usable only when it exists AND meets the version floor;
# anything less is treated exactly like an absent interpreter, so the
# uv-managed runtime takes over automatically. The probe spawns an interpreter,
# so its verdict is cached — run_python funnels through here on every call.
_exakit_has_system_python3() {
    [ "${EXAKIT_DISABLE_SYSTEM_PYTHON:-0}" != "1" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    if [ -z "$_EXAKIT_SYSTEM_PY_OK" ]; then
        if python3 -c "import sys; req = tuple(map(int, '$EXAKIT_MIN_PYTHON'.split('.'))); raise SystemExit(0 if sys.version_info[:2] >= req else 1)" 2>/dev/null; then
            _EXAKIT_SYSTEM_PY_OK="yes"
        else
            _EXAKIT_SYSTEM_PY_OK="no"
            _exakit_log_file "INFO  system python3 is older than $EXAKIT_MIN_PYTHON — using the uv-managed Python runtime instead"
        fi
    fi
    [ "$_EXAKIT_SYSTEM_PY_OK" = "yes" ]
}

exakit_ensure_uv() {
    if [ -n "${EXAKIT_UV_BIN:-}" ] && [ -x "$EXAKIT_UV_BIN" ]; then
        return 0
    fi
    if command -v uv >/dev/null 2>&1; then
        EXAKIT_UV_BIN="$(command -v uv)"
        return 0
    fi
    if [ -x "$EXAKIT_BIN_DIR/uv" ]; then
        EXAKIT_UV_BIN="$EXAKIT_BIN_DIR/uv"
        return 0
    fi
    info "Installing the managed Python bootstrapper (uv)"
    mkdir -p "$EXAKIT_BIN_DIR"
    if command -v curl >/dev/null 2>&1; then
        env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh -c \
            'curl -LsSf https://astral.sh/uv/install.sh | sh' >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 1
    elif command -v wget >/dev/null 2>&1; then
        env UV_NO_MODIFY_PATH=1 INSTALLER_NO_MODIFY_PATH=1 sh -c \
            'wget -qO- https://astral.sh/uv/install.sh | sh' >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || return 1
    else
        warn "Neither curl nor wget is available to install uv."
        return 1
    fi
    if [ -x "$EXAKIT_BIN_DIR/uv" ]; then
        EXAKIT_UV_BIN="$EXAKIT_BIN_DIR/uv"
        ok "uv installed at $EXAKIT_UV_BIN"
        return 0
    fi
    warn "uv installation finished but the binary was not found in $EXAKIT_BIN_DIR."
    return 1
}

run_python() {
    if _exakit_has_system_python3; then
        python3 "$@"
        return $?
    fi
    exakit_ensure_uv || return 1
    "$EXAKIT_UV_BIN" run --python "$EXAKIT_MANAGED_PYTHON_VERSION" --no-project python "$@"
}

# Optional Python for best-effort flows (latest-version checks, digest lookup).
# Unlike require_python3, this never exits: callers can fall back to shell
# parsing or report "unknown" instead of failing a status/version command.
exakit_can_run_python() {
    _exakit_has_system_python3 && return 0
    exakit_ensure_uv >/dev/null 2>&1
}

manifest_init() {
    mkdir -p "$EXAKIT_HOME"
    # The home the skills tell an agent to write into, created with the home
    # itself rather than left for the agent to invent. Cheap, idempotent, and it
    # runs on every install AND every re-run, so an older install grows the
    # directory the moment the installer touches it again.
    mkdir -p "$EXAKIT_WORKFLOWS_DIR" 2>/dev/null || true
    if [ -f "$EXAKIT_MANIFEST" ]; then
        # Self-heal after an interrupted run: a manifest that no longer
        # parses is quarantined and rebuilt. Each install step re-verifies
        # what actually exists on disk, so nothing is reinstalled blindly.
        if run_python -c 'import json,sys; json.load(open(sys.argv[1]))' "$EXAKIT_MANIFEST" 2>/dev/null; then
            return 0
        fi
        warn "The install manifest is corrupted (interrupted run?) — rebuilding it; existing components will be re-detected"
        mv "$EXAKIT_MANIFEST" "$EXAKIT_MANIFEST.corrupt-$(date +%s)"
    fi
    cat > "$EXAKIT_MANIFEST" <<EOF
{
  "manifest_version": 1,
  "kit_level": 1,
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "os": "",
  "arch": "",
  "runtime": {},
  "components": {},
  "data": {
    "loaded": false
  },
  "steps_completed": [],
  "log_dir": "$EXAKIT_LOG_DIR"
}
EOF
    chmod 600 "$EXAKIT_MANIFEST"
    _exakit_log_file "INFO  Initialized manifest at $EXAKIT_MANIFEST"
}

# manifest_set <dot.path> <value>
# Value is stored as JSON if it parses as JSON, otherwise as a string.
manifest_set() {
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$1" "$2" <<'PY' || die "Failed to update manifest ($1)"
import fcntl, json, os, sys, tempfile

def _exakit_locked(path):
    """Serialise the read-modify-write. Without this, concurrent writers each
    read the same document, apply their own key, and the last one to finish
    wins -- silently discarding every other update. Measured before this lock:
    17 of 20 concurrent writes lost, and every one of 30 rounds lost at least
    one. Two kit processes at once is not hypothetical: `exakit start` brings up
    the database and every service, autostart can fire one at boot while
    another runs, and an agent may issue two commands in parallel."""
    lock_path = path + ".lock"
    handle = open(lock_path, "a+")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle

def _exakit_write(path, doc):
    """Unique temp name, not a fixed one: two writers sharing path + '.tmp'
    can interleave inside it, and the loser's os.replace can then publish a
    half-written document."""
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle, indent=2)
            handle.write("\n")
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
_lock = _exakit_locked(path)
with open(path) as f:
    doc = json.load(f)
node = doc
parts = key.split(".")
for part in parts[:-1]:
    node = node.setdefault(part, {})
try:
    node[parts[-1]] = json.loads(value)
except json.JSONDecodeError:
    node[parts[-1]] = value
_exakit_write(path, doc)
PY
}

# manifest_set_many — apply several boolean flags in ONE locked read-modify-write,
# reading "<dot.path>=true|false" lines on stdin. Writes only when at least one
# key actually changes, so a caller can offer it every observation without
# rewriting the file each time.
#
# Exists for `exakit status`, which now verifies the loaded datasets against the
# database and heals the flags it finds wrong. Doing that one manifest_set at a
# time meant six python processes on a command agents poll constantly; the whole
# heal is one process now. Never fatal: healing bookkeeping must not fail a
# status read.
manifest_set_many() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    exakit_can_run_python || return 0
    run_python - "$EXAKIT_MANIFEST" <<'PY' 2>/dev/null || true
import fcntl, json, os, sys, tempfile

path = sys.argv[1]
wanted = []
for line in sys.stdin.read().splitlines():
    if "=" not in line:
        continue
    key, _, value = line.partition("=")
    key = key.strip()
    if key:
        wanted.append((key, value.strip() == "true"))
if not wanted:
    sys.exit(0)

lock = open(path + ".lock", "a+")
fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
try:
    with open(path) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(0)

changed = False
for key, value in wanted:
    node = doc
    parts = key.split(".")
    for part in parts[:-1]:
        nxt = node.get(part)
        if not isinstance(nxt, dict):
            nxt = {}
            node[part] = nxt
        node = nxt
    if node.get(parts[-1]) != value:
        node[parts[-1]] = value
        changed = True
if not changed:
    sys.exit(0)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                          prefix=os.path.basename(path) + ".")
try:
    with os.fdopen(fd, "w") as handle:
        json.dump(doc, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    return 0
}

# manifest_get <dot.path> — prints the value; exits non-zero if missing.
manifest_get() {
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY'
import json, sys
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        doc = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(1)
node = doc
for part in key.split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(1)
print(node if isinstance(node, str) else json.dumps(node))
PY
}

# manifest_get_many <dot.path>... - read SEVERAL keys in ONE python process.
#
# manifest_get starts a fresh interpreter per key. That is fine for one lookup
# and expensive for a panel: six keys out of the same file measured at ~53ms
# each, ~890ms in total, which is the pause a user feels after pressing enter
# on `exakit info`. One interpreter start for the whole set is ~60ms.
#
# Prints one line per key, IN THE ORDER ASKED, so callers can read them
# positionally. A missing key prints an EMPTY LINE rather than failing - a
# caller wanting six values must still get six lines, and every existing
# caller of manifest_get already treats "absent" as "unknown". That is the one
# behavioural difference from manifest_get, which exits non-zero instead.
#
# Values are assumed not to contain newlines. Every manifest value read this
# way is a DSN, a username or a path; if that ever stops being true, this is
# the line-oriented assumption that breaks.
manifest_get_many() {
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$@" <<'PY'
import json, sys
path, keys = sys.argv[1], sys.argv[2:]
try:
    with open(path) as f:
        doc = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    doc = {}
MISSING = object()
for key in keys:
    node = doc
    for part in key.split("."):
        if isinstance(node, dict) and part in node:
            node = node[part]
        else:
            node = MISSING
            break
    if node is MISSING:
        print("")
    else:
        print(node if isinstance(node, str) else json.dumps(node))
PY
}

# manifest_del <dot.path> — remove a key (and everything under it) from the
# manifest. Silent when the key is already absent; a partial uninstall must
# not fail over bookkeeping.
manifest_del() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY' || warn "Could not update the manifest ($1)"
import fcntl, json, os, sys, tempfile

# Same lock + atomic-write pair as manifest_set (see there for the measurements):
# an unlocked read-modify-write silently discards concurrent updates, and a
# shared "<path>.tmp" lets two writers interleave inside it.
def _exakit_locked(path):
    handle = open(path + ".lock", "a+")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle

def _exakit_write(path, doc):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

path, key = sys.argv[1], sys.argv[2]
_lock = _exakit_locked(path)
with open(path) as f:
    doc = json.load(f)
node = doc
parts = key.split(".")
for part in parts[:-1]:
    if not (isinstance(node, dict) and part in node):
        sys.exit(0)
    node = node[part]
if isinstance(node, dict):
    node.pop(parts[-1], None)
_exakit_write(path, doc)
PY
}

# exakit_unmark_step <step> — drop a step flag so a re-run of the installer
# reinstalls what a partial uninstall removed.
exakit_unmark_step() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY' || warn "Could not update the manifest (steps_completed)"
import fcntl, json, os, sys, tempfile

# Same lock + atomic-write pair as manifest_set (see there for the measurements):
# an unlocked read-modify-write silently discards concurrent updates, and a
# shared "<path>.tmp" lets two writers interleave inside it.
def _exakit_locked(path):
    handle = open(path + ".lock", "a+")
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle

def _exakit_write(path, doc):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".",
                               prefix=os.path.basename(path) + ".")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(doc, handle, indent=2)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise

path, step = sys.argv[1], sys.argv[2]
_lock = _exakit_locked(path)
with open(path) as f:
    doc = json.load(f)
steps = doc.get("steps_completed")
if isinstance(steps, list) and step in steps:
    doc["steps_completed"] = [s for s in steps if s != step]
    _exakit_write(path, doc)
PY
}

# ---------------------------------------------------------------------------
# Versions manifest (versions.json)
# ---------------------------------------------------------------------------
# One document answers one question: "which version of each Component is the
# current tested set?". Maintainers edit it via pull request; clients read it.
# Nothing here may ever fail a command — every reader degrades along the chain
#
#   fresh fetch  ->  cached copy (any age)  ->  copy baked into the kit  ->  the
#   *_FALLBACK constants above
#
# so an offline machine, a rate-limited network, or a hand-mangled cache all
# end up with a usable answer instead of an error.
#
# The document's formatting is an interface, not a style choice: canonical
# 2-space pretty-print, one key per line, LF endings, and "version" before any
# nested object inside a block. That is what lets the no-Python fallback below
# read it with awk, and it is enforced by CI on every edit.
#
# ⇄ twin: the Get-ExakitVersions* / Update-ExakitVersionsCache set in
# setup/lib/exakit-common.ps1.
_EXAKIT_VERSIONS_DOC=""
_EXAKIT_VERSIONS_SOURCE=""
_EXAKIT_VERSIONS_SCHEMA_AHEAD=0

# _exakit_json_leaves <file> [dot.path] — scalar reader for the canonical form
# described above: prints "<dot.path><TAB><value>" for every scalar, or just the
# value of one path when asked. Indentation is the nesting depth (two spaces per
# level, one key per line), so no real parser is needed. Used only when there is
# no Python runtime at all — Python stays the primary path everywhere.
_exakit_json_leaves() {
    awk -v want="${2:-}" '
        {
            n = match($0, /[^ ]/)
            if (n == 0) next
            depth = int((n - 1) / 2)
            if (depth < 1) next
            rest = substr($0, n)
            if (!match(rest, /^"[^"]*" *:/)) next
            key = substr(rest, 1, RLENGTH)
            val = substr(rest, RLENGTH + 1)
            sub(/^"/, "", key)
            sub(/" *:$/, "", key)
            keys[depth] = key
            sub(/^ +/, "", val)
            if (val == "" || val == "{" || val == "[") next
            if (substr(val, 1, 1) == "\"") {
                sub(/",$/, "\"", val)
                val = substr(val, 2, length(val) - 2)
            } else {
                sub(/,$/, "", val)
            }
            path = keys[1]
            for (i = 2; i <= depth; i++) path = path "." keys[i]
            if (want != "") {
                if (path == want) { print val; exit }
                next
            }
            print path "\t" val
        }
    ' "$1"
}

# exakit_versions_validate <file> — the gate every document passes before it is
# trusted. Rejects anything that does not parse, announces a schema this kit
# cannot read, or carries a version/digest outside the safe charset (advertised
# versions are interpolated into download URLs and command lines).
exakit_versions_validate() {
    _vv_file="$1"
    [ -f "$_vv_file" ] && [ -s "$_vv_file" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_vv_file" "$EXAKIT_VERSIONS_SCHEMA" <<'PY' 2>/dev/null
import json, re, sys

path, schema = sys.argv[1], int(sys.argv[2])
try:
    with open(path) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
announced = doc.get("schema_version")
if announced != schema:
    # Exit 2 = "readable, but newer than this kit" so the caller can hint at
    # updating instead of reporting a broken document.
    sys.exit(2 if isinstance(announced, int) and announced > schema else 1)

version_re = re.compile(r"^[A-Za-z0-9._+-]+$")
digest_re = re.compile(r"^[0-9a-f]{64}$")


def check_block(block):
    if not isinstance(block, dict):
        sys.exit(1)
    version = block.get("version")
    if not isinstance(version, str) or not version_re.match(version):
        sys.exit(1)
    min_kit = block.get("min_kit_version")
    if min_kit is not None and (not isinstance(min_kit, str) or not version_re.match(min_kit)):
        sys.exit(1)
    digests = block.get("sha256")
    if digests is not None:
        if not isinstance(digests, dict) or not digests:
            sys.exit(1)
        for value in digests.values():
            if not isinstance(value, str) or not digest_re.match(value):
                sys.exit(1)


kit = doc.get("kit")
if not isinstance(kit, dict):
    sys.exit(1)
check_block(kit)
components = doc.get("components")
if not isinstance(components, dict) or not components:
    sys.exit(1)
for block in components.values():
    check_block(block)
# Optional and additive: absent until the first Kit 2 assets ship.
if doc.get("kit2") is not None:
    check_block(doc["kit2"])
PY
        _vv_rc=$?
        [ "$_vv_rc" -eq 2 ] && _EXAKIT_VERSIONS_SCHEMA_AHEAD=1
        [ "$_vv_rc" -eq 0 ] || _exakit_log_file "WARN  versions manifest rejected ($_vv_file, code $_vv_rc)"
        return $_vv_rc
    fi
    _exakit_versions_validate_shell "$_vv_file"
}

# No-Python fallback for the gate above: shape check plus a charset sweep over
# every scalar the kit would actually use.
_exakit_versions_validate_shell() {
    _vs_file="$1"
    case "$(sed -n '1p' "$_vs_file" | tr -d '\r')" in
        '{') ;;
        *) return 1 ;;
    esac
    _vs_schema="$(_exakit_json_leaves "$_vs_file" schema_version)"
    if [ "$_vs_schema" != "$EXAKIT_VERSIONS_SCHEMA" ]; then
        case "$_vs_schema" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$_vs_schema" -gt "$EXAKIT_VERSIONS_SCHEMA" ] || return 1
        _EXAKIT_VERSIONS_SCHEMA_AHEAD=1
        return 2
    fi
    _vs_kit="$(_exakit_json_leaves "$_vs_file" kit.version)"
    [ -n "$_vs_kit" ] || return 1
    _vs_seen_version=0
    while IFS="$(printf '\t')" read -r _vs_path _vs_value; do
        [ -n "$_vs_path" ] || continue
        case "$_vs_path" in
            *.sha256.*)
                case "$_vs_value" in
                    *[!0-9a-f]*|'') return 1 ;;
                esac
                [ "${#_vs_value}" -eq 64 ] || return 1
                ;;
            *version)
                # Covers kit.version, every components.*.version and any
                # min_kit_version; schema_version is the document's own integer.
                case "$_vs_path" in schema_version) continue ;; esac
                case "$_vs_value" in
                    ''|*[!A-Za-z0-9._+-]*) return 1 ;;
                esac
                _vs_seen_version=1
                ;;
        esac
    done <<EOF
$(_exakit_json_leaves "$_vs_file")
EOF
    [ "$_vs_seen_version" -eq 1 ]
}

# exakit_versions_baked_doc — the copy that shipped inside the installed kit.
# It is the last stop before the compiled-in fallbacks, and it is what makes an
# offline machine still agree with the release it installed.
exakit_versions_baked_doc() {
    _vb_root="$(exakit_repo_root 2>/dev/null || true)"
    [ -n "$_vb_root" ] || return 1
    [ -f "$_vb_root/versions.json" ] || return 1
    printf '%s\n' "$_vb_root/versions.json"
}

# exakit_format_local_time <utc-iso> — a manifest timestamp rendered for a human:
# "May 3, 2026 at 5:30 PM", in the machine's own timezone. The manifest keeps UTC
# ISO 8601 (machine-readable state must not move); only the display changes.
# Falls back to the raw value, because an awkward timestamp beats none at all.
# TWIN: Format-ExakitLocalTime in setup/lib/exakit-common.ps1.
exakit_format_local_time() {
    _flt_raw="$1"
    [ -n "$_flt_raw" ] || return 0
    if exakit_can_run_python; then
        _flt_out="$(
            run_python - "$_flt_raw" 2>/dev/null <<'PY'
import sys
from datetime import datetime, timezone

raw = sys.argv[1].strip()
try:
    stamp = datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
except ValueError:
    raise SystemExit(1)
local = stamp.astimezone()
# Assembled by hand rather than with %-d/%-I: those are platform extensions and
# are not available everywhere this kit runs.
hour = local.strftime("%I").lstrip("0") or "12"
print("%s %d, %d at %s:%s" % (local.strftime("%B"), local.day, local.year,
                              hour, local.strftime("%M %p")))
PY
        )"
        if [ -n "$_flt_out" ]; then
            printf '%s\n' "$_flt_out"
            return 0
        fi
    fi
    printf '%s\n' "$_flt_raw"
}

# exakit_format_manifest_date <YYYY-MM-DD> — "2026-07-29" -> "July 29, 2026".
#
# The manifest's "updated" is a calendar date, not an instant, so it must NOT be
# converted to local time: a machine west of UTC would render the day before.
# That also rules out date(1), whose parsing flags differ between BSD and GNU.
# Pure shell instead — the shape is fixed (the CI schema check enforces
# YYYY-MM-DD), and a date is not worth a Python spawn. Anything not of that shape
# is passed through untouched rather than guessed at.
exakit_format_manifest_date() {
    _fmd_raw="$1"
    [ -n "$_fmd_raw" ] || return 0
    _fmd_year="${_fmd_raw%%-*}"
    _fmd_rest="${_fmd_raw#*-}"
    _fmd_month="${_fmd_rest%%-*}"
    _fmd_day="${_fmd_rest#*-}"
    case "${_fmd_year}${_fmd_month}${_fmd_day}" in
        ""|*[!0-9]*) printf '%s\n' "$_fmd_raw"; return 0 ;;
    esac
    case "$_fmd_month" in
        01) _fmd_name="January"   ;; 02) _fmd_name="February" ;;
        03) _fmd_name="March"     ;; 04) _fmd_name="April"    ;;
        05) _fmd_name="May"       ;; 06) _fmd_name="June"     ;;
        07) _fmd_name="July"      ;; 08) _fmd_name="August"   ;;
        09) _fmd_name="September" ;; 10) _fmd_name="October"  ;;
        11) _fmd_name="November"  ;; 12) _fmd_name="December" ;;
        *)  printf '%s\n' "$_fmd_raw"; return 0 ;;
    esac
    # Drop a leading zero for the day: "July 9", not "July 09".
    _fmd_day="${_fmd_day#0}"
    [ -n "$_fmd_day" ] || _fmd_day="0"
    printf '%s %s, %s\n' "$_fmd_name" "$_fmd_day" "$_fmd_year"
}

# exakit_kit_version_at <kit-root> [dot.path] — a version a specific kit tree
# states about itself: kit.version by default, kit2.version for the Kit 2 asset
# bundle. The installers use it on the tree they are installing FROM, which is not
# necessarily the copy under the kit home (that one may be an older install).
exakit_kit_version_at() {
    _kva_doc="$1/versions.json"
    _kva_path="${2:-kit.version}"
    [ -f "$_kva_doc" ] || return 1
    _kva_version="$(exakit_versions_value "$_kva_path" "$_kva_doc" 2>/dev/null || true)"
    case "$_kva_version" in
        ''|*[!A-Za-z0-9._+-]*) return 1 ;;
    esac
    printf '%s\n' "$_kva_version"
}

# exakit_kit_bundled_version — kit.version as recorded by the kit copy on disk.
# This is what "installed" means for the kit itself; the manifest's kit.source
# only says where the copy came from.
exakit_kit_bundled_version() {
    _kbv_root="$(exakit_repo_root 2>/dev/null)" || return 1
    exakit_kit_version_at "$_kbv_root"
}

# exakit_kit2_bundled_version — the version of the Kit 2 asset bundle this kit
# ships. Kit 2 assets travel INSIDE the kit tarball, so the bundle's version is a
# property of the kit copy on disk, not of anything installed separately.
exakit_kit2_bundled_version() {
    _k2b_root="$(exakit_repo_root 2>/dev/null)" || return 1
    exakit_kit_version_at "$_k2b_root" kit2.version
}

exakit_versions_user_agent() {
    _ua_kit="$(exakit_kit_bundled_version 2>/dev/null || true)"
    [ -n "$_ua_kit" ] || _ua_kit="unknown"
    if command -v detect_os >/dev/null 2>&1; then
        _ua_os="$(detect_os 2>/dev/null || true)"
        _ua_arch="$(detect_arch 2>/dev/null || true)"
    else
        _ua_os="$(uname -s 2>/dev/null || true)"
        _ua_arch="$(uname -m 2>/dev/null || true)"
    fi
    printf 'exakit-update-check/%s (%s; %s)\n' "$_ua_kit" "${_ua_os:-unknown}" "${_ua_arch:-unknown}"
}

_exakit_file_mtime() {
    case "$(uname -s 2>/dev/null || true)" in
        Darwin|*BSD*) stat -f %m "$1" 2>/dev/null ;;
        *)            stat -c %Y "$1" 2>/dev/null ;;
    esac
}

# exakit_versions_cache_age — seconds since the cached copy was written.
exakit_versions_cache_age() {
    [ -f "$EXAKIT_VERSIONS_CACHE" ] || return 1
    _vca_mtime="$(_exakit_file_mtime "$EXAKIT_VERSIONS_CACHE")"
    case "$_vca_mtime" in
        ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' "$(( $(date +%s) - _vca_mtime ))"
}

exakit_versions_cache_fresh() {
    _vcf_age="$(exakit_versions_cache_age 2>/dev/null)" || return 1
    case "$EXAKIT_VERSIONS_TTL" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_vcf_age" -lt "$EXAKIT_VERSIONS_TTL" ]
}

# _exakit_versions_attempt_recent — did we already fail to fetch, recently?
#
# WITHOUT THIS, AN UNREACHABLE MANIFEST TAXES EVERY COMMAND. A failed fetch
# writes nothing, so the cache never becomes fresh, so the next command tries
# again and pays the full connect timeout again — and so does the one after
# that. Measured on a corporate network where raw.githubusercontent.com is
# filtered: `exakit status` 12.7s and `exakit version` 19.3s, essentially all
# of it one timing-out request repeated on every invocation.
#
# The About cache has had this since it was written ("an .attempt- stamp so a
# failure is not retried on every run"); the versions cache never got the same
# treatment. Same idea: a stamp written BEFORE the request, so the question
# counts as asked whatever the answer turns out to be.
# ⇄ twin: Test-ExakitVersionsAttemptRecent in exakit-common.ps1.
_exakit_versions_attempt_stamp() {
    printf '%s/.%s.attempt\n' "$(dirname "$EXAKIT_VERSIONS_CACHE")" "$(basename "$EXAKIT_VERSIONS_CACHE")"
}

_exakit_versions_attempt_recent() {
    # TTL 0 means "always ask", and a caller who says that must not be answered
    # from a remembered failure. The cooldown is a cheaper form of the same
    # caching the TTL does, so it can never outlive it.
    case "$EXAKIT_VERSIONS_TTL" in
        0) return 1 ;;
    esac
    _var_stamp="$(_exakit_versions_attempt_stamp)"
    [ -f "$_var_stamp" ] || return 1
    case "$EXAKIT_VERSIONS_RETRY_COOLDOWN" in
        ''|*[!0-9]*) return 1 ;;
    esac
    _var_now="$(date +%s 2>/dev/null)" || return 1
    _var_mtime="$(_exakit_file_mtime "$_var_stamp" 2>/dev/null)" || return 1
    [ -n "$_var_mtime" ] || return 1
    [ "$(( _var_now - _var_mtime ))" -lt "$EXAKIT_VERSIONS_RETRY_COOLDOWN" ]
}

# exakit_versions_update_cache [force] — refresh the cached document.
# Skips the network while the cache is younger than the TTL; "force" is for the
# explicit `exakit version`, which should always ask upstream.
# Returns 0 when a validated document was installed, 2 when the fetch was
# skipped as unnecessary, 1 when nothing could be fetched.
#
# A failed or invalid download never touches the cache: the temporary file lives
# in the cache directory (same filesystem) and only a validated document is
# moved into place, so a reader can never observe a half-written file.
exakit_versions_update_cache() {
    _vu_force="${1:-}"
    case "$EXAKIT_VERSIONS_URL" in
        https://*) ;;
        *)
            _exakit_log_file "WARN  refusing to fetch the versions manifest over a non-HTTPS URL"
            return 1
            ;;
    esac
    if [ "$_vu_force" != "force" ] && exakit_versions_cache_fresh; then
        return 2
    fi
    # A recent failure counts as answered: see _exakit_versions_attempt_recent.
    if [ "$_vu_force" != "force" ] && _exakit_versions_attempt_recent; then
        return 2
    fi
    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$(dirname "$EXAKIT_VERSIONS_CACHE")" 2>/dev/null || return 1
    # Written BEFORE the request, so a timeout or a kill still records that the
    # question was asked.
    : > "$(_exakit_versions_attempt_stamp)" 2>/dev/null || true
    _vu_tmp="$EXAKIT_VERSIONS_CACHE.tmp.$$"
    if ! curl -fsSL --proto '=https' --retry 1 \
            --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" \
            --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
            -A "$(exakit_versions_user_agent)" \
            -o "$_vu_tmp" "$EXAKIT_VERSIONS_URL" 2>/dev/null; then
        rm -f "$_vu_tmp"
        _exakit_log_file "INFO  versions manifest fetch failed — keeping the cached copy"
        return 1
    fi
    if ! exakit_versions_validate "$_vu_tmp"; then
        rm -f "$_vu_tmp"
        _exakit_log_file "WARN  fetched versions manifest did not validate — keeping the cached copy"
        return 1
    fi
    mv -f "$_vu_tmp" "$EXAKIT_VERSIONS_CACHE" 2>/dev/null || {
        rm -f "$_vu_tmp"
        return 1
    }
    _EXAKIT_VERSIONS_DOC="$EXAKIT_VERSIONS_CACHE"
    _EXAKIT_VERSIONS_SOURCE="fetched"
    _exakit_log_file "INFO  versions manifest refreshed from $EXAKIT_VERSIONS_URL"
    return 0
}

# exakit_versions_resolve_doc — pick the document to read and remember it in
# _EXAKIT_VERSIONS_DOC/_SOURCE. Callers that read several values should call
# this once first: command substitutions inherit the memo, so the validation
# gate runs once per command instead of once per lookup.
exakit_versions_resolve_doc() {
    [ -n "$_EXAKIT_VERSIONS_DOC" ] && return 0
    # The cache is written only after validation, but anything under the kit
    # home can be edited by hand — re-check before trusting it.
    if [ -f "$EXAKIT_VERSIONS_CACHE" ] && exakit_versions_validate "$EXAKIT_VERSIONS_CACHE"; then
        _EXAKIT_VERSIONS_DOC="$EXAKIT_VERSIONS_CACHE"
        [ -n "$_EXAKIT_VERSIONS_SOURCE" ] || _EXAKIT_VERSIONS_SOURCE="cache"
        return 0
    fi
    _vr_baked="$(exakit_versions_baked_doc 2>/dev/null || true)"
    if [ -n "$_vr_baked" ] && exakit_versions_validate "$_vr_baked"; then
        _EXAKIT_VERSIONS_DOC="$_vr_baked"
        _EXAKIT_VERSIONS_SOURCE="baked"
        return 0
    fi
    _EXAKIT_VERSIONS_SOURCE="fallback"
    return 1
}

exakit_versions_active_doc() {
    exakit_versions_resolve_doc || return 1
    printf '%s\n' "$_EXAKIT_VERSIONS_DOC"
}

# exakit_versions_source — where the answers came from: fetched | cache | baked
# | fallback. Shown by `exakit version` and recorded as desired.versions_source.
exakit_versions_source() {
    [ -n "$_EXAKIT_VERSIONS_SOURCE" ] || exakit_versions_resolve_doc >/dev/null 2>&1 || true
    printf '%s\n' "${_EXAKIT_VERSIONS_SOURCE:-fallback}"
}

# exakit_versions_schema_ahead — true when a document was readable JSON but
# announced a newer schema, so callers can suggest updating the kit.
exakit_versions_schema_ahead() {
    [ "$_EXAKIT_VERSIONS_SCHEMA_AHEAD" -eq 1 ]
}

# exakit_versions_value <dot.path> [file] — the advertised value, e.g.
#   exakit_versions_value components.exapump.version
#   exakit_versions_value components.exapump.sha256.macos-aarch64
# Non-zero exit means "not advertised" — never a failure to be propagated.
exakit_versions_value() {
    _vv_path="$1"
    _vv_doc="${2:-}"
    if [ -z "$_vv_doc" ]; then
        exakit_versions_resolve_doc || return 1
        _vv_doc="$_EXAKIT_VERSIONS_DOC"
    fi
    [ -f "$_vv_doc" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_vv_doc" "$_vv_path" <<'PY' 2>/dev/null
import json, sys

try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
node = doc
for part in sys.argv[2].split("."):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        sys.exit(1)
print(node if isinstance(node, str) else json.dumps(node))
PY
        return $?
    fi
    _vv_out="$(_exakit_json_leaves "$_vv_doc" "$_vv_path")"
    [ -n "$_vv_out" ] || return 1
    printf '%s\n' "$_vv_out"
}

# ---------------------------------------------------------------------------
# Version resolution and update planning
# ---------------------------------------------------------------------------
# The installed runtime version, read from the runtime itself with the record as
# the fallback. Deliberately different from exapump and pyexasol in one way: a probe
# that cannot answer NEVER reports absence here. A stopped container engine (or a
# closed Docker Desktop) is an ordinary, temporary state, and flipping the runtime
# row to "inspect" every time would be noise. Whether the runtime exists at all is
# `exakit status`'s question, and it asks the engine directly.

# exakit_run_bounded <seconds> <command> [args...] — run a command and give up on
# it after <seconds>, exiting 124 if it had to be cut off.
#
# `docker info` and `docker container inspect` do not return while Docker Desktop
# is still starting, so an unbounded probe turns `exakit version` and
# `exakit version` into commands that print nothing at all for as long as the
# engine takes. Reading a version is never worth that wait: the probes fall back to
# the recorded value, which is exactly what they do when the engine is stopped.
#
# timeout(1) is not on a stock macOS and gtimeout only arrives with coreutils, so
# both are used when present and otherwise the command runs in the background and
# is polled. SIGTERM first, then SIGKILL for a client that ignores it.
exakit_run_bounded() {
    _rb_limit="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_rb_limit" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$_rb_limit" "$@"
        return $?
    fi
    "$@" &
    _rb_pid=$!
    _rb_waited=0
    while [ "$_rb_waited" -lt "$_rb_limit" ]; do
        if ! kill -0 "$_rb_pid" 2>/dev/null; then
            wait "$_rb_pid"
            return $?
        fi
        sleep 1
        _rb_waited=$((_rb_waited + 1))
    done
    kill -TERM "$_rb_pid" 2>/dev/null
    sleep 1
    kill -KILL "$_rb_pid" 2>/dev/null
    wait "$_rb_pid" 2>/dev/null
    return 124
}

# exakit_installed_nano_tag — the tag on the container IS the installed version.
# Needs runtime-nano.sh for the engine and container name.
exakit_installed_nano_tag() {
    _int_live=""
    if command -v nano_engine >/dev/null 2>&1; then
        # The container is not always called exasol-nano; nano_resolve_names reads the
        # recorded name, and without it this probe silently failed on every install
        # that used a custom one (PowerShell has always resolved it).
        command -v nano_resolve_names >/dev/null 2>&1 && nano_resolve_names 2>/dev/null
        _int_engine="$(nano_engine 2>/dev/null || true)"
        if [ -n "$_int_engine" ] && [ "$_int_engine" != "none" ]; then
            _int_image="$(exakit_run_bounded "${EXAKIT_ENGINE_PROBE_TIMEOUT:-8}" \
                "$_int_engine" container inspect -f '{{.Config.Image}}' \
                "${EXAKIT_NANO_CONTAINER:-exasol-nano}" 2>/dev/null | head -1)"
            case "$_int_image" in
                *:*) _int_live="${_int_image##*:}" ;;
            esac
        fi
    fi
    if [ -n "$_int_live" ]; then
        printf '%s\n' "$_int_live"
        return 0
    fi
    _int_recorded="$(manifest_get runtime.image 2>/dev/null || true)"
    [ -n "$_int_recorded" ] || return 1
    printf '%s\n' "${_int_recorded##*:}"
}

# exakit_installed_personal_version — the RECORD, deliberately.
#
# `exasol version` reports the launcher, and the launcher is a different axis from the
# runtime: personal_update --apply installs a new launcher but leaves runtime.version
# alone until the data migration is finished (it records runtime.launcher_version and
# says so). Substituting the launcher version here made `exakit version` call a half-done
# major upgrade "current" and hid the outstanding migration, while personal_update kept
# offering it — the two commands disagreeing about one install.
exakit_installed_personal_version() {
    manifest_get runtime.version 2>/dev/null
}

exakit_installation_runtime_type() {
    manifest_get runtime.type 2>/dev/null
}

# exakit_runtime_is_running — one question, no side effects: is the installed
# database runtime up right now? The pure check that `exakit status` branches
# its exit code on and `exakit mcp-doctor` consults BEFORE any operation that
# needs a live database — so a stopped database is diagnosed as exactly that,
# never as whatever downstream step happened to fail first.
exakit_runtime_is_running() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        nano)
            command -v nano_status >/dev/null 2>&1 || return 1
            [ "$(nano_status 2>/dev/null)" = "running" ]
            ;;
        personal)
            command -v personal_deployment_running >/dev/null 2>&1 || return 1
            personal_deployment_running 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

# exakit_runtime_remedy — the command that actually fixes a database which is not
# running right now. ONE definition, because every place that reports the state
# also has to report the fix, and they must not drift: `exakit start` is right for
# a stopped database and wrong for an interrupted one, where it fails identically
# every time it is tried.
# ⇄ twin: Get-ExakitRuntimeRemedy in setup/exakit.ps1.
exakit_runtime_remedy() {
    if command -v personal_deployment_wedged >/dev/null 2>&1 && \
       personal_deployment_wedged >/dev/null 2>&1; then
        printf 'exakit repair-runtime\n'
    else
        printf 'exakit start\n'
    fi
}

# exakit_loaded_datasets — the bundled datasets that are loaded, one id per
# line. This is what `exakit status` answers "what data is in there?" with, so
# it has to be true and not merely recorded.
#
# THE DATABASE IS ASKED FIRST. The manifest alone reported three loaded datasets
# against a database with zero schemas after a destroy+redeploy — the worst
# possible answer for an agent rebuilding its bearings after a context reset,
# because it sends it straight into "object TPCH.LINEITEM not found" with the
# real cause (no data) recorded nowhere. exakit_verified_datasets checks the
# marker tables and heals the flags; it lives in exapump.sh, which the CLI loads
# conditionally, and it declines when the database is unreachable. Either way
# the manifest read below is the fallback, never the first answer.
exakit_loaded_datasets() {
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    if command -v exakit_verified_datasets >/dev/null 2>&1; then
        _eld_verified="$(exakit_verified_datasets 2>/dev/null)" && {
            [ -n "$_eld_verified" ] && printf '%s\n' "$_eld_verified"
            return 0
        }
    fi
    exakit_can_run_python || return 0
    run_python - "$EXAKIT_MANIFEST" <<'EXAKIT_LD_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except Exception:
    sys.exit(0)
datasets = ((doc.get("data") or {}).get("datasets")) or {}
for name in sorted(datasets):
    if isinstance(datasets[name], dict) and datasets[name].get("loaded"):
        print(name)
EXAKIT_LD_PY
    return 0
}

exakit_installation_runtime_version() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        nano)     exakit_installed_nano_tag ;;
        personal) exakit_installed_personal_version ;;
        *) return 1 ;;
    esac
}

exakit_record_desired_versions() {
    manifest_set version_policy "$EXAKIT_VERSION_POLICY"
    manifest_set desired.versions_source "${EXAKIT_VERSIONS_SOURCE_USED:-unknown}"
    manifest_set desired.runtime.personal "$EXAKIT_PERSONAL_VERSION"
    manifest_set desired.runtime.nano "$EXAKIT_NANO_TAG"
    manifest_set desired.exapump "$EXAKIT_EXAPUMP_VERSION"
    manifest_set desired.mcp "$EXAKIT_MCP_VERSION"
    manifest_set desired.pyexasol "$EXAKIT_PYEXASOL_VERSION"
}

exakit_update_actual_target() {
    case "$1" in
        runtime|database|db)
            _rtype="$(exakit_installation_runtime_type 2>/dev/null || true)"
            [ -n "$_rtype" ] || return 1
            printf '%s\n' "$_rtype"
            ;;
        *) printf '%s\n' "$1" ;;
    esac
}

exakit_latest_github_release_version() {
    _repo="$1"
    _json="$(curl -fsSL --retry 1 --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        "https://api.github.com/repos/${_repo}/releases/latest" 2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c 'import json,sys; print(json.load(sys.stdin).get("tag_name","").lstrip("v"))' 2>/dev/null
        return $?
    fi
    printf '%s' "$_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"v\{0,1\}\([^"]*\)".*/\1/p' | head -1
}

exakit_latest_pypi_version() {
    _package="$1"
    _json="$(curl -fsSL --retry 1 --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        "https://pypi.org/pypi/${_package}/json" 2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c 'import json,sys; print(json.load(sys.stdin).get("info",{}).get("version",""))' 2>/dev/null
        return $?
    fi
    printf '%s' "$_json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Normalise the host CPU to a docker image arch token: amd64 | arm64 | "".
_exakit_docker_arch() {
    case "$(uname -m)" in
        arm64|aarch64) echo arm64 ;;
        x86_64|amd64)  echo amd64 ;;
        *) echo "" ;;
    esac
}

exakit_latest_docker_tag() {
    _image="$1"
    # Pick the newest tag that fits THIS machine's architecture. Exasol Nano
    # publishes arch-suffixed tags (…-arm64, …-amd64) next to the plain
    # multi-arch tag; without filtering, the version sort lands on -arm64 (it
    # sorts after -amd64), so an x86_64 host would pull an arm64 image and run
    # it under slow emulation. Keep the plain (multi-arch) tags plus this
    # host's own arch, and drop the other architecture's tags.
    _dt_arch="$(_exakit_docker_arch)"
    _json="$(curl -fsSL --retry 1 --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        "https://hub.docker.com/v2/repositories/${_image}/tags?page_size=100&ordering=last_updated" 2>/dev/null || true)"
    [ -n "$_json" ] || return 1
    if exakit_can_run_python; then
        printf '%s' "$_json" | run_python -c '
import json, re, sys
doc = json.load(sys.stdin)
arch = sys.argv[1] if len(sys.argv) > 1 else ""
tags = [r.get("name","") for r in doc.get("results", [])]
pattern = re.compile(r"^\d+(?:\.\d+)+(?:[-._A-Za-z0-9]+)?$")
amd = {"amd64", "x86_64", "x86-64"}
arm = {"arm64", "aarch64"}
wrong = arm if arch in amd else (amd if arch in arm else set())
def ok_arch(tag):
    return not any(seg in wrong for seg in re.split(r"[-._]", tag.lower()))
candidates = [t for t in tags if pattern.match(t) and "latest" not in t.lower() and ok_arch(t)]
def key(tag):
    parts = re.split(r"([0-9]+)", tag)
    return [int(p) if p.isdigit() else p for p in parts]
print(sorted(candidates, key=key)[-1] if candidates else "")
' "$_dt_arch" 2>/dev/null
        return $?
    fi
    # Shell fallback (no Python/uv): Docker Hub returns newest-first with
    # ordering=last_updated. Drop the other architecture's suffixed tags, then
    # take the newest of what remains.
    _dt_reject=""
    case "$_dt_arch" in
        amd64) _dt_reject='[-._](arm64|aarch64)$' ;;
        arm64) _dt_reject='[-._](amd64|x86_64|x86-64)$' ;;
    esac
    _dt_names="$(printf '%s' "$_json" | tr ',' '\n' | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | \
        grep -E '^[0-9]+(\.[0-9]+)+[-._A-Za-z0-9]*$' | grep -vi latest)"
    [ -n "$_dt_reject" ] && _dt_names="$(printf '%s\n' "$_dt_names" | grep -viE "$_dt_reject")"
    printf '%s\n' "$_dt_names" | head -1
}

# exakit_version_newer <a> <b> — true when <a> sorts after <b>.
# The _vn_ prefix matters: bash 3.2 has no function-local variables here, and
# callers hold their own state in names like _current/_latest while asking this
# question (sometimes with the arguments the other way round, to detect a
# rollback). Anything less specific would silently overwrite the caller's data.
exakit_version_newer() {
    _vn_a="$1"
    _vn_b="$2"
    [ -n "$_vn_a" ] && [ -n "$_vn_b" ] || return 1
    [ "$_vn_a" != "$_vn_b" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_vn_a" "$_vn_b" <<'PY'
import re, sys
def key(v):
    v = v.strip().lstrip("v")
    return [int(p) if p.isdigit() else p for p in re.split(r"([0-9]+)", v)]
sys.exit(0 if key(sys.argv[1]) > key(sys.argv[2]) else 1)
PY
        return $?
    fi
    _vn_a_major="$(exakit_major_version "$_vn_a")"
    _vn_b_major="$(exakit_major_version "$_vn_b")"
    case "$_vn_a_major$_vn_b_major" in *[!0-9]*) return 1 ;; esac
    if [ "$_vn_a_major" -gt "$_vn_b_major" ]; then return 0; fi
    if [ "$_vn_a_major" -lt "$_vn_b_major" ]; then return 1; fi
    # Same major and no Python/uv: treat different tags as worth inspecting,
    # but avoid claiming a downgrade is newer when the major clearly regressed.
    [ "$_vn_a" != "$_vn_b" ]
}

exakit_major_version() {
    printf '%s\n' "$1" | sed -E 's/^v//; s/^([0-9]+).*/\1/'
}

# exakit_resolve_install_versions — decide which version of each Component this
# install gets. An explicit env override (EXAKIT_*_VERSION / EXAKIT_NANO_TAG)
# always wins; the policy decides where the rest comes from. Resolution never
# fails: each tier degrades into the next, and the recorded
# desired.versions_source says which one answered.
exakit_resolve_install_versions() {
    case "${EXAKIT_VERSION_POLICY:-manifest}" in
        latest)   _exakit_resolve_versions_latest ;;
        manifest) _exakit_resolve_versions_manifest ;;
        *)        _exakit_resolve_versions_pinned ;;
    esac
    export EXAKIT_PERSONAL_VERSION EXAKIT_NANO_TAG EXAKIT_EXAPUMP_VERSION EXAKIT_MCP_VERSION EXAKIT_PYEXASOL_VERSION
    [ -f "$EXAKIT_MANIFEST" ] && exakit_record_desired_versions
    return 0
}

# The versions manifest: one TTL-gated fetch, then read. A fresh install picks up
# the currently advertised set; an offline one silently uses the cached copy, the
# copy that shipped with this kit, or the constants above.
_exakit_resolve_versions_manifest() {
    exakit_versions_update_cache >/dev/null 2>&1 || true
    # Resolve once in THIS shell so the command substitutions below inherit the
    # decision instead of re-validating the document for every lookup.
    exakit_versions_resolve_doc >/dev/null 2>&1 || true
    EXAKIT_VERSIONS_SOURCE_USED="${_EXAKIT_VERSIONS_SOURCE:-fallback}"
    _exakit_resolve_one EXAKIT_PERSONAL_VERSION components.personal.version "$EXAKIT_PERSONAL_VERSION_FALLBACK"
    _exakit_resolve_one EXAKIT_NANO_TAG components.nano.version "$EXAKIT_NANO_TAG_FALLBACK"
    _exakit_resolve_one EXAKIT_EXAPUMP_VERSION components.exapump.version "$EXAKIT_EXAPUMP_VERSION_FALLBACK"
    _exakit_resolve_one EXAKIT_MCP_VERSION components.mcp.version "$EXAKIT_MCP_VERSION_FALLBACK"
    _exakit_resolve_one EXAKIT_PYEXASOL_VERSION components.pyexasol.version "$EXAKIT_PYEXASOL_VERSION_FALLBACK"
    _exakit_log_file "INFO  versions resolved from the manifest ($EXAKIT_VERSIONS_SOURCE_USED)"
}

# _exakit_resolve_one <var-name> <dot.path> <fallback> — fill <var-name> unless
# it already carries an env override. bash 3.2 has no namerefs, so eval does the
# assignment; the value is charset-checked by the validation gate before it ever
# reaches this point.
_exakit_resolve_one() {
    eval "_ro_current=\${$1:-}"
    [ -z "$_ro_current" ] || return 0
    _ro_value="$(exakit_versions_value "$2" 2>/dev/null || true)"
    [ -n "$_ro_value" ] || _ro_value="$3"
    eval "$1=\$_ro_value"
}

# Today's live-lookup behaviour, kept intact as the escape hatch for anyone who
# wants the newest of every Component rather than the tested set.
_exakit_resolve_versions_latest() {
    EXAKIT_VERSIONS_SOURCE_USED="latest"
    if [ -z "$EXAKIT_PERSONAL_VERSION" ]; then
        EXAKIT_PERSONAL_VERSION="$(exakit_latest_github_release_version "$EXAKIT_PERSONAL_REPO" || true)"
        [ -n "$EXAKIT_PERSONAL_VERSION" ] || EXAKIT_PERSONAL_VERSION="$EXAKIT_PERSONAL_VERSION_FALLBACK"
    fi
    if [ -z "$EXAKIT_NANO_TAG" ]; then
        EXAKIT_NANO_TAG="$(exakit_latest_docker_tag "$EXAKIT_NANO_IMAGE" || true)"
        [ -n "$EXAKIT_NANO_TAG" ] || EXAKIT_NANO_TAG="$EXAKIT_NANO_TAG_FALLBACK"
    fi
    if [ -z "$EXAKIT_EXAPUMP_VERSION" ]; then
        EXAKIT_EXAPUMP_VERSION="$(exakit_latest_github_release_version "$EXAKIT_EXAPUMP_REPO" || true)"
        [ -n "$EXAKIT_EXAPUMP_VERSION" ] || EXAKIT_EXAPUMP_VERSION="$EXAKIT_EXAPUMP_VERSION_FALLBACK"
    fi
    if [ -z "$EXAKIT_MCP_VERSION" ]; then
        EXAKIT_MCP_VERSION="$(exakit_latest_pypi_version "$EXAKIT_MCP_PACKAGE" || true)"
        [ -n "$EXAKIT_MCP_VERSION" ] || EXAKIT_MCP_VERSION="$EXAKIT_MCP_VERSION_FALLBACK"
    fi
    if [ -z "$EXAKIT_PYEXASOL_VERSION" ]; then
        EXAKIT_PYEXASOL_VERSION="$(exakit_latest_pypi_version "${EXAKIT_PYEXASOL_PACKAGE:-pyexasol}" || true)"
        [ -n "$EXAKIT_PYEXASOL_VERSION" ] || EXAKIT_PYEXASOL_VERSION="$EXAKIT_PYEXASOL_VERSION_FALLBACK"
    fi
}

# No network at all: the last-known-good constants only.
_exakit_resolve_versions_pinned() {
    EXAKIT_VERSIONS_SOURCE_USED="fallback"
    EXAKIT_PERSONAL_VERSION="${EXAKIT_PERSONAL_VERSION:-$EXAKIT_PERSONAL_VERSION_FALLBACK}"
    EXAKIT_NANO_TAG="${EXAKIT_NANO_TAG:-$EXAKIT_NANO_TAG_FALLBACK}"
    EXAKIT_EXAPUMP_VERSION="${EXAKIT_EXAPUMP_VERSION:-$EXAKIT_EXAPUMP_VERSION_FALLBACK}"
    EXAKIT_MCP_VERSION="${EXAKIT_MCP_VERSION:-$EXAKIT_MCP_VERSION_FALLBACK}"
    EXAKIT_PYEXASOL_VERSION="${EXAKIT_PYEXASOL_VERSION:-$EXAKIT_PYEXASOL_VERSION_FALLBACK}"
}

# exakit_component_latest <component> — the newest version upstream publishes.
# The implementation behind EXAKIT_VERSION_POLICY=latest; under the default
# manifest policy nothing calls it, which is what keeps `exakit version` and the
# update notice off the network.
exakit_component_latest() {
    case "$1" in
        exakit)   exakit_latest_github_release_version "$EXAKIT_KIT_REPO" ;;
        exapump)  exakit_latest_github_release_version "$EXAKIT_EXAPUMP_REPO" ;;
        mcp)      exakit_latest_pypi_version "$EXAKIT_MCP_PACKAGE" ;;
        pyexasol) exakit_latest_pypi_version "${EXAKIT_PYEXASOL_PACKAGE:-pyexasol}" ;;
        nano)     exakit_latest_docker_tag "$EXAKIT_NANO_IMAGE" ;;
        personal) exakit_latest_github_release_version "$EXAKIT_PERSONAL_REPO" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                nano) exakit_component_latest nano ;;
                personal) exakit_component_latest personal ;;
                *) return 1 ;;
            esac
            ;;
        *)
            # Marketplace add-ons declare their upstream in versions.json:
            # repo -> a GitHub release, package -> PyPI. No per-add-on arm.
            _exakit_addon_registered "$1" || return 1
            # An add-on whose "latest" is neither of those answers for itself.
            # json-tables is the case this exists for: what is installable is
            # what the kit's packaging workflow has already built and
            # published, which is a stricter thing than what upstream tagged.
            _cl_fn="$(_exakit_addon_fn "$1" latest)"
            if command -v "$_cl_fn" >/dev/null 2>&1; then
                "$_cl_fn"
                return $?
            fi
            _cl_repo="$(exakit_versions_value "components.$1.repo" 2>/dev/null || true)"
            if [ -n "$_cl_repo" ]; then
                exakit_latest_github_release_version "$_cl_repo"
                return $?
            fi
            _cl_pkg="$(exakit_versions_value "components.$1.package" 2>/dev/null || true)"
            if [ -n "$_cl_pkg" ]; then
                exakit_latest_pypi_version "$_cl_pkg"
                return $?
            fi
            return 1
            ;;
    esac
}

# _exakit_component_block <component> — where this Component lives in
# versions.json. One mapping serves version, severity, note and min_kit_version.
_exakit_component_block() {
    case "$1" in
        exakit) printf '%s\n' kit ;;
        kit2)   printf '%s\n' kit2 ;;
        exapump|mcp|pyexasol|nano|personal) printf 'components.%s\n' "$1" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                nano)     printf '%s\n' components.nano ;;
                personal) printf '%s\n' components.personal ;;
                *) return 1 ;;
            esac
            ;;
        *)
            # Every marketplace add-on lives at components.<id> by convention.
            _exakit_addon_registered "$1" || return 1
            printf 'components.%s\n' "$1"
            ;;
    esac
}

# _exakit_component_env_override <component> — the version the user asked for by
# hand, if any. Same precedence as the install path: an explicit
# EXAKIT_*_VERSION / EXAKIT_NANO_TAG outranks the manifest and any upstream
# lookup, so `EXAKIT_EXAPUMP_VERSION=0.11.2 exakit update exapump` installs
# exactly that (still through the confirmation gate, and still verified — the
# digest chain falls back to the release API when the version is not the
# advertised one).
_exakit_component_env_override() {
    case "$1" in
        exapump)  printf '%s' "${EXAKIT_EXAPUMP_VERSION:-}" ;;
        mcp)      printf '%s' "${EXAKIT_MCP_VERSION:-}" ;;
        pyexasol) printf '%s' "${EXAKIT_PYEXASOL_VERSION:-}" ;;
        nano)     printf '%s' "${EXAKIT_NANO_TAG:-}" ;;
        personal) printf '%s' "${EXAKIT_PERSONAL_VERSION:-}" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                nano)     printf '%s' "${EXAKIT_NANO_TAG:-}" ;;
                personal) printf '%s' "${EXAKIT_PERSONAL_VERSION:-}" ;;
            esac
            ;;
        *)
            # Marketplace add-ons follow the derived-name convention:
            # EXAKIT_<ID>_VERSION with dashes flipped to underscores.
            if _exakit_addon_registered "$1"; then
                eval "printf '%s' \"\${$(_exakit_addon_env_var "$1" VERSION):-}\""
            fi
            ;;
    esac
}

# exakit_component_available <component> — the version this kit would install
# NOW, under the policy in force. That is the promise the Tagged column makes,
# so each policy answers from the same place its install path would:
#   env override  the version the user asked for
#   manifest      versions.json
#   latest        a live upstream lookup
#   anything else the compiled-in *_FALLBACK constant
# Empty output means "cannot tell" (no readable document), which the table reports
# as unknown rather than guessing.
# exakit_version_plain <version> — a version as the tables spell it: no leading
# "v".
#
# Upstreams disagree about the prefix. Most of what the kit reports is a bare
# number (0.1.0, 1.7.0, 2.2.0) because that is what its source says, but
# json-tables takes its version from a git tag and reported "v0.2" — one row in
# two tables wearing a prefix none of its neighbours wore, which reads as a
# different KIND of version rather than the same thing spelled differently.
#
# Normalised where versions are DISPLAYED, never where they are compared or
# stored: the tag is what it is, and nothing downstream should start guessing
# which spelling it is holding. Anything that is not a "v" followed by a digit
# is returned untouched, so a version legitimately starting with a letter
# (a codename, "vNext") keeps it.
exakit_version_plain() {
    case "$1" in
        v[0-9]*) printf '%s\n' "${1#v}" ;;
        *)       printf '%s\n' "$1" ;;
    esac
}

exakit_component_available() {
    _cav_override="$(_exakit_component_env_override "$1")"
    if [ -n "$_cav_override" ]; then
        printf '%s\n' "$_cav_override"
        return 0
    fi
    case "${EXAKIT_VERSION_POLICY:-manifest}" in
        latest)
            exakit_component_latest "$1"
            return $?
            ;;
        manifest) ;;
        *)
            _exakit_component_fallback "$1"
            return $?
            ;;
    esac
    _cav_block="$(_exakit_component_block "$1" 2>/dev/null)" || return 1
    _cav_value="$(exakit_versions_value "${_cav_block}.version" 2>/dev/null || true)"
    if [ -n "$_cav_value" ]; then
        printf '%s\n' "$_cav_value"
        return 0
    fi
    # A marketplace add-on can be newer than the published manifest (the kit
    # copy carrying it ships before the advertised set catches up): its
    # module's own fallback constant answers instead of "unknown" — the same
    # version the marketplace install would actually install.
    if _exakit_addon_registered "$1"; then
        _exakit_component_fallback "$1"
        return $?
    fi
    return 1
}

# The last-known-good constant for a Component: what a no-network install picks.
_exakit_component_fallback() {
    case "$1" in
        exapump)  printf '%s\n' "$EXAKIT_EXAPUMP_VERSION_FALLBACK" ;;
        mcp)      printf '%s\n' "$EXAKIT_MCP_VERSION_FALLBACK" ;;
        pyexasol) printf '%s\n' "$EXAKIT_PYEXASOL_VERSION_FALLBACK" ;;
        nano)     printf '%s\n' "$EXAKIT_NANO_TAG_FALLBACK" ;;
        personal) printf '%s\n' "$EXAKIT_PERSONAL_VERSION_FALLBACK" ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                nano)     printf '%s\n' "$EXAKIT_NANO_TAG_FALLBACK" ;;
                personal) printf '%s\n' "$EXAKIT_PERSONAL_VERSION_FALLBACK" ;;
                *) return 1 ;;
            esac
            ;;
        # The kit's own version is not one of the constants: it comes from the
        # copy on disk, which is exactly what is installed.
        exakit) exakit_kit_bundled_version ;;
        *)
            # Marketplace add-ons: EXAKIT_<ID>_VERSION_FALLBACK, defined by the
            # add-on's own module (empty when the module is not loaded).
            _exakit_addon_registered "$1" || return 1
            eval "_cf_value=\"\${$(_exakit_addon_env_var "$1" VERSION_FALLBACK):-}\""
            [ -n "$_cf_value" ] || return 1
            printf '%s\n' "$_cf_value"
            ;;
    esac
}

# The severity, note and min_kit_version below describe the ADVERTISED version of
# a Component. When the version on offer comes from somewhere else — a live
# upstream lookup under `latest`, the fallback constants, or the user's own env
# override — pairing it with the maintainers' commentary would be actively
# misleading ("0.12.0 is the tested build" next to an available 9.9.9).
_exakit_manifest_metadata_applies() {
    [ "${EXAKIT_VERSION_POLICY:-manifest}" = "manifest" ] || return 1
    [ -z "$(_exakit_component_env_override "$1")" ]
}

# exakit_component_severity <component> — normal | recommended | critical.
# Absent means normal; the value gates the after-command notice and is the only
# thing that makes a row stand out in the table.
exakit_component_severity() {
    _exakit_manifest_metadata_applies "$1" || { printf '%s\n' normal; return 0; }
    _cs_block="$(_exakit_component_block "$1" 2>/dev/null)" || { printf '%s\n' normal; return 0; }
    _cs_value="$(exakit_versions_value "${_cs_block}.severity" 2>/dev/null || true)"
    case "$_cs_value" in
        recommended|critical) printf '%s\n' "$_cs_value" ;;
        *) printf '%s\n' normal ;;
    esac
}

# exakit_component_note <component> — the maintainer's one-line note, if any.
exakit_component_note() {
    _exakit_manifest_metadata_applies "$1" || return 1
    _cn_block="$(_exakit_component_block "$1" 2>/dev/null)" || return 1
    exakit_versions_value "${_cn_block}.note"
}

# exakit_component_min_kit <component> — the kit version this Component needs.
exakit_component_min_kit() {
    _exakit_manifest_metadata_applies "$1" || return 1
    _cm_block="$(_exakit_component_block "$1" 2>/dev/null)" || return 1
    exakit_versions_value "${_cm_block}.min_kit_version"
}

# exakit_component_supported <component> — false when no build of it exists for THIS
# machine. The kit must never offer an update for something that cannot be installed
# here: exapump publishes binaries for x86_64 and arm64 on macOS and Linux, nothing for
# a CPU outside those, and nothing at all for Windows on ARM (see Get-ExapumpAssetName
# in exapump.ps1, and the installer's own $exapumpSupported gate).
# ⇄ twin: Test-ExakitComponentSupported in setup/exakit.ps1.
exakit_component_supported() {
    case "$1" in
        exapump)
            command -v detect_arch >/dev/null 2>&1 || return 0
            [ "$(detect_arch 2>/dev/null || true)" != "unsupported" ] || return 1
            return 0
            ;;
        *) return 0 ;;
    esac
}

# exakit_component_is_heavy <component> — true for changes that stop the
# database. Intrinsic to the Component, so it lives in code rather than in the
# manifest: the runtime is heavy, everything else is seconds of work.
exakit_component_is_heavy() {
    case "$1" in
        runtime|nano|personal) return 0 ;;
        *) return 1 ;;
    esac
}

# The manifest records what the kit INSTALLED. These two read what is actually on
# disk, because a user can upgrade pyexasol inside its venv or drop in a different
# exapump build from GitHub — and an update check that trusted the record would
# compare against a version nobody is running, then call it current.
#
# Only these two are probed live: they are the cheap ones (a binary that prints its
# version, an interpreter that already exists) and the ones a person can most
# easily change by hand. The MCP server would cost a uvx resolution, and the
# runtime's recorded version IS the launcher the kit installed, so both stay on the
# record.

# _exakit_probe_exapump_version <binary> — "exapump 0.11.2" -> "0.11.2". Empty when
# the binary will not run (a release built against a newer glibc, for instance).
_exakit_probe_exapump_version() {
    _pev_out="$("$1" --version </dev/null 2>/dev/null | head -1)"
    [ -n "$_pev_out" ] || return 0
    printf '%s' "$_pev_out" | grep -oE '[0-9]+\.[0-9]+[0-9A-Za-z._+-]*' | head -1
}

# _exakit_probe_pyexasol_version <venv-python> — asks the driver itself.
_exakit_probe_pyexasol_version() {
    # The subshell with `&& :` is the house pattern for this probe: on a guest that
    # advertises SVE its host cannot execute, the import dies on a signal, and this
    # keeps the shell's job-status noise out of the user's output.
    _ppv_out="$( ( "$1" -c 'import pyexasol; print(pyexasol.__version__)' </dev/null && : ) 2>/dev/null | head -1 )"
    case "$_ppv_out" in
        ''|*[!A-Za-z0-9._+-]*) return 0 ;;
    esac
    printf '%s' "$_ppv_out"
}

# exakit_installed_mcp_version — the MCP server is never "installed": uvx
# materialises it per launch. What exists on the machine is the SPEC pinned into each
# AI client config, and that is what will run the next time a client connects.
#
# The adapters own where those configs live, so the paths come from the kit's own
# status operation rather than from a second copy of that knowledge here. When the
# clients disagree — one set up before an update and never refreshed — the oldest pin
# is the answer here, and the per-client picture belongs to `exakit mcp-doctor`: it
# names each client whose managed entry is no longer the one the kit would write, and
# `exakit mcp-doctor` re-writes those entries from the current definition.
exakit_installed_mcp_version() {
    command -v exakit_run_mcp_operation_cli >/dev/null 2>&1 || return 1
    exakit_can_run_python || return 1
    _imv_result="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-pins.XXXXXX")"
    if ! exakit_run_mcp_operation_cli status \
            "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" \
            "$_imv_result" >/dev/null 2>&1; then
        rm -f "$_imv_result"
        return 1
    fi
    _imv_pins="$(run_python - "$_imv_result" 2>/dev/null <<'PY'
import json, re, sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
pins = set()
for artifact in doc.get("artifacts", []) or []:
    path = artifact.get("path")
    if not path:
        continue
    try:
        with open(path, encoding="utf-8") as handle:
            body = handle.read()
    except OSError:
        continue
    pins.update(re.findall(r"exasol-mcp-server@([0-9][0-9A-Za-z._+-]*)", body))
if not pins:
    raise SystemExit(1)


def key(v):
    return [int(p) if p.isdigit() else p for p in re.split(r"([0-9]+)", v)]


# The OLDEST pin, not the set: this value is compared against the advertised version,
# and a comma-joined list is not a version. The oldest is also the honest answer —
# it is the weakest link, the client that would launch the most outdated server.
# Which client is stale belongs to `exakit mcp-doctor`, which prints per-client state
# already. (No apostrophes in here: this heredoc sits inside a command substitution,
# and bash 3.2 mis-tracks a lone quote in that position.)
print(sorted(pins, key=key)[0])
PY
    )"
    rm -f "$_imv_result"
    [ -n "$_imv_pins" ] || return 1
    printf '%s\n' "$_imv_pins"
}

exakit_component_current() {
    case "$1" in
        exakit)
            # kit.version is written by the installer and by self-update; the
            # kit.source parse is the fallback for installs made before that.
            _cur_kit="$(manifest_get kit.version 2>/dev/null || true)"
            if [ -n "$_cur_kit" ]; then
                printf '%s\n' "$_cur_kit"
            else
                _src="$(manifest_get kit.source 2>/dev/null || true)"
                case "$_src" in
                    *@main) exakit_kit_bundled_version 2>/dev/null || printf '%s\n' "unknown" ;;
                    *@*)    printf '%s\n' "${_src##*@}" ;;
                    *)      exakit_kit_bundled_version 2>/dev/null || printf '%s\n' "unknown" ;;
                esac
            fi
            ;;
        exapump)
            _cur_bin="$(manifest_get components.exapump.path 2>/dev/null || true)"
            [ -n "$_cur_bin" ] && [ -x "$_cur_bin" ] || _cur_bin="$(command -v exapump 2>/dev/null || true)"
            # Provably absent beats a stale record: with no binary the table says
            # "not installed" and offers the reinstall, which is the useful answer.
            [ -n "$_cur_bin" ] && [ -x "$_cur_bin" ] || return 1
            _cur_live="$(_exakit_probe_exapump_version "$_cur_bin")"
            if [ -n "$_cur_live" ]; then
                printf '%s\n' "$_cur_live"
            else
                manifest_get components.exapump.version 2>/dev/null
            fi
            ;;
        mcp)
            # What the clients are pinned to is what will actually run; the record is
            # the fallback when no client is configured or the module is absent.
            _cur_live="$(exakit_installed_mcp_version 2>/dev/null || true)"
            if [ -n "$_cur_live" ]; then
                printf '%s\n' "$_cur_live"
            else
                manifest_get components.mcp_server.version 2>/dev/null
            fi
            ;;
        pyexasol)
            _cur_python="$(manifest_get components.pyexasol.python 2>/dev/null || true)"
            [ -n "$_cur_python" ] && [ -x "$_cur_python" ] || _cur_python="$EXAKIT_HOME/pyexasol-venv/bin/python"
            [ -x "$_cur_python" ] || return 1
            _cur_live="$(_exakit_probe_pyexasol_version "$_cur_python")"
            if [ -n "$_cur_live" ]; then
                printf '%s\n' "$_cur_live"
            else
                manifest_get components.pyexasol.version 2>/dev/null
            fi
            ;;
        kit2)     manifest_get kit2.version 2>/dev/null ;;
        nano)
            # Only the runtime this install actually uses. A Nano machine that
            # happens to have the Personal launcher on PATH (or the other way
            # round) must not report a version for a runtime it does not run.
            [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "nano" ] || return 1
            exakit_installed_nano_tag
            ;;
        personal)
            [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "personal" ] || return 1
            exakit_installed_personal_version
            ;;
        runtime)
            exakit_installation_runtime_version
            ;;
        *)
            # Marketplace add-ons: the module's own probe is the authority
            # (<id>_installed_version asks the actual install and fails for a
            # provably absent one, so a stale manifest record can never claim
            # "installed"). Without the module, the record is all there is.
            _exakit_addon_registered "$1" || return 1
            _cur_fn="$(_exakit_addon_fn "$1" installed_version)"
            if command -v "$_cur_fn" >/dev/null 2>&1; then
                _cur_live="$("$_cur_fn" 2>/dev/null || true)"
                [ -n "$_cur_live" ] || return 1
                printf '%s\n' "$_cur_live"
                return 0
            fi
            manifest_get "components.$(printf '%s' "$1" | tr '-' '_').version" 2>/dev/null
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Marketplace add-ons
# ---------------------------------------------------------------------------
# Optional tools the kit can install but the setup scripts never do: the user
# picks them from `exakit marketplace` (a multi-select — Space toggles, Enter
# installs), and only the installed ones join the routine update flow, so
# `exakit update all` can refresh an add-on but never sneak one in.
#
# Adding a new add-on is three additive changes — NO case-statement surgery.
# Every registry function (version block, env override, fallback, upstream
# lookup, installed probe, update targets/dispatch) handles registered add-ons
# through a generic arm driven by these conventions:
#   1. Ship its module as setup/lib/<id>.sh (+ the .ps1 twin), defining
#      <id>_install, <id>_validate, <id>_update, <id>_installed_version and
#      <id>_uninstall — with dashes flipped to underscores, since a shell
#      function name cannot carry a dash — plus its own EXAKIT_<ID>_VERSION
#      and EXAKIT_<ID>_VERSION_FALLBACK constants. The uninstall hook takes a
#      dry flag ("1" narrates the plan) and is what folds the add-on into the
#      selectable `exakit uninstall` menu and the full teardown, with no
#      further wiring.
#   2. Add a components.<id> block to versions.json: version, severity, and
#      repo (GitHub-release-installed) or package (PyPI-installed) — that
#      field is what the generic upstream lookup reads.
#   3. Add one line to exakit_marketplace_addons below.
# The add-on's one-line description is NOT one of those changes: it is the
# About field of its own repository, read through
# exakit_marketplace_addon_description.
# (CI guards move with it: the expected-components set in versions.yml and the
# COUPLED fallback-constant table in versions-bump.yml.)
# ⇄ twin: Get-ExakitMarketplaceAddons and friends in setup/exakit.ps1.

# exakit_marketplace_addons — one line per add-on: "id|label".
#
# There is deliberately no description field here. A one-liner typed into this
# registry is a fourth copy of something the add-on's own repository already
# states in its About, and the copies drifted: the wording differed between the
# shell registry, the PowerShell registry and setup/help/<id>.json, and nothing
# noticed. exakit_marketplace_addon_description reads the About instead.
# EVERY LOOP OVER THIS REGISTRY READS IT ON FILE DESCRIPTOR 3, NOT STDIN.
# The row builders call into the add-on modules, and an add-on module runs
# whatever tool it is about. The VS Code CLI reads and drains the stdin it
# inherits, so with the registry on stdin it swallowed the rest of the loop's
# input and every add-on listed after exasol-vscode vanished from the menu -
# json-tables is last, so json-tables is what disappeared, silently, on any
# machine that had VS Code. Reading on fd 3 makes that class of bug
# impossible here no matter what a future add-on shells out to.
exakit_marketplace_addons() {
    printf '%s\n' "dash-server|dash-server (AI dashboard host)"
    printf '%s\n' "exasol-vscode|Exasol for VS Code (editor extension)"
    printf '%s\n' "json-tables|JSON Tables (JSON into Exasol)"
}

# _exakit_addon_fn <id> <suffix> — the module function for an add-on.
_exakit_addon_fn() {
    printf '%s_%s\n' "$(printf '%s' "$1" | tr '-' '_')" "$2"
}

# _exakit_addon_env_var <id> <suffix> — the env/constant name for an add-on:
# dash-server VERSION_FALLBACK -> EXAKIT_DASH_SERVER_VERSION_FALLBACK.
_exakit_addon_env_var() {
    printf 'EXAKIT_%s_%s\n' "$(printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_')" "$2"
}

# _exakit_addon_registered <id> — is this a marketplace add-on at all? The
# gate every generic registry arm runs first, so an unknown name still reads
# as "unknown component" everywhere.
_exakit_addon_registered() {
    case "$1" in
        ''|*[!a-z0-9-]*) return 1 ;;
    esac
    while IFS='|' read -r _ar_id _ar_label <&3; do
        [ "$_ar_id" = "$1" ] && return 0
    done 3<<EXAKIT_AR_EOF
$(exakit_marketplace_addons)
EXAKIT_AR_EOF
    return 1
}

# ---------------------------------------------------------------------------
# Add-on "About" text — fetched from the add-on's own repository, cached here
# ---------------------------------------------------------------------------
# The description the marketplace shows is the About field of the add-on's
# repository. Nothing about the wording is stored in this repository, so the
# team that owns a tool owns its one-liner, in one place, and it cannot drift
# out of sync with what we print.
#
# The cache is what makes a network-backed string safe in front of an
# interactive menu, and it is the same mechanism help.sh already uses for the
# help documents: a TTL'd file per id, an .attempt- stamp so a failure is not
# retried on every run, an atomic write, and a hard refusal to fetch over
# anything but HTTPS. Only the rows that actually SHOW a description are ever
# fetched (an installed row prints its update command instead), so a machine
# with nothing left to install makes no requests at all.

# _exakit_addon_doc <id> — the best help document for this add-on already on
# disk, and where the add-on's repository name is read from.
#
# help.sh, when loaded, also knows the fetched cache copy and validates it, so
# prefer it. But the setup scripts source only common.sh, detect.sh and the
# runtime module — and the closing offer runs from there — so this has to work
# with help.sh absent, which is why the two shipped locations are resolved here
# as well.
_exakit_addon_doc() {
    if command -v exakit_help_doc_local >/dev/null 2>&1; then
        exakit_help_doc_local "$1" 2>/dev/null && return 0
    fi
    _aad_cache="${EXAKIT_HELP_CACHE_DIR:-$EXAKIT_CACHE_DIR/help}/$1.json"
    [ -f "$_aad_cache" ] && { printf '%s\n' "$_aad_cache"; return 0; }
    _aad_root="$(exakit_repo_root 2>/dev/null || true)"
    for _aad_dir in ${_aad_root:+"$_aad_root/setup/help"} "$EXAKIT_HOME/kit/setup/help"; do
        [ -f "$_aad_dir/$1.json" ] && { printf '%s\n' "$_aad_dir/$1.json"; return 0; }
    done
    return 1
}

# _exakit_addon_doc_field <id> <field> — one top-level string from that document.
_exakit_addon_doc_field() {
    _adf_doc="$(_exakit_addon_doc "$1" 2>/dev/null)" || return 1
    [ -f "$_adf_doc" ] || return 1
    if exakit_can_run_python; then
        run_python - "$_adf_doc" "$2" <<'EXAKIT_ADF_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except Exception:
    sys.exit(1)
value = doc.get(sys.argv[2])
if isinstance(value, str) and value.strip():
    print(value.strip())
EXAKIT_ADF_PY
        return $?
    fi
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_adf_doc" | head -1
}

# _exakit_addon_repo <id> — the add-on's repository, as owner/name.
#
# This value is interpolated into a URL, so it is validated as two plain path
# segments and nothing else. A document that says anything more interesting than
# that has no repository as far as this code is concerned.
_exakit_addon_repo() {
    _aar_repo="$(_exakit_addon_doc_field "$1" repo 2>/dev/null || true)"
    case "$_aar_repo" in
        ''|*[!A-Za-z0-9._/-]*|*/*/*|/*|*/) return 1 ;;
        */*) printf '%s\n' "$_aar_repo" ;;
        *) return 1 ;;
    esac
}

_exakit_about_cache_path() {
    printf '%s\n' "$EXAKIT_ABOUT_CACHE_DIR/$1.txt"
}

# _exakit_about_cache_fresh <file> — younger than the TTL? ⇄ twin of
# _exakit_help_cache_fresh; TTL 0 means "never trust the cache", which is what
# the tests use to force the fetch path.
_exakit_about_cache_fresh() {
    [ -f "$1" ] || return 1
    case "$EXAKIT_ABOUT_TTL" in
        ''|*[!0-9]*) return 1 ;;
        0) return 1 ;;
    esac
    _acf_mtime="$(_exakit_file_mtime "$1")"
    case "$_acf_mtime" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(( $(date +%s) - _acf_mtime ))" -lt "$EXAKIT_ABOUT_TTL" ]
}

# _exakit_about_sanitise — stdin to one printable line, filtered ON THE WAY IN.
#
# This text is free-form prose from a repository we do not control, and it is
# printed straight into the user's terminal. The help documents get their
# guarantees from a JSON schema; a bare string has none, so the filtering is
# explicit and happens once, before anything reaches the cache:
#   1. CSI sequences and OSC 8 hyperlinks are removed whole. One -e per
#      terminator, never a BRE alternation: `\|` is a GNU sed extension that
#      BSD sed (macOS, this kit's first platform) silently fails to match — the
#      trap already documented on _ui_visible_len in ui.sh.
#   2. every remaining control byte goes, the bare ESC of a half-sequence
#      included, so nothing can move the cursor, bleed colour into the rest of
#      the screen, or rewrite the line above with a carriage return.
#   3. newlines and tabs collapse to single spaces: this occupies one table
#      cell, and a second line would break the row alignment.
_exakit_about_sanitise() {
    _abs_esc="$(printf '\033')"
    _abs_bel="$(printf '\007')"
    LC_ALL=C sed \
        -e "s/${_abs_esc}\[[0-9;?]*[A-Za-z]//g" \
        -e "s/${_abs_esc}]8;;[^${_abs_bel}${_abs_esc}]*${_abs_bel}//g" \
        -e "s/${_abs_esc}]8;;[^${_abs_bel}${_abs_esc}]*${_abs_esc}\\\\//g" \
        | LC_ALL=C tr '\n\r\t' '   ' \
        | LC_ALL=C tr -d '\000-\037\177' \
        | LC_ALL=C tr -s ' ' \
        | sed -e 's/^ *//' -e 's/ *$//'
}

# _exakit_about_cap <text> — the length ceiling, trimmed back to a word boundary
# so a multi-byte character is never cut in half (a continuation byte is never
# a space).
_exakit_about_cap() {
    _abc_text="$1"
    case "$EXAKIT_ABOUT_MAX_LEN" in
        ''|*[!0-9]*) printf '%s\n' "$_abc_text"; return 0 ;;
    esac
    [ "${#_abc_text}" -le "$EXAKIT_ABOUT_MAX_LEN" ] && { printf '%s\n' "$_abc_text"; return 0; }
    _abc_text="$(printf '%s' "$_abc_text" | LC_ALL=C cut -b "1-$EXAKIT_ABOUT_MAX_LEN")"
    case "$_abc_text" in *' '*) _abc_text="${_abc_text% *}" ;; esac
    printf '%s\n' "$_abc_text"
}

# _exakit_about_extract <json> — the About field out of a repository response.
_exakit_about_extract() {
    if exakit_can_run_python; then
        printf '%s' "$1" | run_python -c 'import json,sys
try:
    print((json.load(sys.stdin).get("description") or "").strip())
except Exception:
    pass' 2>/dev/null
        return 0
    fi
    printf '%s' "$1" | sed -n 's/.*"description"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# _exakit_about_fetch <id> — refresh one add-on's cached About line.
# 0 = a line was cached, 2 = the fetch was skipped as unnecessary, 1 = nothing
# was cached (and the caller falls back; it never fails a screen).
_exakit_about_fetch() {
    _abf_id="$1"
    [ "$EXAKIT_ABOUT_OFFLINE" = "1" ] && return 1
    case "$EXAKIT_ABOUT_URL" in
        https://*) ;;
        *) _exakit_log_file "WARN  refusing to fetch an add-on About over a non-HTTPS URL"; return 1 ;;
    esac
    _abf_repo="$(_exakit_addon_repo "$_abf_id" 2>/dev/null || true)"
    [ -n "$_abf_repo" ] || return 1
    _abf_cache="$(_exakit_about_cache_path "$_abf_id")"
    _abf_attempt="$EXAKIT_ABOUT_CACHE_DIR/.attempt-$_abf_id"
    _exakit_about_cache_fresh "$_abf_cache" && return 2
    # The stamp is what keeps a rate-limited or offline machine from asking
    # again on every single run: it is written BEFORE the request, so the
    # question counts as asked whatever the answer turns out to be.
    _exakit_about_cache_fresh "$_abf_attempt" && return 2
    command -v curl >/dev/null 2>&1 || return 1
    mkdir -p "$EXAKIT_ABOUT_CACHE_DIR" 2>/dev/null || return 1
    : > "$_abf_attempt" 2>/dev/null || true
    _abf_json="$(curl -fsSL --proto '=https' --retry 1 \
        --connect-timeout "$EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT" \
        --max-time "$EXAKIT_VERSION_LOOKUP_MAX_TIME" \
        -A "$(exakit_versions_user_agent 2>/dev/null || true)" \
        "$EXAKIT_ABOUT_URL/$_abf_repo" 2>/dev/null || true)"
    if [ -z "$_abf_json" ]; then
        _exakit_log_file "INFO  About fetch failed for $_abf_id — keeping whatever is on disk"
        return 1
    fi
    _abf_text="$(_exakit_about_cap "$(_exakit_about_extract "$_abf_json" | _exakit_about_sanitise)")"
    if [ -z "$_abf_text" ]; then
        _exakit_log_file "INFO  $_abf_repo has no About text to show for $_abf_id"
        return 1
    fi
    _abf_tmp="$_abf_cache.tmp.$$"
    printf '%s\n' "$_abf_text" > "$_abf_tmp" 2>/dev/null || { rm -f "$_abf_tmp"; return 1; }
    mv -f "$_abf_tmp" "$_abf_cache" 2>/dev/null || { rm -f "$_abf_tmp"; return 1; }
    _exakit_log_file "INFO  About refreshed for $_abf_id from $_abf_repo"
    return 0
}

# exakit_marketplace_addon_description <id> — the one-liner a screen shows.
# Always answers something; the chain degrades instead of blanking a column:
#   1. a cached About younger than the TTL     — the common case, no network
#   2. a fresh fetch                           — one request, timeouts bounded
#   3. a STALE cached About, any age           — old wording beats no wording
#   4. the help document's own tagline         — on disk, so this is the answer
#                                                offline and when rate-limited
#   5. a pointer at the help screen            — only if even that is missing
exakit_marketplace_addon_description() {
    _mad_cache="$(_exakit_about_cache_path "$1")"
    _exakit_about_cache_fresh "$_mad_cache" || _exakit_about_fetch "$1" >/dev/null 2>&1 || true
    if [ -f "$_mad_cache" ]; then
        _mad_text="$(head -1 "$_mad_cache" 2>/dev/null || true)"
        if [ -n "$_mad_text" ]; then
            printf '%s\n' "$_mad_text"
            return 0
        fi
    fi
    _mad_text="$(_exakit_addon_doc_field "$1" tagline 2>/dev/null || true)"
    if [ -n "$_mad_text" ]; then
        # A tagline is written as a help-screen header and ends in a period; a
        # table cell does not.
        printf '%s\n' "${_mad_text%.}"
        return 0
    fi
    printf 'Details: exakit help %s\n' "$1"
}

# exakit_about_wrap <text> [width] [continuation-indent] — the text in full,
# folded onto as many lines as it needs.
#
# This is the table's renderer: an About is written for a repository page, not
# for a 44-column cell, and truncating it threw away the half that explained
# what the tool was for. Continuation lines carry their own indent (they are
# printed through the same '  %s\n' as the first line), so the Description
# column stays a column.
#
# Word-wrapped, never mid-word: a word longer than the width is emitted on a
# line of its own and allowed to overhang rather than being broken.
exakit_about_wrap() {
    _abw_text="$1"
    _abw_w="${2:-$EXAKIT_ABOUT_WIDTH}"
    _abw_pad="${3:-}"
    case "$_abw_w" in
        ''|*[!0-9]*) printf '%s\n' "$_abw_text"; return 0 ;;
    esac
    [ "$_abw_w" -lt 8 ] && { printf '%s\n' "$_abw_text"; return 0; }
    _abw_line=""
    _abw_first=1
    # Unquoted on purpose: the value was sanitised to single-space-separated
    # words on its way into the cache, so this is the word list.
    for _abw_word in $_abw_text; do
        if [ -z "$_abw_line" ]; then
            _abw_line="$_abw_word"
        elif [ "$(( ${#_abw_line} + 1 + ${#_abw_word} ))" -le "$_abw_w" ]; then
            _abw_line="$_abw_line $_abw_word"
        else
            if [ "$_abw_first" = 1 ]; then
                printf '%s\n' "$_abw_line"
                _abw_first=0
            else
                printf '%s%s\n' "$_abw_pad" "$_abw_line"
            fi
            _abw_line="$_abw_word"
        fi
    done
    [ -n "$_abw_line" ] || return 0
    if [ "$_abw_first" = 1 ]; then
        printf '%s\n' "$_abw_line"
    else
        printf '%s%s\n' "$_abw_pad" "$_abw_line"
    fi
}

# _exakit_marketplace_warm_about — fill the cache for the rows that will show a
# description, before a screen is drawn.
#
# This exists for the closing offer: it runs its gate question ("Browse it
# now?") before the table exists, so the requests land while the user is reading
# two sentences of prose rather than in front of a half-drawn table.
_exakit_marketplace_warm_about() {
    while read -r _mw_id <&3; do
        [ -n "$_mw_id" ] || continue
        _exakit_addon_offerable "$_mw_id" || continue
        _exakit_marketplace_addon_present "$_mw_id" && continue
        exakit_marketplace_addon_available "$_mw_id" || continue
        _exakit_about_fetch "$_mw_id" >/dev/null 2>&1 || true
    done 3<<EXAKIT_MW_EOF
$(exakit_marketplace_addons | cut -d'|' -f1)
EXAKIT_MW_EOF
    return 0
}

# exakit_marketplace_addon_available <id> — is the add-on's module loaded in
# this process? (An old kit copy that predates the add-on simply lacks the
# module file; the menu shows the row as unavailable instead of failing.)
exakit_marketplace_addon_available() {
    command -v "$(_exakit_addon_fn "$1" install)" >/dev/null 2>&1
}

# _exakit_marketplace_load_modules — source any add-on module that is not
# loaded yet. The setup scripts deliberately do not source the modules (the
# marketplace is not part of the install flow), so the closing offer and the
# menu load them here on demand. A module that fails to load only makes its
# own row unavailable.
_exakit_marketplace_load_modules() {
    # The sourcing must happen in THIS shell so the loaded functions stick —
    # ids are collected via command substitution, never through a pipeline
    # (whose stages are subshells).
    _ml_root="$(exakit_repo_root 2>/dev/null || true)"
    _ml_ids="$(exakit_marketplace_addons | cut -d'|' -f1)"
    for _ml_id in $_ml_ids; do
        exakit_marketplace_addon_available "$_ml_id" && continue
        for _ml_dir in ${_ml_root:+"$_ml_root/setup/lib"} "$EXAKIT_HOME/kit/setup/lib"; do
            if [ -f "$_ml_dir/$_ml_id.sh" ]; then
                . "$_ml_dir/$_ml_id.sh" 2>/dev/null || \
                    warn "The $_ml_id module could not be loaded from $_ml_dir (corrupted kit copy?)"
                break
            fi
        done
    done
    return 0
}

# _exakit_addon_applicable <id> — does this add-on make sense on THIS machine
# at all? An add-on that extends something the user does not have (the VS Code
# extension without VS Code) is not "available then failing" — it is simply not
# on offer, and nothing advertises it. A module with no opinion is applicable.
_exakit_addon_applicable() {
    _aa_fn="$(_exakit_addon_fn "$1" applicable)"
    command -v "$_aa_fn" >/dev/null 2>&1 || return 0
    # The probe belongs to the add-on module and can do real work: shell out to
    # a code CLI, inspect the platform, read a path. Run it in a subshell so a
    # probe that dies takes its own answer down and nothing else — `exakit
    # version` listed only INSTALLED add-ons before, so no caller had ever run
    # this for an absent one. "Cannot tell" means do not offer it.
    ( "$_aa_fn" ) 2>/dev/null
}

# _exakit_addon_applicable_reason <id> — the one line that explains why it is
# not on offer, when the module cares to say.
_exakit_addon_applicable_reason() {
    _ar_fn="$(_exakit_addon_fn "$1" applicable_reason)"
    command -v "$_ar_fn" >/dev/null 2>&1 && "$_ar_fn"
    return 0
}

# _exakit_addon_offerable <id> — should this add-on appear at all? Only an
# add-on that is BOTH absent and inapplicable is hidden. Anything actually on
# the machine stays visible: a kit install so it can still be updated or
# removed (even if the host app disappeared afterwards), and a system install
# so the screen can say it is already covered rather than silently omitting a
# tool the user can see for themselves.
_exakit_addon_offerable() {
    _exakit_marketplace_addon_present "$1" && return 0
    _exakit_addon_applicable "$1"
}

# exakit_marketplace_addon_installed <id> — KIT-MANAGED install only: the
# component answers for itself (exakit_component_current probes the actual
# install and fails for a provably absent one, so a stale manifest record
# cannot say "installed"). This is what gates the update flow — the kit only
# ever updates what it manages.
exakit_marketplace_addon_installed() {
    exakit_component_current "$1" >/dev/null 2>&1
}

# _exakit_addon_system_present <id> — is the tool already on this machine
# OUTSIDE the kit? A same-named binary on PATH that is not the kit's own
# launcher counts; a module may sharpen the answer with <id>_system_present.
# The kit never offers, updates or uninstalls such an install — it only stops
# advertising a tool the user already has.
_exakit_addon_system_present() {
    _sp_fn="$(_exakit_addon_fn "$1" system_present)"
    if command -v "$_sp_fn" >/dev/null 2>&1; then
        "$_sp_fn"
        return $?
    fi
    # The command to look for: the id, plus whatever the module named its
    # launcher in EXAKIT_<ID>_BIN. The two differ often enough (json-tables
    # installs `exasol-json-tables`) that keying on the id alone would miss a
    # manual install and offer the user a tool they already have.
    _sp_bin_var="$(_exakit_addon_env_var "$1" BIN)"
    eval "_sp_bin=\${$_sp_bin_var:-}"
    _sp_names="$1"
    if [ -n "$_sp_bin" ]; then
        _sp_base="${_sp_bin##*/}"
        [ "$_sp_base" = "$1" ] || _sp_names="$_sp_names $_sp_base"
    fi
    for _sp_name in $_sp_names; do
        _sp_path="$(command -v "$_sp_name" 2>/dev/null || true)"
        [ -n "$_sp_path" ] || continue
        # The kit's own launcher on PATH is a kit install, not a system one.
        [ "$_sp_path" = "$EXAKIT_BIN_DIR/$_sp_name" ] && continue
        [ "$_sp_path" -ef "$EXAKIT_BIN_DIR/$_sp_name" ] 2>/dev/null && continue
        return 0
    done
    return 1
}

# _exakit_marketplace_addon_present <id> — installed by the kit OR already on
# the system. "Present" is what the offer, the menu and the discovery lines
# key on: a tool the user has, from anywhere, is never advertised.
_exakit_marketplace_addon_present() {
    exakit_marketplace_addon_installed "$1" && return 0
    _exakit_addon_system_present "$1"
}

# exakit_marketplace_installed_addons — ids of the add-ons present on this
# machine. This is what folds them into `exakit update all` / `exakit version`.
exakit_marketplace_installed_addons() {
    while IFS='|' read -r _ma_id _ma_label <&3; do
        [ -n "$_ma_id" ] || continue
        exakit_marketplace_addon_installed "$_ma_id" && printf '%s\n' "$_ma_id"
    done 3<<EXAKIT_MA_EOF
$(exakit_marketplace_addons)
EXAKIT_MA_EOF
    return 0
}

# exakit_marketplace_has_pending — true while at least one add-on is not on
# this machine yet (neither kit-managed nor a system install). Drives the
# discovery one-liners and the closing offer.
exakit_marketplace_has_pending() {
    [ -n "$(while IFS='|' read -r _mp_id _mp_label <&3; do
        [ -n "$_mp_id" ] || continue
        _exakit_addon_offerable "$_mp_id" || continue
        _exakit_marketplace_addon_present "$_mp_id" || printf '%s\n' "$_mp_id"
    done 3<<EXAKIT_MP_EOF
$(exakit_marketplace_addons)
EXAKIT_MP_EOF
)" ]
}

# --- the add-ons table --------------------------------------------------------
# The SELECTION and the install progress are ONE table -- the same component the
# dataset load uses (ui_table_* in ui.sh) -- so the rows a reader ticks are the
# rows whose Status column then fills in, and nothing has to be mapped from one
# screen onto another. What lives here is which rows there are and what their
# Status column says.
#
# Every row's state lives in a FILE because the animator that draws it is a
# background subshell: it can read a file and could never read a variable this
# shell set.

EXAKIT_ADDON_TABLE_STATE=""
EXAKIT_ADDON_TABLE_LIVE=0
EXAKIT_ADDON_TABLE_IDS=""
EXAKIT_ADDON_TABLE_ROW=""
EXAKIT_ADDON_TABLE_ROW_SKIP=0
# Said once the table has stopped redrawing — see _exakit_addon_note.
EXAKIT_ADDON_NOTES=""

# _exakit_addon_bar_live — is a table painting this install? True means the
# one-line progress bar must keep its hands off the UI layer's single animation
# slot; the table owns it.
_exakit_addon_bar_live() {
    [ "${EXAKIT_ADDON_TABLE_LIVE:-0}" = 1 ]
}

# _exakit_addon_note <info|warn> <text> — something the reader must see, said
# AFTER the table has stopped. A line printed into a frame that is still being
# repainted lands INSIDE the box, so while the table is live nothing speaks
# except the table. With no table it is said where it stands, exactly as before.
_exakit_addon_note() {
    if _exakit_addon_bar_live; then
        EXAKIT_ADDON_NOTES="${EXAKIT_ADDON_NOTES}$1|$2
"
        return 0
    fi
    case "$1" in
        warn) warn "$2" ;;
        *)    info "$2" ;;
    esac
}

# _exakit_addon_notes_say — drain the collected notes, now that the table is off
# the screen and a line can be read where it is printed.
_exakit_addon_notes_say() {
    while IFS='|' read -r _ans_kind _ans_text; do
        [ -n "$_ans_text" ] || continue
        case "$_ans_kind" in
            warn) warn "$_ans_text" ;;
            *)    info "$_ans_text" ;;
        esac
    done <<EXAKIT_ADDON_NOTES_EOF
$EXAKIT_ADDON_NOTES
EXAKIT_ADDON_NOTES_EOF
    EXAKIT_ADDON_NOTES=""
}

# _exakit_addon_table_build <state-file> <id> [id ...] — the rows, in the order
# they are drawn: the group row, one row per installable add-on hanging off a
# tree connector, and the exclusive Skip. Sets EXAKIT_TABLE_DEFAULTS / _GROUP /
# _EXCLUSIVE the way ui_table_menu expects, and EXAKIT_ADDON_TABLE_IDS to the
# add-on id per row (empty for the rows that are not add-ons) so the installer
# can find a row again.
#
# Only INSTALLABLE add-ons get a row. An add-on that is already present, or
# whose module did not ship in this kit copy, is answered by the state table
# above with its own version and status, and a checkbox that cannot be ticked
# would be the same fact twice — the data-load table leaves already-loaded
# datasets out for exactly that reason. This is also what keeps the group's
# child range contiguous.
_exakit_addon_table_build() {
    _atb_f="$1"; shift
    : > "$_atb_f"
    _atb_n=$#
    printf 'group|Select All|1|idle|||||| \n' >> "$_atb_f"
    # Via a newline-separated STRING, one line per row, so a row that is not an
    # add-on is an EMPTY line rather than a gap a space-separated list would
    # close up — the row number is the index, and it has to stay one.
    EXAKIT_ADDON_TABLE_IDS="
"
    _atb_i=0
    for _atb_id in "$@"; do
        _atb_i=$(( _atb_i + 1 ))
        if [ "$_atb_i" -eq "$_atb_n" ]; then _atb_kind=corner; else _atb_kind=tee; fi
        printf '%s|%s|1|idle|||||| \n' "$_atb_kind" "$_atb_id" >> "$_atb_f"
        EXAKIT_ADDON_TABLE_IDS="$EXAKIT_ADDON_TABLE_IDS$_atb_id
"
    done
    printf 'plain|Skip|0|idle|||||| \n' >> "$_atb_f"
    EXAKIT_ADDON_TABLE_IDS="$EXAKIT_ADDON_TABLE_IDS
"
    EXAKIT_ADDON_TABLE_ROW_SKIP=$(( _atb_n + 2 ))
    EXAKIT_TABLE_EXCLUSIVE="$EXAKIT_ADDON_TABLE_ROW_SKIP"
    # "all": the parent is a master toggle, checked only while EVERY child is.
    # Under the default "any" it stayed checked with one child ticked, so the
    # summary row read "everything is selected" when it was not — on the row a
    # user glances at to confirm what is about to be installed.
    EXAKIT_TABLE_GROUP="1:2:$(( _atb_n + 1 )):all"
    # The group AND every add-on pre-selected, so Enter alone installs what is
    # on offer and Skip is the explicit opt-out. Mirrors exakit_data_load_select.
    EXAKIT_TABLE_DEFAULTS=""
    _atb_i=1
    while [ "$_atb_i" -le $(( _atb_n + 1 )) ]; do
        EXAKIT_TABLE_DEFAULTS="${EXAKIT_TABLE_DEFAULTS:+$EXAKIT_TABLE_DEFAULTS,}$_atb_i"
        _atb_i=$(( _atb_i + 1 ))
    done
    # Every row here can be checked, and saying so is not optional:
    # _UI_CHECKBOX_SELECTABLE is published by ui_checkbox_menu and never cleared,
    # so the offer's two-row "Explore ?" question leaves "1 2" behind — and the
    # group helpers would then treat row 2 as the only child, making Select All
    # toggle the first add-on and nothing else. Empty means "every row".
    _UI_CHECKBOX_SELECTABLE=""
    return 0
}

# _exakit_addon_table_row <id> — which row that add-on is on, or 0.
_exakit_addon_table_row() {
    _atr_i=0
    while IFS= read -r _atr_id; do
        _atr_i=$(( _atr_i + 1 ))
        [ "$_atr_id" = "$1" ] && { printf '%s\n' "$_atr_i"; return 0; }
    done <<EXAKIT_ATR_EOF
$EXAKIT_ADDON_TABLE_IDS
EXAKIT_ATR_EOF
    printf '0\n'
}

# _exakit_addon_table_cell <summary> <seconds> — the Status column for a
# finished add-on. The tick in front of it already says "installed", so the cell
# carries the add-on's own one fact instead ("dashboards at
# http://127.0.0.1:8000"), with the elapsed time padded to a fixed width so the
# times line up down the table rather than wandering with the length of the text
# in front of them.
#
# Truncated to the column rather than allowed to widen it: ui_table_widths sizes
# the Status column from the widest FINISHED status and only ever gives ground
# from the name column, so a sixty-character summary pushes the table past an
# 80-column terminal — and a row that wraps is two terminal lines the frame
# counted as one, which is how a table starts stacking on every redraw. The full
# text is in the logfile either way.
_exakit_addon_table_cell() {
    _atc_el="$(printf '%5s' "(${2}s)")"
    _atc_text="${1:-installed}"
    # The room is what is left of the column's FLOOR after the tick glyph and
    # its space, the space before the elapsed time, and the time itself: the
    # cell _ui_table_cell builds is "<tick> <final>", and a final that overruns
    # the column makes ui_table_frame's padding arithmetic go negative — which
    # is a bash substring error printed over the table, not a wider column.
    _atc_tick="${UI_TICK:-[ok]}"
    _atc_room=$(( ${UI_TABLE_STAT_MIN:-44} - ${#_atc_tick} - ${#_atc_el} - 2 ))
    [ "${#_atc_text}" -le "$_atc_room" ] || \
        _atc_text="${_atc_text:0:$(( _atc_room - 1 ))}…"
    # Padded to the room, not merely fitted into it: the summaries are all
    # different lengths, so an unpadded cell puts each row's elapsed time at a
    # different column and the eye has nothing to run down.
    printf "%-${_atc_room}s %s\n" "$_atc_text" "$_atc_el"
}

# _exakit_addon_table_cleanup — the state file and the animator's scratch files
# go together with the table. Called on every path out of the selection, so a
# cancelled marketplace leaves nothing in TMPDIR.
_exakit_addon_table_cleanup() {
    [ -n "$EXAKIT_ADDON_TABLE_STATE" ] || return 0
    rm -f "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_ADDON_TABLE_STATE.new" \
          "$EXAKIT_ADDON_TABLE_STATE.lines" "$EXAKIT_ADDON_TABLE_STATE.stop"
    EXAKIT_ADDON_TABLE_STATE=""
    return 0
}

# _exakit_marketplace_install_one <id> — install + validate one add-on. The
# validate half must not fail the install (same contract as the setup steps):
# a component that installed but could not be validated explains itself and is
# retried by `exakit update <id>`.
_exakit_marketplace_install_one() {
    _mi_install="$(_exakit_addon_fn "$1" install)"
    _mi_validate="$(_exakit_addon_fn "$1" validate)"
    command -v "$_mi_install" >/dev/null 2>&1 || {
        _exakit_addon_note warn "The $1 module is not part of this kit copy — update the kit first: exakit update exakit"
        return 1
    }
    # Every silent stretch of an add-on install — creating the venv, resolving
    # and installing from PyPI, downloading an extension — already animates,
    # because run_logged and fetch start the spinner. What they did NOT have was
    # a truthful label: EXAKIT_ACTIVE_LABEL is set by begin_step, and add-ons are
    # installed after the last numbered step (or from `exakit marketplace`, with
    # no step at all), so a two-minute install animated under the previous step's
    # title, or under the bare word "working". Name what is actually running.
    # Twin of the same block in Invoke-ExakitMarketplaceApply (exakit-common.ps1).
    _mi_prev_label="${EXAKIT_ACTIVE_LABEL:-}"
    _mi_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    # Installing three add-ons printed fifty lines: a venv, a pip resolve, a
    # download, a checksum, a launcher, a package-data repair and a validation
    # probe, each announcing itself twice. None of it is something the person
    # who ticked three boxes can act on, and all of it is in the logfile.
    #
    # EXAKIT_QUIET_DETAIL routes it there; the progress line below is the
    # narration, carried by the spinner run_logged and fetch already start (so
    # the bar, the percentage, the phase and the animation are ONE line). The
    # percentages are milestone positions weighted by where the TIME goes -
    # fetching and installing is nearly all of it - not a step count.
    EXAKIT_QUIET_DETAIL=1
    _mi_state="$(mktemp "${TMPDIR:-/tmp}/exakit-addon.XXXXXX")" || _mi_state=""
    _mi_t0="$(date +%s 2>/dev/null || echo 0)"
    if [ -n "$_mi_state" ]; then
        _exakit_addon_progress "$_mi_state" "$1" 0 65 40 "installing"
        # The TABLE is already painting this add-on's row, and it holds the UI
        # layer's single animation slot. A second painter here would fight it for
        # the cursor, and the ui_progress_end below would kill the TABLE's
        # animator instead of a bar of its own -- mid-frame, which leaves half a
        # table on screen with the finished one printed under it.
        _exakit_addon_bar_live || ui_progress_begin "$_mi_state" "$_mi_t0" || true
    fi
    "$_mi_install"
    _mi_rc=$?
    if [ "$_mi_rc" -ne 0 ]; then
        _exakit_addon_bar_live || ui_progress_end
        [ -n "$_mi_state" ] && rm -f "$_mi_state"
        EXAKIT_QUIET_DETAIL="$_mi_prev_quiet"
        EXAKIT_ACTIVE_LABEL="$_mi_prev_label"
        return 1
    fi
    if command -v "$_mi_validate" >/dev/null 2>&1; then
        [ -n "$_mi_state" ] && _exakit_addon_progress "$_mi_state" "$1" 65 90 8 "validating"
        "$_mi_validate" || true
    fi
    # A service add-on joins the boot set the moment it is installed, so the
    # user does not have to remember a second command after saying yes. On
    # macOS loading the agent also starts it, so it is usable right away.
    if [ "$(manifest_get autostart.enabled 2>/dev/null || true)" = "true" ] && \
       command -v "$(_exakit_addon_fn "$1" autostart_command)" >/dev/null 2>&1; then
        _exakit_autostart_register "$1" || true
    fi
    # ...and it is STARTED now. Registering for boot is not the same as running:
    # on Linux and Windows nothing starts until the next login, so `exakit
    # status` reported the add-on the user had just installed as "stopped".
    # Best-effort, and only for an add-on that declares a start hook.
    _mi_start="$(_exakit_addon_fn "$1" start)"
    if command -v "$_mi_start" >/dev/null 2>&1; then
        [ -n "$_mi_state" ] && _exakit_addon_progress "$_mi_state" "$1" 90 100 3 "starting"
        "$_mi_start" >/dev/null 2>&1 || \
            _exakit_addon_note warn "$1 installed but did not start — start it with: exakit start"
    fi
    _exakit_addon_bar_live || ui_progress_end
    [ -n "$_mi_state" ] && rm -f "$_mi_state"
    EXAKIT_QUIET_DETAIL="$_mi_prev_quiet"
    EXAKIT_ACTIVE_LABEL="$_mi_prev_label"
    return 0
}

# _exakit_addon_progress <state-file> <id> <pct> <ceiling> <seconds> <phase> —
# the add-on install has reached a new stage.
#
# The percentages are milestone positions weighted by where the TIME goes:
# fetching and installing is nearly all of it, validating a little, starting
# almost none. The seconds are what the creep fills the gaps with, and it is
# capped below the next stage, so a slow PyPI resolve makes the bar wait rather
# than walk into "validating".
# ⇄ twin: Set-ExakitAddonProgress in exakit-common.ps1.
_exakit_addon_progress() {
    # An add-on being installed from the TABLE reports into its ROW; the row
    # already names it, so the "<id> · " prefix the one-line bar needs would be
    # the same fact twice, in a cell that has to spell a phase in a fixed width.
    if [ -n "${EXAKIT_ADDON_TABLE_ROW:-}" ] && [ -n "${EXAKIT_ADDON_TABLE_STATE:-}" ]; then
        ui_table_set "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_ADDON_TABLE_ROW" running \
            "$3" "$4" "$5" "$6"
        return 0
    fi
    ui_progress_state "$1" "$3" "$4" "$5" "$2 · $6"
}

# exakit_marketplace_menu — the `exakit marketplace` command body, wearing the
# kit's two established looks so nothing here reads foreign:
#   1. the STATE, as the same aligned table `exakit version` prints
#      (Add-on / Status / Version / Action, one row per add-on, whatever its
#      state — installed, on the system, missing module, or available);
#   2. the SELECTION, as the same live table the data-load menu uses: a group
#      row with the add-ons hanging off UI_TEE/UI_CORNER connectors, Space
#      toggles, Enter installs, Skip as the exclusive default — and the Status
#      column of those very rows is what the install then fills in.
# Only installable add-ons become menu rows — everything else is answered by
# the table, exactly like already-loaded datasets are not re-offered.
#
# Non-interactive runs answer with EXAKIT_MARKETPLACE_ADDONS: a csv of add-on
# ids, "all", or "none" — same contract as EXAKIT_MCP_CLIENTS / EXAKIT_DATASETS.
exakit_marketplace_menu() {
    _mm_ids=()
    _mm_rows=()
    _mm_selectable=0
    while IFS='|' read -r _mm_id _mm_label <&3; do
        [ -n "$_mm_id" ] || continue
        # Not applicable here and not installed: it is not an option on this
        # machine, so it is not shown at all — no row, no table line.
        _exakit_addon_offerable "$_mm_id" || continue
        # Every add-on gets a STATE row; only an installable one also gets a
        # selection row. A state that cannot be installed is answered by the
        # state table — its own version, and a last column that says why it is
        # not on offer — which is more room than a dimmed one-line menu label
        # had, and it is the only output on the all-covered path, where the
        # selection is never drawn at all. "__disabled__" keeps the row in
        # _mm_ids so the env answer can still tell a real add-on it names from
        # an unknown one.
        if exakit_marketplace_addon_installed "$_mm_id"; then
            _mm_ver="$(exakit_component_current "$_mm_id" 2>/dev/null || true)"
            _mm_rows+=("$(printf '%-14s %-14s %s' "$_mm_id" "$(exakit_version_plain "${_mm_ver:-?}")" "Installed")")
            _mm_ids+=("__disabled__")
        elif _exakit_addon_system_present "$_mm_id"; then
            # The user already has the tool from somewhere else: covered, and
            # the kit does not manage it.
            _mm_rows+=("$(printf '%-14s %-14s %s' "$_mm_id" "-" "Already on this system, managed outside the kit")")
            _mm_ids+=("__disabled__")
        elif ! exakit_marketplace_addon_available "$_mm_id"; then
            _mm_rows+=("$(printf '%-14s %-14s %s' "$_mm_id" "-" "Not in this kit copy. Run: exakit update exakit")")
            _mm_ids+=("__disabled__")
        else
            _mm_adv="$(exakit_component_available "$_mm_id" 2>/dev/null || true)"
            # Only an installable row shows a description, and only a run that
            # will actually DRAW one needs to resolve it: a scripted answer
            # (EXAKIT_MARKETPLACE_ADDONS) installs without a table, so an agent
            # or a CI job never pays for the lookup.
            _mm_cell=""
            if [ -z "${EXAKIT_MARKETPLACE_ADDONS:-}" ]; then
                # The table carries the About IN FULL, folded onto as many lines
                # as it needs. Nothing truncates it.
                # The continuation indent is the width of the two leading
                # cells, MEASURED from the very format string the rows are
                # printed with rather than counted by hand. Counted by hand it
                # was 32 against a 30-column prefix, so every folded line of a
                # description sat two columns to the right of the line above it.
                # Written this way the two cannot drift apart again.
                _mm_cell="$(exakit_about_wrap \
                    "$(exakit_marketplace_addon_description "$_mm_id")" \
                    "$EXAKIT_ABOUT_WIDTH" "$(printf '%-14s %-14s ' '' '')")"
            fi
            _mm_rows+=("$(printf '%-14s %-14s %s' "$_mm_id" "$(exakit_version_plain "${_mm_adv:-unknown}")" "$_mm_cell")")
            _mm_ids+=("$_mm_id")
            _mm_selectable=$((_mm_selectable + 1))
        fi
    done 3<<EXAKIT_MM_EOF
$(exakit_marketplace_addons)
EXAKIT_MM_EOF

    # The env answer wins over any menu, so agents and CI never need a TTY.
    if [ -n "${EXAKIT_MARKETPLACE_ADDONS:-}" ]; then
        _mm_answer="$(printf '%s' "$EXAKIT_MARKETPLACE_ADDONS" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
        _mm_picked=""
        case "$_mm_answer" in
            none) info "EXAKIT_MARKETPLACE_ADDONS=none — installing nothing."; return 0 ;;
            all)
                _mm_i=0
                while [ "$_mm_i" -lt "${#_mm_ids[@]}" ]; do
                    case "${_mm_ids[$_mm_i]}" in __*__) ;; *) _mm_picked="${_mm_picked:+$_mm_picked,}${_mm_ids[$_mm_i]}" ;; esac
                    _mm_i=$((_mm_i + 1))
                done
                ;;
            *)
                for _mm_tok in $(printf '%s' "$_mm_answer" | tr ',' ' '); do
                    _mm_known=0
                    _mm_i=0
                    while [ "$_mm_i" -lt "${#_mm_ids[@]}" ]; do
                        [ "${_mm_ids[$_mm_i]}" = "$_mm_tok" ] && _mm_known=1
                        _mm_i=$((_mm_i + 1))
                    done
                    if [ "$_mm_known" -eq 1 ]; then
                        _mm_picked="${_mm_picked:+$_mm_picked,}$_mm_tok"
                    elif exakit_marketplace_addon_installed "$_mm_tok" 2>/dev/null; then
                        info "$_mm_tok is already installed — update it with: exakit update $_mm_tok"
                    elif _exakit_addon_registered "$_mm_tok" && _exakit_addon_system_present "$_mm_tok"; then
                        info "$_mm_tok is already on this system — the kit leaves it alone"
                    elif _exakit_addon_registered "$_mm_tok" && ! _exakit_addon_applicable "$_mm_tok"; then
                        _mm_why="$(_exakit_addon_applicable_reason "$_mm_tok")"
                        die "$_mm_tok is not available on this machine${_mm_why:+: $_mm_why}"
                    elif _exakit_addon_registered "$_mm_tok"; then
                        # Registered but no module in this kit copy: a real
                        # add-on the user asked for by name — say what fixes it
                        # instead of calling it unknown.
                        die "The $_mm_tok module is not part of this kit copy — update the kit first: exakit update exakit"
                    else
                        die "Unknown marketplace add-on in EXAKIT_MARKETPLACE_ADDONS: '$_mm_tok' (known: $(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//'))"
                    fi
                done
                ;;
        esac
        [ -n "$_mm_picked" ] || { info "Nothing to install — every requested add-on is already present."; return 0; }
        _exakit_marketplace_apply "$_mm_picked"
        return $?
    fi

    # The state table, drawn with the SAME panel `exakit version` uses so every
    # table in the kit reads as one family. The glyphs come from the ui palette
    # (rounded where the terminal supports it, ASCII where it does not), so
    # nothing here spells a box character itself.
    #
    # The last column is named for what it actually carries: with nothing left
    # to install every row is a state, so it is a Status column; while anything
    # is still installable the column carries the add-on's description.
    if [ "$_mm_selectable" -eq 0 ]; then
        _mm_lastcol="Status"
    else
        _mm_lastcol="Description"
    fi
    printf '\n'
    ui_panel_begin "Marketplace add-ons"
    ui_panel_line "$(printf '%-14s %-14s %s' "Add-on" "Version" "$_mm_lastcol")"
    _mm_i=0
    while [ "$_mm_i" -lt "${#_mm_rows[@]}" ]; do
        # A description cell is already folded onto continuation lines; the
        # panel splits the buffer on newlines, so it lands correctly as-is.
        ui_panel_line "${_mm_rows[$_mm_i]}"
        _mm_i=$((_mm_i + 1))
    done
    ui_panel_end
    printf '\n'

    if [ "$_mm_selectable" -eq 0 ]; then
        info "Everything available is already covered."
        return 0
    fi

    # The selection — the same live table the data-load menu draws: a group row
    # with the add-ons hanging off connectors (UI_TEE/UI_CORNER from the ui
    # palette; ASCII in plain mode), the available add-ons pre-selected so Enter
    # alone installs what is on offer, and Skip as the exclusive opt-out. A
    # non-interactive run keeps the pre-selected defaults, exactly like the
    # data-load menu (EXAKIT_MARKETPLACE_ADDONS=none is the scripted opt-out).
    # Mirrors exakit_data_load_select / Show-ExakitMarketplaceMenu.
    #
    # The rows the reader ticks here are the rows _exakit_marketplace_apply then
    # fills in, so the choice and the progress are one screen. The disabled rows
    # the checkbox version carried are gone: the state table directly above
    # already gives each of them a version and a status, in more room than a
    # dimmed one-line label had.
    EXAKIT_ADDON_TABLE_STATE="$(mktemp "${TMPDIR:-/tmp}/exakit-addons.XXXXXX")" || {
        warn "Could not create a temporary file for the add-ons table."
        return 1
    }
    _mm_pick_ids=()
    _mm_i=0
    while [ "$_mm_i" -lt "${#_mm_ids[@]}" ]; do
        case "${_mm_ids[$_mm_i]}" in
            __*__) ;;
            *) _mm_pick_ids+=("${_mm_ids[$_mm_i]}") ;;
        esac
        _mm_i=$((_mm_i + 1))
    done
    _exakit_addon_table_build "$EXAKIT_ADDON_TABLE_STATE" "${_mm_pick_ids[@]}"
    UI_TABLE_TITLE="Add-ons to install"
    # The first column's heading, or the add-ons would sit under "Dataset".
    UI_TABLE_COL1="Add-on"
    ui_table_menu "$EXAKIT_ADDON_TABLE_STATE"
    case ",$EXAKIT_TABLE_SELECTION," in
        *",$EXAKIT_ADDON_TABLE_ROW_SKIP,"*)
            _exakit_addon_table_cleanup
            info "Marketplace closed — nothing was installed."
            return 0
            ;;
    esac
    _mm_picked=""
    for _mm_idx in $(printf '%s' "$EXAKIT_TABLE_SELECTION" | tr ',' ' '); do
        # "none" is a selection too (a read that hit EOF), and it would reach sed
        # as a line address it cannot parse.
        case "$_mm_idx" in ''|*[!0-9]*) continue ;; esac
        _mm_id="$(printf '%s\n' "$EXAKIT_ADDON_TABLE_IDS" | sed -n "${_mm_idx}p")"
        [ -n "$_mm_id" ] || continue
        _mm_picked="${_mm_picked:+$_mm_picked,}$_mm_id"
    done
    if [ -z "$_mm_picked" ]; then
        _exakit_addon_table_cleanup
        info "Nothing selected — nothing was installed."
        return 0
    fi
    _exakit_marketplace_apply "$_mm_picked"
}

# exakit_marketplace_offer — the closing moment of an install: everything ran,
# the panel is on screen, and this asks ONE question — add optional tools now,
# or maybe later? Dynamic by design:
#   - an add-on that is already on the machine (kit-managed, or a system
#     install the kit does not manage) is not on offer;
#   - when nothing is left to offer, the question disappears entirely;
#   - a run with soft failures gets the one-line hint instead of a victory lap;
#   - no TTY (scripted/agent installs) also gets the hint — unless
#     EXAKIT_MARKETPLACE_ADDONS pre-answers, which installs without asking.
# Best-effort by contract: callers run it in a subshell so nothing in here can
# end an install that already succeeded. ⇄ twin: Request-ExakitMarketplaceOffer.
exakit_marketplace_offer() {
    _exakit_marketplace_load_modules
    exakit_marketplace_has_pending || return 0
    # Fill the About cache now, while the gate question below is still being
    # read: this is the one screen where the cache is reliably cold (a machine
    # minutes old), and the table it feeds does not exist yet.
    _exakit_marketplace_warm_about

    # A scripted answer wins over any prompt (same contract as the menu).
    if [ -n "${EXAKIT_MARKETPLACE_ADDONS:-}" ]; then
        exakit_marketplace_menu
        return $?
    fi

    # "Done and working" must be true before it is said: a run that recorded
    # soft failures points at the marketplace without the celebration.
    if [ -n "${EXAKIT_SOFT_FAILED:-}" ] || [ -z "$(_exakit_prompt_tty)" ]; then
        info "Optional add-ons (dashboards & more): exakit marketplace"
        return 0
    fi

    # One gate question first — the same cursor menu every other kit choice
    # uses, no typing: Yes is pre-ticked, No is the exclusive opt-out. Only a
    # Yes opens the marketplace selection itself (where the available add-ons
    # come pre-selected, so Enter installs them and Skip still backs out).
    printf '\n'
    ok "Your starter kit is ready to use."
    # The install is over; what follows is a different question. A rule with air
    # around it is the seam, so the offer does not read as one more install step.
    ui_rule
    info "Supercharge starterkit with exasol add-ons"
    EXAKIT_CHECKBOX_EXCLUSIVE=2
    ui_checkbox_menu "Explore ?" "1" \
        "Yes" \
        "No"
    case ",$EXAKIT_CHECKBOX_SELECTION," in
        *",1,"*)
            exakit_marketplace_menu || true
            info "Browse again: exakit marketplace  ·  how to use one: exakit help <add-on>"
            ;;
        *)
            info "Maybe later — browse any time with: exakit marketplace"
            ;;
    esac
    return 0
}

# _exakit_marketplace_apply <ids_csv> — install each picked add-on in turn. One
# failure does not strand the rest; the exit status says whether all made it.
_exakit_marketplace_apply() {
    _mp_status=0
    # The SAME table the selection was just made in becomes the progress display:
    # the rows do not move, so nobody has to map one screen onto another. It
    # animates only where there is a terminal to animate on, and a scripted
    # answer (EXAKIT_MARKETPLACE_ADDONS) never built a table at all — every
    # add-on then narrates in plain lines exactly as it did before.
    EXAKIT_ADDON_TABLE_LIVE=0
    if [ -n "$EXAKIT_ADDON_TABLE_STATE" ]; then
        ui_table_begin "$EXAKIT_ADDON_TABLE_STATE" && EXAKIT_ADDON_TABLE_LIVE=1
    fi
    # With the table narrating, the per-add-on lines underneath it are the same
    # facts twice — and printing one scrolls the frame the animator is redrawing.
    # EXAKIT_QUIET_DETAIL routes them to the logfile instead, which is what it is
    # for; install_one saves and restores it, so nesting is already handled.
    _mp_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    _exakit_addon_bar_live && EXAKIT_QUIET_DETAIL=1
    for _mp_id in $(printf '%s' "$1" | tr ',' ' '); do
        # Which row this add-on owns, if a table is on screen. Empty means there
        # is none and the single-line bar takes over, unchanged.
        EXAKIT_ADDON_TABLE_ROW=""
        if _exakit_addon_bar_live; then
            EXAKIT_ADDON_TABLE_ROW="$(_exakit_addon_table_row "$_mp_id")"
            [ "$EXAKIT_ADDON_TABLE_ROW" = "0" ] && EXAKIT_ADDON_TABLE_ROW=""
        fi
        info "Installing add-on: $_mp_id"
        _mp_t0="$(date +%s 2>/dev/null || echo 0)"
        if _exakit_marketplace_install_one "$_mp_id"; then
            # <id>_summary is an OPTIONAL hook: the one fact worth carrying out
            # of an install whose reference panel is now log-only. Resolved
            # generically, so a new add-on gets it by defining the function and
            # nothing here has to learn its name.
            _mp_note=""
            _mp_summary_fn="$(_exakit_addon_fn "$_mp_id" summary)"
            if command -v "$_mp_summary_fn" >/dev/null 2>&1; then
                _mp_note="$("$_mp_summary_fn" 2>/dev/null || true)"
            fi
            _mp_elapsed=$(( $(date +%s 2>/dev/null || echo 0) - _mp_t0 ))
            [ "$_mp_elapsed" -ge 0 ] 2>/dev/null || _mp_elapsed=0
            # ok() is the record either way: it writes the FULL summary to the
            # logfile whether or not the screen is showing it, which is what
            # keeps a summary too long for the column from being lost.
            ok "$_mp_id installed${_mp_note:+ — $_mp_note}"
            [ -n "$EXAKIT_ADDON_TABLE_ROW" ] && \
                ui_table_set "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_ADDON_TABLE_ROW" \
                    done "" "" "" "" \
                    "$(_exakit_addon_table_cell "$_mp_note" "$_mp_elapsed")"
        else
            [ -n "$EXAKIT_ADDON_TABLE_ROW" ] && \
                ui_table_set "$EXAKIT_ADDON_TABLE_STATE" "$EXAKIT_ADDON_TABLE_ROW" \
                    failed "" "" "" "" "did not finish — see the log"
            _exakit_addon_note warn \
                "$_mp_id did not finish installing — retry with: exakit marketplace (or exakit update $_mp_id)"
            _mp_status=1
        fi
        EXAKIT_ADDON_TABLE_ROW=""
    done
    # The table stops redrawing BEFORE anything is said over it, and only then is
    # what was collected on the way said.
    if _exakit_addon_bar_live; then
        ui_table_end "$EXAKIT_ADDON_TABLE_STATE"
        EXAKIT_ADDON_TABLE_LIVE=0
    fi
    EXAKIT_QUIET_DETAIL="$_mp_prev_quiet"
    _exakit_addon_notes_say
    _exakit_addon_table_cleanup
    return "$_mp_status"
}

exakit_update_targets() {
    case "${1:-all}" in
        all)
            printf '%s\n' exakit runtime exapump mcp pyexasol
            # Marketplace add-ons join the routine update set only once they
            # are installed: `exakit update all` must never install a tool the
            # user did not pick from `exakit marketplace`.
            exakit_marketplace_installed_addons
            # Kit 2 is a target only once it is installed: at Kit 1 the update
            # check offers it as a discovery line instead, and a routine update
            # must never add a kit level on its own. It comes last because its
            # assets arrive with the kit copy that `exakit` updates above.
            if [ "$(manifest_get kit_level 2>/dev/null || true)" = "2" ]; then
                printf '%s\n' kit2
            fi
            ;;
        runtime|database|db) printf '%s\n' runtime ;;
        nano|personal|exakit|exapump|mcp|pyexasol|kit2) printf '%s\n' "$1" ;;
        *)
            # Any registered marketplace add-on is a valid explicit target.
            _exakit_addon_registered "$1" || return 1
            printf '%s\n' "$1"
            ;;
    esac
}

# exakit_min_kit_satisfied <required> — can this kit run the advertised
# Component? An unknown kit version never blocks: it would strand the user.
exakit_min_kit_satisfied() {
    _mks_kit="$(exakit_component_current exakit 2>/dev/null || true)"
    [ -n "$_mks_kit" ] && [ "$_mks_kit" != "unknown" ] || return 0
    [ "$_mks_kit" != "$1" ] || return 0
    exakit_version_newer "$_mks_kit" "$1"
}

# exakit_component_is_ahead <component> — is the installed version newer than the
# one the manifest publishes?
#
# The kit never moves a component backwards: not on request, not with a
# confirmation, not behind an env override. A user who upgraded pyexasol or
# exapump themselves keeps what they chose, and a maintainer who lowers a version
# in versions.json does not drag anyone back with it — to withdraw a bad release,
# publish a higher version. Returns 0 when installed is ahead, so the caller can
# leave the component alone.
exakit_component_is_ahead() {
    _cia_component="$1"
    _cia_current="$(exakit_component_current "$_cia_component" 2>/dev/null || true)"
    _cia_available="$(exakit_component_available "$_cia_component" 2>/dev/null || true)"
    [ -n "$_cia_current" ] && [ -n "$_cia_available" ] || return 1
    [ "$_cia_current" != "unknown" ] || return 1
    [ "$_cia_current" != "not installed" ] || return 1
    exakit_version_newer "$_cia_current" "$_cia_available"
}

# exakit_print_versions_source_line — where the Tagged column came from, so
# nobody has to guess whether a stale answer is being shown.
exakit_print_versions_source_line() {
    case "${EXAKIT_VERSION_POLICY:-manifest}" in
        manifest) ;;
        latest)
            info "Available versions come from live upstream lookups (EXAKIT_VERSION_POLICY=latest)"
            _exakit_print_override_line
            return 0
            ;;
        *)
            info "Available versions come from this kit's built-in fallbacks (EXAKIT_VERSION_POLICY=${EXAKIT_VERSION_POLICY}, no network)"
            _exakit_print_override_line
            return 0
            ;;
    esac
    case "$(exakit_versions_source)" in
        fetched) _vsl_text="published manifest, fetched just now" ;;
        cache)   _vsl_text="cached manifest copy" ;;
        baked)   _vsl_text="manifest shipped with this kit, no network" ;;
        # Nothing readable anywhere: the rows say "unknown" rather than inventing
        # a number, so say that plainly instead of crediting a source.
        *)       info "The versions manifest could not be read, so the available versions are unknown"
                 _exakit_print_override_line
                 return 0
                 ;;
    esac
    _vsl_updated="$(exakit_versions_value updated 2>/dev/null || true)"
    if [ -n "$_vsl_updated" ]; then
        _vsl_updated="$(exakit_format_manifest_date "$_vsl_updated")"
        _vsl_text="$_vsl_text (updated $_vsl_updated)"
    fi
    # Kept inside 80 columns: this sits directly under the version card,
    # and a line that wraps there undoes the alignment the card just bought.
    info "Versions: $_vsl_text"
    if exakit_versions_schema_ahead; then
        info "This kit is older than the published manifest — update it first: exakit update exakit"
    fi
    _exakit_print_override_line
    return 0
}

# An env override outranks every source above, so say so rather than letting the
# line above take credit for a version the user picked.
_exakit_print_override_line() {
    for _pol_component in exapump mcp pyexasol nano personal; do
        if [ -n "$(_exakit_component_env_override "$_pol_component")" ]; then
            info "Some versions come from EXAKIT_* environment overrides and not from the manifest"
            return 0
        fi
    done
    return 0
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
# It is NOT a nag about every version: `exakit version` is where the full
# picture lives, and `exakit version` has its own always-on hint.
# ⇄ twin: Show-ExakitUpdateNotice in setup/lib/exakit-common.ps1.
EXAKIT_NOTICE_STATE="${EXAKIT_NOTICE_STATE:-$EXAKIT_CACHE_DIR/notice-state.json}"
# The notice is printed after every command, but working out WHAT to say costs
# real time: nine manifest reads and a live probe per component, about 600ms. The
# answer barely changes, so it is computed occasionally and printed from a cached
# plan. EXAKIT_NOTICE_PLAN_TTL is how long a plan is trusted; it is also thrown away
# the moment the manifest or the versions cache changes, which covers every update
# applied through the kit.
#
# What it cannot see is a component upgraded behind the kit's back -- `uv tool
# upgrade` on the MCP server, say -- because that moves only the binary on disk,
# which is the reading the cache exists to stop repeating. Such a machine is told
# about an update it has already taken, until the TTL runs out. That is the trade:
# one stale line for at most fifteen minutes, against 600ms on every command.
EXAKIT_NOTICE_PLAN="${EXAKIT_NOTICE_PLAN:-$EXAKIT_CACHE_DIR/notice-plan}"
EXAKIT_NOTICE_PLAN_TTL="${EXAKIT_NOTICE_PLAN_TTL:-900}"
# 0 = show the notice after every command. A pending update that nobody is told
# about is the same as no update mechanism at all: the machines that most need one
# belong to people who never run `exakit version`. Set
# EXAKIT_NOTICE_INTERVAL to a number of seconds to throttle it (86400 for the old
# once-a-day behaviour), or EXAKIT_NO_UPDATE_NOTICE=1 to silence it entirely.
EXAKIT_NOTICE_INTERVAL="${EXAKIT_NOTICE_INTERVAL:-0}"

# exakit_notice_due — has enough time passed since the last notice?
exakit_notice_due() {
    [ -f "$EXAKIT_NOTICE_STATE" ] || return 0
    _nd_last="$(sed -n 's/.*"last_shown"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "$EXAKIT_NOTICE_STATE" 2>/dev/null | head -1)"
    case "$_nd_last" in
        ''|*[!0-9]*) return 0 ;;
    esac
    case "$EXAKIT_NOTICE_INTERVAL" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$(( $(date +%s) - _nd_last ))" -ge "$EXAKIT_NOTICE_INTERVAL" ]
}

# exakit_notice_record — stamp the state file. Atomic, and never a reason for a
# command to fail: a read-only cache directory just means the notice repeats.
exakit_notice_record() {
    mkdir -p "$(dirname "$EXAKIT_NOTICE_STATE")" 2>/dev/null || return 0
    _nr_tmp="$EXAKIT_NOTICE_STATE.tmp.$$"
    printf '{\n  "last_shown": %s\n}\n' "$(date +%s)" > "$_nr_tmp" 2>/dev/null || return 0
    mv -f "$_nr_tmp" "$EXAKIT_NOTICE_STATE" 2>/dev/null || rm -f "$_nr_tmp"
    return 0
}

# A notice may never make an unrelated command feel slow. The cache is normally
# warm (version and update both refresh it); when it is not, this is
# one very short attempt that gives up almost immediately.
# _exakit_notice_signature — what the plan was derived from, as content.
#
# Timestamps were the obvious choice and the wrong one: bash compares mtimes with
# whole-second granularity, so an `exakit update` that rewrote the manifest in the
# same second the plan was written left the plan looking fresh. cksum is two forks
# and a few milliseconds, and it cannot be fooled by the clock.
# The files are passed as arguments, not redirected in: `cksum < missing` makes the
# SHELL report the failed redirection on its own stderr, which no 2>/dev/null inside
# the substitution can suppress, and a version notice must never leak a diagnostic
# about its own bookkeeping.
_exakit_notice_signature() {
    _ns_manifest=""
    _ns_cache=""
    if [ -f "$EXAKIT_MANIFEST" ]; then
        _ns_manifest="$(cksum "$EXAKIT_MANIFEST" 2>/dev/null | awk '{print $1"-"$2}')"
    fi
    if [ -f "$EXAKIT_VERSIONS_CACHE" ]; then
        _ns_cache="$(cksum "$EXAKIT_VERSIONS_CACHE" 2>/dev/null | awk '{print $1"-"$2}')"
    fi
    # The kit's own copy of the document counts too. It is the tier that answers
    # when there is no cache, and a self-update replaces it -- without this, a kit
    # whose baked document changed would keep announcing the previous one's news.
    _ns_baked=""
    _ns_baked_doc="$(exakit_versions_baked_doc 2>/dev/null || true)"
    if [ -n "$_ns_baked_doc" ] && [ -f "$_ns_baked_doc" ]; then
        _ns_baked="$(cksum "$_ns_baked_doc" 2>/dev/null | awk '{print $1"-"$2}')"
    fi
    printf '%s:%s:%s' "$_ns_manifest" "$_ns_cache" "$_ns_baked"
}

# _exakit_notice_plan_fresh — is the cached plan still worth believing?
#
# The TTL is the least of it. What matters is that applying an update silences the
# notice on the very next command: the manifest is rewritten by every install and
# every update, and the versions cache by every refresh, so a change to either
# retires the plan. Without that, `exakit update` would be followed by fifteen
# minutes of being told to run `exakit update`.
_exakit_notice_plan_fresh() {
    [ -f "$EXAKIT_NOTICE_PLAN" ] || return 1
    _npf_sig="$(_exakit_notice_plan_field sig)"
    [ "$_npf_sig" = "$(_exakit_notice_signature)" ] || return 1
    _npf_at="$(sed -n 's/^computed_at=\([0-9][0-9]*\)$/\1/p' "$EXAKIT_NOTICE_PLAN" 2>/dev/null | head -1)"
    case "$_npf_at" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$EXAKIT_NOTICE_PLAN_TTL" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$(( $(date +%s) - _npf_at ))" -lt "$EXAKIT_NOTICE_PLAN_TTL" ]
}

# _exakit_notice_plan_field <name> — one line out of the cached plan.
_exakit_notice_plan_field() {
    sed -n "s/^$1=//p" "$EXAKIT_NOTICE_PLAN" 2>/dev/null | head -1
}

# _exakit_notice_plan_write — key=value lines, not JSON: this is read on every
# single command, and a sed call beats parsing.
_exakit_notice_plan_write() {
    [ -n "$EXAKIT_NOTICE_PLAN" ] || return 0
    mkdir -p "$(dirname "$EXAKIT_NOTICE_PLAN")" 2>/dev/null || return 0
    _npw_tmp="$(mktemp "${EXAKIT_NOTICE_PLAN}.XXXXXX" 2>/dev/null)" || return 0
    {
        printf 'computed_at=%s\n' "$(date +%s)"
        printf 'sig=%s\n' "$(_exakit_notice_signature)"
        printf 'light=%s\n' "$_notice_light_detail"
        printf 'light_worst=%s\n' "$_notice_light_worst"
        printf 'heavy=%s\n' "$_notice_heavy_detail"
        printf 'heavy_worst=%s\n' "$_notice_heavy_worst"
    } > "$_npw_tmp" 2>/dev/null || { rm -f "$_npw_tmp"; return 0; }
    mv "$_npw_tmp" "$EXAKIT_NOTICE_PLAN" 2>/dev/null || rm -f "$_npw_tmp"
    return 0
}

_exakit_notice_refresh_cache() {
    exakit_versions_cache_fresh && return 0
    (
        EXAKIT_VERSION_LOOKUP_CONNECT_TIMEOUT=1
        EXAKIT_VERSION_LOOKUP_MAX_TIME=2
        exakit_versions_update_cache force >/dev/null 2>&1
    ) || true
    return 0
}

_exakit_notice_word() {
    case "$1" in
        critical)    printf 'A critical' ;;
        recommended) printf 'A recommended' ;;
        # A routine bump says nothing about urgency, because it has none to claim.
        *)           printf 'An' ;;
    esac
}

# exakit_notice_after_command — the whole notice, gates included. Always returns 0:
# nothing about version news may change what a command reports.
exakit_notice_after_command() {
    [ "${EXAKIT_NO_UPDATE_NOTICE:-0}" = "1" ] && return 0
    [ "${EXAKIT_VERSION_POLICY:-manifest}" = "manifest" ] || return 0
    # stderr must be a terminal: a notice has no business in a log file, a pipe,
    # or a CI transcript.
    [ -t 2 ] || return 0
    [ -f "$EXAKIT_MANIFEST" ] || return 0
    exakit_notice_due || return 0

    if _exakit_notice_plan_fresh; then
        _notice_light_worst="$(_exakit_notice_plan_field light_worst)"
        _notice_heavy_worst="$(_exakit_notice_plan_field heavy_worst)"
        [ -n "$_notice_light_worst" ] || _notice_light_worst="normal"
        [ -n "$_notice_heavy_worst" ] || _notice_heavy_worst="normal"
        # Confirm each cached candidate is STILL behind before repeating it. A plan
        # written while a component was mid-install kept announcing an update the
        # user had already taken, and disagreed with `exakit version` run
        # seconds later. Costs one probe per pending component -- and when nothing
        # is pending, which is the normal case, it costs nothing at all.
        _notice_light="$(_exakit_notice_still_behind "$(_exakit_notice_plan_field light)")"
        _notice_heavy="$(_exakit_notice_still_behind "$(_exakit_notice_plan_field heavy)")"
        _exakit_notice_say
        return 0
    fi

    _exakit_notice_refresh_cache
    exakit_versions_resolve_doc >/dev/null 2>&1 || return 0

    # Severity is tracked per group, not once for the whole notice: a routine
    # exapump bump must not be announced as critical just because the runtime
    # happens to have a critical one pending in the same breath.
    _notice_light=""
    _notice_heavy=""
    _notice_light_detail=""
    _notice_heavy_detail=""
    _notice_light_worst="normal"
    _notice_heavy_worst="normal"
    for _notice_component in $(exakit_update_targets all); do
        _notice_actual="$(exakit_update_actual_target "$_notice_component" 2>/dev/null || printf '%s\n' "$_notice_component")"
        _notice_avail="$(exakit_component_available "$_notice_actual" 2>/dev/null || true)"
        [ -n "$_notice_avail" ] || continue
        _notice_cur="$(exakit_component_current "$_notice_actual" 2>/dev/null || true)"
        [ -n "$_notice_cur" ] && [ "$_notice_cur" != "unknown" ] || continue
        [ "$_notice_cur" != "$_notice_avail" ] || continue
        # Different is not the same as behind. An install that is PAST the
        # advertised version has nothing pending: the kit never moves a component
        # backwards, so `exakit version` renders that row as "none" and
        # `exakit update` says "keeping yours". Announcing an update here made the
        # three commands contradict each other, and pointed the user at a command
        # that could not do anything. Compared in place rather than through
        # exakit_component_is_ahead, which would re-probe what is already in hand.
        if exakit_version_newer "$_notice_cur" "$_notice_avail"; then
            continue
        fi
        # Every pending update is announced, whatever its severity. Severity still
        # decides the WORDING (a critical bump says so), but no longer whether the
        # user hears about it at all: a routine exapump bump that is never
        # mentioned is a bump that never gets applied.
        _notice_severity="$(exakit_component_severity "$_notice_actual")"
        # Keep the worst severity in the group, on the normal < recommended <
        # critical ladder. This used to promote normal straight to recommended,
        # which was invisible while only flagged bumps got this far and would now
        # word every routine bump as a recommendation.
        if exakit_component_is_heavy "$_notice_actual"; then
            _notice_heavy="${_notice_heavy}${_notice_heavy:+, }$_notice_actual"
            _notice_heavy_detail="${_notice_heavy_detail:-}${_notice_heavy_detail:+, }$_notice_actual:$_notice_avail"
            case "$_notice_severity" in
                critical)    _notice_heavy_worst="critical" ;;
                recommended) [ "$_notice_heavy_worst" = "critical" ] || _notice_heavy_worst="recommended" ;;
            esac
        else
            _notice_light="${_notice_light}${_notice_light:+, }$_notice_actual"
            _notice_light_detail="${_notice_light_detail:-}${_notice_light_detail:+, }$_notice_actual:$_notice_avail"
            case "$_notice_severity" in
                critical)    _notice_light_worst="critical" ;;
                recommended) [ "$_notice_light_worst" = "critical" ] || _notice_light_worst="recommended" ;;
            esac
        fi
    done
    _exakit_notice_plan_write
    _exakit_notice_say
    return 0
}

# _exakit_notice_still_behind <name:advertised, name:advertised> — the names that are
# genuinely still behind, as a display list.
#
# The advertised version is stored with each candidate so this needs no document and
# no severity lookup: probe what is installed, compare, drop whatever has caught up.
_exakit_notice_still_behind() {
    _nsb_in="$1"
    [ -n "$_nsb_in" ] || return 0
    _nsb_out=""
    _nsb_rest="$_nsb_in"
    while [ -n "$_nsb_rest" ]; do
        case "$_nsb_rest" in
            *,*) _nsb_entry="${_nsb_rest%%,*}"; _nsb_rest="${_nsb_rest#*,}" ;;
            *)   _nsb_entry="$_nsb_rest"; _nsb_rest="" ;;
        esac
        # trim the space after a comma
        _nsb_entry="${_nsb_entry# }"
        _nsb_name="${_nsb_entry%%:*}"
        _nsb_want="${_nsb_entry#*:}"
        [ -n "$_nsb_name" ] || continue
        if [ -z "$_nsb_want" ] || [ "$_nsb_want" = "$_nsb_name" ]; then
            # A plan written before versions were recorded with the names: keep the
            # entry rather than silently dropping a real pending update.
            _nsb_out="${_nsb_out}${_nsb_out:+, }$_nsb_name"
            continue
        fi
        _nsb_now="$(exakit_component_current "$_nsb_name" 2>/dev/null || true)"
        if [ -z "$_nsb_now" ] || [ "$_nsb_now" = "unknown" ] || [ "$_nsb_now" = "$_nsb_want" ]; then
            continue
        fi
        # "Caught up" is not only "landed on exactly the advertised version" — an
        # install that overshot it has nothing pending either. Testing equality
        # alone kept such a component alive as a candidate, so a cached plan went
        # on announcing an update on every command with nothing able to clear it.
        if exakit_version_newer "$_nsb_now" "$_nsb_want"; then
            continue
        fi
        _nsb_out="${_nsb_out}${_nsb_out:+, }$_nsb_name"
    done
    printf '%s' "$_nsb_out"
}

# _exakit_notice_say — print whatever the plan says, freshly computed or cached.
# Reads the same four variables either path fills in.
_exakit_notice_say() {
    [ -n "$_notice_light" ] || [ -n "$_notice_heavy" ] || return 0

    printf '\n' >&2
    if [ -n "$_notice_light" ]; then
        printf '%s%s update is available for %s — apply in seconds:  exakit update%s\n' \
            "${UI_DIM:-}" "$(_exakit_notice_word "$_notice_light_worst")" "$_notice_light" "${UI_RESET:-}" >&2
    fi
    if [ -n "$_notice_heavy" ]; then
        # Never "run update now" for the runtime: it stops the database, so the
        # user picks the moment after seeing what it involves.
        printf '%s%s update is available for %s — requires stopping the database, details:  exakit version%s\n' \
            "${UI_DIM:-}" "$(_exakit_notice_word "$_notice_heavy_worst")" "$_notice_heavy" "${UI_RESET:-}" >&2
    fi
    printf '%sSilence this with EXAKIT_NO_UPDATE_NOTICE=1%s\n' "${UI_DIM:-}" "${UI_RESET:-}" >&2
    exakit_notice_record
    return 0
}

# exakit_print_kit2_discovery_line — one dim line offering the Kit 2 add-on, and
# ONLY when the maintainers have deliberately enabled that path by adding a kit2
# block to versions.json. Its absence is the launch switch: no block, no line,
# anywhere. It is never part of the after-command notice either — discovering an
# add-on is not an update anyone is behind on.
exakit_print_kit2_discovery_line() {
    [ "$(manifest_get kit_level 2>/dev/null || true)" = "1" ] || return 0
    _k2d_version="$(exakit_component_available kit2 2>/dev/null || true)"
    [ -n "$_k2d_version" ] || return 0
    _k2d_min="$(exakit_component_min_kit kit2 2>/dev/null || true)"
    if [ -n "$_k2d_min" ] && ! exakit_min_kit_satisfied "$_k2d_min"; then
        return 0
    fi
    _k2d_note="$(exakit_component_note kit2 2>/dev/null || true)"
    printf '    %sKit 2 (%s) is available — add it with: exakit upgrade-kit2%s\n' \
        "${UI_DIM:-}" "${_k2d_note:-Trusted AI Workflow add-on}" "${UI_RESET:-}"
    return 0
}

# exakit_update_kit2 — re-stage the Kit 2 assets from the kit copy. Kit 2 assets
# travel inside the kit tarball, so "updating Kit 2" is: make sure the kit copy is
# the one carrying them, then re-run the additive upgrade, which is idempotent and
# touches nothing but kit2.* state.
exakit_update_kit2() {
    [ "$(manifest_get kit_level 2>/dev/null || true)" = "2" ] || \
        die "Kit 2 is not installed. Add it with: exakit upgrade-kit2"
    _k2u_root="$(exakit_repo_root)" || die "Could not locate the kit's upgrade scripts."
    _k2u_script="$_k2u_root/upgrade/upgrade-kit2.sh"
    [ -f "$_k2u_script" ] || die "upgrade-kit2.sh is not part of this kit build."
    _k2u_bundled="$(exakit_kit2_bundled_version 2>/dev/null || true)"
    _k2u_advertised="$(exakit_component_available kit2 2>/dev/null || true)"
    if [ -n "$_k2u_advertised" ] && [ -n "$_k2u_bundled" ] && \
       exakit_version_newer "$_k2u_advertised" "$_k2u_bundled"; then
        # The newer bundle is not on this machine yet, and no amount of re-staging
        # will conjure it: the assets arrive with the kit itself.
        warn "Kit 2 $_k2u_advertised is advertised, but this kit copy carries $_k2u_bundled."
        info "Kit 2 assets travel with the kit — update it first:  exakit update exakit"
        return 0
    fi
    info "Re-staging the Kit 2 assets from $(ui_tilde "$_k2u_root")"
    bash "$_k2u_script" || die "The Kit 2 upgrade script reported an error; nothing else was changed."
}

# exakit_print_version_table — the component table `exakit version` renders
# under its Kit panel: what is installed, and whether anything newer is waiting.
#
# This is the merge of what used to be two commands. `exakit version` listed the
# installed versions and `exakit update-check` compared them against the
# advertised set, so answering the only question either was ever asked meant
# running both and reading one screen against the other — and they disagreed
# often enough to need a comment saying which to trust. There is one screen now,
# and one place where a component's state is decided.
#
# Three columns, because the third answers the question the other two raise:
#   Component  what to name in `exakit update <component>`
#   Version    what is on this machine right now
#   Status     current, or the advertised version and what applying it involves
# The tagged version, the maintainer's severity and the action all live in
# Status: each is only ever interesting for a row that is behind, and four
# mostly-empty columns pushed the card past 80 columns to say nothing.
#
# Someone who asks explicitly gets fresh data: the TTL exists for the readers
# that run behind other commands, not for this one.
# ⇄ twin: Invoke-CmdVersion in setup/exakit.ps1.
exakit_print_version_table() {
    # Everything down to the table itself is GATHERING, and on a cold cache or a
    # slow network it is the longest part of `exakit version` — the screen sat
    # silent right after the Kit box, which is where it was reported. Narrated
    # in two phases so the reader can see which one is taking the time.
    # ui_spin_begin draws nothing unless stdout is a terminal, so a piped or
    # captured run is unchanged.
    if [ "${EXAKIT_VERSION_POLICY:-manifest}" = "manifest" ]; then
        ui_spin_begin "Checking for newer versions"
        exakit_versions_update_cache force >/dev/null 2>&1 || true
        exakit_versions_resolve_doc >/dev/null 2>&1 || true
        ui_spin_end
    fi
    ui_spin_begin "Checking installed components"
    # One parallel array per column, not one packed string per row. The packed
    # form needs a delimiter, and the tab it used was the wrong one: `set -- $row`
    # collapses runs of IFS *whitespace*, so a row whose severity cell was empty
    # silently shifted its notes into the wrong fields. The old code escaped that
    # only because its severity cell was padded to a fixed width and could never
    # be empty — which is exactly the invariant this table drops. Separate arrays
    # cannot shift.
    _uc_comp=(); _uc_ver=(); _uc_status=(); _uc_note=(); _uc_maint=()
    # Column widths measured, not guessed. A fixed %-10s fits the built-in
    # component names and nothing else: dash-server (11), json-tables (11) and
    # exasol-vscode (13) each overflow it, and an overflowing cell pushes every
    # column after it right ON THAT ROW ONLY — so the table lost its alignment
    # exactly when a user had add-ons installed, and only for their rows.
    _uc_cw=9; _uc_vw=7
    # One counter, not three. The table used to sort what was waiting into quick,
    # heavy and staged so it could print a different closing line for each, and
    # the three lines said the same thing three ways. `exakit update` already
    # knows a runtime change needs the database stopped and asks at the moment it
    # matters; this screen only has to say that something is waiting.
    _pending=0
    for _component in $(exakit_version_table_targets); do
        _row_component="$(exakit_update_actual_target "$_component" 2>/dev/null || printf '%s\n' "$_component")"
        _row_installed="$(exakit_version_plain "$(exakit_version_installed_cell "$_row_component")")"
        _row_available="$(exakit_version_plain "$(exakit_component_available "$_row_component" 2>/dev/null || true)")"
        [ -n "$_row_available" ] || _row_available="unknown"
        _row_note=""
        _row_severity="$(exakit_component_severity "$_row_component" 2>/dev/null || true)"
        _status="current"
        if ! exakit_component_supported "$_row_component"; then
            # Nothing to offer and nothing wrong: there is simply no build for
            # this machine, and an update command that cannot succeed must not be
            # printed.
            _row_installed="not available"
            _status="-"
            _row_severity=""
            _row_note="no $_row_component build exists for this platform"
        elif [ "$_row_installed" = "not installed" ] && _exakit_addon_registered "$_row_component"; then
            # An add-on nobody has installed is not behind on anything: it is an
            # offer. The marketplace is the only path that installs one, so that
            # is the whole status — naming a version here would read as a pending
            # update to something that is not on the machine.
            _status="exakit marketplace"
            _row_severity=""
        elif [ "$_row_available" = "unknown" ] || [ "$_row_installed" = "unknown" ]; then
            _status="inspect"
        elif [ "$_row_installed" = "not installed" ] && exakit_component_is_heavy "$_row_component"; then
            # A runtime that is not installed is not a runtime this machine wants:
            # offering to deploy Exasol Personal onto a Nano install would be
            # actively wrong. (A missing light component, by contrast, is exactly
            # the repair case below.)
            _status="inspect"
        elif [ "$_row_installed" != "not installed" ] && \
             exakit_version_newer "$_row_installed" "$_row_available"; then
            # Installed is ahead of the published set. The kit never moves a
            # component backwards, so there is nothing to offer: lowering a
            # version in versions.json is not a rollback lever, and a user who
            # upgraded a component themselves keeps what they chose. Counts toward
            # neither the "apply them in one go" hint nor the heavy deferral,
            # because no command belongs in this row at all.
            #
            # The row says only "none". Not "yours is newer than tested", which
            # apologised for the install and made the tested set sound abandoned;
            # not the tagged number either, which invites the reader to go looking
            # for a way back to it. There is nothing to do, so the row says so and
            # stops. The severity goes with it — a severity rates the advertised
            # version, and there is nothing to recommend to someone already past it.
            _status="none"
            _row_severity=""
        elif [ "$_row_installed" != "$_row_available" ]; then
            _row_min_kit="$(exakit_component_min_kit "$_row_component" 2>/dev/null || true)"
            if [ -n "$_row_min_kit" ] && ! exakit_min_kit_satisfied "$_row_min_kit"; then
                # Waiting, but not on this reader: `exakit update` cannot apply
                # it until the kit itself moves, so it must not be counted into
                # the closing line that promises it can.
                _status="update exakit first (needs kit >= $_row_min_kit)"
                _pending=$((_pending - 1))
            elif [ "$_row_installed" = "not installed" ]; then
                # Not an upgrade: the component the manifest says belongs here is
                # missing, and `exakit update` puts it back.
                _status="$_row_available available (repair)"
            else
                # No "(heavy)" or "(major)" suffix: what applying a component
                # involves is `exakit update`'s to explain, at the point where it
                # asks. Saying it here warned about a cost on a screen that cannot
                # charge it, twice for the runtime, and left the Status column
                # reading like a set of caveats rather than a set of versions.
                _status="$_row_available available"
            fi
            _pending=$((_pending + 1))
        fi
        [ "${#_row_component}" -gt "$_uc_cw" ] && _uc_cw="${#_row_component}"
        [ "${#_row_installed}" -gt "$_uc_vw" ] && _uc_vw="${#_row_installed}"
        _uc_comp+=("$_row_component")
        _uc_ver+=("$_row_installed")
        _uc_status+=("$(_exakit_status_cell "$_status" "$_row_severity")")
        _uc_note+=("$_row_note")
        _uc_maint+=("$(exakit_component_note "$_row_component" 2>/dev/null || true)")
    done

    # A card, like every other framed answer the kit gives. ui_panel_end measures
    # with _ui_visible_len, so the coloured severity suffix does not throw the
    # border off the way a byte count would.
    ui_spin_end
    ui_panel_begin "Components"
    ui_panel_line "$(printf '%-*s %-*s %s' "$_uc_cw" "Component" "$_uc_vw" "Version" "Status")"
    _uc_i=0
    while [ "$_uc_i" -lt "${#_uc_comp[@]}" ]; do
        ui_panel_line "$(printf '%-*s %-*s %s' \
            "$_uc_cw" "${_uc_comp[$_uc_i]}" "$_uc_vw" "${_uc_ver[$_uc_i]}" "${_uc_status[$_uc_i]}")"
        _exakit_version_note_lines "${_uc_note[$_uc_i]}"
        _exakit_version_note_lines "${_uc_maint[$_uc_i]}"
        _uc_i=$((_uc_i + 1))
    done
    ui_panel_end
    printf '\n'
    # This screen just worked out the truth the long way. Retire the cached plan
    # so the next notice cannot repeat something the table above has just
    # contradicted.
    rm -f "$EXAKIT_NOTICE_PLAN" 2>/dev/null || true
    exakit_print_versions_source_line
    exakit_print_kit2_discovery_line
    # One command is promoted, and it is the one that handles everything:
    # `exakit update`. Per-component commands still work and the rows name the
    # components, so anyone who wants one has it — but a screen that listed a
    # command per row taught the long way round to the reader who least needed it.
    # The add-on rows carry their own `exakit marketplace`, so the discovery line
    # that used to repeat it here is gone too.
    if [ "$_pending" -gt 0 ]; then
        info "Bring everything up to date with: exakit update"
    fi
    return 0
}

# _exakit_version_note_lines <text> — one note, wrapped and indented inside the
# card. A maintainer note is free text, and one long enough to blow the card past
# 80 columns would wrap in the terminal instead, taking the border with it.
# Silent on an empty note, so no caller has to test first.
_exakit_version_note_lines() {
    [ -n "$1" ] || return 0
    _vnl_line=""
    for _vnl_word in $1; do
        if [ -z "$_vnl_line" ]; then
            _vnl_line="$_vnl_word"
        elif [ "$(( ${#_vnl_line} + 1 + ${#_vnl_word} ))" -le 68 ]; then
            _vnl_line="$_vnl_line $_vnl_word"
        else
            ui_panel_line "  ${UI_DIM:-}$_vnl_line${UI_RESET:-}"
            _vnl_line="$_vnl_word"
        fi
    done
    [ -n "$_vnl_line" ] && ui_panel_line "  ${UI_DIM:-}$_vnl_line${UI_RESET:-}"
    return 0
}

# exakit_version_table_targets — every row the table shows.
#
# The update set (what `exakit update` would act on) plus the add-ons this
# machine COULD install: a row saying "not installed" is only worth printing when
# `exakit marketplace` can actually fix it, so an add-on that cannot run here (no
# VS Code, JSON Tables on Windows) is left out entirely rather than dangling an
# install that would be refused. Same filter, and so the same list, as the
# marketplace screen itself.
exakit_version_table_targets() {
    exakit_update_targets all
    while read -r _vtt_id <&3; do
        [ -n "$_vtt_id" ] || continue
        _exakit_addon_offerable "$_vtt_id" || continue
        # PRESENT, not kit-installed: a tool the user installed themselves is
        # already on the machine, and the kit refuses to manage that copy — so a
        # row telling them to run `exakit marketplace` for it advertises an
        # install that would be declined. Same check the marketplace screen makes,
        # so the two screens agree about what is still on offer.
        _exakit_marketplace_addon_present "$_vtt_id" && continue
        printf '%s\n' "$_vtt_id"
    done 3<<EXAKIT_VTT_EOF
$(exakit_marketplace_addons | cut -d'|' -f1)
EXAKIT_VTT_EOF
}

# exakit_version_installed_cell <component> — the Version cell: the version that
# is on this machine right now, or "not installed".
#
# Only that. The cell used to carry a "(kit installed X)" suffix when the copy on
# the machine was not the one the kit put there, and it cost more than it said:
# the annotation is twice the width of the version it explains, so it widened
# every row of the table to push the card past 80 columns, and it had to be
# stripped back off before each of the comparisons below — one more thing to
# forget on the next arm added. What is installed is what is installed.
exakit_version_installed_cell() {
    # The reader returns non-zero only when the component is provably ABSENT, and
    # that verdict has to survive: swallowing it made `exakit version` print a
    # recorded version for a deleted binary while status said "not installed".
    if _vic_live="$(exakit_component_current "$1" 2>/dev/null)"; then
        :
    else
        printf 'not installed\n'
        return 0
    fi
    if [ -z "$_vic_live" ]; then
        printf '%s\n' "$(exakit_version_recorded "$1" | sed -e 's/^$/not installed/')"
        return 0
    fi
    printf '%s\n' "$_vic_live"
}

# exakit_version_recorded <component> — the version the manifest says this
# install put on the machine, or empty when it records none.
exakit_version_recorded() {
    case "$1" in
        nano|personal)
            # runtime.image is a full reference (docker.io/exasol/nano:TAG) while
            # the live probe reports the tag alone. Compare tag with tag, or every
            # Nano install would claim a drift that is not there.
            _vr_val="$(manifest_get runtime.version 2>/dev/null || true)"
            if [ -z "$_vr_val" ]; then
                _vr_val="$(manifest_get runtime.image 2>/dev/null || true)"
                case "$_vr_val" in *:*) _vr_val="${_vr_val##*:}" ;; esac
            fi
            ;;
        mcp) _vr_val="$(manifest_get components.mcp_server.version 2>/dev/null || true)" ;;
        # The kit records no version for itself: exakit_component_current reads it
        # from the installed command, and annotating that with the manifest's copy
        # would report drift against the very file that was just updated.
        exakit) _vr_val="" ;;
        *) _vr_val="$(manifest_get "components.$(printf '%s' "$1" | tr '-' '_').version" 2>/dev/null || true)" ;;
    esac
    printf '%s\n' "$_vr_val"
}

# _exakit_status_cell <status> <severity> — the Status cell, with the maintainer's
# severity appended when it is not the normal one.
#
# Only a flagged row shows a severity, so it stays the one thing on the screen
# that draws the eye. Colour goes on last and only on the suffix: ui_panel_end
# measures with _ui_visible_len, so the escapes cost the border nothing.
_exakit_status_cell() {
    case "$2" in
        critical)
            _sc_suffix="(critical)"
            [ "${UI_FANCY:-0}" = 1 ] && _sc_suffix="${UI_WARN:-}${_sc_suffix}${UI_RESET:-}"
            printf '%s %s' "$1" "$_sc_suffix"
            ;;
        recommended)
            _sc_suffix="(recommended)"
            [ "${UI_FANCY:-0}" = 1 ] && _sc_suffix="${UI_OK:-}${_sc_suffix}${UI_RESET:-}"
            printf '%s %s' "$1" "$_sc_suffix"
            ;;
        *) printf '%s' "$1" ;;
    esac
}

exakit_update_self() {
    _latest="$(exakit_component_available exakit)"
    [ -n "$_latest" ] || die "Could not resolve the advertised starter kit version."
    _current="$(exakit_component_current exakit 2>/dev/null || true)"
    if [ "$_latest" = "$_current" ]; then
        ok "exakit is already current ($_current)"
        return 0
    fi
    _repo="$EXAKIT_KIT_REPO"
    _kit_dir="$EXAKIT_HOME/kit"
    _tmp="$(mktemp "${TMPDIR:-/tmp}/exakit-kit.XXXXXX")"
    _stage="$(mktemp -d "${TMPDIR:-/tmp}/exakit-kit-stage.XXXXXX")"
    _backup="${_kit_dir}.backup-$(date +%Y%m%d-%H%M%S)"
    info "Updating starter kit ${_current:-unknown} -> $_latest"
    # main first — that is what install.sh fetches, and kit script changes live on
    # main: a tag exists only where a release was cut. The tag URLs stay behind it
    # so a kit installed from a tagged release still updates, and so a v0.1.0 field
    # kit (which only ever knew tags) keeps working.
    _kit_ref=""
    for _kit_candidate in "main" "v${_latest}" "${_latest}"; do
        case "$_kit_candidate" in
            main) _kit_url="https://github.com/${_repo}/archive/refs/heads/main.tar.gz" ;;
            *)    _kit_url="https://github.com/${_repo}/archive/refs/tags/${_kit_candidate}.tar.gz" ;;
        esac
        if curl -fL --proto '=https' --retry 3 --connect-timeout 15 -sS -o "$_tmp" "$_kit_url"; then
            _kit_ref="$_kit_candidate"
            break
        fi
    done
    if [ -z "$_kit_ref" ]; then
        rm -f "$_tmp"
        rm -rf "$_stage"
        die "Could not download the starter kit from $_repo (tried main and the $_latest tags)."
    fi
    tar -xzf "$_tmp" -C "$_stage" --strip-components 1 || {
        rm -rf "$_stage"
        rm -f "$_tmp"
        die "Could not unpack the starter kit update; existing kit copy was left untouched."
    }
    rm -f "$_tmp"
    # versions.json is on this list deliberately: without it the new kit copy has
    # no offline version tier and cannot say what version it is. The eight paths
    # before it are the ones v0.1.0 also validates — none of them may ever be
    # renamed, or an old kit refuses the upgrade.
    for _required in setup/exakit setup/lib/common.sh setup/lib/runtime-nano.sh setup/lib/runtime-personal.sh setup/lib/exapump.sh setup/lib/mcp.sh setup/exakit.ps1 setup/lib/exakit-common.ps1 versions.json; do
        [ -f "$_stage/$_required" ] || {
            rm -rf "$_stage"
            die "Downloaded starter kit is incomplete (missing $_required); existing kit copy was left untouched."
        }
    done
    # What actually landed is what gets recorded. GitHub's raw endpoint can serve a
    # newer versions.json than the branch tarball for a few minutes after a merge,
    # and claiming a version that is not on disk would make every later comparison
    # lie (and re-download this kit on every update).
    _staged_version="$(exakit_kit_version_at "$_stage" 2>/dev/null || true)"
    if [ -z "$_staged_version" ]; then
        _staged_version="$_latest"
    elif [ "$_staged_version" != "$_latest" ] && exakit_version_newer "$_latest" "$_staged_version"; then
        warn "The downloaded kit is $_staged_version, not the advertised $_latest — the published manifest is a few minutes ahead of $_kit_ref. Recording $_staged_version."
    fi
    if [ -d "$_kit_dir" ]; then
        mv "$_kit_dir" "$_backup" || {
            rm -rf "$_stage"
            die "Could not back up existing kit copy; update was not applied."
        }
        info "Previous kit copy kept at $_backup"
    fi
    mkdir -p "$(dirname "$_kit_dir")"
    if ! mv "$_stage" "$_kit_dir"; then
        [ -d "$_backup" ] && mv "$_backup" "$_kit_dir"
        rm -rf "$_stage"
        die "Could not install the staged starter kit update; previous kit copy was restored."
    fi
    if [ -f "$_kit_dir/setup/exakit" ]; then
        mkdir -p "$EXAKIT_BIN_DIR"
        install -m 755 "$_kit_dir/setup/exakit" "$EXAKIT_BIN_DIR/exakit" \
            || die "Could not install the exakit command to $EXAKIT_BIN_DIR (is it writable? is the disk full?)."
    else
        [ -d "$_backup" ] && { rm -rf "$_kit_dir"; mv "$_backup" "$_kit_dir"; }
        die "Updated kit did not contain setup/exakit after staging; previous kit copy was restored."
    fi
    manifest_set kit.source "${_repo}@${_kit_ref}"
    # Record the version too, not just where it came from. exakit_component_current
    # reads kit.version first, so without this the kit would report its old
    # version forever: the table would keep offering the same update, `exakit
    # version` would keep nagging, and `exakit update` would re-download the whole
    # kit on every run.
    manifest_set kit.version "$_staged_version"
    ok "exakit updated to $_staged_version. Database data, credentials, and MCP state were not changed."
    # Refresh the AI skills from the copy that just landed. The update replaces
    # the whole kit directory, so a release that adds or rewords a skill leaves
    # the agents' discovery folders holding the PREVIOUS text with nothing to say
    # so. `exakit skills` can now report that drift, but detecting it and never
    # resolving it just moves the work to the user; the skills ship with the kit,
    # so they travel with a kit update. Best-effort: a stale skill must not fail
    # an otherwise complete update.
    if ls "$_kit_dir"/skills/*/SKILL.md >/dev/null 2>&1; then
        exakit_install_skills >/dev/null 2>&1 \
            && ok "AI skills refreshed from the new kit copy." \
            || warn "The AI skills could not be refreshed — run: exakit skills-install"
    fi
    # The kit that just landed describes itself: read the section out of the NEW
    # copy, which is already in place at this point.
    exakit_print_whats_new "$_staged_version" "What's new in $_staged_version" || true
}

exakit_update_component() {
    _component="$1"
    shift || true
    # Defence in depth, and the last word on the subject. exakit_update settles
    # this before it gets here, but the updaters below hold no version opinion of
    # their own -- they install whatever they are handed, older included -- so a
    # caller that forgets to ask is one edit away from a downgrade. That is how
    # the runtime offer came to ask permission to stop a database and replace
    # 2.1.0 with 2.0.0.
    #
    # There is no downgrade in this kit: not on request, not by naming a
    # component explicitly, not with an env override, and not as a
    # maintainer-advised rollback. Lowering a version in versions.json is a way
    # to describe a tested set, never a lever to drag installs backwards -- to
    # withdraw a bad release, publish a higher version.
    _uc_actual="$(exakit_update_actual_target "$_component" 2>/dev/null || printf '%s\n' "$_component")"
    if exakit_component_is_ahead "$_uc_actual"; then
        ok "$_uc_actual is newer than the tested version -- keeping yours"
        return 0
    fi
    case "$_component" in
        exakit) exakit_update_self ;;
        exapump)
            command -v exapump_update >/dev/null 2>&1 || die "exapump module is not available in this version."
            exapump_update
            ;;
        mcp)
            command -v mcp_update >/dev/null 2>&1 || die "MCP module is not available in this version."
            mcp_update
            ;;
        pyexasol)
            command -v pyexasol_update >/dev/null 2>&1 || die "pyexasol module is not available in this version."
            pyexasol_update
            ;;
        kit2) exakit_update_kit2 ;;
        runtime)
            case "$(exakit_installation_runtime_type 2>/dev/null)" in
                nano)
                    [ "$#" -eq 0 ] || die "Personal upgrade options are not valid for the Nano runtime."
                    nano_update
                    ;;
                personal) personal_update "$@" ;;
                *) die "No runtime is recorded in the manifest." ;;
            esac
            ;;
        nano)
            [ "$#" -eq 0 ] || die "Personal upgrade options are not valid for Nano."
            nano_update
            ;;
        personal) personal_update "$@" ;;
        *)
            # Marketplace add-ons dispatch to their module's <id>_update.
            if _exakit_addon_registered "$_component"; then
                _uc_fn="$(_exakit_addon_fn "$_component" update)"
                command -v "$_uc_fn" >/dev/null 2>&1 || die "The $_component module is not available in this version."
                "$_uc_fn"
            else
                die "Unknown update target: $_component"
            fi
            ;;
    esac
}

# --- the heavy (runtime) update, offered inline instead of handed back --------
#
# `exakit update` used to refuse the heavy part outright: it printed "needs the
# database stopped, so it is not part of a routine update" and left the user to
# run `exakit update runtime` themselves, after stopping nothing and updating
# nothing. The work was never the problem — the second command was. On a
# terminal the offer is now made where the user already is, and one "y" runs the
# whole sequence: stop the database, update the runtime, bring it back up, say so.
#
# Both entry points run the SAME implementation: everything below ends at
# exakit_update_component, which is exactly what `exakit update runtime` calls.
# `exakit update runtime` itself is untouched — still standalone, still
# unprompted beyond the runtime updater's own confirmation.

# exakit_runtime_status / exakit_runtime_start — the runtime-agnostic pair the
# inline offer needs to keep its promise ("the database is running again
# afterwards"). Guarded on purpose: common.sh is sourced without the runtime
# modules (the test suites do it, and so does any caller that only needs version
# state), and an absent module means "cannot tell", not "not running".
# ⇄ twins: Get-ExakitRuntimeStatus / Start-ExakitRuntime in setup/exakit.ps1.
exakit_runtime_status() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        nano)     command -v nano_status >/dev/null 2>&1 && nano_status 2>/dev/null ;;
        personal) command -v personal_status >/dev/null 2>&1 && personal_status 2>/dev/null ;;
    esac
    return 0
}

exakit_runtime_start() {
    case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
        nano)     command -v nano_start >/dev/null 2>&1 && nano_start ;;
        personal) command -v personal_start >/dev/null 2>&1 && personal_start ;;
    esac
    return 0
}

# exakit_stdin_is_tty — is there a terminal this run can actually ask a question
# on? Deliberately stricter than confirm()'s _exakit_prompt_tty, which falls back
# to /dev/tty: a piped or redirected run must not have a database-stopping
# question put on a terminal it is not reading from.
# ⇄ twin: Test-ExakitInteractive in setup/lib/exakit-common.ps1.
exakit_stdin_is_tty() {
    [ -t 0 ]
}

# exakit_runtime_update_is_staged <installed> <advertised> — true for an Exasol
# Personal MAJOR upgrade. That one is a data migration with its own backup-gated
# three-step flow (personal_upgrade_plan: --plan, --backup, --apply). A single
# y/N is not informed consent for it, so it keeps the deferral it has today.
# ⇄ twin: Test-ExakitRuntimeUpdateStaged in setup/exakit.ps1.
exakit_runtime_update_is_staged() {
    [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "personal" ] || return 1
    _rus_cur="$(exakit_major_version "${1:-}" 2>/dev/null || true)"
    _rus_new="$(exakit_major_version "${2:-}" 2>/dev/null || true)"
    case "$_rus_cur$_rus_new" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_rus_cur" != "$_rus_new" ]
}

# exakit_runtime_update_preanswer — "yes", "no", or empty when nobody has
# answered yet. Two ways to answer without a prompt, and they are the ways this
# kit already uses: `exakit update --yes` (the uninstall flag spelling) and
# EXAKIT_CONFIRM_RUNTIME_UPDATE, the variable that already pre-answers
# `exakit update runtime`. One opt-in, both entry points — a fleet that has said
# "yes, you may recreate the database container" has said it once.
# ⇄ twin: Get-ExakitRuntimeUpdatePreanswer in setup/exakit.ps1.
exakit_runtime_update_preanswer() {
    if [ "${_upd_assume_yes:-0}" = "1" ]; then
        printf 'yes\n'
        return 0
    fi
    case "${EXAKIT_CONFIRM_RUNTIME_UPDATE:-}" in
        1|y|Y|yes|YES|Yes) printf 'yes\n' ;;
        0|n|N|no|NO|No)    printf 'no\n' ;;
    esac
    return 0
}

# exakit_runtime_update_explain <actual> <installed> <advertised> — what the user
# is about to agree to, before they agree to it: that the database goes down,
# roughly for how long, that it comes back up, and what happens to the data.
# Stopping a database is disruptive and outward-facing; a bare "[y/N]" is not
# enough to consent to it.
# ⇄ twin: Write-ExakitRuntimeUpdateExplanation in setup/exakit.ps1.
exakit_runtime_update_explain() {
    warn "$1 $2 -> $3 needs the database stopped."
    case "$1" in
        nano)
            info "The database goes down while the container is recreated, then it is started again and checked — usually a minute or two, longer if the new image still has to be pulled."
            info "Your data is kept: the same data volume is reused, and the previous image is put back if the new container does not come up."
            ;;
        personal)
            info "The launcher is replaced; the database is checked afterwards and started again if it ends up down — usually under a minute."
            info "Your data is kept: this update neither deletes nor migrates the deployment's database content."
            ;;
        *)
            info "The database goes down for the update and is started again afterwards."
            info "Your data is kept."
            ;;
    esac
}

# exakit_apply_runtime_update <component> — stop, update, start, report.
#
# The runtime updaters own the sequence itself and are called here exactly as
# `exakit update runtime` calls them: nano_update pulls the new image, stops the
# container, recreates it on the SAME data volume, waits for readiness and puts
# the previous image back if it never becomes ready; personal_update replaces the
# launcher and leaves the deployment's data alone. There is no separate copy of
# that logic here, and no separate copy of the backup story either — see the
# comment on exakit_offer_runtime_update.
#
# What this adds is the one thing the prompt promises and the updaters do not
# guarantee across runtimes: a database that was up before this command is up
# after it.
# ⇄ twin: Invoke-ExakitRuntimeUpdateApply in setup/exakit.ps1.
exakit_apply_runtime_update() {
    _aru_was_running=no
    [ "$(exakit_runtime_status)" = "running" ] && _aru_was_running=yes
    # The offer above IS the confirmation the runtime updater asks for. Asking one
    # question twice is not a safety feature, so the answer is passed down.
    EXAKIT_CONFIRM_RUNTIME_UPDATE=1
    export EXAKIT_CONFIRM_RUNTIME_UPDATE
    exakit_update_component "$1"
    _aru_status="$(exakit_runtime_status)"
    if [ "$_aru_was_running" = "yes" ] && [ -n "$_aru_status" ] && [ "$_aru_status" != "running" ] && [ "$_aru_status" != "starting" ]; then
        info "Bringing the database back up"
        exakit_runtime_start
        _aru_status="$(exakit_runtime_status)"
    fi
    case "$_aru_status" in
        running)  ok "Runtime updated and the database is running again." ;;
        starting) ok "Runtime updated; the database is still coming up — check it with: exakit status" ;;
        '')       ok "Runtime updated." ;;
        *)        warn "Runtime updated, but the database reports '$_aru_status' — start it with: exakit start" ;;
    esac
    return 0
}

# exakit_offer_runtime_update <component> <actual> <installed> <advertised> —
# the heavy part of a routine `exakit update`, decided here instead of being
# handed to the user as homework. Returns 0 when it was applied, 1 when it was
# deferred (and then prints the exact command that applies it later).
#
# On backups: the kit has no data-export facility, and this path needs none.
# Neither runtime update touches the database content — Nano recreates the
# container over the persisted data volume and records a pre-update snapshot of
# the runtime metadata under ~/.exasol-starter-kit/backups/nano-update/, with an
# automatic restore of the previous image if the new one will not start; Personal
# replaces the launcher binary and says so. The one runtime change that IS a data
# migration is the Personal major upgrade, and that already has a real backup
# (personal_upgrade_backup tars the whole deployment) inside its own three-step
# flow — which is exactly why this function refuses to start it from a y/N.
# ⇄ twin: Invoke-ExakitRuntimeUpdateOffer in setup/exakit.ps1.
exakit_offer_runtime_update() {
    _oru_component="$1"
    _oru_actual="$2"
    _oru_cur="$3"
    _oru_avail="$4"

    if exakit_runtime_update_is_staged "$_oru_cur" "$_oru_avail"; then
        warn "$_oru_actual $_oru_cur -> $_oru_avail is a major upgrade: it needs a backup and a data migration, so a routine update does not start it."
        info "See the steps first:  exakit update runtime --plan"
        return 1
    fi

    case "$(exakit_runtime_update_preanswer)" in
        yes)
            exakit_runtime_update_explain "$_oru_actual" "$_oru_cur" "$_oru_avail"
            ;;
        no)
            warn "$_oru_actual $_oru_cur -> $_oru_avail was left alone: the runtime update is answered 'no' (EXAKIT_CONFIRM_RUNTIME_UPDATE)."
            info "Apply it when convenient:  exakit update runtime"
            return 1
            ;;
        *)
            # No terminal, no answer: a prompt nobody can answer must never turn
            # into a stopped database, so a pipe, a CI job, a cron entry and a
            # scripted install all get exactly today's safe deferral.
            if ! exakit_stdin_is_tty; then
                warn "$_oru_actual $_oru_cur -> $_oru_avail needs the database stopped, so it is not part of a routine update."
                info "Apply it when convenient:  exakit update runtime"
                info "Unattended runs can opt in:  exakit update --yes  (or EXAKIT_CONFIRM_RUNTIME_UPDATE=1)"
                return 1
            fi
            exakit_runtime_update_explain "$_oru_actual" "$_oru_cur" "$_oru_avail"
            if ! confirm "Stop the database and update the runtime now?" n; then
                info "Nothing was stopped. Apply it when convenient:  exakit update runtime"
                return 1
            fi
            ;;
    esac

    exakit_apply_runtime_update "$_oru_component"
}

exakit_update() {
    # -y/--yes answers the runtime offer below and may appear anywhere in the
    # arguments; everything else keeps its position, so the target and the
    # Personal upgrade options arrive exactly as they did. Rebuilt by rotating
    # the positional parameters — no arrays, so bash 3.2 and dash both cope.
    _upd_assume_yes=0
    _upd_left="$#"
    while [ "$_upd_left" -gt 0 ]; do
        case "$1" in
            -y|--yes) _upd_assume_yes=1 ;;
            *) set -- "$@" "$1" ;;
        esac
        shift
        _upd_left=$((_upd_left - 1))
    done
    if [ "$_upd_assume_yes" = "1" ]; then
        # --yes answers the only question this command asks: may it stop the
        # database. The runtime updaters read the same variable, so an explicit
        # `exakit update runtime --yes` is unprompted for the same reason.
        EXAKIT_CONFIRM_RUNTIME_UPDATE=1
        export EXAKIT_CONFIRM_RUNTIME_UPDATE
    fi
    _target="${1:-all}"
    if [ "$#" -gt 0 ]; then shift; fi
    if [ "$#" -gt 0 ]; then
        case "$_target" in
            personal|runtime|database|db) ;;
            *) die "Update options are only supported for Personal runtime updates." ;;
        esac
    fi
    _targets="$(exakit_update_targets "$_target")" || die "Unknown update target: $_target"
    exakit_init_logging
    # An explicit update applies what is advertised right NOW, so ask upstream
    # once and resolve in this shell — the loop below reads the same document.
    if [ "${EXAKIT_VERSION_POLICY:-manifest}" = "manifest" ]; then
        exakit_versions_update_cache force >/dev/null 2>&1 || true
        exakit_versions_resolve_doc >/dev/null 2>&1 || true
    fi
    exakit_print_versions_source_line
    _deferred=0
    _acted=0
    for _component in $_targets; do
        # _upd_ prefix: verify_sha256 (reached through the component updaters)
        # assigns _actual, and bash has no function-local variables here.
        _upd_actual="$(exakit_update_actual_target "$_component" 2>/dev/null || printf '%s\n' "$_component")"
        _cur="$(exakit_component_current "$_upd_actual" 2>/dev/null || true)"
        _avail="$(exakit_component_available "$_upd_actual" 2>/dev/null || true)"
        # No build for this machine: a routine update stays quiet about it (there is
        # nothing the user can do), and an explicit target says why rather than
        # failing deep inside the installer.
        if ! exakit_component_supported "$_upd_actual"; then
            [ "$_target" = "all" ] && continue
            die "$_upd_actual has no build for this platform, so there is nothing to update."
        fi
        # Nothing advertised for this component (unreadable manifest, or a
        # component this kit knows nothing about): a routine update says so and
        # moves on. An explicit single target still runs, so its updater can
        # report the real reason.
        if [ "$_target" = "all" ] && [ -z "$_avail" ]; then
            warn "No advertised version for $_upd_actual — skipping it. Details: exakit version"
            continue
        fi
        # Never backwards, and this has to be settled BEFORE the heavy branch.
        # That branch gates on "$_cur" != "$_avail" and then continues, so it used
        # to reach the runtime offer with the installed version AHEAD of the
        # tested one and ask to stop the database for a downgrade -- while
        # `exakit version` rendered the same row as "none" and every light
        # component said "keeping yours". Different is not behind. Asked once
        # here, for every component, so no later branch can reach an update path
        # by skipping the question.
        if exakit_component_is_ahead "$_upd_actual"; then
            ok "$_upd_actual ${_cur:-unknown} is newer than the tested $_avail — keeping yours"
            continue
        fi
        # A blanket update stops the database only for an answer it was given: on a
        # terminal it asks, with a flag or the env var it was already told, and with
        # neither it defers exactly as it always did. See
        # exakit_offer_runtime_update.
        if [ "$_target" = "all" ] && exakit_component_is_heavy "$_upd_actual"; then
            if [ -n "$_cur" ] && [ -n "$_avail" ] && [ "$_cur" != "unknown" ] && [ "$_cur" != "$_avail" ]; then
                if exakit_offer_runtime_update "$_component" "$_upd_actual" "$_cur" "$_avail"; then
                    _acted=$((_acted + 1))
                else
                    _deferred=$((_deferred + 1))
                fi
            fi
            continue
        fi
        # Only the components this run will actually touch are reported: the work
        # plan, not a status table. `exakit version` is where everything is
        # listed, including what is already current.
        #
        # A marketplace add-on named EXPLICITLY is the exception: its update hook
        # is also its repair command (it rewrites the launcher a newer kit
        # improved, re-registers the boot entry, re-reads a changed DSN), so
        # `exakit update dash-server` must reach the module even when the version
        # already matches. `update all` still skips it — a routine update stays a
        # work plan, not a sweep of every component's repair path.
        if [ -n "$_cur" ] && [ -n "$_avail" ] && [ "$_cur" = "$_avail" ]; then
            if [ "$_target" = "all" ] || ! _exakit_addon_registered "$_component"; then
                continue
            fi
        fi
        # The table's "update exakit first" verdict has to hold here too, or the
        # manifest's only hard compatibility lever would be advice nobody applies.
        _upd_min_kit="$(exakit_component_min_kit "$_upd_actual" 2>/dev/null || true)"
        if [ -n "$_upd_min_kit" ] && ! exakit_min_kit_satisfied "$_upd_min_kit"; then
            warn "$_upd_actual $_avail needs kit >= $_upd_min_kit — update the kit first: exakit update exakit"
            [ "$_target" = "all" ] && continue
            die "Refusing to install $_upd_actual $_avail on kit $(exakit_component_current exakit 2>/dev/null || printf unknown)."
        fi
        if [ -n "$_avail" ]; then
            info "$_upd_actual ${_cur:-not installed} -> $_avail"
        fi
        exakit_update_component "$_component" "$@"
        _acted=$((_acted + 1))
    done
    if [ "$_acted" -eq 0 ] && [ "$_deferred" -eq 0 ]; then
        ok "Everything is already current."
    fi
    if [ "$_deferred" -gt 0 ]; then
        info "See everything, including the deferred runtime change: exakit version"
    fi
    return 0
}

# step_done <name> — succeeds if the step is recorded in steps_completed.
step_done() {
    [ -f "$EXAKIT_MANIFEST" ] || return 1
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
sys.exit(0 if sys.argv[2] in doc.get("steps_completed", []) else 1)
PY
}

# _sas_launcher_on_path — true when a usable `exasol` is reachable on PATH.
# Helper for step_artifact_state's launcher case, held to the same bar: command
# -v is a PATH lookup and not an execution (rule 2 below), and the resolved
# launcher must be a non-empty executable file (rule 4). A `command -v` answer
# that is not a path at all (a shell function) fails those tests and counts as
# no launcher, which only ever means the step runs again.
_sas_launcher_on_path() {
    _sas_cli="$(command -v exasol 2>/dev/null || true)"
    [ -n "$_sas_cli" ] || return 1
    [ -x "$_sas_cli" ] && [ -s "$_sas_cli" ]
}

# step_artifact_state <step> — prints "present", "missing", or "unknown".
#
# The tick in steps_completed records that a step RAN once, not that what it
# produced is still on disk. A machine turned up with steps_completed:
# ["launcher"] and no ~/.local/bin/exasol, and every re-run then skipped the
# launcher step and failed the deployment step that needs it — the one step that
# could have repaired the install was the one being skipped. begin_step consults
# this so a completed step can be re-run when its artifact is gone.
#
# Three rules hold this function together:
#
#   1. "unknown" NEVER overrides the manifest. There is no cheap way to prove a
#      database deployment exists, and re-running the runtime step on a guess
#      would stop a working database — far worse than the bug this fixes. A
#      wrong "missing" is destructive; a wrong "unknown" just leaves today's
#      behaviour in place. Anything not cheaply provable is "unknown".
#   2. FILE TESTS ONLY. This runs once per step on every install, so no network,
#      no PyPI, no GitHub and above all nothing that could wake or probe a
#      container engine (a starting Docker is why the kit's own probes are
#      bounded).
#   3. "present" means what the NEXT step will actually resolve. The launcher
#      case mirrors personal_cli(), which is what the deployment step calls.
#   4. EXECUTABLE IS NOT ENOUGH — it must also be non-empty. `[ -x ]` is true of
#      a 0-byte file with mode 755, which is exactly what an interrupted or
#      out-of-space install leaves behind, and running one is either an exec
#      failure or (worse) an empty script that "succeeds" without doing
#      anything. Every branch that judges a binary pairs `-x` with `-s`.
step_artifact_state() {
    case "$1" in
        launcher)
            if [ -z "${EXAKIT_PERSONAL_BIN:-}" ]; then
                # runtime-personal.sh is not loaded: this platform has no
                # launcher step, so there is nothing to judge.
                printf 'unknown\n'
            elif [ -x "$EXAKIT_PERSONAL_BIN" ]; then
                # personal_cli() prefers the kit-managed binary the moment it is
                # executable, so THIS file is what the deployment step will run —
                # even when it is a truncated 0-byte stub, and even when a good
                # launcher sits on PATH. Only a non-empty one is "present".
                if [ -s "$EXAKIT_PERSONAL_BIN" ]; then
                    printf 'present\n'
                else
                    printf 'missing\n'
                fi
            elif _sas_launcher_on_path; then
                # personal_install_launcher deliberately keeps an existing
                # launcher on PATH that supports the `local` preset instead of
                # installing its own, and personal_cli() then resolves that one —
                # so a launcher on PATH is "present" even with no kit-managed
                # binary. command -v is a PATH lookup, not an execution.
                #
                # RESIDUAL HOLE, stated plainly: this branch is not merely a
                # guard against a false "missing". An `exasol` on PATH that is
                # too OLD for the `local` preset, with the managed binary gone,
                # is reported "present" here, the launcher step is skipped, and
                # the deployment step fails again — the same forever-loop this
                # function exists to break, through a different door. Telling
                # the two apart means running `exasol install --help` (what
                # personal_install_launcher does), which rule 2 forbids at this
                # cost. The narrower, self-inflicted case is covered: the kit's
                # own managed binary is judged by the branch above, which no
                # PATH lookup can override.
                printf 'present\n'
            else
                printf 'missing\n'
            fi
            ;;
        exakit_helper)
            if [ -x "$EXAKIT_BIN_DIR/exakit" ] && [ -s "$EXAKIT_BIN_DIR/exakit" ]; then
                printf 'present\n'
            else
                printf 'missing\n'
            fi
            ;;
        exapump)
            # The install records the exact path it resolved. No record means an
            # older install (or a soft failure) we cannot judge: "unknown".
            _sas_path="$(manifest_get components.exapump.path 2>/dev/null || true)"
            if [ -z "$_sas_path" ]; then
                printf 'unknown\n'
            elif [ ! -x "$_sas_path" ] || [ ! -s "$_sas_path" ]; then
                printf 'missing\n'
            elif [ -n "${EXAPUMP_CONFIG:-}" ] && [ ! -s "$EXAPUMP_CONFIG" ]; then
                # THE BINARY IS NOT THE WHOLE STEP. The step also writes the
                # connection profile, and only the binary was ever checked — so a
                # profile that had been removed left the step "already done,
                # skipping" on every re-run while `exapump sql -p starter-kit`
                # answered "Profile 'starter-kit' not found in config" forever.
                # Re-running the installer is supposed to be the cure for that.
                EXAKIT_STEP_RERUN_REASON="the exapump connection profile is gone — writing it again"
                printf 'missing\n'
            else
                printf 'present\n'
            fi
            ;;
        runtime)
            # A deployed database is normally "unknown" by rule 1: a false
            # "missing" here redeploys and destroys data, so neither "stopped"
            # nor "unreachable" may ever answer it.
            #
            # ONE state is safe to call missing, and it is the one that used to
            # loop forever: a deployment the LAUNCHER ITSELF has recorded as
            # interrupted. That is not an opinion this function forms — it is a
            # flag the launcher wrote, and after it every start fails identically
            # ("local VM state contains invalid database port: 0"). The step was
            # skipped as done, the run then failed at start, and the closing
            # advice was to re-run the installer, which skipped it again. The
            # deployment step already knows how to try a start, watch it fail,
            # and replace the deployment; this is what lets it be reached.
            if command -v personal_deployment_wedged >/dev/null 2>&1 && \
               personal_deployment_wedged >/dev/null 2>&1; then
                EXAKIT_STEP_RERUN_REASON="the database is interrupted and cannot be started — rebuilding it"
                printf 'missing\n'
            else
                printf 'unknown\n'
            fi
            ;;
        *)
            # mcp, pyexasol and the kit2 asset steps: nothing a file test can
            # settle without risking a destructive false "missing". See rule 1.
            printf 'unknown\n'
            ;;
    esac
}

# mark_step <name> — records a completed step (idempotent). Completing a
# step also discards the undo entries registered during it: rollback only
# ever covers the step that actually failed, never a finished one (a late
# transient failure must not undo an earlier successful deployment).
mark_step() {
    require_python3
    run_python - "$EXAKIT_MANIFEST" "$1" <<'PY' || die "Failed to record step $1"
import json, os, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
steps = doc.setdefault("steps_completed", [])
if sys.argv[2] not in steps:
    steps.append(sys.argv[2])
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")
os.replace(tmp, sys.argv[1])
PY
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && : > "$EXAKIT_ROLLBACK_FILE"
    _exakit_log_file "STEP  completed: $1"
}

# ---------------------------------------------------------------------------
# Rollback handling
#
# Steps register undo commands as they make changes. On failure the handler
# reports what failed and (interactively) offers to undo this run's changes.
# Completed runs discard their rollback stack — the manifest is then the
# source of truth for uninstall.
# ---------------------------------------------------------------------------
EXAKIT_ROLLBACK_FILE=""
EXAKIT_CURRENT_STEP=""

rollback_init() {
    EXAKIT_ROLLBACK_FILE="$(mktemp "${TMPDIR:-/tmp}/exakit-rollback.XXXXXX")"
}

# push_rollback <command...> — register an undo command for the current run.
push_rollback() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] || return 0
    printf '%s\n' "$*" >> "$EXAKIT_ROLLBACK_FILE"
}

run_rollback() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && [ -s "$EXAKIT_ROLLBACK_FILE" ] || return 0
    info "Rolling back this run's changes..."
    # Execute registered undo commands in reverse order.
    awk '{ lines[NR] = $0 } END { for (i = NR; i >= 1; i--) print lines[i] }' \
        "$EXAKIT_ROLLBACK_FILE" | while IFS= read -r cmd; do
        _exakit_log_file "UNDO  $cmd"
        sh -c "$cmd" >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || \
            warn "Rollback command failed (see log): $cmd"
    done
    : > "$EXAKIT_ROLLBACK_FILE"
    ok "Rollback finished"
}

rollback_discard() {
    [ -n "$EXAKIT_ROLLBACK_FILE" ] && rm -f "$EXAKIT_ROLLBACK_FILE"
    EXAKIT_ROLLBACK_FILE=""
}

# begin_step <name> <description> — announce a step; skips if already done AND
# what it installed is still there. Returns 1 when the step can be skipped
# (caller should honor it).
#
# A step is skipped only when the manifest tick and the disk agree. When the tick
# says done but step_artifact_state() proves the artifact is gone, the step is
# announced and run again — that is what makes "re-running the installer is safe
# and resumes" (AGENTS.md) true even after something removed an artifact from
# under a completed install.
begin_step() {
    EXAKIT_CURRENT_STEP="$1"
    EXAKIT_ACTIVE_LABEL="$2"     # spinner label for run_logged inside this step
    _bs_rerun=0
    # Cleared before every judgement so one step's reason cannot be reported
    # against the next; step_artifact_state sets it when it has a better
    # explanation than the generic "what it installed is missing".
    EXAKIT_STEP_RERUN_REASON=""
    if step_done "$1"; then
        # "unknown" (and "present") keep the manifest's answer: only a proven
        # "missing" is allowed to override the tick.
        if [ "$(step_artifact_state "$1")" = "missing" ]; then
            # Run the judgement AGAIN, in this shell, purely to recover
            # EXAKIT_STEP_RERUN_REASON: the call above is a command
            # substitution, so the variable it set died with the subshell and
            # every re-run reported the generic reason. The check is file tests
            # and a manifest read, so a second one costs nothing.
            step_artifact_state "$1" >/dev/null 2>&1
            _bs_rerun=1
        else
            # Step-level line (a whole step's status, not a nested outcome).
            printf '\n  %s%s%s %s%s%s %s— already done, skipping%s\n' \
                "${UI_OK:-}" "${UI_TICK:-[ok]}" "${UI_RESET:-}" \
                "${UI_BOLD:-}" "$2" "${UI_RESET:-}" "${UI_DIM:-}" "${UI_RESET:-}"
            _exakit_log_file "OK    $2 — already done, skipping"
            return 1
        fi
    fi
    # Styled step header: accent arrow + bold title, set off by a blank line.
    printf '\n  %s%s%s %s%s%s\n' \
        "${UI_ACCENT:-}" "${UI_ARROW:->}" "${UI_RESET:-}" \
        "${UI_BOLD:-}" "$2" "${UI_RESET:-}"
    _exakit_log_file "STEP  $2"
    if [ "$_bs_rerun" -eq 1 ]; then
        info "Recorded as done, but ${EXAKIT_STEP_RERUN_REASON:-what it installed is missing — running it again}"
    fi
    return 0
}

exakit_on_failure() {
    _status=$?
    # Runs on EXIT (any status). Stop any live spinner and un-hide the cursor
    # first, so a failure mid-animation never leaves a stuck/invisible cursor.
    ui_spin_end 2>/dev/null || true
    ui_restore_cursor
    exakit_sweep_sensitive_tmp     # never leave credential temp files behind
    [ $_status -eq 0 ] && return 0
    # Same "card" shape as die(): prominent ✗ header, dim gutter details.
    printf '\n  %s%s %s%s%s\n' "${UI_ERR:-}" "${UI_CROSS:-[x]}" "${UI_BOLD:-}" \
        "Setup failed${EXAKIT_CURRENT_STEP:+ during step: $EXAKIT_CURRENT_STEP}" "${UI_RESET:-}" >&2
    _exakit_log_file "ERROR Setup failed${EXAKIT_CURRENT_STEP:+ during step: $EXAKIT_CURRENT_STEP}"
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        printf '    %s%s Log: %s%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "$EXAKIT_LOG_FILE" "${UI_RESET:-}" >&2
    fi
    printf '    %s%s Re-running the installer is safe: completed steps are skipped.%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
    if [ "${EXAKIT_AUTO_ROLLBACK:-0}" = "1" ]; then
        run_rollback
    elif confirm "Undo the failed step's changes?" n; then
        run_rollback
    else
        info "Keeping partial progress. Re-run the installer to resume."
    fi
    rollback_discard
    exakit_release_lock
    exit $_status
}

# exakit_acquire_lock — one setup run at a time. A lock left behind by a
# dead process is detected and removed automatically.
EXAKIT_LOCK_FILE=""
exakit_acquire_lock() {
    _lock="$EXAKIT_HOME/.install.lock"
    mkdir -p "$EXAKIT_HOME"
    if [ -f "$_lock" ]; then
        _pid="$(cat "$_lock" 2>/dev/null)"
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            die "Another setup run is already in progress (pid $_pid). Wait for it to finish; if you are sure it is dead, remove $_lock and re-run."
        fi
        warn "Found a lock from an interrupted run — removing it and continuing"
        rm -f "$_lock"
    fi
    printf '%s' "$$" > "$_lock"
    EXAKIT_LOCK_FILE="$_lock"
}

exakit_release_lock() {
    [ -n "$EXAKIT_LOCK_FILE" ] && rm -f "$EXAKIT_LOCK_FILE"
    EXAKIT_LOCK_FILE=""
}

# Call once near the top of each setup script (after init_logging).
exakit_enable_failure_handling() {
    rollback_init
    exakit_acquire_lock
    trap exakit_on_failure EXIT
}

# Call at the very end of a successful run.
exakit_finish() {
    trap - EXIT
    rollback_discard
    exakit_release_lock
    EXAKIT_CURRENT_STEP=""
}

# ---------------------------------------------------------------------------
# Downloads and verification
# ---------------------------------------------------------------------------
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1. $2"
}

# fetch <url> <dest-file>
# Runs curl silently (-sS) under the kit's braille spinner so downloads animate
# consistently with every other step, instead of curl's own hash progress bar.
# The spinner no-ops on non-interactive terminals, so logs/CI stay clean.
fetch() {
    _url="$1"
    _dest="$2"
    mkdir -p "$(dirname "$_dest")"
    _exakit_log_file "GET   $_url -> $_dest"
    ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-downloading $(basename "$_dest")}"
    curl -fL --proto '=https' --retry 3 --connect-timeout 15 \
        -sS -o "$_dest" "$_url"
    _fetch_rc=$?
    ui_spin_end
    if [ "$_fetch_rc" -ne 0 ]; then
        rm -f "$_dest"
        error "Download failed: $_url"
        printf '      %s%s Check your internet connection. Behind a corporate proxy, set%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        printf '      %s%s HTTPS_PROXY (curl honors it) and re-run. If the URL looks wrong,%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        printf '      %s%s a version override (EXAKIT_*_VERSION) may point at a missing release.%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        die "Could not download $(basename "$_dest")"
    fi
}

# fetch_quiet <url> <dest-file>
# A fetch whose chatter goes to the logfile and whose failure is soft: it
# returns non-zero where fetch would die.
#
# Callers used to write this themselves as `( fetch ... ) >> "$LOG" 2>&1`, which
# silenced more than it meant to: ui_spin_begin animates only while stdout is a
# terminal, so redirecting the subshell sent the SPINNER to the logfile too and
# every add-on download sat on screen as a still line for as long as it took.
# Starting the spinner out here, before the redirect, is what gives those
# downloads their "something is happening" back. Clearing _UI_SPIN_PID inside
# the subshell matters just as much: fetch ends with its own ui_spin_end, and
# with the parent's pid still visible it would kill this spinner on the way in.
fetch_quiet() {
    ui_spin_begin "${EXAKIT_ACTIVE_LABEL:-downloading $(basename "$2")}"
    ( _UI_SPIN_PID=''; fetch "$1" "$2" ) >>"${EXAKIT_LOG_FILE:-/dev/null}" 2>&1
    _fq_rc=$?
    ui_spin_end
    return "$_fq_rc"
}

# sha256_of <file>
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die "Neither shasum nor sha256sum available for checksum verification"
    fi
}

# verify_sha256 <file> <expected-hash>
verify_sha256() {
    _actual="$(sha256_of "$1")"
    if [ "$_actual" != "$2" ]; then
        error "Checksum mismatch for $(basename "$1")"
        error "  expected: $2"
        error "  actual:   $_actual"
        die "Refusing to continue with an unverified artifact"
    fi
    ok "Checksum verified: $(basename "$1")"
}

# verify_sha256_from_file <file> <checksums.txt> — looks the file up by name.
verify_sha256_from_file() {
    _name="$(basename "$1")"
    _expected="$(awk -v f="$_name" '$2 == f || $2 == "*"f {print $1; exit}' "$2")"
    [ -n "$_expected" ] || die "No checksum entry for $_name in $(basename "$2")"
    verify_sha256 "$1" "$_expected"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# ensure_path_hint <dir> — make dir usable on PATH without sudo: fix the
# current process immediately, then persist the export in the user's own
# shell profile (their file, their permissions — never /etc, never root).
# Mirrors the Windows side, which has always persisted the user PATH via
# [Environment]::SetEnvironmentVariable(..., "User") in exakit-common.ps1.
# Idempotent: the marker comment keeps re-runs from stacking duplicates.
# EXAKIT_NO_PROFILE_EDIT=1 restores the old print-a-hint-only behavior.
ensure_path_hint() {
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
    esac
    # Fix the running install right away so later steps can call the kit's
    # CLIs by name; the profile edit below covers future sessions.
    PATH="$1:$PATH"
    export PATH

    if [ "${EXAKIT_NO_PROFILE_EDIT:-0}" = "1" ]; then
        warn "$1 is not on your PATH."
        printf '      %s%s Add this to your shell profile:%s\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" >&2
        printf '      %s%s%s   export PATH="%s:$PATH"\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" "$1" >&2
        return 0
    fi

    # The user's interactive shell decides which profile matters; fish has
    # no POSIX profile, so it keeps the printed hint instead of a bad edit.
    case "$(basename "${SHELL:-}")" in
        zsh)  _eph_profile="$HOME/.zshrc" ;;
        bash) _eph_profile="$HOME/.bashrc" ;;
        fish)
            warn "$1 is not on your PATH. For fish, run: fish_add_path $1"
            return 0
            ;;
        *)    _eph_profile="$HOME/.profile" ;;
    esac

    _eph_marker="# Added by the Exasol Personal Local Starter Kit (exakit CLIs)"
    if [ -f "$_eph_profile" ] && grep -qF "$_eph_marker" "$_eph_profile"; then
        # Already persisted by an earlier run; this session just hasn't
        # sourced it (covered by the export above).
        return 0
    fi
    if { printf '\n%s\nexport PATH="%s:$PATH"\n' "$_eph_marker" "$1" >> "$_eph_profile"; } 2>/dev/null; then
        ok "Added $1 to your PATH in $_eph_profile (new terminals pick it up automatically)"
    else
        warn "$1 is not on your PATH and $_eph_profile is not writable. Add this to your shell profile:"
        printf '      %s%s%s   export PATH="%s:$PATH"\n' "${UI_DIM:-}" "${UI_VB:-|}" "${UI_RESET:-}" "$1" >&2
    fi
}

exakit_repo_root() {
    if [ -d "$EXAKIT_HOME/kit/mcp" ]; then
        printf '%s\n' "$EXAKIT_HOME/kit"
        return 0
    fi
    _common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _repo_root="$(cd "$_common_dir/../.." && pwd)"
    if [ -d "$_repo_root/mcp" ]; then
        printf '%s\n' "$_repo_root"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Skills registry
# ---------------------------------------------------------------------------
# The registry is the FILESYSTEM, not a hardcoded list: every directory under
# skills/ carrying a SKILL.md is a skill, and its identity comes from that
# file's own frontmatter. Adding a skill therefore stays a one-folder change
# with no code edit anywhere — the property skills/README.md promises. A
# hardcoded list here would quietly take that away, so tests/skills.sh asserts
# no skill name is ever hardcoded in this file.

EXAKIT_SKILL_ROOTS="${EXAKIT_SKILL_ROOTS:-$HOME/.claude/skills $HOME/.agents/skills}"

# exakit_skills_dir — the kit's skills/ source directory.
exakit_skills_dir() {
    _sd_root="$(exakit_repo_root)" || return 1
    [ -d "$_sd_root/skills" ] || return 1
    printf '%s\n' "$_sd_root/skills"
}

# exakit_skill_field <skill-md> <field> — one value out of the YAML
# frontmatter. Deliberately tiny: the frontmatter this reads is the two flat
# keys the SKILL.md standard defines (name, description), so a real YAML parser
# would be a dependency bought for nothing.
exakit_skill_field() {
    awk -v want="$2" '
        NR == 1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        {
            key = want ": "
            if (index($0, key) == 1) { print substr($0, length(key) + 1); exit }
        }
    ' "$1" 2>/dev/null
}

# exakit_skill_summary <description> — the one-line gist for a list row. The
# full description is written for an AGENT to match on (long, trigger-laden);
# a human scanning a table wants the first sentence, so cut the trigger list
# and then the first sentence, and truncate on a word boundary.
exakit_skill_summary() {
    _ss_text="$1"
    case "$_ss_text" in *"Triggers"*) _ss_text="${_ss_text%%Triggers*}" ;; esac
    case "$_ss_text" in *". "*) _ss_text="${_ss_text%%". "*}" ;; esac
    # Trim trailing separators and whitespace left by either cut above.
    _ss_text="$(printf '%s' "$_ss_text" | sed 's/[[:space:]]*[—-]*[[:space:]]*$//')"
    printf '%s' "$_ss_text" | awk '{
        if (length($0) <= 64) { print; exit }
        out = ""
        n = split($0, words, " ")
        for (i = 1; i <= n; i++) {
            if (length(out) + length(words[i]) + 1 > 61) break
            out = (out == "" ? words[i] : out " " words[i])
        }
        # A dangling connector reads as a truncation bug rather than an
        # ellipsis, so drop one if the cut landed on it.
        sub(/[[:space:]]*(—|-|,|:)$/, "", out)
        print out "..."
    }'
}

# exakit_skills_registry — one line per skill: id|summary. Skills whose
# frontmatter does not parse are skipped here, so they are skipped everywhere
# (list AND install read this one function).
exakit_skills_registry() {
    _sr_dir="$(exakit_skills_dir)" || return 1
    for _sr_path in "$_sr_dir"/*/; do
        [ -f "$_sr_path/SKILL.md" ] || continue
        _sr_name="$(exakit_skill_field "$_sr_path/SKILL.md" name)"
        [ -n "$_sr_name" ] || continue
        _sr_desc="$(exakit_skill_field "$_sr_path/SKILL.md" description)"
        printf '%s|%s\n' "$_sr_name" "$(exakit_skill_summary "$_sr_desc")"
    done
}

# exakit_skill_state <id> — installed (in every discovery root), partial (in
# some), or available (in none). "partial" is worth its own word: it is what a
# half-finished install or a hand-deleted copy looks like, and the remedy
# differs from a clean "never installed".
exakit_skill_state() {
    _sks_have=0
    _sks_total=0
    for _sks_root in $EXAKIT_SKILL_ROOTS; do
        _sks_total=$((_sks_total + 1))
        [ -f "$_sks_root/$1/SKILL.md" ] && _sks_have=$((_sks_have + 1))
    done
    if [ "$_sks_have" -eq 0 ]; then
        printf 'available\n'
    elif [ "$_sks_have" -eq "$_sks_total" ]; then
        printf 'installed\n'
    else
        printf 'partial\n'
    fi
}

# exakit_skills_list [--json] — what skills this kit carries and whether each
# one has reached the agents' discovery folders.
exakit_skills_list() {
    if ! exakit_skills_dir >/dev/null 2>&1; then
        warn "No skills/ directory in this kit build — nothing to list."
        return 1
    fi

    if [ "${1:-}" = "--json" ] || [ "${1:-}" = "-j" ]; then
        _skl_first=1
        printf '{"skills":['
        while IFS='|' read -r _skl_id _skl_sum; do
            [ -n "$_skl_id" ] || continue
            [ "$_skl_first" -eq 1 ] || printf ','
            _skl_first=0
            printf '{"name":"%s","state":"%s","summary":"%s"}' \
                "$_skl_id" "$(exakit_skill_state "$_skl_id")" \
                "$(printf '%s' "$_skl_sum" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        done <<EXAKIT_SKL_EOF
$(exakit_skills_registry)
EXAKIT_SKL_EOF
        printf ']}\n'
        return 0
    fi

    _skl_count=0
    _skl_pending=0
    printf '\n'
    ui_panel_begin "AI skills in this kit"
    while IFS='|' read -r _skl_id _skl_sum; do
        [ -n "$_skl_id" ] || continue
        _skl_state="$(exakit_skill_state "$_skl_id")"
        [ "$_skl_state" = "installed" ] || _skl_pending=$((_skl_pending + 1))
        ui_panel_line "$(printf '%-26s %-10s %s' "$_skl_id" "$_skl_state" "$_skl_sum")"
        _skl_count=$((_skl_count + 1))
    done <<EXAKIT_SKL_EOF
$(exakit_skills_registry)
EXAKIT_SKL_EOF

    if [ "$_skl_count" -eq 0 ]; then
        ui_panel_line "No SKILL.md files found in this kit copy."
        ui_panel_end
        printf '\n'
        return 1
    fi

    ui_panel_line ""
    # Stale beats pending in the advice: copies that exist but predate a kit
    # update are the case a user cannot see for themselves, and the remedy is
    # the same command either way.
    _skl_have="$(manifest_get components.skills.version 2>/dev/null || true)"
    _skl_want="$(exakit_versions_value components.skills.version 2>/dev/null || true)"
    if [ -n "$_skl_have" ] && [ -n "$_skl_want" ] && [ "$_skl_have" != "$_skl_want" ]; then
        ui_panel_line "Installed from skill set $_skl_have; this kit carries $_skl_want."
        ui_panel_line "Refresh them:  exakit skills-install"
    elif [ "$_skl_pending" -gt 0 ]; then
        ui_panel_line "Install or refresh every skill:  exakit skills-install"
    else
        ui_panel_line "All installed. Refresh after a kit update:  exakit skills-install"
    fi
    ui_panel_line "Agents load a skill only when its triggers match your request."
    ui_panel_end
    printf '\n'
    return 0
}

# exakit_stray_launchers — superseded launcher copies the kit set aside during an
# upgrade (exasol.backup-<epoch>). Each is a full ~130 MB binary and nothing
# reported them, so they accumulated invisibly and no command reclaimed the disk.
# Prints one absolute path per line; silent when there are none.
exakit_stray_launchers() {
    [ -d "${EXAKIT_BIN_DIR:-}" ] || return 0
    for _sl in "$EXAKIT_BIN_DIR"/exasol.backup-*; do
        [ -f "$_sl" ] || continue
        printf '%s\n' "$_sl"
    done
}

# exakit_install_skills — copy the kit's AI skills into the per-user discovery
# folders so CLI agents auto-load them. Idempotent: each run replaces the
# managed copy of every skill, so edits and deletions propagate cleanly.
#   ~/.claude/skills/<name>/   — Claude Code
#   ~/.agents/skills/<name>/   — Codex, Cursor, other open-standard agents
exakit_install_skills() {
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not locate the kit to find its skills/ directory."
        return 1
    }
    _skills_src="$_repo_root/skills"
    if [ ! -d "$_skills_src" ]; then
        warn "No skills/ directory in this kit build yet — nothing to install."
        return 1
    fi

    _installed=0
    _installed_json=""
    for _skill_dir in "$_skills_src"/*/; do
        [ -f "$_skill_dir/SKILL.md" ] || continue
        # Frontmatter that does not parse is skipped HERE as well as in the
        # listing: a skill an agent cannot identify is not one worth copying,
        # and installing what `exakit skills` refuses to show would be a lie.
        [ -n "$(exakit_skill_field "$_skill_dir/SKILL.md" name)" ] || {
            warn "Skipping $(basename "$_skill_dir"): its SKILL.md has no readable name in the frontmatter."
            continue
        }
        _name="$(basename "$_skill_dir")"
        for _dest_root in $EXAKIT_SKILL_ROOTS; do
            rm -rf "$_dest_root/$_name"
            mkdir -p "$_dest_root/$_name"
            cp -R "$_skill_dir". "$_dest_root/$_name/"
        done
        # The names go to the logfile, not the screen: nine ticked lines say
        # nothing the count does not, and `exakit skills` lists them any time.
        _exakit_log_file "OK    Installed skill: $_name"
        _installed=$((_installed + 1))
        _installed_json="${_installed_json:+$_installed_json,}\"$_name\""
    done

    if [ "$_installed" -eq 0 ]; then
        warn "No SKILL.md files found under $_skills_src — nothing to install."
        return 1
    fi
    ok "Installed $_installed AI skill$([ "$_installed" = 1 ] || printf 's') for Claude Code (~/.claude/skills) and open-standard agents (~/.agents/skills)"

    # Record what was placed and which skill-set version it came from. This is
    # the only honest source for two later questions: which skill directories
    # are OURS to remove at uninstall time (the discovery folders also hold
    # skills the user installed themselves, which the kit must never touch),
    # and whether the installed copies have gone stale behind a kit update.
    if [ -f "$EXAKIT_MANIFEST" ]; then
        manifest_set components.skills.version \
            "$(exakit_versions_value components.skills.version 2>/dev/null || printf 'unknown')"
        manifest_set components.skills.installed "[$_installed_json]"
    fi

    exakit_report_readonly_allowlist
    info "Restart or reload your AI client to pick them up."
    return 0
}

# exakit_report_readonly_allowlist — apply the allowlist and say what happened.
# Split out of exakit_install_skills so the friction fix does not depend on the
# skills copy succeeding: when a staging fault meant no skill was ever placed,
# this never ran either, and every prompt the doc promises to remove kept being
# asked. The two are independent remedies and now fail independently.
exakit_report_readonly_allowlist() {
    # Claude Code reads ~/.claude/settings.json. Other agents keep the doc:
    # their settings formats differ and hand-editing them would be presumptuous.
    _skills_applied="$(exakit_apply_readonly_allowlist 2>/dev/null || true)"
    case "$_skills_applied" in
        # ADDED 0 is the nothing-changed branch, so it fired on every re-run to
        # report that nothing happened. The branch below, where commands really
        # are allowlisted, still says so.
        ADDED\ 0) _exakit_log_file "INFO  Read-only command allowlist already present in ~/.claude/settings.json." ;;
        ADDED\ *) ok "Read-only exakit commands allowlisted in ~/.claude/settings.json (status, info, version, mcp-doctor, logs, catalog, preflight, guide, mcp-status, mcp-validate, skills; uninstall stays gated)." ;;
        SKIP*)    warn "~/.claude/settings.json could not be merged safely ($_skills_applied) — the allowlist in skills/reducing-agent-prompts.md shows what to add by hand." ;;
    esac
    return 0
}

# exakit_apply_readonly_allowlist — make the documented friction-reduction
# real. skills/reducing-agent-prompts.md tells Claude Code users which
# read-only exakit commands are safe to allow without a prompt; copying a doc
# nobody hand-applies eliminates zero prompts, so skills-install merges that
# same allowlist into ~/.claude/settings.json itself.
#
# The merge is strictly ADDITIVE and idempotent: existing settings are kept
# byte for byte, entries already present are not duplicated, nothing is ever
# removed, and a malformed or unreadable settings file is left alone (warn,
# not clobber). The list deliberately covers only read-only commands — exapump
# and SQL execution keep prompting, exactly as the doc explains — plus a deny
# for uninstall so an agent can never remove the kit unprompted.
exakit_apply_readonly_allowlist() {
    exakit_can_run_python || return 0
    _ral_file="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude" 2>/dev/null || return 0
    run_python - "$_ral_file" <<'EXAKIT_RAL_PY'
import json, os, sys

path = sys.argv[1]

# The kit's read-only command surface. Leaving any of these out is what kept the
# friction real: an agent following AGENTS.md is told to discover commands with
# `exakit catalog` and to check its footing with `version` / `mcp-status`,
# and every one of those asked for approval while changing nothing. `exapump sql`
# and every mutating command stay absent on purpose — that gate is the trust
# model.
READONLY = [
    "status", "info", "version", "mcp-doctor", "logs", "catalog", "preflight",
    "guide", "mcp-status", "mcp-validate", "help",
]

# EVERY SPELLING THE AGENT IS TOLD TO USE. A permission rule matches the command
# text, and AGENTS.md tells agents in as many words that ~/.local/bin is absent
# from a bare non-interactive PATH and to call the binary by absolute path. So
# the bare-`exakit` rules covered exactly the invocation the docs steer agents
# AWAY from, and every "read-only" command kept prompting anyway — the two halves
# of the kit's own advice cancelling out. All three spellings are listed now.
PREFIXES = ["exakit", "~/.local/bin/exakit", "$HOME/.local/bin/exakit"]

ALLOW = []
for prefix in PREFIXES:
    for command in READONLY:
        ALLOW.append("Bash(%s %s:*)" % (prefix, command))
    # Exact forms, deliberately NOT "exakit skills:*": that prefix would also
    # match `exakit skills-install`, which writes this very settings file. An
    # allowlisted command that can add allowlist entries is an escalation path,
    # so the listing is allowed and the install still asks.
    ALLOW.append("Bash(%s skills)" % prefix)
    ALLOW.append("Bash(%s skills --json)" % prefix)
ALLOW.append("mcp__exasol")

# The deny needs every spelling too, for the opposite reason: a rule that only
# names the bare form is trivially sidestepped by the absolute path the docs
# recommend.
DENY = ["Bash(%s uninstall:*)" % prefix for prefix in PREFIXES]

doc = {}
if os.path.exists(path):
    try:
        with open(path) as handle:
            doc = json.load(handle)
    except (ValueError, OSError):
        print("SKIP unreadable")
        sys.exit(0)
    if not isinstance(doc, dict):
        print("SKIP not-an-object")
        sys.exit(0)

permissions = doc.setdefault("permissions", {})
if not isinstance(permissions, dict):
    print("SKIP permissions-not-an-object")
    sys.exit(0)
added = 0
for key, wanted in (("allow", ALLOW), ("deny", DENY)):
    existing = permissions.setdefault(key, [])
    if not isinstance(existing, list):
        continue
    for entry in wanted:
        if entry not in existing:
            existing.append(entry)
            added += 1
if added:
    tmp = path + ".exakit-tmp"
    with open(tmp, "w") as handle:
        json.dump(doc, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, path)
print("ADDED %d" % added)
EXAKIT_RAL_PY
}

# exakit_maybe_offer_skills_install — after setup, place the skills where CLI
# agents can find them. Always installs — no prompt — so the skills are
# present without requiring interactive confirmation. Non-fatal and
# idempotent.
exakit_maybe_offer_skills_install() {
    _repo_root="$(exakit_repo_root)" || {
        exakit_note_failure "the kit copy could not be located, so no skills were installed"
        return 1
    }
    # A missing skills/ directory used to return SUCCESS here, which is how a
    # staging bug that shipped zero skills to every install stayed invisible:
    # the closing summary had nothing to report and AGENTS.md's first
    # post-install instruction failed on a machine the installer called done.
    # It is a real failure now, and it books itself in the summary.
    if ! ls "$_repo_root"/skills/*/SKILL.md >/dev/null 2>&1; then
        warn "No skills/ directory in this kit copy ($_repo_root) — no AI skills were installed."
        exakit_note_failure "this kit copy carries no skills/ directory (expected $_repo_root/skills)"
        return 1
    fi
    if ! exakit_install_skills; then
        warn "Skills install did not finish cleanly. Retry any time with: exakit skills-install"
        exakit_note_failure "the AI skills could not be copied into place (see the log)"
        return 1
    fi
}

exakit_exapump_bin() {
    _manifest_path="$(manifest_get components.exapump.path 2>/dev/null || true)"
    if [ -n "$_manifest_path" ] && [ -x "$_manifest_path" ]; then
        printf '%s\n' "$_manifest_path"
        return 0
    fi
    if command -v exapump >/dev/null 2>&1; then
        command -v exapump
        return 0
    fi
    if [ -x "$EXAKIT_BIN_DIR/exapump" ]; then
        printf '%s\n' "$EXAKIT_BIN_DIR/exapump"
        return 0
    fi
    return 1
}

_exakit_sql_literal() {
    printf "%s" "$1" | sed "s/'/''/g"
}

_exakit_manifest_runtime_value() {
    manifest_get "$1" 2>/dev/null || true
}

_exakit_parse_runtime_host() {
    _dsn="$(_exakit_manifest_runtime_value runtime.dsn)"
    printf '%s\n' "${_dsn%%:*}"
}

_exakit_parse_runtime_port() {
    _dsn="$(_exakit_manifest_runtime_value runtime.dsn)"
    printf '%s\n' "${_dsn##*:}"
}

_exakit_first_schema() {
    _schemas="$1"
    _old_ifs="$IFS"
    IFS=', '
    set -- $_schemas
    IFS="$_old_ifs"
    printf '%s\n' "${1:-STARTER_KIT}"
}

_exakit_write_exapump_config() {
    _config_path="$1"
    _host="$2"
    _port="$3"
    _admin_user="$4"
    _admin_password="$5"
    _readonly_user="$6"
    _readonly_password="$7"
    _schema="$8"
    run_python - "$_config_path" "$_host" "$_port" "$_admin_user" "$_admin_password" "$_readonly_user" "$_readonly_password" "$_schema" <<'PY'
import sys

config_path, host, port, admin_user, admin_password, readonly_user, readonly_password, schema = sys.argv[1:]

def toml_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

doc = [
    "[admin]\n",
    f"host = {toml_string(host)}\n",
    f"port = {port}\n",
    f"user = {toml_string(admin_user)}\n",
    f"password = {toml_string(admin_password)}\n",
    "tls = true\n",
    "validate_certificate = false\n",
    "\n",
    "[mcp_readonly]\n",
    f"host = {toml_string(host)}\n",
    f"port = {port}\n",
    f"user = {toml_string(readonly_user)}\n",
    f"password = {toml_string(readonly_password)}\n",
    f"schema = {toml_string(schema)}\n",
    "tls = true\n",
    "validate_certificate = false\n",
]
with open(config_path, "w", encoding="utf-8") as handle:
    handle.writelines(doc)
PY
    chmod 600 "$_config_path"
}

_exakit_run_exapump_sql() {
    _config_path="$1"
    _profile="$2"
    _sql="$3"
    _bin="$(exakit_exapump_bin)" || die "exapump is required for MCP read-only setup but was not found."
    # Feed the SQL over stdin, not as an argv: some of these statements are
    # CREATE/ALTER USER … IDENTIFIED BY <password>, and an argv is visible to any
    # local user via `ps` for the life of the call. stdin keeps it off the
    # process table; callers still capture stdout exactly as before.
    printf '%s\n' "$_sql" | EXAPUMP_CONFIG="$_config_path" "$_bin" sql -p "$_profile"
}

_exakit_exapump_sql_has_token() {
    _config_path="$1"
    _profile="$2"
    _sql="$3"
    _token="$4"
    _output="$(_exakit_run_exapump_sql "$_config_path" "$_profile" "$_sql" 2>> "${EXAKIT_LOG_FILE:-/dev/null}")" || return 1
    printf '%s\n' "$_output" | grep -Fq "$_token"
}

# _exakit_assert_mcp_readonly_posture <config> <user> <default-schema>
# Verifies the read-only user holds EXACTLY the database-wide read set
# (CREATE SESSION + USE ANY SCHEMA + SELECT ANY TABLE) and nothing more: no
# extra system privilege, no non-SELECT object privilege, and a live write is
# rejected. This is what lets the user read every schema while still being
# provably unable to write. <default-schema> is only the write-probe target.
_exakit_assert_mcp_readonly_posture() {
    _config_path="$1"
    _readonly_user="$2"
    _schemas="$3"
    _identifier_user="$(printf '%s' "$_readonly_user" | tr '[:lower:]' '[:upper:]')"
    _user_lit="$(_exakit_sql_literal "$_identifier_user")"

    # The read-only user's system privileges must be EXACTLY the read set:
    # CREATE SESSION + USE ANY SCHEMA + SELECT ANY TABLE. Assert each is present,
    # then assert nothing outside that set exists — which is what guarantees the
    # user has no write/DDL/admin privilege (no INSERT ANY TABLE, CREATE USER,
    # GRANT ANY, SELECT ANY DICTIONARY, etc.).
    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE = 'CREATE SESSION') THEN 'EXAKIT_CREATE_SESSION_OK' ELSE 'EXAKIT_CREATE_SESSION_MISSING' END AS STATUS" \
        "EXAKIT_CREATE_SESSION_OK" || die "The MCP read-only user is missing CREATE SESSION."

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE = 'USE ANY SCHEMA') THEN 'EXAKIT_USE_ANY_SCHEMA_OK' ELSE 'EXAKIT_USE_ANY_SCHEMA_MISSING' END AS STATUS" \
        "EXAKIT_USE_ANY_SCHEMA_OK" || die "The MCP read-only user is missing USE ANY SCHEMA (needed to read every schema)."

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE = 'SELECT ANY TABLE') THEN 'EXAKIT_SELECT_ANY_TABLE_OK' ELSE 'EXAKIT_SELECT_ANY_TABLE_MISSING' END AS STATUS" \
        "EXAKIT_SELECT_ANY_TABLE_OK" || die "The MCP read-only user is missing SELECT ANY TABLE (needed to read every table)."

    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_SYS_PRIV_SCOPE_OK' ELSE 'EXAKIT_SYS_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_SYS_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE NOT IN ('CREATE SESSION', 'USE ANY SCHEMA', 'SELECT ANY TABLE')" \
        "EXAKIT_SYS_PRIV_SCOPE_OK" || die "The MCP read-only user has system privileges beyond the read-only set (CREATE SESSION, USE ANY SCHEMA, SELECT ANY TABLE)."

    # No object privilege may be anything other than SELECT — i.e. the user
    # holds no INSERT/UPDATE/DELETE/ALTER/etc. object grant anywhere.
    _exakit_exapump_sql_has_token \
        "$_config_path" "admin" \
        "SELECT CASE WHEN COUNT(*) = 0 THEN 'EXAKIT_OBJ_PRIV_SCOPE_OK' ELSE 'EXAKIT_OBJ_PRIV_SCOPE_TOO_WIDE' END AS STATUS FROM EXA_DBA_OBJ_PRIVS WHERE GRANTEE = '$_user_lit' AND PRIVILEGE <> 'SELECT'" \
        "EXAKIT_OBJ_PRIV_SCOPE_OK" || die "The MCP read-only user has a write object privilege; it must be read-only."

    # Live proof the user cannot write: creating a table in the default schema
    # (which USE ANY SCHEMA lets it OPEN) MUST be rejected, since neither read
    # privilege grants CREATE/INSERT.
    _probe_schema="$(_exakit_first_schema "$_schemas")"
    _probe_schema_uc="$(printf '%s' "$_probe_schema" | tr '[:lower:]' '[:upper:]')"
    if _exakit_run_exapump_sql \
        "$_config_path" "mcp_readonly" \
        "CREATE TABLE ${_probe_schema_uc}.EXAKIT_MCP_PERMISSION_PROBE (ID DECIMAL)" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        _exakit_run_exapump_sql \
            "$_config_path" "admin" \
            "DROP TABLE ${_probe_schema_uc}.EXAKIT_MCP_PERMISSION_PROBE" \
            >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || true
        die "Security check failed: the MCP read-only user was able to write to schema $_probe_schema_uc, but it must be read-only. Setup stopped to protect your database."
    fi
}

# _exakit_reassert_mcp_readonly_posture — re-run the grant-posture check
# against the database using the credentials already on file, without
# re-provisioning anything. Used by `exakit mcp-doctor` so
# privilege drift after install (e.g. someone widening a grant by hand) is
# actually caught, not just checked once at setup time.
# Runs the (die()-on-failure) assertion in a subshell so a posture failure
# is reported back to the caller instead of aborting the whole CLI.
_exakit_reassert_mcp_readonly_posture() {
    # Ensure exapump is on PATH (both current session and permanently)
    _exapump_bin="$(exakit_exapump_bin 2>/dev/null)" || true
    if [ -n "$_exapump_bin" ]; then
        _exapump_dir="$(dirname "$_exapump_bin")"
        case ":$PATH:" in
            *":$_exapump_dir:"*) ;;
            *)
                PATH="$_exapump_dir:$PATH"
                _exakit_add_bin_to_shell_rc "$_exapump_dir"
                ;;
        esac
    fi
    
    _runtime_user="$(_exakit_manifest_runtime_value runtime.user)"
    _runtime_password_file="$(_exakit_manifest_runtime_value runtime.password_file)"
    _readonly_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _readonly_password_file="$(manifest_get components.mcp_server.connection.password_file 2>/dev/null || true)"
    _schemas_json="$(manifest_get components.mcp_server.connection.schemas 2>/dev/null || true)"

    if [ -z "$_runtime_user" ] || [ -z "$_runtime_password_file" ] || \
       [ -z "$_readonly_user" ] || [ -z "$_readonly_password_file" ] || [ -z "$_schemas_json" ]; then
        return 0
    fi
    [ -f "$_runtime_password_file" ] || { warn "Runtime password file missing; skipping MCP grant-posture re-check."; return 1; }
    [ -f "$_readonly_password_file" ] || { warn "MCP read-only password file missing; skipping MCP grant-posture re-check."; return 1; }

    _schemas_csv="$(run_python - "$_schemas_json" <<'PY'
import json, sys
print(",".join(json.loads(sys.argv[1])))
PY
)"
    [ -n "$_schemas_csv" ] || return 0

    _admin_password="$(cat "$_runtime_password_file")"
    _readonly_password="$(cat "$_readonly_password_file")"
    _host="$(_exakit_parse_runtime_host)"
    _port="$(_exakit_parse_runtime_port)"
    _default_schema="$(_exakit_first_schema "$_schemas_csv")"

    _temp_config="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"
    exakit_track_sensitive_tmp "$_temp_config"   # holds plaintext DB passwords; swept on any exit
    _exakit_write_exapump_config \
        "$_temp_config" "$_host" "$_port" "$_runtime_user" "$_admin_password" \
        "$_readonly_user" "$_readonly_password" "$_default_schema"

    info "Re-checking MCP read-only grant posture against the database"
    if ( _exakit_assert_mcp_readonly_posture "$_temp_config" "$_readonly_user" "$_schemas_csv" ) \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1; then
        rm -f "$_temp_config"
        ok "MCP read-only grant posture is still correct"
        return 0
    fi
    rm -f "$_temp_config"
    warn "MCP read-only grant posture has drifted from the expected read-only set (see log). Run 'exakit mcp-doctor' or review grants manually."
    return 1
}

_exakit_validate_identifier() {
    case "$1" in
        ""|*[!A-Za-z0-9_]*)
            return 1
            ;;
    esac
    return 0
}

_exakit_validate_sql_password_token() {
    case "$1" in
        ""|[!A-Z]*|*[!A-Z0-9]*)
            return 1
            ;;
    esac
    return 0
}

_exakit_generate_sql_password_token() {
    # Generate alphanumeric password (A-Z, 0-9 only, no underscores) for maximum SQL compatibility
    # Format: A followed by 23 random uppercase/digits
    printf 'A%s\n' "$(LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 23)"
}

# _exakit_add_bin_to_shell_rc <bin-directory>
# Adds the bin directory to shell startup files for persistent PATH updates
# across future shell sessions. Works for bash, zsh, and sh.
_exakit_add_bin_to_shell_rc() {
    _bin_dir="$1"
    _export_line="export PATH=\"$_bin_dir:\$PATH\""
    
    # Prefer ~/.bashrc (most common for interactive bash shells)
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -Fq "$_bin_dir" "$HOME/.bashrc" 2>/dev/null; then
            printf '\n%s\n' "$_export_line" >> "$HOME/.bashrc"
            ok "Added $_bin_dir to PATH in $HOME/.bashrc"
        fi
        return 0
    fi
    
    # Fall back to ~/.profile (POSIX shell / login shells)
    if [ -f "$HOME/.profile" ]; then
        if ! grep -Fq "$_bin_dir" "$HOME/.profile" 2>/dev/null; then
            printf '\n%s\n' "$_export_line" >> "$HOME/.profile"
            ok "Added $_bin_dir to PATH in $HOME/.profile"
        fi
        return 0
    fi
    
    # For macOS or when ~/.bashrc doesn't exist, try ~/.zshrc
    if [ -f "$HOME/.zshrc" ]; then
        if ! grep -Fq "$_bin_dir" "$HOME/.zshrc" 2>/dev/null; then
            printf '\n%s\n' "$_export_line" >> "$HOME/.zshrc"
            ok "Added $_bin_dir to PATH in $HOME/.zshrc"
        fi
        return 0
    fi
    
    # If no startup file exists yet, create ~/.profile
    if ! grep -Fq "$_bin_dir" "$HOME/.profile" 2>/dev/null; then
        printf '%s\n' "$_export_line" >> "$HOME/.profile"
        ok "Added $_bin_dir to PATH in new $HOME/.profile"
    fi
}

_exakit_redact_mcp_secret_output() {
    _text="$1"
    _secret="$2"
    if [ -n "$_secret" ]; then
        _text="${_text//$_secret/<redacted>}"
    fi
    printf '%s\n' "$_text" | sed -E "s/(IDENTIFIED BY )('[^']*'|[A-Z][A-Z0-9]*(\.\.\.)?)/\1<redacted>/g"
}

# _exakit_read_exapump_profile_password <profile> — print the password stored
# in the given exapump profile (EXAPUMP_CONFIG / ~/.exapump/config.toml), or
# nothing (non-zero) if it can't be read. Symmetric with how the profile is
# written in exapump.sh (an unescaped `password = "..."` line).
_exakit_read_exapump_profile_password() {
    _cfg="${EXAPUMP_CONFIG:-$HOME/.exapump/config.toml}"
    [ -f "$_cfg" ] || return 1
    require_python3
    run_python - "$_cfg" "$1" <<'PY'
import re, sys
path, profile = sys.argv[1], sys.argv[2]
try:
    content = open(path).read()
except OSError:
    sys.exit(1)
m = re.search(r"\[" + re.escape(profile) + r"\](.*?)(?:\n\[|\Z)", content, re.S)
if not m:
    sys.exit(1)
pw = re.search(r'(?m)^\s*password\s*=\s*"(.*)"\s*$', m.group(1))
if not pw:
    sys.exit(1)
sys.stdout.write(pw.group(1))
PY
}

# Four lines became one. Creating the user, creating the schema and validating
# the login are phases of a single outcome -- the read-only access exists and
# works -- and the tick at the end already said all three happened. They become
# spinner phases; the tick goes through ok_step so it survives the quieting.
exakit_configure_mcp_readonly_access() {
    _cmra_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    _cmra_t0="$(date +%s 2>/dev/null || echo 0)"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    require_python3
    # Ensure exapump is on PATH (both current session and permanently)
    _exapump_bin="$(exakit_exapump_bin)" || die "exapump is required for MCP read-only setup but was not found."
    _exapump_dir="$(dirname "$_exapump_bin")"
    case ":$PATH:" in
        *":$_exapump_dir:"*) ;;
        *)
            PATH="$_exapump_dir:$PATH"
            _exakit_add_bin_to_shell_rc "$_exapump_dir"
            ;;
    esac
    
    _runtime_user="$(_exakit_manifest_runtime_value runtime.user)"
    [ -n "$_runtime_user" ] || die "runtime.user is missing; cannot prepare the MCP read-only database user."
    _runtime_password_file="$(_exakit_manifest_runtime_value runtime.password_file)"
    _admin_password=""
    if [ -n "$_runtime_password_file" ] && [ -f "$_runtime_password_file" ]; then
        _admin_password="$(cat "$_runtime_password_file")"
    fi
    # Fallback: recover the admin password from the exapump profile that the
    # data step already wrote and validated. Covers installs where the runtime
    # step could not record runtime.password_file (an adopted deployment with
    # unreadable secrets) — including re-runs, where the exapump step is skipped
    # as "already done" and so cannot record it either. Persist it forward so
    # later runs and mcp-doctor find it directly.
    if [ -z "$_admin_password" ]; then
        _admin_password="$(_exakit_read_exapump_profile_password "$EXAKIT_EXAPUMP_PROFILE" 2>/dev/null || true)"
        if [ -n "$_admin_password" ]; then
            store_credential runtime_sys_password "$_admin_password"
            manifest_set runtime.password_file "$EXAKIT_CREDS_DIR/runtime_sys_password"
        fi
    fi
    [ -n "$_admin_password" ] || die "No runtime database password is available (runtime.password_file is missing and the exapump '$EXAKIT_EXAPUMP_PROFILE' profile has none). Set it with 'exapump profile init $EXAKIT_EXAPUMP_PROFILE', then re-run."
    _host="$(_exakit_parse_runtime_host)"
    _port="$(_exakit_parse_runtime_port)"
    [ -n "$_host" ] || die "runtime.dsn is missing a host; cannot prepare the MCP read-only database user."
    [ -n "$_port" ] || die "runtime.dsn is missing a port; cannot prepare the MCP read-only database user."

    _readonly_user="$EXAKIT_MCP_READONLY_USER"
    # The MCP user gets database-wide READ (USE ANY SCHEMA + SELECT ANY TABLE),
    # so it can query every schema and table — bundled datasets, your own
    # uploads, and anything you create later — with no per-schema grant. This
    # list is now only the connection's DEFAULT schema (the landing spot for
    # local uploads); it must exist so the exapump profile can OPEN it on
    # connect, and it is the schema the write-rejection probe targets.
    _readonly_schemas="$EXAKIT_MCP_READONLY_SCHEMAS"
    _default_schema="$(_exakit_first_schema "$_readonly_schemas")"
    _readonly_password="$(read_credential mcp_readonly_password)"
    if ! _exakit_validate_sql_password_token "$_readonly_password"; then
        _readonly_password="$(_exakit_generate_sql_password_token)"
        store_credential mcp_readonly_password "$_readonly_password"
    fi

    _identifier_user="$(printf '%s' "$_readonly_user" | tr '[:lower:]' '[:upper:]')"
    _default_schema_uc="$(printf '%s' "$_default_schema" | tr '[:lower:]' '[:upper:]')"
    _exakit_validate_identifier "$_identifier_user" || die "Invalid EXAKIT_MCP_READONLY_USER: $_readonly_user"
    _temp_config="$(mktemp "${TMPDIR:-/tmp}/exakit-exapump.XXXXXX")"
    exakit_track_sensitive_tmp "$_temp_config"   # holds plaintext DB passwords; swept on any exit
    _exakit_write_exapump_config \
        "$_temp_config" "$_host" "$_port" "$_runtime_user" "$_admin_password" \
        "$_readonly_user" "$_readonly_password" "$_default_schema_uc"

    if ! _exakit_exapump_sql_has_token \
        "$_temp_config" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_DBA_USERS WHERE USER_NAME = '$(_exakit_sql_literal "$_identifier_user")') THEN 'EXAKIT_MCP_USER_PRESENT' ELSE 'EXAKIT_MCP_USER_MISSING' END AS STATUS" \
        "EXAKIT_MCP_USER_PRESENT"; then
        EXAKIT_ACTIVE_LABEL="Creating the dedicated MCP read-only database user"
        info "Creating the dedicated MCP read-only database user ($_readonly_user)"
        _create_user_output="$(_exakit_run_exapump_sql \
            "$_temp_config" "admin" \
            "CREATE USER ${_identifier_user} IDENTIFIED BY ${_readonly_password}" 2>&1)"
        if [ $? -ne 0 ]; then
            _create_user_redacted="$(_exakit_redact_mcp_secret_output "$_create_user_output" "$_readonly_password")"
            _exakit_log_file "ERROR_DETAIL $_create_user_redacted"
            error "CREATE USER details: $_create_user_redacted"
            die "Could not create the MCP read-only database user."
        fi
        _create_user_redacted="$(_exakit_redact_mcp_secret_output "$_create_user_output" "$_readonly_password")"
        [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_create_user_redacted" >> "$EXAKIT_LOG_FILE"
    fi

    _alter_user_output="$(_exakit_run_exapump_sql \
        "$_temp_config" "admin" \
        "ALTER USER ${_identifier_user} IDENTIFIED BY ${_readonly_password}" 2>&1)"
    if [ $? -ne 0 ]; then
        _alter_user_redacted="$(_exakit_redact_mcp_secret_output "$_alter_user_output" "$_readonly_password")"
        _exakit_log_file "ERROR_DETAIL $_alter_user_redacted"
        error "ALTER USER details: $_alter_user_redacted"
        die "Could not refresh the MCP read-only database password."
    fi
    _alter_user_redacted="$(_exakit_redact_mcp_secret_output "$_alter_user_output" "$_readonly_password")"
    [ -n "${EXAKIT_LOG_FILE:-}" ] && printf '%s\n' "$_alter_user_redacted" >> "$EXAKIT_LOG_FILE"
    _exakit_run_exapump_sql \
        "$_temp_config" "admin" \
        "GRANT CREATE SESSION TO ${_identifier_user}" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not grant CREATE SESSION to the MCP read-only database user."

    # Make sure the connection's default schema exists — exapump OPENs it on
    # connect, and the write-rejection probe targets it.
    _exakit_validate_identifier "$_default_schema_uc" || die "Invalid MCP default schema name: $_default_schema"
    if ! _exakit_exapump_sql_has_token \
        "$_temp_config" "admin" \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM EXA_ALL_SCHEMAS WHERE SCHEMA_NAME = '$(_exakit_sql_literal "$_default_schema_uc")') THEN 'EXAKIT_SCHEMA_PRESENT' ELSE 'EXAKIT_SCHEMA_MISSING' END AS STATUS" \
        "EXAKIT_SCHEMA_PRESENT"; then
        EXAKIT_ACTIVE_LABEL="Creating the default schema for MCP-safe querying"
        info "Creating default schema $_default_schema_uc for MCP-safe querying"
        _exakit_run_exapump_sql "$_temp_config" "admin" "CREATE SCHEMA ${_default_schema_uc}" \
            >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not create schema $_default_schema_uc for MCP access."
    fi

    # Database-wide READ: USE ANY SCHEMA (see every schema) + SELECT ANY TABLE
    # (read table/view contents in any schema). Together these let the AI client
    # query every schema and table — present and future, including ones you
    # create by hand — without a per-schema grant. Neither privilege permits any
    # write or DDL, so the read-only guarantee is preserved (and re-checked by
    # _exakit_assert_mcp_readonly_posture below). SELECT ANY DICTIONARY is
    # deliberately NOT granted, so system dictionaries (audit logs, sessions,
    # other users) stay private; the server lists metadata from the self-scoped
    # EXA_ALL_* views, which USE ANY SCHEMA already covers.
    _exakit_run_exapump_sql "$_temp_config" "admin" "GRANT USE ANY SCHEMA TO ${_identifier_user}" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not grant USE ANY SCHEMA to the MCP read-only database user."
    _exakit_run_exapump_sql "$_temp_config" "admin" "GRANT SELECT ANY TABLE TO ${_identifier_user}" \
        >> "${EXAKIT_LOG_FILE:-/dev/null}" 2>&1 || die "Could not grant SELECT ANY TABLE to the MCP read-only database user."

    EXAKIT_ACTIVE_LABEL="Validating the dedicated MCP read-only login"
    info "Validating dedicated MCP read-only login"
    _exakit_exapump_sql_has_token \
        "$_temp_config" "mcp_readonly" \
        "SELECT CURRENT_USER AS EXAKIT_CURRENT_USER" \
        "$_identifier_user" || die "The MCP read-only user could not log in with the generated credentials."
    _exakit_exapump_sql_has_token \
        "$_temp_config" "mcp_readonly" \
        "SELECT 'EXAKIT_MCP_READONLY_OK' AS STATUS" \
        "EXAKIT_MCP_READONLY_OK" || die "The MCP read-only user did not pass the validation query."
    _exakit_assert_mcp_readonly_posture "$_temp_config" "$_readonly_user" "$_readonly_schemas"

    manifest_set components.mcp_server.connection.user "$_readonly_user"
    manifest_set components.mcp_server.connection.password_file "$EXAKIT_CREDS_DIR/mcp_readonly_password"
    # Records the connection's default schema (read access is database-wide, not
    # limited to this list); kept as an array for the posture re-check and the
    # exapump default-schema pick.
    manifest_set components.mcp_server.connection.schemas "[\"$(printf '%s' "$_readonly_schemas" | tr ',' '\n' | sed '/^$/d' | paste -sd '","' -)\"]"
    # THE SAME FACT, SPELLED SO IT CANNOT BE MISREAD. `schemas: ["STARTER_KIT"]`
    # reads as "this user can only see STARTER_KIT" — and an agent checking the
    # install record before querying concluded exactly that, while the MCP user
    # was in fact returning TPCH, ENERGY and WEATHER quite happily. The array
    # stays (internal readers parse it); these two say what it means.
    manifest_set components.mcp_server.connection.default_schema "$_default_schema"
    manifest_set components.mcp_server.connection.read_scope \
        "every schema (USE ANY SCHEMA + SELECT ANY TABLE); 'schemas' is the connection default, not a limit"
    manifest_set components.mcp_server.connection.validated "true"
    rm -f "$_temp_config"
    EXAKIT_QUIET_DETAIL="$_cmra_prev_quiet"
    ok_step "Dedicated MCP read-only access is configured and validated ($(( $(date +%s 2>/dev/null || echo 0) - _cmra_t0 ))s)"
    return 0
}

# _exakit_mcp_reported <result_file> — did the operation produce a real report?
#
# True when the file parses as a result document carrying an operation and a
# status. That is the difference between "the runtime ran and is telling you
# something" and "the runtime never got far enough to say anything", which the
# exit code alone cannot express.
_exakit_mcp_reported() {
    [ -s "${1:-}" ] || return 1
    exakit_can_run_python 2>/dev/null || return 1
    run_python - "$1" <<'PY' >/dev/null 2>&1
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if isinstance(doc, dict) and doc.get("operation") and doc.get("status") else 1)
PY
}

# _exakit_log_mcp_result_failure <result_file> — copy the CLI's structured
# diagnosis (status + findings) into the log so "see log" is honest. A crash
# already lands in the log via the runners' stderr redirect; this covers the
# other failure shape, where the CLI exits non-zero with the cause only in its
# JSON payload. Deliberately logs findings, not the raw payload — the payload
# can embed rendered client-config material.
_exakit_log_mcp_result_failure() {
    [ -s "$1" ] || return 0
    [ -n "${EXAKIT_LOG_FILE:-}" ] || return 0
    run_python - "$1" <<'PY' >> "$EXAKIT_LOG_FILE" 2>&1 || true
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception as exc:  # noqa: BLE001 - diagnostics only, never fatal
    print(f"MCP result file unreadable: {exc}")
    raise SystemExit(0)

print(f"MCP status: {doc.get('status', 'unknown')} — {doc.get('summary', '')}")
for finding in doc.get("findings", []) or []:
    line = f"MCP finding [{finding.get('severity')}] {finding.get('code')}: {finding.get('message')}"
    action = finding.get("recommended_action")
    if action:
        line += f" -> {action}"
    print(line)
PY
}

exakit_run_mcp_setup_cli() {
    _clients_csv="$1"
    _output_file="$2"
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to configure MCP clients."
        return 1
    }
    # The caller may have prepared the read-only user already: it narrates as it
    # goes, and the client table is animating by the time this runs, so nothing
    # may print. One call only — the flag is cleared here, so a later run in the
    # same process (a refresh after a redeploy) prepares the user again.
    if [ "${EXAKIT_MCP_READONLY_READY:-0}" = 1 ]; then
        EXAKIT_MCP_READONLY_READY=0
    else
        exakit_configure_mcp_readonly_access || return 1
    fi
    _old_ifs="$IFS"
    IFS=','
    set -- $_clients_csv
    IFS="$_old_ifs"
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp setup-runtime-clients \
                --runtime-root "$EXAKIT_HOME" \
                --clients "$@"
    ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        _exakit_log_mcp_result_failure "$_output_file"
        # First, not last: the client table may be animating, and its next frame
        # moves the cursor up and clears — which would wipe this warning off the
        # screen before anyone could read it. die() stops the animation for the
        # same reason.
        command -v ui_animation_stop >/dev/null 2>&1 && ui_animation_stop
        warn "MCP client setup failed (see log)."
        return 1
    fi
    return 0
}

exakit_run_mcp_operation_cli() {
    _operation="$1"
    _clients_csv="$2"
    _output_file="$3"
    _snapshot_id="${4:-}"
    require_python3
    _repo_root="$(exakit_repo_root)" || {
        warn "Could not find the MCP package source to manage MCP clients."
        return 1
    }
    case "$_operation" in
        validate|repair|doctor)
            exakit_configure_mcp_readonly_access || return 1
            ;;
    esac
    _old_ifs="$IFS"
    IFS=','
    set -- $_clients_csv
    IFS="$_old_ifs"
    if [ -n "$_snapshot_id" ]; then
        if ! (
            cd "$_repo_root" &&
            PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
                run_python -m mcp run-runtime-operation \
                    "$_operation" \
                    --runtime-root "$EXAKIT_HOME" \
                    --snapshot-id "$_snapshot_id" \
                    --clients "$@"
        ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
            _exakit_log_mcp_result_failure "$_output_file"
            _exakit_mcp_reported "$_output_file" && return 2
            warn "MCP $_operation failed (see log)."
            return 1
        fi
        return 0
    fi
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp run-runtime-operation \
                "$_operation" \
                --runtime-root "$EXAKIT_HOME" \
                --clients "$@"
    ) > "$_output_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        _exakit_log_mcp_result_failure "$_output_file"
        # A diagnosis that FOUND something is not a diagnosis that failed to run.
        # The runtime exits non-zero for both, so the two were reported the same
        # way: doctor printed a complete report naming the exact fault, and then
        # said "MCP doctor failed" and "Could not run MCP diagnostics" - telling
        # the reader the tool broke, when the tool had just done its job.
        # Return 2 so the caller can keep a non-zero exit for scripts without
        # contradicting the report it just printed.
        _exakit_mcp_reported "$_output_file" && return 2
        warn "MCP $_operation failed (see log)."
        return 1
    fi
    return 0
}

# exakit_print_mcp_setup_summary <result-json> — what MCP setup did, in the
# fewest lines that still tell the reader everything they have to act on.
#
# This was a twenty-line panel: a Mode row, a Meaning row explaining the Mode
# row, a Status row, and one File: row per client. None of that is actionable,
# and every word of it is one `exakit mcp-status` away. What IS actionable — the
# clients configured, the plaintext-credential warning, and the per-client
# "restart it like this" lines, which differ per client — stays, as plain lines
# rather than boxed rows. Python emits typed records; the shell renders each
# through the same info/ok/warn the rest of the run uses.
#
# <table-shown> = 1 when the client table carried the per-client outcome: the
# headline is then dropped, because the table said it row by row and said which
# client got what. A run that did NOT finish clean still says so here.
exakit_print_mcp_setup_summary() {
    _result_file="$1"
    _table_shown="${2:-0}"
    require_python3
    _summary_lines="$(run_python - "$_result_file" "$_table_shown" <<'PY'
import json, sys

LABELS = {
    "claude_desktop": "Claude",
    "claude_code": "Claude Code (CLI)",
    "vscode_copilot": "GitHub Copilot",
    "gemini_cli": "Gemini CLI",
    "cursor": "Cursor",
    "codex": "Codex",
    "opencode": "OpenCode",
    "continue": "Continue",
}

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)

# One record per line: "<kind>|<text>". The shell knows how to draw each kind;
# nothing here decides what it looks like.
clients = ", ".join(LABELS.get(item, item) for item in doc.get("selected_clients", []))
lines = []
status = doc.get("status", "unknown")
table_shown = len(sys.argv) > 2 and sys.argv[2] == "1"
if str(status).startswith("success"):
    # The table already named every client and what happened to it, so this
    # line would be the same fact twice, the second time less precisely.
    if not table_shown:
        lines.append(f"ok|MCP configured for {clients or 'no clients'}")
else:
    lines.append(f"warn|MCP setup finished as '{status}' for {clients or 'no clients'}")

# A client whose own config file could not be used is skipped on its own; the
# other clients are still configured, so name it rather than leave a silent gap.
for skipped in doc.get("details", {}).get("skipped_clients", []):
    client = LABELS.get(skipped.get("client"), skipped.get("client", "unknown"))
    lines.append(f"warn|Skipped {client}: {skipped.get('reason', 'unknown reason')}")

# The plaintext-credential finding is a standing property of how every MCP
# client stores a credential, not something this run did or the reader can act
# on -- and it is the READ-ONLY user's password, not the admin one. Raising it
# as a warning on every single install taught people to read past warnings.
# It stays in the result JSON and in the logfile, and `exakit help mcp`
# documents it in full.
for finding in doc.get("findings", []):
    if finding.get("code") == "plaintext_credential_reference":
        continue
    lines.append(f"warn|{finding.get('message', 'Unknown issue')}")

# One "restart your client" line per configured client says the same thing
# four times over, in four wordings, for an action the reader takes once. The
# skills step closes the same install with the generic form already. Every
# adapter tags these kind="restart_client" (json_config.py covers Cursor), so
# dropping that kind drops exactly them -- a repair's next_actions carry the
# finding code as their kind and are untouched.
for action in doc.get("next_actions", []):
    if action.get("kind") == "restart_client":
        continue
    message = action.get("message", "")
    if message:
        lines.append(f"info|{message}")

print("\n".join(lines))
PY
)" || { warn "Could not render the MCP setup summary (see log)."; return 0; }
    while IFS='|' read -r _sum_kind _sum_text; do
        [ -n "$_sum_text" ] || continue
        case "$_sum_kind" in
            ok)   ok   "$_sum_text" ;;
            warn) warn "$_sum_text" ;;
            *)    info "$_sum_text" ;;
        esac
    done <<EOF
$_summary_lines
EOF
    # Already in the closing panel, verbatim in effect:
    #   MCP configs:  in each AI client's config (list: exakit mcp-status)
    # so the pointer survives without being given twice.
    _exakit_log_file "INFO  Config file paths and per-client state: exakit mcp-status"
}

exakit_print_mcp_ready_panel() {
    _mode="${1:-}"
    _dsn="$(manifest_get runtime.dsn 2>/dev/null || true)"
    _mcp_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"
    _mcp_package="$(manifest_get components.mcp_server.package 2>/dev/null || printf '%s' "$EXAKIT_MCP_PACKAGE")"
    _mcp_version="$(manifest_get components.mcp_server.version 2>/dev/null || printf '%s' "$EXAKIT_MCP_VERSION")"
    _mcp_command="$(manifest_get components.mcp_server.command 2>/dev/null || true)"
    _tls="$(manifest_get runtime.tls 2>/dev/null || true)"
    [ -n "$_mcp_command" ] || _mcp_command="uvx"

    # An eight-row panel of reference values became one line. The command, the
    # package version and the managed-state directory are what `exakit
    # mcp-status` is for; what the reader needs here is that the server exists,
    # what it is called, and that it reaches the database read-only. The whole
    # panel still goes to the logfile, so nothing is unrecoverable.
    _exakit_log_file "DATA  MCP command: $_mcp_command $_mcp_package@$_mcp_version"
    _exakit_log_file "DATA  MCP managed state: $EXAKIT_MCP_DIR"
    _exakit_log_file "DATA  MCP TLS: ${_tls:-unknown}"
    ok "MCP server 'exasol' — ${_dsn:-unknown} as ${_mcp_user:-mcp_readonly} (read-only), started by your AI client on demand"
    # Put the prompt straight onto the clipboard so the first interaction is a
    # paste, not a retype. Best-effort: silent when no clipboard tool exists.
    #
    # ONLY WITH A TERMINAL ATTACHED. The clipboard is the user's, and an
    # unattended install — an agent driving the kit, CI, a provisioning script —
    # has no business overwriting whatever they had on it for a prompt nobody is
    # about to paste. There is no undo for a clipboard.
    _first_prompt='Use the exasol MCP server connected to my local Exasol database. List the available schemas and tables first. Then answer my questions with read-only SQL only, show me the SQL before you run it, and do not create, update, or delete anything.'
    # The prompt is only PRINTED when it could not be handed over: on the
    # clipboard it is four lines nobody has to read, and off a terminal (an
    # agent, CI) the clipboard is not ours to take, so the text is the only way
    # to pass it on. Never both.
    if exakit_stdin_is_tty && printf '%s' "$_first_prompt" | exakit_copy_clipboard 2>/dev/null; then
        ok "A first prompt for your AI client is on your clipboard — paste it after the restart."
    else
        printf '\n'
        ui_panel_begin "First prompt to try in your AI client"
        ui_panel_line '"Use the exasol MCP server connected to my local Exasol database.'
        ui_panel_line 'List the available schemas and tables first. Then answer my'
        ui_panel_line 'questions with read-only SQL only, show me the SQL before you run'
        ui_panel_line 'it, and do not create, update, or delete anything."'
        ui_panel_end
    fi
}

exakit_print_mcp_operation_summary() {
    _result_file="$1"
    require_python3
    run_python - "$_result_file" <<'PY'
import json, os, sys

LABELS = {
    "claude_desktop": "Claude",
    "claude_code": "Claude Code (CLI)",
    "vscode_copilot": "GitHub Copilot",
    "gemini_cli": "Gemini CLI",
    "cursor": "Cursor",
    "codex": "Codex",
    "opencode": "OpenCode",
    "continue": "Continue",
}

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = json.load(handle)

# `mcp-status` is a STATE QUERY, and the operation summary answers a different
# question. It listed `selected_clients`, which with no client named is every
# client the kit SUPPORTS - so all eight printed whether one was configured or
# eight - and reduced the per-client records to "Tracked 4 managed artifact(s)".
# A reader asking "is my Claude set up?" got the kit's capabilities and a count.
#
# The rows are already in the result; this prints them. Snapshot is left out on
# purpose: a backup id is worth showing after a command that CHANGED something,
# and is noise on a read-only screen.
STATE_LABELS = {
    "configured": "configured",
    "not_set_up": "not set up",
    "not_installed": "not installed",
}
clients_detail = doc.get("details", {}).get("clients") or []
if doc.get("operation") == "status" and clients_detail:
    rows = []
    for entry in clients_detail:
        name = LABELS.get(entry.get("client"), entry.get("client", "unknown"))
        state = STATE_LABELS.get(entry.get("state"), entry.get("state", "unknown"))
        if entry.get("state") == "configured":
            note = entry.get("path") or ""
            home = os.path.expanduser("~")
            if note.startswith(home):
                note = "~" + note[len(home):]
        elif entry.get("state") == "not_set_up":
            note = "run: exakit mcp-setup"
        else:
            # The State column already said "not installed"; repeating it here
            # spends the widest column on nothing.
            note = ""
        rows.append((name, state, note))
    width = max(len(r[0]) for r in rows)
    state_w = max(len(r[1]) for r in rows)
    # Keep the row inside 80 columns. A real config path is long enough on its
    # own ("~/Library/Application Support/Claude/claude_desktop_config.json" is
    # 62) to push the table past any terminal, and a wrapped row loses the
    # column alignment that makes the table readable at a glance. The FILE NAME
    # is the part that identifies it, so the middle goes rather than the end.
    budget = 80 - (2 + width + 2 + state_w + 2)
    trimmed = []
    for name, state, note in rows:
        if len(note) > budget and "/" in note:
            parts = note.split("/")
            # Keep as many trailing segments as fit: the directory above the file
            # is often what tells two clients apart (Code/User/mcp.json), so drop
            # only what the budget forces.
            keep = 1
            while keep < len(parts):
                candidate = parts[0] + "/.../" + "/".join(parts[-(keep + 1):])
                if len(candidate) > budget:
                    break
                keep += 1
            note = parts[0] + "/.../" + "/".join(parts[-keep:])
            if len(note) > budget:
                note = ".../" + parts[-1]
        trimmed.append((name, state, note))
    rows = trimmed
    print("")
    print("  MCP clients")
    print("  " + "-" * 74)
    print(f"  {'Client'.ljust(width)}  {'State'.ljust(state_w)}  Config")
    for name, state, note in rows:
        print(f"  {name.ljust(width)}  {state.ljust(state_w)}  {note}".rstrip())
    print("")
    configured = sum(1 for e in clients_detail if e.get("state") == "configured")
    if configured:
        print("  Not working? Check it end to end with: exakit mcp-doctor")
    else:
        print("  Nothing configured yet. Connect a client with: exakit mcp-setup")
else:
    clients = ", ".join(LABELS.get(item, item) for item in doc.get("selected_clients", []))
    print("")
    print("  MCP operation summary")
    print(f"  Operation: {doc.get('operation', 'unknown')}")
    print(f"  Clients:   {clients or 'all managed clients'}")
    print(f"  Status:    {doc.get('status', 'unknown')}")
    print(f"  Summary:   {doc.get('summary', 'No summary returned')}")
    if doc.get("backup_reference"):
        print(f"  Snapshot:  {doc.get('backup_reference')}")

# Clients left alone because their own config file could not be used. The rest
# of the selection is still configured, so report this per client.
skipped_clients = doc.get("details", {}).get("skipped_clients", [])
if skipped_clients:
    print("")
    print("  Skipped clients:")
    for skipped in skipped_clients:
        name = LABELS.get(skipped.get("client"), skipped.get("client", "unknown"))
        print(f"  - {name}: {skipped.get('reason', 'unknown reason')}")

# Doctor carries per-client discovery plus the managed-artifact list: render
# a state map in the same vocabulary as the setup menu, so "not installed"
# reads as expected state instead of a warning.
discovered = (doc.get("details") or {}).get("discovered_clients") or []
if discovered:
    managed = {artifact.get("client") for artifact in doc.get("artifacts") or []}
    groups = {"connected": [], "available": [], "needs attention": [], "not installed": []}
    for entry in discovered:
        cid = entry.get("client")
        name = LABELS.get(cid, cid)
        if entry.get("detected") and cid in managed:
            groups["connected"].append(name)
        elif entry.get("detected"):
            groups["available"].append(name)
        elif cid in managed:
            groups["needs attention"].append(name)
        else:
            groups["not installed"].append(name)
    hints = {
        "available": "-> connect with: exakit mcp-setup",
        "needs attention": "-> managed entry, client missing (exakit mcp-remove)",
    }
    print("")
    print("  Client state:")
    for label, names in groups.items():
        if names:
            hint = hints.get(label, "")
            print(f"    {label:<15} {', '.join(names)}{'   ' + hint if hint else ''}")

changes = doc.get("changes", [])
if changes:
    print("")
    print("  Changes:")
    for change in changes:
        print(f"  - {change.get('kind', 'change')} {change.get('path', '')}")

# Absent-client INFO findings are already represented in the state map above;
# repeating them as notes made a healthy machine read like a problem report.
findings = [
    finding
    for finding in doc.get("findings", [])
    if not (discovered and finding.get("severity") == "info" and finding.get("code") == "client_not_detected")
]
if findings:
    print("")
    print("  Notes:")
    for finding in findings:
        print(f"  - {finding.get('message', 'Unknown issue')}")

actions = doc.get("next_actions", [])
if actions:
    print("")
    print("  Next:")
    for action in actions:
        print(f"  - {action.get('message', '')}")
PY
}

exakit_mcp_clients_from_args() {
    if [ "$#" -eq 0 ]; then
        printf '%s\n' "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue"
        return 0
    fi
    exakit_parse_mcp_client_selection "$*"
}

exakit_parse_mcp_client_selection() {
    _raw="$(printf '%s' "$1" | tr ',/' '  ' | tr -s ' ')"
    case "$_raw" in
        "" ) return 1 ;;
        all|ALL|All ) printf '%s\n' "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue"; return 0 ;;
    esac
    _result=""
    for _token in $_raw; do
        # "claude" (or 1) covers both Claude surfaces — the desktop app and the
        # Claude Code CLI — one user choice, two configs. The explicit ids
        # (claude_desktop / claude_code) still address a single surface.
        case "$_token" in
            1|claude) _clients="claude_desktop claude_code" ;;
            claude_desktop) _clients="claude_desktop" ;;
            claude_code) _clients="claude_code" ;;
            2|codex) _clients="codex" ;;
            3|cursor) _clients="cursor" ;;
            4|copilot|vscode|vscode_copilot) _clients="vscode_copilot" ;;
            5|gemini|gemini_cli) _clients="gemini_cli" ;;
            6|opencode) _clients="opencode" ;;
            7|continue) _clients="continue" ;;
            *) return 1 ;;
        esac
        for _client in $_clients; do
            case ",$_result," in
                *,"$_client",*) ;;
                *)
                    if [ -n "$_result" ]; then
                        _result="$_result,$_client"
                    else
                        _result="$_client"
                    fi
                    ;;
            esac
        done
    done
    [ -n "$_result" ] || return 1
    printf '%s\n' "$_result"
}

# exakit_mcp_discover_status — one "id state" line per supported MCP client,
# straight from the adapters' own detection: "pending" (installed on this
# machine, no managed config yet), "connected" (has a managed config), or
# "missing" (not installed). Used to build the setup menu: pending clients are
# selectable and pre-selected, the others are shown greyed out with the
# reason. Fails (rc 1) when discovery is unavailable so the caller can fall
# back to the static everything-selectable menu.
exakit_mcp_discover_status() {
    require_python3 2>/dev/null || return 1
    _repo_root="$(exakit_repo_root)" || return 1
    _discover_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-discover.XXXXXX")"
    if ! (
        cd "$_repo_root" &&
        PYTHONPATH="$_repo_root${PYTHONPATH:+:$PYTHONPATH}" \
            run_python -m mcp discover-clients --runtime-root "$EXAKIT_HOME"
    ) > "$_discover_file" 2>> "${EXAKIT_LOG_FILE:-/dev/null}"; then
        rm -f "$_discover_file"
        return 1
    fi
    run_python - "$_discover_file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except Exception:
    sys.exit(1)
for client in doc.get("clients", []):
    if client.get("configured"):
        state = "connected"
    elif client.get("detected"):
        state = "pending"
    else:
        state = "missing"
    print(f'{client["id"]} {state}')
PY
    _parse_status=$?
    rm -f "$_discover_file"
    return "$_parse_status"
}

# exakit_ensure_runtime_running [deploy] — the kit's self-heal for "the
# database is not answering", shared by every command that is about to speak
# SQL. A runtime that is merely STOPPED (exakit stop, a reboot) is started and
# health-checked; a MISSING one is deployed when the caller passes "deploy"
# (the action commands do), and otherwise refused with the exact command that
# fixes it. A machine with no runtime recorded, or whose runtime module is not
# loaded, is left alone — that is the installer's territory, not a repair.
# ⇄ twin: Confirm-ExakitRuntimeRunning in setup/lib/exakit-common.ps1.
exakit_ensure_runtime_running() {
    _err_deploy="${1:-}"
    case "$(manifest_get runtime.type 2>/dev/null || true)" in
        personal)
            command -v personal_deployment_running >/dev/null 2>&1 || return 0
            personal_deployment_running && return 0
            if personal_deployment_exists; then
                info "Self-heal: the database is deployed but not running — starting it"
                personal_start
                personal_wait_ready
                return 0
            fi
            if [ "$_err_deploy" = "deploy" ]; then
                info "Self-heal: no database deployment found — deploying one"
                personal_deploy_local
                return 0
            fi
            die "No database deployment found. Deploy one with: exakit start (or re-run the installer)"
            ;;
        nano)
            command -v nano_status >/dev/null 2>&1 || return 0
            [ "$(nano_status 2>/dev/null)" = "running" ] && return 0
            # nano_install self-heals both halves: it starts an existing
            # container and creates a missing one, then waits for ready.
            if nano_container_exists 2>/dev/null; then
                info "Self-heal: the database container exists but is not running — starting it"
                nano_install
                return 0
            fi
            if [ "$_err_deploy" = "deploy" ]; then
                info "Self-heal: no database container found — creating one"
                nano_install
                return 0
            fi
            die "No database container found. Create one with: exakit start (or re-run the installer)"
            ;;
        *) return 0 ;;
    esac
}

# The AI-client table: the rows a reader ticks in the selection phase are the
# rows the progress phase fills in. The state file is what the two phases share
# (see ui_table_* in ui.sh); empty means this run has no table — a scripted
# EXAKIT_MCP_CLIENTS answer, or no terminal to draw one on.
EXAKIT_MCP_TABLE_STATE=""

# _exakit_mcp_table_release — the table is finished with: drop its state file and
# the two globals the component reads from the caller, so the NEXT table in the
# same run (the dataset load) is not left wearing this one's title and column
# heading.
_exakit_mcp_table_release() {
    UI_TABLE_TITLE=""
    UI_TABLE_COL1=""
    # And the read-only user's "already done" flag, which only ever covers the
    # one CLI call this table was drawn for: a later run in the same process
    # (mcp.sh's refresh after a redeploy) must prepare it again.
    EXAKIT_MCP_READONLY_READY=0
    if [ -n "$EXAKIT_MCP_TABLE_STATE" ]; then
        rm -f "$EXAKIT_MCP_TABLE_STATE" "$EXAKIT_MCP_TABLE_STATE.lines" \
            "$EXAKIT_MCP_TABLE_STATE.stop" "$EXAKIT_MCP_TABLE_STATE.new"
    fi
    EXAKIT_MCP_TABLE_STATE=""
    return 0
}

# _exakit_mcp_result_states <result-json> — one "<client-id> configured" or
# "<client-id> skipped" line per client the run touched, straight from the CLI's
# own record of what it wrote. The table's final cells are built from this rather
# than from the exit status, which cannot tell "one client's config file was
# unusable" from "nothing was configured".
_exakit_mcp_result_states() {
    [ -s "$1" ] || return 1
    exakit_can_run_python || return 1
    run_python - "$1" <<'PY' 2>/dev/null
import json, sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
details = doc.get("details") or {}
for client in details.get("configured_clients") or []:
    print(f"{client} configured")
for item in details.get("skipped_clients") or []:
    client = item.get("client")
    if client:
        print(f"{client} skipped")
PY
}

exakit_mcp_setup() {
    # About to create/verify the read-only database user: a stopped database
    # here used to surface as a bare "Connection refused" — heal it first.
    exakit_ensure_runtime_running

    info "MCP setup will edit the selected AI client config files."

    EXAKIT_MCP_TABLE_STATE=""
    _mcp_rows=""                    # the table rows the progress phase fills in

    # EXAKIT_MCP_CLIENTS lets an agent-driven or scripted install pick clients
    # without a prompt (e.g. "claude", "claude,cursor", "all", or "1,2").
    if [ -n "${EXAKIT_MCP_CLIENTS:-}" ]; then
        case "$EXAKIT_MCP_CLIENTS" in
            skip|SKIP|Skip|none|NONE|None)
                info "Skipping MCP client setup (EXAKIT_MCP_CLIENTS=$EXAKIT_MCP_CLIENTS) — run 'exakit mcp-setup' any time."
                return 0
                ;;
        esac
        _clients_csv="$(exakit_parse_mcp_client_selection "$EXAKIT_MCP_CLIENTS")" || {
            warn "EXAKIT_MCP_CLIENTS='$EXAKIT_MCP_CLIENTS' is not valid (use claude, codex, cursor, copilot, gemini, opencode, continue, all, skip, or numbers 1-7)."
            return 1
        }
        info "Configuring MCP clients from EXAKIT_MCP_CLIENTS: $_clients_csv"
    else
        # Show the FULL list of supported clients so the user sees everything
        # the kit can connect: pending clients (installed, not connected yet)
        # are selectable and pre-selected; clients that are already connected
        # or not installed on this machine appear as DISABLED rows with the
        # reason and cannot be checked. One "Claude" row covers both Claude
        # surfaces (desktop app + Claude Code CLI) while their states match;
        # when they differ, each surface gets its own row. Falls back to
        # everything selectable when discovery is unavailable.
        _cd_state=pending; _cc_state=pending; _codex_state=pending
        _cursor_state=pending; _copilot_state=pending; _gemini_state=pending
        _opencode_state=pending; _continue_state=pending
        if _client_status="$(exakit_mcp_discover_status)"; then
            while read -r _st_id _st_state; do
                [ -n "$_st_id" ] || continue
                case "$_st_id" in
                    claude_desktop)  _cd_state="$_st_state" ;;
                    claude_code)     _cc_state="$_st_state" ;;
                    codex)           _codex_state="$_st_state" ;;
                    cursor)          _cursor_state="$_st_state" ;;
                    vscode_copilot)  _copilot_state="$_st_state" ;;
                    gemini_cli)      _gemini_state="$_st_state" ;;
                    opencode)        _opencode_state="$_st_state" ;;
                    continue)        _continue_state="$_st_state" ;;
                esac
            done <<EOF
$_client_status
EOF
        fi
        _menu_labels=()
        _menu_ids=()
        _menu_notes=()
        _pending_count=0
        # _exakit_mcp_menu_row <label> <state> <ids_csv> — one client row:
        # pending rows carry their ids and are selectable; connected and missing
        # rows carry no id and a note saying why, which is what makes them a
        # disabled row in the table.
        _exakit_mcp_menu_row() {
            _menu_labels+=("$1")
            case "$2" in
                pending)
                    _menu_ids+=("$3"); _menu_notes+=("")
                    _pending_count=$((_pending_count + 1))
                    ;;
                connected) _menu_ids+=(""); _menu_notes+=("already connected") ;;
                *)         _menu_ids+=(""); _menu_notes+=("not installed") ;;
            esac
        }
        if [ "$_cd_state" = "$_cc_state" ]; then
            _exakit_mcp_menu_row "Claude" "$_cd_state" "claude_desktop,claude_code"
        else
            _exakit_mcp_menu_row "Claude (desktop app)" "$_cd_state" "claude_desktop"
            _exakit_mcp_menu_row "Claude Code (CLI)" "$_cc_state" "claude_code"
        fi
        _exakit_mcp_menu_row "Codex" "$_codex_state" "codex"
        _exakit_mcp_menu_row "Cursor" "$_cursor_state" "cursor"
        _exakit_mcp_menu_row "GitHub Copilot" "$_copilot_state" "vscode_copilot"
        _exakit_mcp_menu_row "Gemini CLI" "$_gemini_state" "gemini_cli"
        _exakit_mcp_menu_row "OpenCode" "$_opencode_state" "opencode"
        _exakit_mcp_menu_row "Continue" "$_continue_state" "continue"
        if [ "$_pending_count" -eq 0 ]; then
            ok "All AI clients found on this machine are already connected over MCP."
            info "Check them with 'exakit mcp-status'; new clients appear here once installed."
            return 0
        fi
        # The read-only database user is prepared BEFORE the table is drawn.
        # Everything it does narrates itself, and from the moment the table is on
        # screen a line printed under it shifts the frame out from under the
        # cursor arithmetic that redraws it: the animator's first frame would
        # then repaint over its own table instead of the menu's, and the top of a
        # stale table is left stranded above it (the failure ui.sh's comments
        # describe). It is the kit's own database user, not any client's, so
        # preparing it before the choice costs a skipped run nothing but an idle
        # user — and it is what the next 'exakit mcp-setup' needs anyway.
        exakit_configure_mcp_readonly_access || return 1
        EXAKIT_MCP_READONLY_READY=1

        # ONE table for the whole step, the same component the dataset load uses
        # (ui_table_* in ui.sh): the rows a reader ticks are the rows that then
        # fill in, so nobody has to map one screen onto another.
        EXAKIT_MCP_TABLE_STATE="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-table.XXXXXX")" || {
            warn "Could not create a temporary file for the AI client table."
            _exakit_mcp_table_release
            return 1
        }
        _mcp_client_n="${#_menu_labels[@]}"
        _mcp_row_first=2
        _mcp_row_last=$(( _mcp_row_first + _mcp_client_n - 1 ))
        _mcp_row_skip=$(( _mcp_row_last + 1 ))
        printf 'group|Select All|0|idle|||||| \n' > "$EXAKIT_MCP_TABLE_STATE"
        _menu_i=0
        while [ "$_menu_i" -lt "$_mcp_client_n" ]; do
            if [ "$_menu_i" -eq $(( _mcp_client_n - 1 )) ]; then
                _mcp_kind=corner
            else
                _mcp_kind=tee
            fi
            printf '%s|%s|0|idle|||||| \n' "$_mcp_kind" "${_menu_labels[$_menu_i]}" \
                >> "$EXAKIT_MCP_TABLE_STATE"
            _menu_i=$(( _menu_i + 1 ))
        done
        printf 'plain|Skip|0|idle|||||| \n' >> "$EXAKIT_MCP_TABLE_STATE"
        # Pre-select every pending client, and the group row with them: under the
        # all-or-none parent it is ticked exactly while every pickable child is.
        # A client with no id is one this machine cannot offer — it becomes a
        # disabled row carrying the reason, so the list is the whole answer
        # rather than a list that quietly omits things.
        _defaults="1"
        _menu_i=0
        while [ "$_menu_i" -lt "$_mcp_client_n" ]; do
            _mcp_row=$(( _mcp_row_first + _menu_i ))
            if [ -n "${_menu_ids[$_menu_i]}" ]; then
                _defaults="$_defaults,$_mcp_row"
            else
                ui_table_disable "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" "${_menu_notes[$_menu_i]}"
            fi
            _menu_i=$(( _menu_i + 1 ))
        done
        EXAKIT_TABLE_GROUP="1:$_mcp_row_first:$_mcp_row_last:all"
        EXAKIT_TABLE_EXCLUSIVE="$_mcp_row_skip"
        EXAKIT_TABLE_DEFAULTS="$_defaults"
        UI_TABLE_TITLE="AI clients to connect"
        UI_TABLE_COL1="Client"
        printf '\n'
        # Loop so a not-confirmed skip returns the user to the menu.
        while :; do
            ui_table_menu "$EXAKIT_MCP_TABLE_STATE"
            case ",$EXAKIT_TABLE_SELECTION," in
                *",$_mcp_row_skip,"*)
                    warn "No AI client will be connected to your database."
                    if confirm "Are you sure you want to continue without an AI client?" y; then
                        info "Okay — you can connect one any time with: exakit mcp-setup"
                        exakit_print_no_ai_panel
                        _exakit_mcp_table_release
                        return 0
                    fi
                    # Back into the SAME table, not a second one under it: the
                    # frame is still on screen with the warning and the question
                    # below it (one line each), so the menu is told how far up
                    # its own top border is.
                    UI_TABLE_MENU_ONSCREEN=$(( UI_TABLE_LINES + 2 ))
                    continue                              # back to the menu
                    ;;
            esac
            break
        done
        _clients_csv=""
        for _client_idx in $(printf '%s' "$EXAKIT_TABLE_SELECTION" | tr ',' ' '); do
            [ "$_client_idx" -ge "$_mcp_row_first" ] && [ "$_client_idx" -le "$_mcp_row_last" ] || continue
            _client_id="${_menu_ids[$(( _client_idx - _mcp_row_first ))]}"
            [ -n "$_client_id" ] || continue              # disabled rows carry no id
            _clients_csv="${_clients_csv:+$_clients_csv,}$_client_id"
            _mcp_rows="${_mcp_rows:+$_mcp_rows,}$_client_idx"
        done
        if [ -z "$_clients_csv" ]; then
            # Enter needs a selection and the group row can never be the only
            # one ticked, so this is the impossible answer rather than a real
            # one. Still: never call the setup CLI with an empty client list.
            info "No AI client selected — connect one any time with: exakit mcp-setup"
            _exakit_mcp_table_release
            return 0
        fi
    fi

    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-setup.XXXXXX")"
    _setup_status=0
    _mcp_table_shown=0
    if [ -n "$EXAKIT_MCP_TABLE_STATE" ] && [ -n "$_mcp_rows" ]; then
        for _mcp_row in $(printf '%s' "$_mcp_rows" | tr ',' ' '); do
            ui_table_set "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" waiting
        done
        if ui_table_begin "$EXAKIT_MCP_TABLE_STATE"; then
            _mcp_table_shown=1
            # The bar sits on the GROUP row, not on a client row: ONE python
            # process configures every selected client, so there is no
            # per-client checkpoint a per-client bar could be honest about. The
            # client rows wait, and each one's final cell is read out of the
            # result file afterwards — nothing on screen calls a client done
            # before the run says it is.
            ui_table_set "$EXAKIT_MCP_TABLE_STATE" 1 running 5 90 20 "writing client configs"
        fi
    fi
    # No live table to say what is happening: say it in a line, as before. With
    # the table there is nothing to add — and a line printed here would land
    # between the menu's frame and the animator's first frame, which is the one
    # place on this screen where nothing may be printed.
    [ "$_mcp_table_shown" = 1 ] || info "Applying MCP setup"
    if exakit_run_mcp_setup_cli "$_clients_csv" "$_result_file"; then
        :
    else
        _setup_status=$?
    fi
    if [ "$_mcp_table_shown" = 1 ]; then
        # What each row ends up saying comes from the result file, client by
        # client: one client can be skipped on its own (an unparseable config
        # file of its own) while every other client is configured, and the exit
        # status cannot tell those two apart.
        _mcp_states="$(_exakit_mcp_result_states "$_result_file" 2>/dev/null || true)"
        _mcp_ok_n=0
        _mcp_sel_n=0
        for _mcp_row in $(printf '%s' "$_mcp_rows" | tr ',' ' '); do
            _mcp_sel_n=$(( _mcp_sel_n + 1 ))
            _mcp_id_n=0
            _mcp_id_ok=0
            for _mcp_id in $(printf '%s' "${_menu_ids[$(( _mcp_row - _mcp_row_first ))]}" | tr ',' ' '); do
                _mcp_id_n=$(( _mcp_id_n + 1 ))
                # grep, not a case pattern: bash 3.2 mis-parses case patterns
                # written inside $( ).
                if printf '%s\n' "$_mcp_states" | grep -qxF "$_mcp_id configured"; then
                    _mcp_id_ok=$(( _mcp_id_ok + 1 ))
                fi
            done
            if [ "$_mcp_id_ok" -eq 0 ]; then
                ui_table_set "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" failed "" "" "" "" \
                    "not configured"
            elif [ "$_mcp_id_ok" -eq "$_mcp_id_n" ]; then
                ui_table_set "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" done "" "" "" "" \
                    "configured"
                _mcp_ok_n=$(( _mcp_ok_n + 1 ))
            else
                # The Claude row is two surfaces behind one label; say which
                # rather than call a half-written row configured.
                ui_table_set "$EXAKIT_MCP_TABLE_STATE" "$_mcp_row" done "" "" "" "" \
                    "configured · $_mcp_id_ok of $_mcp_id_n"
                _mcp_ok_n=$(( _mcp_ok_n + 1 ))
            fi
        done
        if [ "$_mcp_sel_n" = 1 ]; then _mcp_unit=client; else _mcp_unit=clients; fi
        if [ "$_mcp_ok_n" -eq "$_mcp_sel_n" ]; then
            ui_table_set "$EXAKIT_MCP_TABLE_STATE" 1 done "" "" "" "" \
                "configured · $_mcp_sel_n $_mcp_unit"
        else
            ui_table_set "$EXAKIT_MCP_TABLE_STATE" 1 failed "" "" "" "" \
                "$_mcp_ok_n of $_mcp_sel_n $_mcp_unit configured"
        fi
        # Normally still animating. A failed CLI stops the animation itself
        # before it warns, so that its warning is not painted into the frame —
        # and then the frame on screen is already the last one.
        if [ -n "${_UI_TABLE_ACTIVE:-}" ]; then
            ui_table_end "$EXAKIT_MCP_TABLE_STATE"
        fi
    fi
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_setup_summary "$_result_file" "$_mcp_table_shown"
    fi
    rm -f "$_result_file"
    _exakit_mcp_table_release
    if [ "$_setup_status" -ne 0 ]; then
        return "$_setup_status"
    fi
    exakit_print_mcp_ready_panel "permanent"
    # The panel above IS the guidance; announcing that it exists, directly
    # under it, told the reader nothing they had not just read.
    return 0
}

exakit_mcp_operation() {
    _operation="$1"
    shift
    _clients_csv="$(exakit_mcp_clients_from_args "$@")" || {
        warn "Please choose valid MCP clients: claude_desktop, cursor, codex, or all."
        return 1
    }
    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-operation.XXXXXX")"
    _operation_status=0
    # _exakit_stamp_mcp_json <file> — print the MCP result with `installed` and
    # `remedy` added. Fails (prints nothing) when the file is not a JSON object,
    # so the caller can fall back to passing it through untouched.
    _exakit_stamp_mcp_json() {
        exakit_can_run_python || return 1
        run_python - "$1" <<'EXAKIT_MCP_STAMP_PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
doc.setdefault("installed", True)
if "remedy" not in doc:
    actions = doc.get("next_actions")
    remedy = None
    if isinstance(actions, list):
        for action in actions:
            if isinstance(action, dict) and action.get("message"):
                remedy = action["message"]
                break
    doc["remedy"] = remedy
print(json.dumps(doc, indent=2, sort_keys=True))
EXAKIT_MCP_STAMP_PY
    }
    # JSON mode (EXAKIT_MCP_RESULT_JSON=1): the operation's own result file is
    # already the machine-readable truth the summary is rendered from — print
    # it verbatim and keep every human line off stdout.
    if [ "${EXAKIT_MCP_RESULT_JSON:-0}" = "1" ]; then
        if ( exakit_run_mcp_operation_cli "$_operation" "$_clients_csv" "$_result_file" ) >/dev/null 2>&1; then
            :
        else
            _operation_status=$?
        fi
        if [ -s "$_result_file" ]; then
            # Add the discriminators every --json answer from a state query
            # carries — `installed` and `remedy` — so one parser handles the
            # healthy report, the database-down answer and the not-installed
            # answer alike. The subsystem's own fields are never touched, and a
            # result that is not valid JSON is passed through byte for byte
            # rather than swallowed.
            _exakit_stamp_mcp_json "$_result_file" || cat "$_result_file"
        else
            printf '{"installed": true, "status": "error", "remedy": "exakit logs setup", "error": "the MCP %s operation produced no result (see log)"}\n' "$_operation"
            [ "$_operation_status" -eq 0 ] && _operation_status=1
        fi
        rm -f "$_result_file"
        case "$_operation" in
            doctor|validate) _exakit_reassert_mcp_readonly_posture >/dev/null 2>&1 || _operation_status=1 ;;
        esac
        return "$_operation_status"
    fi
    info "Running MCP $_operation"
    if exakit_run_mcp_operation_cli "$_operation" "$_clients_csv" "$_result_file"; then
        :
    else
        _operation_status=$?
    fi
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_operation_summary "$_result_file"
    fi
    rm -f "$_result_file"

    case "$_operation" in
        doctor|validate)
            _exakit_reassert_mcp_readonly_posture || _operation_status=1
            ;;
    esac

    # A diagnosis is only useful next to its remedy. Doctor is the command people
    # run when something looks wrong with an AI client, and the answer is almost
    # always the same one — so name it rather than making them go and find it.
    case "$_operation" in
        doctor) info "Connect or re-connect AI clients any time with:  exakit mcp-setup" ;;
    esac

    return "$_operation_status"
}

exakit_mcp_restore() {
    _snapshot_id="${1:-}"
    _result_file="$(mktemp "${TMPDIR:-/tmp}/exakit-mcp-restore.XXXXXX")"
    _operation_status=0
    info "Running MCP restore"
    if exakit_run_mcp_operation_cli "restore" "claude_desktop,claude_code,cursor,codex,vscode_copilot,gemini_cli,opencode,continue" "$_result_file" "$_snapshot_id"; then
        :
    else
        _operation_status=$?
    fi
    if [ -s "$_result_file" ]; then
        exakit_print_mcp_operation_summary "$_result_file"
    fi
    rm -f "$_result_file"
    return "$_operation_status"
}

exakit_maybe_offer_mcp_setup() {
    _already_done="$(manifest_get components.mcp_server.client_setup.completed 2>/dev/null || true)"
    [ "$_already_done" = "true" ] && return 0
    if [ "${EXAKIT_SKIP_MCP:-}" = "1" ]; then
        info "Skipping MCP client setup (EXAKIT_SKIP_MCP=1). Run it any time with: exakit mcp-setup"
        return 0
    fi
    # Connecting an AI client is the point of the kit, so this step always
    # runs (EXAKIT_SKIP_MCP=1 above is the scripted escape hatch). The client
    # selection pre-selects every detected-but-unconnected client;
    # non-interactive runs keep that default.
    # No lead-in: the ticks directly above already said the runtime and the
    # server are ready, and this restated them in a sentence.
    if ! exakit_mcp_setup; then
        warn "Your local runtime is installed, but MCP client setup did not finish cleanly."
        warn "Retry any time with: exakit mcp-setup"
        exakit_note_failure "the AI client configuration did not finish (see the log)"
        return 1
    fi
}

# exakit_maybe_offer_data_load <kit_root> — load data during install, via the
# dynamic dataset checkbox (bundled datasets not loaded yet are pre-selected;
# the user can additionally or instead pick a local file, or explicitly skip).
# Scripted installs can still steer with EXAKIT_DATASETS (csv of bundled
# dataset ids) or EXAKIT_LOAD_SAMPLE (=0 skips, =1 bundled sample);
# EXAKIT_DATASETS takes precedence. Non-interactive runs keep the
# pre-selected defaults. Each load runs in a subshell so a die() inside the
# loading flow never aborts the surrounding install.
exakit_maybe_offer_data_load() {
    _kit_root="$1"
    : "$_kit_root"
    command -v exakit_load_sample_data >/dev/null 2>&1 || return 0

    # EXAKIT_DATASETS names bundled datasets directly (csv of ids from
    # data/datasets/<id>/, e.g. "tpch,weather") so an agent-driven or scripted
    # install can pick an exact selection. Unknown ids warn and are skipped;
    # if none are valid the install stops — the caller asked for something
    # this kit does not ship.
    # Every path below reports through _data_failed, so the caller can book the
    # step in the closing summary. Nothing here ends the run any more: an empty
    # database is a thing to repair with one command, not a reason to abandon an
    # install whose database is already up.
    _data_failed=0
    if [ -n "${EXAKIT_DATASETS:-}" ]; then
        _known_ids=" $(exakit_bundled_datasets | cut -d'|' -f1 | tr '\n' ' ') "
        _valid_any=0
        for _env_id in $(printf '%s' "$EXAKIT_DATASETS" | tr ',' ' '); do
            case "$_known_ids" in
                *" $_env_id "*)
                    _valid_any=1
                    info "Loading dataset '$_env_id' (EXAKIT_DATASETS)."
                    if ! ( exakit_load_dataset "$_kit_root" "$_env_id" ); then
                        warn "Data loading did not finish cleanly. Retry any time with: exakit data-load"
                        exakit_note_failure "loading dataset '$_env_id' did not finish (see the log)"
                        _data_failed=1
                    fi
                    ;;
                *)
                    warn "Unknown dataset id '$_env_id' in EXAKIT_DATASETS (available:$(printf '%s' "$_known_ids" | sed 's/ *$//'))."
                    ;;
            esac
        done
        if [ "$_valid_any" -ne 1 ]; then
            error "EXAKIT_DATASETS='$EXAKIT_DATASETS' matched no bundled dataset — nothing was loaded."
            exakit_note_failure "EXAKIT_DATASETS='$EXAKIT_DATASETS' matched no bundled dataset"
            return 1
        fi
        return "$_data_failed"
    fi

    # EXAKIT_LOAD_SAMPLE lets an agent-driven or scripted install decide up front:
    # =1 loads the bundled sample without asking, =0 skips data loading entirely.
    if [ "${EXAKIT_LOAD_SAMPLE:-}" = "0" ]; then
        info "Skipping data loading (EXAKIT_LOAD_SAMPLE=0). Run it any time with: exakit data-load"
        return 0
    fi
    if [ "${EXAKIT_LOAD_SAMPLE:-}" = "1" ]; then
        info "Loading the bundled sample data (EXAKIT_LOAD_SAMPLE=1)."
        if ! ( exakit_load_sample_data "$_kit_root" ); then
            warn "Data loading did not finish cleanly. Retry any time with: exakit data-load"
            exakit_note_failure "the bundled sample data did not finish loading (see the log)"
            return 1
        fi
        return 0
    fi

    # No lead-in sentence: the checkbox below names every dataset on offer and
    # the skip, which is the whole of what this line was explaining.
    # Dynamic dataset checkbox (shared with `exakit data-load`): only bundled
    # datasets that are not loaded yet are offered, plus the local-file option
    # and an explicit skip. Each load runs in a subshell so a die() inside the
    # loading flow never aborts the surrounding install.
    exakit_data_load_select "Skip"
    if [ "$EXAKIT_DATA_LOAD_SELECTION" = "none" ]; then
        info "Skipping data loading. Run it any time with: exakit data-load"
        return 0
    fi
    # The SAME table the selection was just made in becomes the progress display.
    # This is the path an install actually takes, and it was the one left out:
    # exakit_data_load_menu (the standalone `exakit data-load`) started the table
    # and this loop did not, so during an install the table drew, stayed empty,
    # and every dataset fell back to the single-line bar underneath it.
    #
    # The loads below run in subshells, which is exactly why a row's state lives
    # in a FILE: a subshell can write to it, and could never write to a variable
    # the animator would see.
    EXAKIT_TABLE_LIVE=0
    if [ -n "${EXAKIT_TABLE_STATE:-}" ]; then
        ui_table_begin "$EXAKIT_TABLE_STATE" && EXAKIT_TABLE_LIVE=1
    fi
    _data_notes=""
    # Anything fatal inside the loads below is written here instead of onto the
    # animating table; it is read out after ui_table_end.
    EXAKIT_DEFER_ERRORS=""
    if [ "$EXAKIT_TABLE_LIVE" = 1 ]; then
        EXAKIT_DEFER_ERRORS="$EXAKIT_TABLE_STATE.fatal"
        : > "$EXAKIT_DEFER_ERRORS"
    fi
    for _data_id in $(printf '%s' "$EXAKIT_DATA_LOAD_SELECTION" | tr ',' ' '); do
        case "$_data_id" in
            local)
                ( ui_table_detach; exakit_load_local_file )
                _local_status=$?
                if [ "$_local_status" -eq 2 ]; then
                    _data_notes="${_data_notes}info|Local file load skipped.
"
                elif [ "$_local_status" -ne 0 ]; then
                    _data_notes="${_data_notes}warn|Data loading did not finish cleanly. Retry any time with: exakit data-load
"
                    exakit_note_failure "loading the local file did not finish (see the log)"
                    _data_failed=1
                fi
                ;;
            *)
                if ! ( ui_table_detach; exakit_load_dataset "$_kit_root" "$_data_id" ); then
                    _data_notes="${_data_notes}warn|Data loading did not finish cleanly. Retry any time with: exakit data-load
"
                    exakit_note_failure "loading dataset '$_data_id' did not finish (see the log)"
                    _data_failed=1
                fi
                ;;
        esac
    done
    # The table stops redrawing BEFORE anything is said over it. A warn printed
    # into a frame that is still being repainted lands inside the box.
    [ "$EXAKIT_TABLE_LIVE" = 1 ] && ui_table_end "$EXAKIT_TABLE_STATE"
    EXAKIT_TABLE_LIVE=0
    if [ -n "$EXAKIT_DEFER_ERRORS" ] && [ -s "$EXAKIT_DEFER_ERRORS" ]; then
        while IFS='|' read -r _df_kind _df_text; do
            [ -n "$_df_text" ] || continue
            error "$_df_text"
        done < "$EXAKIT_DEFER_ERRORS"
        rm -f "$EXAKIT_DEFER_ERRORS"
    fi
    EXAKIT_DEFER_ERRORS=""
    while IFS='|' read -r _dn_kind _dn_text; do
        [ -n "$_dn_text" ] || continue
        case "$_dn_kind" in
            warn) warn "$_dn_text" ;;
            *)    info "$_dn_text" ;;
        esac
    done <<EXAKIT_DATA_NOTES_EOF
$_data_notes
EXAKIT_DATA_NOTES_EOF
    return "$_data_failed"
}

# kit_shared_steps <first-step-no> <total-steps> <script-dir> <kit-root>
# The steps every platform runs after its runtime is up, in order: exapump,
# the sample-data load offer, the MCP server, the exakit helper, and the MCP
# client setup offer. Data is loaded before MCP so the read-only user is
# provisioned against a populated schema. One implementation so the per-OS
# setup scripts cannot drift apart.
# exakit_soft_step <component> <repair-command> <function...> — run one
# component's install without letting it end the run.
#
# The component installers die() on failure, and die() exits. exapump alone has 32
# of them, and it runs three steps before the `exakit` command is installed: a
# broken download left the user with a deployed database, no CLI, and no way to
# repair it except re-running the whole installer. So each component runs in a
# subshell, and a failure is recorded and stepped over instead of ending the run.
#
# Nothing is lost to the subshell: these functions keep their state in the manifest
# and on disk, not in shell variables, and no component reads a global set by
# another one.
exakit_soft_step() {
    _ss_component="$1"
    _ss_repair="$2"
    shift 2
    # Start from a clean slate so a reason left by an earlier step cannot be
    # attributed to this one.
    exakit_clear_failure_note
    if ( "$@" ); then
        exakit_clear_failure_note
        return 0
    fi
    exakit_record_soft_failure "$_ss_component" "$_ss_repair" "$(exakit_take_failure_note)"
    warn "$_ss_component did not finish — carrying on so the rest of the install completes"
    return 1
}

# exakit_record_soft_failure <component> <repair> [reason] [label] — book a
# step as "did not complete" without any of the running/subshell machinery.
#
# The soft-step wrapper is for component installers that die(); this is for the
# steps that report failure by returning non-zero or by being wrapped in `|| true`
# (the data load, the AI client wiring, the skills copy). Before this they failed
# silently as far as the closing summary was concerned, so a user whose sample data
# never loaded saw a clean "Setup complete" and no way to know.
exakit_record_soft_failure() {
    _rsf_component="$1"
    _rsf_repair="$2"
    _rsf_reason="${3:-}"
    _rsf_label="${4:-}"
    # First failure wins: a later, vaguer report must not overwrite the specific
    # reason the original failure recorded.
    exakit_soft_failed "$_rsf_component" && return 0
    EXAKIT_SOFT_FAILED="${EXAKIT_SOFT_FAILED:-}${EXAKIT_SOFT_FAILED:+ }$_rsf_component"
    # The repair command and the reason travel with the failure, so the summary
    # never has to guess either back.
    eval "EXAKIT_SOFT_REPAIR_${_rsf_component}=\"\$_rsf_repair\""
    eval "EXAKIT_SOFT_REASON_${_rsf_component}=\"\$_rsf_reason\""
    eval "EXAKIT_SOFT_LABEL_${_rsf_component}=\"\$_rsf_label\""
    return 0
}

# exakit_soft_failed <component> — did this component fail earlier in the run?
exakit_soft_failed() {
    case " ${EXAKIT_SOFT_FAILED:-} " in
        *" $1 "*) return 0 ;;
        *)        return 1 ;;
    esac
}

# exakit_print_soft_failures — the closing account of what did not make it.
#
# Said plainly, with what went wrong and the exact command that fixes it: the
# install is usable, some of it is missing, and here is the one line per piece
# that repairs it. Printed last, after the connection panel, so it is the final
# thing on screen rather than something scrolled past mid-install.
exakit_print_soft_failures() {
    [ -n "${EXAKIT_SOFT_FAILED:-}" ] || return 0
    _sf_count=0
    for _sf in $EXAKIT_SOFT_FAILED; do
        _sf_count=$((_sf_count + 1))
    done
    printf '\n'
    if [ "$_sf_count" = "1" ]; then
        warn "The install finished, but one step did not complete:"
    else
        warn "The install finished, but $_sf_count steps did not complete:"
    fi
    printf '\n'
    for _sf in $EXAKIT_SOFT_FAILED; do
        eval "_sf_repair=\"\${EXAKIT_SOFT_REPAIR_${_sf}:-}\""
        eval "_sf_reason=\"\${EXAKIT_SOFT_REASON_${_sf}:-}\""
        eval "_sf_label=\"\${EXAKIT_SOFT_LABEL_${_sf}:-}\""
        [ -n "$_sf_label" ] || _sf_label="$_sf"
        printf '      %s%s%s is not installed: %s\n' \
            "${UI_BOLD:-}" "$_sf_label" "${UI_RESET:-}" \
            "${_sf_reason:-the step did not finish (see the log)}"
        printf '        reinstall it with:  %s%s%s\n' \
            "${UI_ACCENT:-}" "${_sf_repair:-see the log}" "${UI_RESET:-}"
    done
    printf '\n'
    info "Everything else is ready — the database, and the exakit command itself."
    if [ -n "${EXAKIT_LOG_FILE:-}" ]; then
        info "Full detail for each failure: $EXAKIT_LOG_FILE"
    fi
    info "See where you stand any time with: exakit status"
    return 0
}

# The component chains, named so exakit_soft_step has something to isolate.
# Three lines for this step, not nine. run_logged animates the label
# begin_step set, so the info bullets under it were the second telling, and the
# checksum tick named a mktemp temp file rather than the asset (exapump
# downloads to a bare mktemp path, so basename saw "exakit-exapump.ANyKf0").
# What survives goes through ok_step: what was installed and where, the profile
# name someone types again, and the one fact the next two steps depend on --
# that the database can persist a schema, not merely answer SELECT 1.
_exakit_install_exapump() {
    _eie_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    exapump_install || { EXAKIT_QUIET_DETAIL="$_eie_prev_quiet"; return 1; }
    exapump_create_profile || { EXAKIT_QUIET_DETAIL="$_eie_prev_quiet"; return 1; }
    exapump_validate_connection
    _eie_rc=$?
    EXAKIT_QUIET_DETAIL="$_eie_prev_quiet"
    return $_eie_rc
}

# One line for this step's server work: the spinner narrates the prime and the
# handshake, so the info/ok pairs beneath were the second telling.
_exakit_install_mcp() {
    _eim_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    if ! mcp_install; then
        EXAKIT_QUIET_DETAIL="$_eim_prev_quiet"
        return 1
    fi
    mcp_validate
    _eim_rc=$?
    EXAKIT_QUIET_DETAIL="$_eim_prev_quiet"
    return $_eim_rc
}

# pyexasol_validate used to run OUTSIDE the soft step, which defeated the whole
# point of the step being soft: the driver could install fine and a die() from
# anywhere inside validation (a manifest write on a full disk, say) still ended
# the run before the exakit helper was installed. Install and validate belong to
# the same isolated unit.
# Two lines for this step, not five: the outcome, and the interpreter to run it
# with. Everything between -- the venv creation, the pip resolve, the SELECT 1
# narration -- is in the logfile, and the spinner covered it live.
_exakit_install_pyexasol() {
    _eip_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    if ! pyexasol_install; then
        EXAKIT_QUIET_DETAIL="$_eip_prev_quiet"
        return 1
    fi
    pyexasol_validate || true
    EXAKIT_QUIET_DETAIL="$_eip_prev_quiet"
}

# --- What's new -------------------------------------------------------------
#
# ONE source: setup/whats-new.json, a version -> array-of-lines map. The card the
# installer draws after an upgrade and the text `exakit whats-new` prints are the
# same lines, so there is nothing to keep in step.
#
# This block used to parse WHATS-NEW.md with awk, deliberately, so that a missing
# interpreter could not turn a successful upgrade into a failure. JSON needs a
# real parser, so that property is gone: on a machine without python3 the cards
# simply do not appear. That is survivable where the old design's concern was
# not — the box is best-effort already, and manifest_get requires python3 for
# every other thing the kit does, so a box that cannot run it has no working kit
# to upgrade in the first place. Every function here stays quiet on failure.
EXAKIT_WHATS_NEW_POINT_WIDTH=68
EXAKIT_WHATS_NEW_POINTS_PER_VERSION=6

# exakit_whats_new_file <kit-root> — the card source, or non-zero when this kit
# copy does not carry one (an older kit, or a partial download).
exakit_whats_new_file() {
    _wnf_root="${1:-}"
    [ -n "$_wnf_root" ] || return 1
    [ -f "$_wnf_root/setup/whats-new.json" ] || return 1
    printf '%s\n' "$_wnf_root/setup/whats-new.json"
}

# _exakit_whats_new_py <file> <mode> [from] [to] — the one parser.
#   mode "versions": every version in (from, to], oldest first
#   mode "points":   the lines of the single version passed as <from>
# Keys starting with "_" are comments in the file and are never versions.
_exakit_whats_new_py() {
    exakit_can_run_python 2>/dev/null || return 1
    run_python - "$1" "$2" "${3:-}" "${4:-}" "$EXAKIT_WHATS_NEW_POINT_WIDTH" \
        "$EXAKIT_WHATS_NEW_POINTS_PER_VERSION" <<'PY' 2>/dev/null
import json, sys
path, mode, a, b, width, maxpoints = sys.argv[1:7]
width, maxpoints = int(width), int(maxpoints)
try:
    with open(path) as f:
        doc = json.load(f)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)

def key(v):
    # Dotted numbers only, so a jump sorts the way a human reads it. Anything
    # else is skipped rather than guessed at.
    return tuple(int(p) for p in v.split("."))

versions = []
for k in doc:
    if k.startswith("_") or not isinstance(doc[k], list):
        continue
    try:
        versions.append((key(k), k))
    except ValueError:
        continue
versions.sort()

if mode == "versions":
    lo = key(a) if a else None
    hi = key(b) if b else None
    for kk, name in versions:
        if lo is not None and kk <= lo:
            continue
        if hi is not None and kk > hi:
            continue
        print(name)
    sys.exit(0)

if mode == "points":
    for line in doc.get(a, [])[:maxpoints]:
        if not isinstance(line, str):
            continue
        line = " ".join(line.split())
        if not line:
            continue
        # Authoring is guarded by tests/whats-new.sh; this is the last resort so
        # an over-long line cannot break the box's borders.
        if len(line) > width:
            line = line[: width - 3].rstrip() + "..."
        print("  - " + line)
    sys.exit(0)
sys.exit(1)
PY
}

# exakit_whats_new_versions <kit-root> <from> <to> — the versions with cards that
# lie in (from, to], oldest first. A `to` older than `from` (a downgrade) selects
# nothing, which is what keeps the box off the screen.
exakit_whats_new_versions() {
    _wnv_file="$(exakit_whats_new_file "$1")" || return 1
    _exakit_whats_new_py "$_wnv_file" versions "${2:-}" "${3:-}"
}

# exakit_whats_new_points <kit-root> <version> — one line per highlight, as
# "  - text". Non-zero when that version has no card.
exakit_whats_new_points() {
    _wnp_file="$(exakit_whats_new_file "$1")" || return 1
    _wnp_out="$(_exakit_whats_new_py "$_wnp_file" points "${2:-}")" || return 1
    [ -n "$_wnp_out" ] || return 1
    printf '%s\n' "$_wnp_out"
}

# exakit_print_whats_new <version> [heading] — what `exakit whats-new` shows.
exakit_print_whats_new() {
    _pwn_version="$1"
    _pwn_heading="${2:-}"
    _pwn_root="$(exakit_repo_root 2>/dev/null || true)"
    [ -n "$_pwn_root" ] || return 1
    _pwn_body="$(exakit_whats_new_points "$_pwn_root" "$_pwn_version")" || return 1
    # The same card the installer draws. `exakit whats-new` is the command the
    # card itself points at ("Full notes: exakit whats-new 0.2.0"), so printing
    # loose lines there made the follow-up look like a lesser version of the
    # thing that sent you.
    printf '\n'
    # Built in two steps, not "${_pwn_heading:-What's new in ...}": inside a
    # ${:-} default bash treats the apostrophe as an opening quote, so the
    # string ran on to the next apostrophe ANYWHERE in the file and swallowed
    # 300 lines of function bodies with it. `bash -n` accepts that happily -
    # it is valid syntax, just not the program anyone wrote.
    _pwn_title="$_pwn_heading"
    [ -n "$_pwn_title" ] || _pwn_title="What's new in $_pwn_version"
    ui_panel_begin "$_pwn_title"
    # Fed by a here-document, not a pipe: ui_panel_line buffers into a variable,
    # and a pipeline would build that buffer in a subshell.
    while IFS= read -r _pwn_line; do
        [ -n "$_pwn_line" ] || continue
        ui_panel_line "$_pwn_line"
    done <<PWN_BODY
$_pwn_body
PWN_BODY
    ui_panel_end
    printf '\n'
    return 0
}


# exakit_note_kit_upgrade <kit-root> — record the kit version installed BEFORE
# this run, for the box at the end to read. Call it while the manifest still holds
# the previous run's number.
#
# The record is in the manifest, not an environment variable, because a run that
# dies partway has already overwritten kit.version: the next re-run would compare
# the new number against itself, decide nothing moved, and lose the notes for a
# hop nobody ever saw. A pending record therefore wins over anything this run
# computes, and only the box clears it.
exakit_note_kit_upgrade() {
    _nku_pending="$(manifest_get kit.whats_new_from 2>/dev/null || true)"
    [ -z "$_nku_pending" ] || return 0
    _nku_now="$(exakit_kit_version_at "${1:-}" 2>/dev/null || true)"
    [ -n "$_nku_now" ] || return 0
    _nku_was="$(manifest_get kit.version 2>/dev/null || true)"

    # kit.version did not exist before 0.2.0, so an install made by an older kit
    # records no version at all. Treating "no version" as "no previous install"
    # silenced the cards for the ONLY upgrade anyone can currently make: every
    # existing user is on a kit that predates the field, so the feature stayed
    # quiet for exactly the people it exists for.
    #
    # A prior install still leaves proof - it was installed at a time, and it
    # completed steps - so an unversioned manifest with either is an upgrade
    # from something older than we can name, not a first install.
    if [ -z "$_nku_was" ]; then
        # Proof of a PRIOR install, and manifest_init is why this has to be
        # careful: a brand-new manifest already carries installed_at and
        # "steps_completed": [], so either of those alone marks a first-ever
        # install as an upgrade and shows cards to someone who has just met the
        # kit. A COMPLETED step is the thing only a previous run can leave.
        _nku_steps="$(manifest_get steps_completed 2>/dev/null || true)"
        case "$_nku_steps" in
            ''|'[]') _nku_prior=0 ;;
            *)       _nku_prior=1 ;;
        esac
        if [ "$_nku_prior" = 1 ]; then
            # The sentinel is not a version: it means "no lower bound", so every
            # card up to the new version is shown, and the box words itself
            # without claiming a number the manifest never held.
            _nku_was="__unversioned__"
        else
            # A genuine first-ever install: nothing to announce.
            return 0
        fi
    fi

    if [ "$_nku_was" != "__unversioned__" ]; then
        [ "$_nku_was" != "$_nku_now" ] || return 0
        # Only forward. A downgrade has no notes to read out anyway, and recording
        # one would leave a pending marker no later run could resolve.
        exakit_version_newer "$_nku_now" "$_nku_was" || return 0
    fi
    ( manifest_set kit.whats_new_from "$_nku_was" ) >/dev/null 2>&1 || true
    return 0
}

# exakit_print_whats_new_box [kit-root] — the box itself, after the connection
# panel. Prints only when the kit version moved during this run.
#
# No record means nothing is printed, which is the whole reason a first install
# and an idempotent re-run stay silent: the installer is documented as safe to
# re-run, and a box on every no-op run teaches people to ignore it.
exakit_print_whats_new_box() {
    _pwb_root="${1:-}"
    [ -n "$_pwb_root" ] || _pwb_root="$(exakit_repo_root 2>/dev/null || true)"
    _pwb_from="$(manifest_get kit.whats_new_from 2>/dev/null || true)"
    [ -n "$_pwb_from" ] || return 0
    _pwb_to="$(exakit_kit_version_at "$_pwb_root" 2>/dev/null || true)"
    [ -n "$_pwb_to" ] || _pwb_to="$(manifest_get kit.version 2>/dev/null || true)"

    # The sentinel from an unversioned predecessor: no lower bound, so every card
    # up to this version is shown.
    _pwb_lower="$_pwb_from"
    [ "$_pwb_lower" = "__unversioned__" ] && _pwb_lower=""
    _pwb_versions=""
    if [ -n "$_pwb_root" ] && [ -n "$_pwb_to" ]; then
        _pwb_versions="$(exakit_whats_new_versions "$_pwb_root" "$_pwb_lower" "$_pwb_to" 2>/dev/null || true)"
    fi
    if [ -n "$_pwb_versions" ]; then
        # ONE width for every card. ui_panel_end sizes a panel to its own longest
        # line, so a three-version jump drew three boxes of three widths and read
        # as a staircase rather than one announcement.
        _pwb_w=0
        _pwb_any=0
        _pwb_last=""
        for _pwb_v in $_pwb_versions; do
            _pwb_pts="$(exakit_whats_new_points "$_pwb_root" "$_pwb_v" 2>/dev/null || true)"
            # A version in range can still have nothing to say (an empty list).
            # It draws no card, so it must not make the run look announced.
            [ -n "$_pwb_pts" ] || continue
            _pwb_any=1
            _pwb_last="$_pwb_v"
            while IFS= read -r _pwb_l; do
                [ -n "$_pwb_l" ] || continue
                [ "${#_pwb_l}" -gt "$_pwb_w" ] && _pwb_w="${#_pwb_l}"
            done <<PWB_WIDTH
$_pwb_pts
PWB_WIDTH
        done
    fi
    if [ "${_pwb_any:-0}" = 1 ]; then
        # One lead-in above the cards. The titles say which versions arrived;
        # only this says where the reader started, and repeating it on every
        # card would be noise. Printed only once a card is certain: an empty
        # box is worse than no box, and so is a lead-in with nothing under it.
        if [ "$_pwb_from" = "__unversioned__" ]; then
            # The old kit recorded no version, so there is no number to name.
            printf '\n  %sYour kit is now %s.%s\n' \
                "${UI_BOLD:-}" "$_pwb_to" "${UI_RESET:-}"
        else
            printf '\n  %sYour kit moved from %s to %s.%s\n' \
                "${UI_BOLD:-}" "$_pwb_from" "$_pwb_to" "${UI_RESET:-}"
        fi

        for _pwb_v in $_pwb_versions; do
            _pwb_pts="$(exakit_whats_new_points "$_pwb_root" "$_pwb_v" 2>/dev/null || true)"
            [ -n "$_pwb_pts" ] || continue
            printf '\n'
            ui_panel_begin "What's new in $_pwb_v"
            # Fed by a here-document, not a pipe: ui_panel_line buffers into a
            # variable, and a pipeline would build that buffer in a subshell.
            while IFS= read -r _pwb_l; do
                [ -n "$_pwb_l" ] || continue
                ui_panel_line "$(printf '%-*s' "$_pwb_w" "$_pwb_l")"
            done <<PWB_BODY
$_pwb_pts
PWB_BODY
            ui_panel_end
        done
    fi
    # Announced, or found nothing worth announcing: either way this move is dealt
    # with, and the record goes so the next re-run does not repeat the cards.
    ( manifest_set kit.whats_new_from "" ) >/dev/null 2>&1 || true
    return 0
}

kit_shared_steps() {
    _step_no="$1"
    _total="$2"
    _script_dir="$3"
    _kit_root="$4"

    if command -v exapump_install >/dev/null 2>&1; then
        if begin_step exapump "Step ${_step_no}/${_total}  exapump (data loading CLI)"; then
            if exakit_soft_step exapump "exakit update exapump" \
                    _exakit_install_exapump; then
                mark_step exapump
            fi
        fi
    else
        info "Step ${_step_no}/${_total}  exapump — not part of this installation, skipping"
    fi
    _step_no=$((_step_no + 1))

    # Load the sample data before any MCP configuration. exapump is now up
    # (its only dependency), and doing this first means the read-only MCP
    # user is provisioned, granted, and posture-checked against a schema
    # that already holds the sample tables — and the AI client has data to
    # query the moment it connects.
    if exakit_soft_failed exapump; then
        info "Skipping the sample data — it is loaded with exapump, which is not installed"
    else
        # `|| true` alone hid a failed load completely: the run carried on (right)
        # and the closing summary said nothing (wrong). Record it so the user
        # leaves knowing the database is empty and which command fills it.
        exakit_clear_failure_note
        if ! exakit_maybe_offer_data_load "$_kit_root"; then
            exakit_record_soft_failure sample_data "exakit data-load" \
                "$(exakit_take_failure_note)" "sample data"
            warn "Sample data did not finish loading — carrying on so the rest of the install completes"
        fi
        exakit_clear_failure_note
    fi

    if command -v mcp_install >/dev/null 2>&1; then
        if begin_step mcp "Step ${_step_no}/${_total}  AI bridge (MCP server, clients and skills)"; then
            if exakit_soft_step mcp "exakit update mcp" _exakit_install_mcp; then
                mark_step mcp
            fi
        fi
    else
        info "Step ${_step_no}/${_total}  MCP server — not part of this installation, skipping"
    fi

    # The AI bridge is finished HERE, in the step that says it is being built:
    # the server, the clients that talk to it, the skills those clients load, and
    # the "restart your client" line that makes all three take effect. These two
    # offers used to run at the very end of the run instead — so a reader watched
    # step 4 announce the AI bridge, sat through pyexasol and the exakit helper,
    # and was then asked which AI clients to connect, under no step at all. The
    # step numbering said one thing and the screen did another.
    #
    # Nothing here needs a later step. The client configs point at `uvx
    # <mcp-server>`, never at the exakit command, and exakit_repo_root falls back
    # to the checkout for skills/ when the helper step has not staged its copy
    # yet. What they DO need is the database and exapump, which are two steps
    # back.
    #
    # Both offers are best-effort and neither may end the run — but "best-effort"
    # used to mean "vanishes without trace". Each books itself in the closing
    # summary with the command that retries it.
    exakit_clear_failure_note
    if ! ( exakit_maybe_offer_mcp_setup ); then
        exakit_record_soft_failure mcp_clients "exakit mcp-setup" \
            "$(exakit_take_failure_note)" "AI client (MCP) setup"
    fi
    exakit_clear_failure_note
    if ! ( exakit_maybe_offer_skills_install ); then
        exakit_record_soft_failure skills "exakit skills-install" \
            "$(exakit_take_failure_note)" "AI skills"
    fi
    exakit_clear_failure_note
    _step_no=$((_step_no + 1))

    if command -v pyexasol_install >/dev/null 2>&1; then
        if begin_step pyexasol "Step ${_step_no}/${_total}  pyexasol (Exasol Python driver)"; then
            # pyexasol is the last, optional Component and it must not be able to
            # end the run: the exakit helper step below still has to happen, or
            # the user is left without the command that fixes everything else. A
            # soft failure explains itself, records validated=false, and leaves
            # the step unmarked so a re-run (or `exakit update pyexasol`) retries.
            if exakit_soft_step pyexasol "exakit update pyexasol" _exakit_install_pyexasol; then
                mark_step pyexasol
            fi
        fi
    else
        info "Step ${_step_no}/${_total}  pyexasol — not part of this installation, skipping"
    fi
    _step_no=$((_step_no + 1))

    # The step flag alone is not trusted: if the exakit command was removed
    # (cleanup, testing), a re-run must reinstall it rather than skip.
    _helper_needed=0
    if begin_step exakit_helper "Step ${_step_no}/${_total}  exakit helper command"; then
        _helper_needed=1
    elif [ ! -x "$EXAKIT_BIN_DIR/exakit" ]; then
        info "exakit command is missing — reinstalling it"
        _helper_needed=1
    elif ! cmp -s "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit" 2>/dev/null; then
        # The flag records "installed", not "current". Re-running the installer
        # over an older install (the 0.1.0 -> 0.2.0 upgrade path) arrives with
        # the flag already set and a command already on disk, while install.sh
        # has just replaced the kit copy underneath it. The installed command is
        # a COPY of setup/exakit, so without this it stays at the old version
        # and drives the new library: the update notice, the version panel and
        # the kit2 subcommands all live in the command itself and would go
        # missing until the next self-update.
        info "exakit command is out of date — refreshing it"
        _helper_needed=1
    else
        ensure_path_hint "$EXAKIT_BIN_DIR"
    fi
    if [ "$_helper_needed" -eq 1 ]; then
        mkdir -p "$EXAKIT_BIN_DIR" || die "Could not create $EXAKIT_BIN_DIR for the exakit command."
        # Fail loudly here: without a check, a failed install (e.g. non-writable
        # ~/.local/bin, full disk) would fall through to mark_step + "exakit
        # installed", reporting success while no binary exists.
        install -m 755 "$_script_dir/exakit" "$EXAKIT_BIN_DIR/exakit" \
            || die "Could not install the exakit command to $EXAKIT_BIN_DIR (is it writable? is the disk full?)."
        # Keep a copy of the kit library (and the mcp/ and sql/ packages
        # exakit_repo_root() depends on) next to the state so exakit finds
        # them even when this checkout moves or disappears. Skip when setup is
        # ALREADY running from the kit home (the curl|sh flow, where install.sh
        # placed the kit there): copying a directory onto itself makes cp error
        # out with "are identical", which is not a real failure.
        if [ "$_script_dir" -ef "$EXAKIT_HOME/kit/setup" ] 2>/dev/null; then
            :   # already in place; nothing to copy
        else
            mkdir -p "$EXAKIT_HOME/kit/setup" || die "Could not create $EXAKIT_HOME/kit/setup."
            cp -R "$_script_dir/lib" "$EXAKIT_HOME/kit/setup/" \
                || die "Could not copy the kit library to $EXAKIT_HOME/kit/setup."
            # Copy the assets exakit needs after the checkout is gone: the mcp/
            # and sql/ packages, the data/ CSVs, load-data.sh, and the versions
            # manifest (the offline tier of version resolution, and the record of
            # which kit version this is).
            [ -f "$_kit_root/versions.json" ] && cp "$_kit_root/versions.json" "$EXAKIT_HOME/kit/"
            # whats-new.json lives under setup/, and only setup/lib is copied
            # above, so it needs naming or `exakit whats-new` finds nothing once
            # the checkout is gone.
            [ -f "$_kit_root/setup/whats-new.json" ] && cp "$_kit_root/setup/whats-new.json" "$EXAKIT_HOME/kit/setup/"
            [ -d "$_kit_root/mcp" ] && cp -R "$_kit_root/mcp" "$EXAKIT_HOME/kit/"
            [ -d "$_kit_root/sql" ] && cp -R "$_kit_root/sql" "$EXAKIT_HOME/kit/"
            [ -d "$_kit_root/data" ] && cp -R "$_kit_root/data" "$EXAKIT_HOME/kit/"
            # skills/ is not optional decoration: `exakit skills`, `exakit
            # skills-install` and the post-install skills step all resolve
            # through exakit_repo_root, which PREFERS this staged copy once
            # kit/mcp exists. Omitting it here does not fall back to the
            # checkout — it shadows it, so every one of those commands reports
            # "no skills/ directory in this kit build" on a working install.
            [ -d "$_kit_root/skills" ] && cp -R "$_kit_root/skills" "$EXAKIT_HOME/kit/"
            [ -f "$_script_dir/load-data.sh" ] && cp "$_script_dir/load-data.sh" "$EXAKIT_HOME/kit/setup/"
        fi
        ensure_path_hint "$EXAKIT_BIN_DIR"
        mark_step exakit_helper
        ok_step "exakit installed ($(ui_tilde "$EXAKIT_BIN_DIR/exakit"))"
    fi

    # The database should be there after a reboot without anyone thinking about
    # it, the way a system service is. Best-effort, and now reported to the
    # LOGFILE rather than the screen: the step leaves one line, and the plist
    # path was never something to act on -- `exakit autostart off` reverses it
    # and `exakit status` reports it.
    _eah_prev_quiet="${EXAKIT_QUIET_DETAIL:-0}"
    [ -t 1 ] && EXAKIT_QUIET_DETAIL=1
    exakit_autostart_enable || true
    EXAKIT_QUIET_DETAIL="$_eah_prev_quiet"

    # The upgrade news (exakit_print_whats_new_box) and the closing summary
    # (exakit_print_soft_failures) are printed by the setup scripts after the
    # connection panel at the very end of the run — not here, in the middle of
    # the step output where the connection details would push them off screen.
}

# connection_summary — the CLOSING panel of an install: the four things somebody
# who just watched a setup finish actually reaches for, and the command that has
# the rest.
#
# connection_panel below is the same information in full — eighteen rows — and it
# stays that way, because it is also what `exakit info` prints, and a reference
# screen is exactly where every path belongs. What an install should end with is
# not a reference screen.
connection_summary() {
    [ -f "$EXAKIT_MANIFEST" ] || { warn "No installation found ($EXAKIT_MANIFEST missing)"; return 1; }
    _cs_dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _cs_user="$(manifest_get runtime.user 2>/dev/null)"
    printf '\n'
    ui_panel_begin "Your local Exasol"
    ui_panel_line "$(printf '%-13s %s' "DSN" "${_cs_dsn:-unknown}   (admin ${_cs_user:-sys}, TLS self-signed)")"
    ui_panel_line "$(printf '%-13s %s' "Passwords" "$(ui_tilde "$EXAKIT_CREDS_DIR")/")"
    if exakit_marketplace_addon_installed exasol-vscode 2>/dev/null; then
        ui_panel_line "$(printf '%-13s %s' "SQL client" "VS Code (Exasol extension), $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")")"
    else
        ui_panel_line "$(printf '%-13s %s' "SQL client" "$(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")")"
    fi
    ui_panel_line "$(printf '%-13s %s' "Everything" "exakit info  ·  exakit guide")"
    ui_panel_end
}

# connection_panel — the payoff screen: everything needed to connect.
# Reads the manifest; sections appear as components get installed.
connection_panel() {
    [ -f "$EXAKIT_MANIFEST" ] || { warn "No installation found ($EXAKIT_MANIFEST missing)"; return 1; }

    # Six manifest_get calls, and every one starts a Python process to read a
    # single key out of the same file: measured at 53ms each, ~890ms for this
    # whole panel. That is why `exakit info` sits there for a moment before
    # anything appears, and it is what this narrates.
    #
    # ui_spin_begin draws nothing unless stdout is a terminal, so the
    # installer's use of this panel and any captured run are unchanged. The
    # spinner is stopped before the panel prints, never across it.
    ui_spin_begin "Reading your connection details"
    # ONE python process for all six keys, not six.
    #
    # This used to be six manifest_get calls, each starting its own interpreter
    # to read one key out of the same file: ~53ms each, ~890ms for the panel.
    # The spinner above explains that wait; batching removes it.
    #
    # THE ORDER OF THESE SIX NAMES IS THE CONTRACT with the loop below. Every
    # variable is initialised first, so a missing manifest leaves them empty
    # and the panel prints "unknown" exactly as it did before.
    _type=""; _dsn=""; _user=""; _pwfile=""; _mcp_user=""; _mcp_pwfile=""
    _cp_values="$(manifest_get_many \
        runtime.type \
        runtime.dsn \
        runtime.user \
        runtime.password_file \
        components.mcp_server.connection.user \
        components.mcp_server.connection.password_file 2>/dev/null)"
    _cp_i=0
    while IFS= read -r _cp_line; do
        _cp_i=$((_cp_i + 1))
        case "$_cp_i" in
            1) _type="$_cp_line" ;;
            2) _dsn="$_cp_line" ;;
            3) _user="$_cp_line" ;;
            4) _pwfile="$_cp_line" ;;
            5) _mcp_user="$_cp_line" ;;
            6) _mcp_pwfile="$_cp_line" ;;
        esac
    done <<_EXAKIT_CONN_EOF
$_cp_values
_EXAKIT_CONN_EOF
    ui_spin_end

    printf '\n'
    ui_panel_begin "Connection details"
    ui_panel_line "Runtime:      ${_type:-unknown}"
    ui_panel_line "DSN:          ${_dsn:-unknown}"
    ui_panel_line "Admin user:   ${_user:-sys}"
    [ -n "$_pwfile" ]    && ui_panel_line "Admin pass:   stored in $(ui_tilde "$_pwfile")"
    [ -n "$_mcp_user" ]  && ui_panel_line "MCP user:     $_mcp_user"
    [ -n "$_mcp_pwfile" ] && ui_panel_line "MCP pass:     stored in $(ui_tilde "$_mcp_pwfile")"
    ui_panel_line "TLS:          enabled (self-signed certificate)"

    _exapump="$(manifest_get components.exapump.path 2>/dev/null)"
    if [ -n "$_exapump" ]; then
        ui_panel_line "exapump:      $(ui_tilde "$_exapump") (profile: $(manifest_get components.exapump.profile 2>/dev/null))"
    fi

    # Stdio MCP configs live inside each AI client's own config file, not in
    # the kit's mcp/ dir (that holds only pre-edit backups) — point users at
    # the command that lists the real locations.
    _mcp="$(manifest_get components.mcp_server.configs 2>/dev/null)"
    if [ -n "$_mcp" ]; then
        ui_panel_line "MCP configs:  in each AI client's config (list: exakit mcp-status)"
        ui_panel_line "MCP backups:  $(ui_tilde "$EXAKIT_MCP_DIR")"
    fi

    ui_panel_line "Manifest:     $(ui_tilde "$EXAKIT_MANIFEST")"
    ui_panel_line "Logs:         $(ui_tilde "$EXAKIT_LOG_DIR")"
    # The two download links are always true: anyone can fetch them. The VS Code
    # extension is a marketplace add-on, so it is named only when it is actually
    # on this machine — otherwise the row would advertise a SQL client the reader
    # may not have, and on a machine without VS Code cannot get.
    #
    # It has to be named SOMEWHERE, though: the "Add-ons:" row below prints only
    # while something is still pending, so on a fully equipped machine an
    # installed extension went unmentioned by the whole panel.
    if exakit_marketplace_addon_installed exasol-vscode 2>/dev/null; then
        ui_panel_line "SQL client:   VS Code (Exasol extension), $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")"
    else
        ui_panel_line "SQL client:   $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")"
    fi
    ui_panel_line "More info:    exakit guide"
    # One line, only while something is still on offer: the marketplace is the
    # optional layer on top of a finished install, so this is where it is
    # discovered — never during the install itself.
    if exakit_marketplace_has_pending 2>/dev/null; then
        ui_panel_line "Add-ons:      exakit marketplace (dashboards, editor tools and more)"
    fi
    ui_panel_end
    printf '\n'
}

# exakit_print_no_ai_panel — shown when the user skips MCP client setup: the
# database is still fully usable without an AI assistant, and this says how.
exakit_print_no_ai_panel() {
    _nap_dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _nap_host="${_nap_dsn%%:*}"; _nap_port="${_nap_dsn##*:}"
    printf '\n'
    ui_panel_begin "Using your database without an AI client"
    ui_panel_line "Your database works great on its own — three easy ways in:"
    ui_panel_line ""
    ui_panel_line "GUI client:  $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")"
    ui_panel_line "             New Connection > Exasol > Host ${_nap_host:-127.0.0.1} Port ${_nap_port:-8563}"
    ui_panel_line "Python:      pyexasol is preinstalled in its own environment:"
    ui_panel_line "             $(ui_tilde "$EXAKIT_HOME/pyexasol-venv/bin/python")"
    ui_panel_line "Terminal:    exapump interactive -p starter-kit   (SQL shell)"
    ui_panel_line ""
    ui_panel_line "Step-by-step (credentials, TLS setting, first query):"
    ui_panel_line "  exakit guide"
    ui_panel_line "Changed your mind about AI? Any time:"
    ui_panel_line "  exakit mcp-setup"
    ui_panel_end
    printf '\n'
}

# exakit_guide — friendly how-to-connect walkthrough: AI clients over MCP,
# GUI SQL clients (DBeaver, DbVisualizer), and terminal/Python access. Everything below is
# rendered from the live manifest so the values are the user's own.
exakit_guide() {
    [ -f "$EXAKIT_MANIFEST" ] || { warn "No installation found. Run the installer first."; return 1; }
    _g_dsn="$(manifest_get runtime.dsn 2>/dev/null)"
    _g_host="${_g_dsn%%:*}"; _g_port="${_g_dsn##*:}"
    _g_host="${_g_host:-127.0.0.1}"; _g_port="${_g_port:-8563}"
    _g_user="$(manifest_get runtime.user 2>/dev/null)"; _g_user="${_g_user:-sys}"
    _g_pwfile="$(manifest_get runtime.password_file 2>/dev/null)"
    _g_mcp_user="$(manifest_get components.mcp_server.connection.user 2>/dev/null || true)"

    ui_banner "How to connect" "AI clients, SQL clients, Python — pick your door"

    ui_panel_begin "1 · Ask questions with an AI client (MCP)"
    ui_panel_line "Connect one or more AI clients in a single guided step:"
    ui_panel_line "  exakit mcp-setup"
    ui_panel_line "Supported: Claude, Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode, Continue"
    ui_panel_line "Then restart/reload the client and look for the MCP server 'exasol'."
    ui_panel_line ""
    ui_panel_line "First thing to ask it:"
    ui_panel_line "  \"List the schemas and tables in my Exasol database, then answer my"
    ui_panel_line "   questions with read-only SQL — show me the SQL before you run it.\""
    ui_panel_line "14 ready-made questions: data/example-questions.md (in the kit)"
    ui_panel_end

    ui_panel_begin "2 · Browse and query with a SQL client (GUI)"
    ui_panel_line "Both free: $(ui_link https://dbeaver.io/download/ "DBeaver") or $(ui_link https://www.dbvis.com/download/ "DbVisualizer")"
    ui_panel_line ""
    ui_panel_line "In DBeaver: Database > New Database Connection > search 'Exasol'"
    ui_panel_line "  Host:      $_g_host"
    ui_panel_line "  Port:      $_g_port"
    ui_panel_line "  User:      $_g_user"
    [ -n "$_g_pwfile" ] && \
    ui_panel_line "  Password:  cat $(ui_tilde "$_g_pwfile")"
    [ -n "$_g_mcp_user" ] && \
    ui_panel_line "  (read-only alternative: user $_g_mcp_user)"
    ui_panel_line "  TLS:       local self-signed certificate — in Driver properties set"
    ui_panel_line "             validateservercertificate = 0 (or add ;validateservercertificate=0"
    ui_panel_line "             to the JDBC URL), then Test Connection > Finish."
    ui_panel_line "Each bundled dataset has its own schema (TPCH, ENERGY, WEATHER);"
    ui_panel_line "your own uploads default to STARTER_KIT."
    ui_panel_end

    ui_panel_begin "3 · Terminal and Python"
    ui_panel_line "Interactive SQL shell:   exapump interactive -p starter-kit"
    ui_panel_line "One-off query:           exapump sql -p starter-kit \"SELECT 42\""
    ui_panel_line ""
    ui_panel_line "Python (pyexasol preinstalled in its own environment):"
    ui_panel_line "  $(ui_tilde "$EXAKIT_HOME/pyexasol-venv/bin/python")"
    ui_panel_line "  import pyexasol"
    ui_panel_line "  c = pyexasol.connect(dsn='$_g_host:$_g_port', user='$_g_user',"
    ui_panel_line "                       password=open('<password file above>').read(),"
    ui_panel_line "                       websocket_sslopt={'cert_reqs': 0})"
    ui_panel_line "  c.export_to_pandas('SELECT * FROM TPCH.CUSTOMER LIMIT 5')"
    ui_panel_end

    ui_panel_begin "Everything else"
    ui_panel_line "Connection summary:   exakit info"
    ui_panel_line "Load more data:       exakit data-load"
    ui_panel_line "Optional add-ons:     exakit marketplace (dashboards & more)"
    ui_panel_line "Health check:         exakit status · exakit mcp-doctor"
    ui_panel_end
    printf '\n'
}

# generate_password — local random password (not logged anywhere).
generate_password() {
    LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24
}

# store_credential <name> <value> — 0600 file under credentials dir.
# Written atomically so an interrupted run can never leave a truncated secret.
store_credential() {
    mkdir -p "$EXAKIT_CREDS_DIR" || die "Could not create the credentials directory $EXAKIT_CREDS_DIR."
    # chmod fails when the dir is owned by someone else (root-owned debris
    # from an interrupted install) — the writability diagnosis below reports
    # that case precisely, so don't let the raw chmod noise muddy the output.
    chmod 700 "$EXAKIT_CREDS_DIR" 2>/dev/null || true
    # Fail loudly on a write error: a silently dropped secret makes a later
    # step read an empty credential and either regenerate a mismatching
    # password or die with a confusing message far from the real cause.
    # Diagnose the actual cause instead of guessing — an end user cannot
    # act on "disk full or not writable?".
    if ! printf '%s' "$2" > "$EXAKIT_CREDS_DIR/$1.tmp" 2>/dev/null; then
        rm -f "$EXAKIT_CREDS_DIR/$1.tmp" 2>/dev/null
        if [ -d "$EXAKIT_CREDS_DIR/$1" ]; then
            die "Could not save credential '$1': $EXAKIT_CREDS_DIR/$1 exists as a directory (leftover from an interrupted install). Remove it with: sudo rm -rf $EXAKIT_CREDS_DIR — then re-run."
        elif [ ! -w "$EXAKIT_CREDS_DIR" ]; then
            _sc_owner="$(ls -ld "$EXAKIT_CREDS_DIR" 2>/dev/null | awk '{print $3}')"
            die "Could not save credential '$1': $EXAKIT_CREDS_DIR is not writable by $(id -un) (owned by ${_sc_owner:-unknown} — leftover from an interrupted install). Remove it with: sudo rm -rf $EXAKIT_CREDS_DIR — then re-run."
        fi
        die "Could not save credential '$1' to $EXAKIT_CREDS_DIR (disk full or read-only filesystem?)."
    fi
    chmod 600 "$EXAKIT_CREDS_DIR/$1.tmp"
    mv "$EXAKIT_CREDS_DIR/$1.tmp" "$EXAKIT_CREDS_DIR/$1" || die "Could not save credential '$1'."
}

read_credential() {
    _rc_file="$EXAKIT_CREDS_DIR/$1"
    # A file that exists but can't be read would otherwise look "missing" and
    # trigger a regenerated, diverging password — surface it instead.
    if [ -f "$_rc_file" ] && [ ! -r "$_rc_file" ]; then
        warn "Credential file exists but is not readable: $_rc_file (check permissions)."
    fi
    cat "$_rc_file" 2>/dev/null
}

# exakit_install_command - the install one-liner for THIS platform, so the
# farewell line of an uninstall is something the reader can actually paste.
# This side serves macOS, Linux and WSL, which all curl into sh; Windows has
# its own twin (Get-ExakitInstallCommand) that hands back the irm form.
exakit_install_command() {
    printf 'curl -fsSL %s | sh\n' "$EXAKIT_INSTALL_URL"
}

# --- full uninstall --------------------------------------------------------
#
# exakit_uninstall_run <dry_run> — remove every artifact this kit installs, in
# dependency order: the local database and ALL its data, the managed MCP client
# configs, the installed AI skills, the exapump profile, the kit home, and the
# CLI binaries. With <dry_run>="1" it prints the plan and changes nothing, so
# the caller can show exactly what will go before asking for confirmation.
#
# Deliberately NOT removed (reported instead): uv/uvx (a shared third-party
# Python runner the user may rely on elsewhere) and the PATH line added to the
# shell profile (unmarked and shared with other tools — unsafe to edit blindly).
# _exakit_remove_installed_skills <dry> — the kit's AI skills, wherever they
# were installed. Prefer the live list from the kit's skills/ dir; fall back
# to the known names when the checkout is already gone.
_exakit_remove_installed_skills() {
    _rs_dry="${1:-0}"
    _skill_names=""
    _repo_root="$(exakit_repo_root 2>/dev/null || true)"
    if [ -n "$_repo_root" ] && [ -d "$_repo_root/skills" ]; then
        for _sd in "$_repo_root"/skills/*/; do
            [ -f "$_sd/SKILL.md" ] || continue
            _skill_names="$_skill_names $(basename "$_sd")"
        done
    fi
    # The kit copy is gone (uninstall order, or a hand-deleted checkout), so
    # fall back to what the install actually recorded. A hardcoded name list
    # was the old fallback and it aged badly: it named a skill that never
    # shipped and knew nothing of the ones added since. Enumerating the
    # discovery folders instead is not an option — they also hold skills the
    # user installed themselves, and the kit removes only what it placed.
    if [ -z "$_skill_names" ]; then
        _skill_names="$(manifest_get components.skills.installed 2>/dev/null |
            tr -d '[]"' | tr ',' ' ')"
    fi
    # One line per FOLDER, not per skill. Nine skills across two discovery
    # folders printed eighteen near-identical lines in the middle of an
    # uninstall - long enough to push everything else off a screen, and saying
    # nothing the count and the folder do not. The individual paths are still
    # worth having in the log, where a reader goes when they want them.
    for _root in "$HOME/.claude/skills" "$HOME/.agents/skills"; do
        _rs_found=0
        for _name in $_skill_names; do
            [ -e "$_root/$_name" ] || continue
            _rs_found=$((_rs_found + 1))
            _exakit_log_file "INFO  AI skill $_root/$_name"
            [ "$_rs_dry" = "1" ] || rm -rf "$_root/$_name"
        done
        [ "$_rs_found" -gt 0 ] || continue
        if [ "$_rs_found" = 1 ]; then _rs_word="skill"; else _rs_word="skills"; fi
        if [ "$_rs_dry" = "1" ]; then
            info "  will remove: $_rs_found AI $_rs_word from $(ui_tilde "$_root")"
        else
            info "$_rs_found AI $_rs_word from $(ui_tilde "$_root")"
        fi
    done
    return 0
}

# _exakit_uninstall_component <key> <dry> — one selectable piece of the kit,
# removed on its own. Each removal also clears its manifest record and step
# flag, so `exakit status`, `exakit version` and an installer re-run all read the
# machine honestly afterwards. Best-effort throughout: one piece failing must
# not strand the others.
_exakit_uninstall_component() {
    _uc_key="$1"
    _uc_dry="${2:-0}"
    case "$_uc_key" in
        database)
            _uc_type="$(manifest_get runtime.type 2>/dev/null || true)"
            if [ "$_uc_dry" = "1" ]; then
                info "  will remove: the local Exasol $_uc_type deployment and ALL its data"
                return 0
            fi
            info "Removing the local Exasol $_uc_type deployment and all data"
            case "$_uc_type" in
                nano)     nano_teardown --data     || warn "Database removal reported errors" ;;
                personal) personal_teardown --data || warn "Database removal reported errors" ;;
                *)        warn "Unknown runtime type '$_uc_type'; skipping database removal" ;;
            esac
            exakit_unmark_step runtime
            ;;
        mcp_configs)
            if [ "$_uc_dry" = "1" ]; then
                info "  will remove: the managed MCP configuration from the AI clients"
                return 0
            fi
            info "Removing the managed MCP configuration from the AI clients"
            if command -v exakit_mcp_operation >/dev/null 2>&1; then
                exakit_mcp_operation uninstall >/dev/null 2>&1 || \
                    warn "Removing the managed MCP client config reported issues"
            fi
            ;;
        skills)
            _exakit_remove_installed_skills "$_uc_dry"
            ;;
        exapump)
            if [ "$_uc_dry" = "1" ]; then
                info "  will remove: exapump ($EXAKIT_BIN_DIR/exapump and the profiles at ~/.exapump)"
                return 0
            fi
            info "Removing exapump and its profiles"
            rm -f "$EXAKIT_BIN_DIR/exapump"
            # Through the shared variable, never a bare "$HOME/.exapump": a
            # caller that sandboxes EXAKIT_HOME but not HOME would otherwise
            # delete the real profile directory (a test suite did exactly that).
            rm -rf "${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}" "$EXAKIT_HOME/libexec"
            manifest_del components.exapump
            exakit_unmark_step exapump
            ;;
        pyexasol)
            if [ "$_uc_dry" = "1" ]; then
                info "  will remove: pyexasol (the managed venv at $EXAKIT_HOME/pyexasol-venv)"
                return 0
            fi
            info "Removing the pyexasol venv"
            rm -rf "${EXAKIT_PYEXASOL_VENV:-$EXAKIT_HOME/pyexasol-venv}"
            manifest_del components.pyexasol
            exakit_unmark_step pyexasol
            ;;
        everything)
            exakit_uninstall_run "$_uc_dry"
            ;;
        *)
            # A marketplace add-on: its module owns the removal.
            if _exakit_addon_registered "$_uc_key"; then
                _uc_fn="$(_exakit_addon_fn "$_uc_key" uninstall)"
                if command -v "$_uc_fn" >/dev/null 2>&1; then
                    "$_uc_fn" "$_uc_dry" || warn "Removing the $_uc_key add-on reported issues"
                else
                    warn "The $_uc_key module carries no uninstall — update the kit: exakit update exakit"
                fi
            else
                warn "Unknown uninstall target: $_uc_key"
            fi
            ;;
    esac
    return 0
}

# exakit_uninstall_menu — the interactive `exakit uninstall`: pick exactly
# what goes, see exactly what that means, then type the word. The selection
# is the same tree-checkbox every other kit choice uses; Skip is the
# exclusive, pre-selected default, so Enter alone removes nothing. Only what
# is actually on this machine is offered, and EVERYTHING is the one row that
# means the full teardown (kit home and the exakit command included).
# ⇄ twin: Show-ExakitUninstallMenu in setup/exakit.ps1.
# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
# One command reaches every log the kit can show: the install run, the database
# container's own output, each service add-on's log, and whatever the boot
# entries wrote at login. Add-ons opt in with <id>_log_path, so a new one is
# viewable with no wiring here.

# exakit_log_targets — one line per viewable log: "id|label|kind|source".
# kind=file → source is a path; kind=cmd → source is a command to run (the
# container keeps its log itself, there is no file to tail).
exakit_log_targets() {
    _lt_setup="$(ls -t "$EXAKIT_LOG_DIR"/install-*.log 2>/dev/null | head -1)"
    [ -n "$_lt_setup" ] && printf 'setup|Installer and setup runs|file|%s\n' "$_lt_setup"

    if [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "nano" ]; then
        _lt_engine="$(detect_container_runtime 2>/dev/null || true)"
        if [ -n "$_lt_engine" ] && [ "$_lt_engine" != "none" ]; then
            printf 'database|Database container|cmd|%s logs %s\n' \
                "$_lt_engine" "${EXAKIT_NANO_CONTAINER:-exasol-nano}"
        fi
    fi

    for _lt_id in $(exakit_marketplace_installed_addons 2>/dev/null); do
        _lt_fn="$(_exakit_addon_fn "$_lt_id" log_path)"
        command -v "$_lt_fn" >/dev/null 2>&1 || continue
        _lt_path="$("$_lt_fn" 2>/dev/null || true)"
        [ -n "$_lt_path" ] && printf '%s|%s service|file|%s\n' "$_lt_id" "$_lt_id" "$_lt_path"
    done

    # What the boot entries wrote at login — the only record of a start that
    # happened while nobody was watching.
    for _lt_auto in "$EXAKIT_LOG_DIR"/autostart-*.log; do
        [ -f "$_lt_auto" ] || continue
        _lt_name="$(basename "$_lt_auto" .log)"
        printf '%s|%s at login|file|%s\n' "$_lt_name" "${_lt_name#autostart-}" "$_lt_auto"
    done
    return 0
}

# _exakit_log_size <file> / _exakit_log_mtime <file> — small, portable columns.
# `date -r <file>` is understood by both BSD (macOS) and GNU date.
_exakit_log_size() {
    [ -f "$1" ] || { printf '%s' "-"; return 0; }
    _ls_bytes="$(wc -c < "$1" 2>/dev/null | tr -d ' ')"
    case "$_ls_bytes" in
        ''|*[!0-9]*) printf '%s' "-" ;;
        *) if [ "$_ls_bytes" -ge 1048576 ]; then printf '%sM' "$((_ls_bytes / 1048576))"
           elif [ "$_ls_bytes" -ge 1024 ]; then printf '%sK' "$((_ls_bytes / 1024))"
           else printf '%sB' "$_ls_bytes"; fi ;;
    esac
}

_exakit_log_mtime() {
    [ -f "$1" ] || { printf '%s' "-"; return 0; }
    date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "-"
}

# exakit_logs_overview — what can be viewed, in the kit's table shape.
# exakit_logs_overview_json — the same listing, machine-readable, so an agent can
# pick a target and its path without parsing a column-aligned table. Always an
# object, including when there are no logs at all, so a parser never gets empty
# stdout (the same rule the other --json surfaces follow).
exakit_logs_overview_json() {
    exakit_can_run_python || return 1
    _loj_rows=""
    while IFS='|' read -r _loj_id _loj_label _loj_kind _loj_src; do
        [ -n "$_loj_id" ] || continue
        if [ "$_loj_kind" = "cmd" ]; then
            _loj_rows="${_loj_rows}${_loj_id}|${_loj_label}|${_loj_kind}|${_loj_src}|live|kept by the engine
"
        else
            _loj_rows="${_loj_rows}${_loj_id}|${_loj_label}|${_loj_kind}|${_loj_src}|$(_exakit_log_size "$_loj_src")|$(_exakit_log_mtime "$_loj_src")
"
        fi
    done <<EXAKIT_LOJ_EOF
$(exakit_log_targets)
EXAKIT_LOJ_EOF
    # Rows go through argv, not stdin: run_python reads the PROGRAM from stdin
    # (the here-doc), so a piped payload arrives as an empty read and the
    # listing silently comes back with zero targets.
    run_python - "$_loj_rows" <<'EXAKIT_LOJ_PY'
import json, sys
targets = []
for line in sys.argv[1].splitlines():
    if not line.strip():
        continue
    fields = line.split("|")
    if len(fields) < 6:
        continue
    identifier, label, kind, source, size, updated = fields[:6]
    targets.append({
        "target": identifier,
        "what": label,
        "kind": kind,
        # A command-backed target has no file; null is the honest answer, and it
        # is what tells a caller to use `exakit logs <target>` instead of opening
        # a path itself.
        "path": source if kind != "cmd" else None,
        "command": source if kind == "cmd" else None,
        "size": size,
        "updated": updated,
    })
print(json.dumps({"count": len(targets), "targets": targets}, indent=2))
EXAKIT_LOJ_PY
}

exakit_logs_overview() {
    _lo_rows="$(exakit_log_targets)"
    if [ -z "$_lo_rows" ]; then
        info "No logs yet. They appear here after an install or once a service has run."
        return 0
    fi
    printf '\n  Component logs\n'
    printf '  --------------\n'
    printf '%-22s %-26s %-8s %s\n' "Target" "What" "Size" "Updated"
    while IFS='|' read -r _lo_id _lo_label _lo_kind _lo_src; do
        [ -n "$_lo_id" ] || continue
        if [ "$_lo_kind" = "cmd" ]; then
            printf '%-22s %-26s %-8s %s\n' "$_lo_id" "$_lo_label" "live" "kept by the engine"
        else
            printf '%-22s %-26s %-8s %s\n' "$_lo_id" "$_lo_label" \
                "$(_exakit_log_size "$_lo_src")" "$(_exakit_log_mtime "$_lo_src")"
        fi
    done <<EXAKIT_LO_EOF
$_lo_rows
EXAKIT_LO_EOF
    printf '\n'
    info "View one:  exakit logs <target>        (add -f to follow it live)"
    info "Its path:  exakit logs <target> --path"
    return 0
}

# exakit_logs_show <target> [follow] [lines] [path_only]
exakit_logs_show() {
    _lsh_target="$1"
    _lsh_follow="${2:-0}"
    _lsh_lines="${3:-200}"
    _lsh_path_only="${4:-0}"
    _lsh_found=""
    while IFS='|' read -r _lsh_id _lsh_label _lsh_kind _lsh_src; do
        [ "$_lsh_id" = "$_lsh_target" ] || continue
        _lsh_found="$_lsh_kind|$_lsh_src"
        break
    done <<EXAKIT_LSH_EOF
$(exakit_log_targets)
EXAKIT_LSH_EOF
    if [ -z "$_lsh_found" ]; then
        # A registered add-on that is simply NOT INSTALLED is not an unknown
        # name, and saying "No log called 'dash-server'" next to a list that
        # does not contain it leaves the reader to work out why theirs is
        # missing. Name the actual state instead: not installed here, or not
        # installable on this machine at all.
        if command -v _exakit_addon_registered >/dev/null 2>&1 && \
           _exakit_addon_registered "$_lsh_target"; then
            if command -v _exakit_addon_applicable >/dev/null 2>&1 && \
               ! _exakit_addon_applicable "$_lsh_target"; then
                _lsh_why="$(_exakit_addon_applicable_reason "$_lsh_target" 2>/dev/null || true)"
                die "$_lsh_target is not available on this machine${_lsh_why:+: $_lsh_why}"
            fi
            die "$_lsh_target is not installed, so it has written no log yet. Install it with: exakit marketplace"
        fi
        _lsh_known="$(exakit_log_targets | cut -d'|' -f1 | tr '\n' ' ' | sed 's/ $//')"
        die "No log called '$_lsh_target'.${_lsh_known:+ Available: $_lsh_known}"
    fi
    _lsh_kind="${_lsh_found%%|*}"
    _lsh_src="${_lsh_found#*|}"

    if [ "$_lsh_kind" = "cmd" ]; then
        if [ "$_lsh_path_only" = "1" ]; then
            printf '%s\n' "$_lsh_src"
            return 0
        fi
        # The container engine owns this log; ask it, with the same shape of
        # options the file path uses.
        if [ "$_lsh_follow" = "1" ]; then
            $_lsh_src --tail "$_lsh_lines" -f
        else
            $_lsh_src --tail "$_lsh_lines"
        fi
        return $?
    fi

    if [ "$_lsh_path_only" = "1" ]; then
        printf '%s\n' "$_lsh_src"
        return 0
    fi
    [ -f "$_lsh_src" ] || die "The $_lsh_target log has not been written yet ($_lsh_src)."
    if [ "$_lsh_follow" = "1" ]; then
        info "Following $_lsh_src — Ctrl-C to stop"
        tail -n "$_lsh_lines" -f "$_lsh_src"
    else
        tail -n "$_lsh_lines" "$_lsh_src"
    fi
}

# ---------------------------------------------------------------------------
# Services and autostart
# ---------------------------------------------------------------------------
# Everything the kit runs as a process — the database and any add-on that
# serves (dash-server today) — answers the same three questions: are you
# running, start, stop. Add-ons opt in by defining <id>_status, <id>_start,
# <id>_stop and <id>_autostart_command; the registry does the rest, so
# `exakit start|stop|status` and the boot entries pick a new add-on up with no
# wiring here.
#
# Autostart uses the platform's own supervisor rather than anything invented:
#   macOS  — a LaunchAgent per service in ~/Library/LaunchAgents (RunAtLoad).
#   Linux  — a systemd --user unit when the session has one.
#   Nano   — the container's own restart policy, which Docker honours on boot.
# A registration is a file the user can read, and `exakit autostart off`
# removes every one of them.

EXAKIT_LAUNCHAGENT_DIR="${EXAKIT_LAUNCHAGENT_DIR:-$HOME/Library/LaunchAgents}"
EXAKIT_SYSTEMD_USER_DIR="${EXAKIT_SYSTEMD_USER_DIR:-$HOME/.config/systemd/user}"
EXAKIT_AUTOSTART_PREFIX="com.exasol.exakit"

# exakit_service_ids — every service on this machine, database first. Add-ons
# appear only when installed AND carrying the service hooks.
exakit_service_ids() {
    [ -n "$(manifest_get runtime.type 2>/dev/null || true)" ] && printf '%s\n' database
    for _si_id in $(exakit_marketplace_installed_addons 2>/dev/null); do
        command -v "$(_exakit_addon_fn "$_si_id" status)" >/dev/null 2>&1 && printf '%s\n' "$_si_id"
    done
    return 0
}

# exakit_service_status <id> — running | stopped | not installed | unknown.
exakit_service_status() {
    if [ "$1" = "database" ]; then
        case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
            nano)     nano_status ;;
            personal) personal_status ;;
            *)        printf '%s\n' "unknown" ;;
        esac
        return 0
    fi
    _ss_fn="$(_exakit_addon_fn "$1" status)"
    if command -v "$_ss_fn" >/dev/null 2>&1; then
        "$_ss_fn"
    else
        printf '%s\n' "unknown"
    fi
}

# exakit_service_start <id> / exakit_service_stop <id> — the database self-heals
# (a missing deployment is refused with the remedy, a stopped one started);
# add-ons delegate to their own hooks.
exakit_service_start() {
    if [ "$1" = "database" ]; then
        exakit_ensure_runtime_running deploy
        return $?
    fi
    _sst_fn="$(_exakit_addon_fn "$1" start)"
    command -v "$_sst_fn" >/dev/null 2>&1 || return 0
    "$_sst_fn"
}

exakit_service_stop() {
    if [ "$1" = "database" ]; then
        case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
            nano)     nano_stop ;;
            personal) personal_stop ;;
        esac
        return $?
    fi
    _ssp_fn="$(_exakit_addon_fn "$1" stop)"
    command -v "$_ssp_fn" >/dev/null 2>&1 || return 0
    "$_ssp_fn"
}

# _exakit_service_autostart_command <id> — the command a boot entry runs, or
# nothing when the service needs no entry (Nano rides Docker's restart policy).
_exakit_service_autostart_command() {
    if [ "$1" = "database" ]; then
        case "$(exakit_installation_runtime_type 2>/dev/null || true)" in
            personal)
                _sac_cli="$(personal_cli 2>/dev/null || true)"
                [ -n "$_sac_cli" ] && printf '%s start\n' "$_sac_cli"
                ;;
            nano) ;;   # the container restart policy covers it
        esac
        return 0
    fi
    _sac_fn="$(_exakit_addon_fn "$1" autostart_command)"
    command -v "$_sac_fn" >/dev/null 2>&1 && "$_sac_fn"
    return 0
}

_exakit_autostart_label() { printf '%s.%s\n' "$EXAKIT_AUTOSTART_PREFIX" "$1"; }

# _exakit_autostart_register <id> — write the platform's boot entry. Returns 1
# (with an explanation) when the platform has no supervisor to register with.
_exakit_autostart_register() {
    _ar_id="$1"
    _ar_cmd="$(_exakit_service_autostart_command "$_ar_id")"
    if [ -z "$_ar_cmd" ]; then
        # Nano: the container itself carries the policy.
        if [ "$_ar_id" = "database" ] && \
           [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "nano" ]; then
            _exakit_nano_restart_policy always && \
                ok "database: the container restarts with Docker"
            return $?
        fi
        return 0
    fi
    _ar_label="$(_exakit_autostart_label "$_ar_id")"
    case "$(detect_os)" in
        macos)
            mkdir -p "$EXAKIT_LAUNCHAGENT_DIR" || { warn "Could not create $EXAKIT_LAUNCHAGENT_DIR"; return 1; }
            _ar_plist="$EXAKIT_LAUNCHAGENT_DIR/$_ar_label.plist"
            # One <string> per argument: launchd does not run a shell.
            {
                printf '<?xml version="1.0" encoding="UTF-8"?>\n'
                printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
                printf '<plist version="1.0">\n<dict>\n'
                printf '  <key>Label</key><string>%s</string>\n' "$_ar_label"
                printf '  <key>ProgramArguments</key>\n  <array>\n'
                for _ar_arg in $_ar_cmd; do
                    printf '    <string>%s</string>\n' "$_ar_arg"
                done
                printf '  </array>\n'
                printf '  <key>RunAtLoad</key><true/>\n'
                printf '  <key>StandardOutPath</key><string>%s/autostart-%s.log</string>\n' "$EXAKIT_LOG_DIR" "$_ar_id"
                printf '  <key>StandardErrorPath</key><string>%s/autostart-%s.log</string>\n' "$EXAKIT_LOG_DIR" "$_ar_id"
                printf '</dict>\n</plist>\n'
            } > "$_ar_plist" || { warn "Could not write $_ar_plist"; return 1; }
            # Load it now so the entry is live without a logout, and so a
            # rewritten plist replaces the old registration.
            launchctl unload "$_ar_plist" >/dev/null 2>&1
            launchctl load "$_ar_plist" >/dev/null 2>&1
            ok "$_ar_id: starts at login ($(ui_tilde "$_ar_plist"))"
            ;;
        # WSL takes the linux arm: detect_os separates the two because the
        # INSTALLER must, but a systemd --user session is a systemd --user
        # session. Left out, WSL fell to the catch-all and was told automatic
        # start is "not supported on this platform" — while a WSL2 distro with
        # systemd enabled supports it exactly as any other Linux does, and one
        # without it is already answered, accurately, by the guard below.
        linux|wsl)
            if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
                warn "$_ar_id: this session has no systemd --user, so nothing was registered."
                info "Start it by hand after a reboot with: exakit start"
                return 1
            fi
            mkdir -p "$EXAKIT_SYSTEMD_USER_DIR" || { warn "Could not create $EXAKIT_SYSTEMD_USER_DIR"; return 1; }
            _ar_unit="$EXAKIT_SYSTEMD_USER_DIR/$_ar_label.service"
            {
                printf '[Unit]\nDescription=Exasol Starter Kit: %s\n\n' "$_ar_id"
                printf '[Service]\nType=simple\nExecStart=%s\nRestart=on-failure\n\n' "$_ar_cmd"
                printf '[Install]\nWantedBy=default.target\n'
            } > "$_ar_unit" || { warn "Could not write $_ar_unit"; return 1; }
            systemctl --user daemon-reload >/dev/null 2>&1
            systemctl --user enable "$_ar_label.service" >/dev/null 2>&1 || {
                warn "Could not enable $_ar_label.service"; return 1; }
            ok "$_ar_id: starts at login ($(ui_tilde "$_ar_unit"))"
            ;;
        *)
            warn "$_ar_id: automatic start is not supported on this platform."
            return 1
            ;;
    esac
}

# _exakit_autostart_unregister <id> — remove the boot entry, quietly.
_exakit_autostart_unregister() {
    _au_label="$(_exakit_autostart_label "$1")"
    _au_plist="$EXAKIT_LAUNCHAGENT_DIR/$_au_label.plist"
    if [ -f "$_au_plist" ]; then
        launchctl unload "$_au_plist" >/dev/null 2>&1
        rm -f "$_au_plist"
        ok "$1: no longer starts at login"
    fi
    _au_unit="$EXAKIT_SYSTEMD_USER_DIR/$_au_label.service"
    if [ -f "$_au_unit" ]; then
        systemctl --user disable "$_au_label.service" >/dev/null 2>&1
        rm -f "$_au_unit"
        systemctl --user daemon-reload >/dev/null 2>&1
        ok "$1: no longer starts at login"
    fi
    return 0
}

# _exakit_autostart_registered <id> — is a boot entry in place?
_exakit_autostart_registered() {
    _arg_label="$(_exakit_autostart_label "$1")"
    [ -f "$EXAKIT_LAUNCHAGENT_DIR/$_arg_label.plist" ] && return 0
    [ -f "$EXAKIT_SYSTEMD_USER_DIR/$_arg_label.service" ] && return 0
    # Nano needs no file: the container carries the policy itself.
    if [ "$1" = "database" ] && \
       [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "nano" ]; then
        _exakit_nano_restart_policy_is_set && return 0
    fi
    return 1
}

# _exakit_nano_restart_policy <policy> — apply it to the existing container, no
# recreation and no data risk.
_exakit_nano_restart_policy() {
    command -v detect_container_runtime >/dev/null 2>&1 || return 1
    _nrp_engine="$(detect_container_runtime 2>/dev/null)"
    [ -n "$_nrp_engine" ] && [ "$_nrp_engine" != "none" ] || return 1
    "$_nrp_engine" update --restart="$1" "${EXAKIT_NANO_CONTAINER:-exasol-nano}" >/dev/null 2>&1
}

_exakit_nano_restart_policy_is_set() {
    command -v detect_container_runtime >/dev/null 2>&1 || return 1
    _nrs_engine="$(detect_container_runtime 2>/dev/null)"
    [ -n "$_nrs_engine" ] && [ "$_nrs_engine" != "none" ] || return 1
    _nrs_policy="$("$_nrs_engine" inspect -f '{{.HostConfig.RestartPolicy.Name}}' \
        "${EXAKIT_NANO_CONTAINER:-exasol-nano}" 2>/dev/null)"
    case "$_nrs_policy" in
        ''|no) return 1 ;;
        *) return 0 ;;
    esac
}

# exakit_autostart_enable / _disable — every service at once. Best-effort: a
# platform without a supervisor says so and the rest still applies.
exakit_autostart_enable() {
    _ae_any=0
    for _ae_id in $(exakit_service_ids); do
        _exakit_autostart_register "$_ae_id" && _ae_any=1
    done
    if [ "$_ae_any" = 1 ]; then
        manifest_set autostart.enabled true
    else
        manifest_set autostart.enabled false
    fi
    return 0
}

# exakit_autostart_default_on — turn automatic start ON for a FRESH install.
#
# The kit exists to give someone a database that is simply there; leaving it off
# by default meant a reboot silently took it away and the next command failed
# with a connection error. Only ever applied when the manifest has no opinion
# yet: a user who ran `exakit autostart off` has said no, and that answer is
# recorded as false and must survive every later run of the installer.
# ⇄ twin: Enable-ExakitAutostartDefault in exakit-common.ps1.
# exakit_with_spinner <label> <command...> — run a slow phase behind the kit's
# spinner, so a command never sits there silent.
#
# `exakit status`, `info` and `version` all have to ask something slow before
# they can print anything: a database round trip, a container probe, sometimes
# the network. They used to show nothing at all until the answer arrived, so a
# two-second wait was indistinguishable from a hang — the reader has no way to
# tell "working" from "stuck". The install path has used this spinner for its
# steps since it was written; the read commands never adopted it.
#
# ui_spin_begin re-checks `-t 1` at call time, so nothing is drawn when stdout
# is a pipe or a file — which is also what keeps a frame out of the middle of
# a --json document.
#
# The command's own stdout is left alone: only the spinner writes to the
# terminal, and it clears its line before this returns. The exit status is the
# command's, so callers can still branch on it.
# ⇄ twin: Invoke-ExakitWithSpinner in exakit-common.ps1.
exakit_with_spinner() {
    _ws_label="$1"; shift
    ui_spin_begin "$_ws_label"
    "$@"
    _ws_rc=$?
    ui_spin_end
    return "$_ws_rc"
}

exakit_autostart_default_on() {
    case "$(manifest_get autostart.enabled 2>/dev/null || true)" in
        true|false) return 0 ;;
    esac
    exakit_autostart_enable
    return 0
}

exakit_autostart_disable() {
    for _ad_id in $(exakit_service_ids); do
        _exakit_autostart_unregister "$_ad_id"
    done
    # The database container keeps running, it just no longer comes back on boot.
    [ "$(exakit_installation_runtime_type 2>/dev/null || true)" = "nano" ] && \
        _exakit_nano_restart_policy no >/dev/null 2>&1
    manifest_set autostart.enabled false
    ok "Automatic start after a restart is off."
    return 0
}

# exakit_autostart_print — the state of every boot entry.
exakit_autostart_print() {
    # A card, like every other framed answer the kit gives. The service ids come
    # from the registry, so the name column is measured rather than assumed.
    _ap_w=7
    for _ap_id in $(exakit_service_ids); do
        [ "${#_ap_id}" -gt "$_ap_w" ] && _ap_w="${#_ap_id}"
    done
    printf '\n'
    ui_panel_begin "Automatic start after a restart"
    ui_panel_line "$(printf '%-*s  %s' "$_ap_w" "Service" "Status")"
    for _ap_id in $(exakit_service_ids); do
        if _exakit_autostart_registered "$_ap_id"; then
            ui_panel_line "$(printf '%-*s  %s' "$_ap_w" "$_ap_id" "yes")"
        else
            ui_panel_line "$(printf '%-*s  %s' "$_ap_w" "$_ap_id" "no")"
        fi
    done
    ui_panel_end
    printf '\n'
    info "Turn it on with: exakit autostart on   ·   off with: exakit autostart off"
    return 0
}

exakit_uninstall_menu() {
    _um_labels=("Skip — uninstall nothing")
    _um_keys=("__skip__")
    _um_tee="${UI_TEE:-|-}"; _um_corner="${UI_CORNER:-\`-}"

    # The BUILT-IN components are deliberately NOT rows here.
    #
    # They are not independent things a user meaningfully picks between: the
    # database, its MCP configs, the read-only MCP user, exapump's profile and
    # the pyexasol venv are one working installation, and removing one of them
    # leaves a kit that looks installed and does not work — a state nobody
    # asked for and the update flow cannot repair. The two honest choices for
    # the core are keep it or remove it, which is exactly Skip and EVERYTHING.
    #
    # ADD-ONS are the real per-item choice: each is optional by construction,
    # nothing else depends on it, and removing one leaves everything else
    # working. So they are the only individually selectable rows.
    #
    # A single component can still be removed on purpose, by name, for the rare
    # case that wants it -- `exakit uninstall mcp_configs` -- and the hint below
    # the menu says so. That keeps the capability without putting a
    # half-installed kit one keystroke away.

    # Kit-managed add-ons, each removable on its own.
    _um_addons="$(exakit_marketplace_installed_addons 2>/dev/null || true)"
    if [ -n "$_um_addons" ]; then
        # "Clear the add-ons, keep the kit" was already reachable - tick every
        # add-on row and leave EVERYTHING alone - but nothing on the screen said
        # so, and with three add-ons it was three keystrokes and a guess about
        # whether the combination was safe. This states the outcome instead.
        #
        # A plain row, not a group parent: the checkbox widget carries one group
        # spec and EVERYTHING already owns it (it has to stay a master over the
        # add-on rows, or the screen could claim "everything" with one unticked).
        # Only offered when there is more than one add-on, because with a single
        # add-on it is the same keystroke twice.
        # The scope row, and the caption at the same time. A separate
        # "Add-ons (kit-managed)" caption said the word twice and left the sweep
        # floating above the tree it acts on.
        #
        # Both scope rows say what SURVIVES, not what goes: that is the one
        # fact a reader at this screen is actually weighing, and "keeps:
        # nothing" is the plainest statement EVERYTHING can make.
        #
        # "keeps: starter-kit" names the thing, not its parts. The row used to
        # list them -- database, data, exapump, MCP, pyexasol -- which is the
        # longest line on the screen, has to be re-checked against reality every
        # time a component is added, and asks the reader to reassemble "the kit"
        # from five nouns to answer a question they already think of in one.
        _um_labels+=("Add-ons only — keeps: starter-kit")
        _um_keys+=("__all_addons__")
        _um_count="$(printf '%s\n' $_um_addons | grep -c .)"
        _um_i=0
        for _um_id in $_um_addons; do
            _um_i=$((_um_i + 1))
            if [ "$_um_i" -eq "$_um_count" ]; then _um_conn="$_um_corner"; else _um_conn="$_um_tee"; fi
            # Indented a level further than the scope row above them, so the
            # members read as belonging to it rather than sitting beside it.
            _um_labels+=("  $_um_conn $_um_id")
            _um_keys+=("$_um_id")
        done
    fi

    _um_labels+=("EVERYTHING — keeps: nothing")
    _um_keys+=("everything")
    _um_every_idx="${#_um_labels[@]}"

    # Named single-component removal stays available; it is just not one
    # keystroke away in a menu.
    printf '\n    %sOne component on purpose: exakit uninstall <database|mcp_configs|skills|exapump|pyexasol>%s\n' \
        "${UI_DIM:-}" "${UI_RESET:-}"

    # EVERYTHING is a MASTER toggle over every row above it: picking it ticks
    # them all, and unticking any single row releases it — so the screen can
    # never claim "everything" while something sits unticked. Skip stays the
    # exclusive opt-out. (No children means nothing but Skip and EVERYTHING is
    # on offer, and a group spec would be meaningless.)
    if [ "$_um_every_idx" -gt 2 ]; then
        EXAKIT_CHECKBOX_GROUP="$_um_every_idx:2:$((_um_every_idx - 1)):all"
    fi
    EXAKIT_CHECKBOX_EXCLUSIVE=1
    ui_checkbox_menu "Select what to uninstall" "1" "${_um_labels[@]}"
    case ",$EXAKIT_CHECKBOX_SELECTION," in
        *",1,"*)
            info "Nothing was uninstalled."
            return 0
            ;;
    esac

    _um_picked=""
    _um_picked_labels=""
    for _um_idx in $(printf '%s' "$EXAKIT_CHECKBOX_SELECTION" | tr ',' ' '); do
        [ "$_um_idx" -ge 2 ] || continue
        _um_key="${_um_keys[$((_um_idx - 1))]}"
        # BEFORE the __*__ skip below: the sweep key is spelled like the
        # placeholder keys (headers, spacers) that the skip exists to drop, so
        # checking it afterwards silently discarded the pick and the menu
        # answered "Nothing selected" with the row plainly ticked.
        if [ "$_um_key" = "__all_addons__" ]; then
            # Expand to the add-ons themselves, so the confirmation panel and the
            # removal loop see the same concrete list every other pick produces:
            # nobody types UNINSTALL against a row that hides its members.
            for _um_a in $_um_addons; do
                case " $_um_picked " in *" $_um_a "*) continue ;; esac
                _um_picked="${_um_picked:+$_um_picked }$_um_a"
                _um_picked_labels="${_um_picked_labels:+$_um_picked_labels
}$_um_a"
            done
            continue
        fi
        case "$_um_key" in __*__) continue ;; esac
        # EVERYTHING swallows any other pick — the full run covers it all.
        if [ "$_um_key" = "everything" ]; then
            _um_picked="everything"
            _um_picked_labels="EVERYTHING — the full kit (database + data, MCP configs, skills, exapump, pyexasol, add-ons, kit home, exakit)"
            break
        fi
        case " $_um_picked " in *" $_um_key "*) continue ;; esac
        _um_picked="${_um_picked:+$_um_picked }$_um_key"
        _um_picked_labels="${_um_picked_labels:+$_um_picked_labels
}$(printf '%s' "${_um_labels[$((_um_idx - 1))]}" | sed "s/^  *//; s/^$_um_tee //; s/^$_um_corner //")"
    done
    [ -n "$_um_picked" ] || { info "Nothing selected — nothing was uninstalled."; return 0; }

    # The informed consent: exactly what was picked, in plain words, then the
    # irreversibility warning, then the typed gate. --yes never reaches this
    # menu (it is the scripted FULL uninstall), so the word is always typed.
    printf '\n'
    ui_panel_begin "This will PERMANENTLY remove"
    # No pipeline here: ui_panel_line buffers in the CURRENT shell, and a
    # pipeline stage is a subshell that would swallow every line.
    while IFS= read -r _um_line; do
        [ -n "$_um_line" ] && ui_panel_line "$_um_line"
    done <<EXAKIT_UM_PANEL_EOF
$_um_picked_labels
EXAKIT_UM_PANEL_EOF
    ui_panel_end
    printf '\n'
    warn "This is IRREVERSIBLE. Removed data cannot be recovered."
    case " $_um_picked " in
        *" database "*|everything*) warn "The database selection deletes ALL local database data." ;;
    esac
    _um_tty="$(_exakit_prompt_tty)"
    [ -n "$_um_tty" ] || die "uninstall needs an interactive terminal to confirm; use --yes for the scripted full uninstall."
    printf '\033[1;31m  !\033[0m Type \033[1mUNINSTALL\033[0m to remove the items above (anything else cancels): '
    if [ "$_um_tty" = "/dev/tty" ]; then read -r _um_answer < /dev/tty; else read -r _um_answer; fi
    [ "$_um_answer" = "UNINSTALL" ] || { info "Uninstall cancelled — nothing was removed."; return 0; }

    printf '\n'
    for _um_key in $_um_picked; do
        _exakit_uninstall_component "$_um_key" 0
    done
    printf '\n'
    # A full uninstall has just deleted the exakit binary, so pointing at
    # `exakit info` sends the reader to a command that no longer exists -
    # the last word of the run being one that cannot be followed. Anything
    # short of EVERYTHING leaves the CLI in place, and there info is exactly
    # the right next step.
    case " $_um_picked " in
        *" everything "*)
            ok "Done. The kit is gone."
            info "Install it again any time: $(exakit_install_command)"
            ;;
        *)
            ok "Done. See where you stand with: exakit info"
            ;;
    esac
    return 0
}

exakit_uninstall_run() {
    _dry="${1:-0}"
    _step() { # _step <message>  — narrate the action (or the plan line)
        if [ "$_dry" = "1" ]; then info "  will remove: $1"; else info "$1"; fi
    }
    _rm() { # _rm <path> — remove a path unless dry-run
        [ "$_dry" = "1" ] || rm -rf "$1"
    }

    # 0a) Boot entries first: a LaunchAgent or systemd unit left behind would
    #     try to start something that no longer exists on the next login.
    if command -v exakit_service_ids >/dev/null 2>&1; then
        for _un_svc in $(exakit_service_ids 2>/dev/null); do
            if _exakit_autostart_registered "$_un_svc" 2>/dev/null; then
                if [ "$_dry" = "1" ]; then
                    info "  will remove: the automatic-start entry for $_un_svc"
                else
                    _exakit_autostart_unregister "$_un_svc" >/dev/null 2>&1 || true
                fi
            fi
        done
    fi

    # 0b) Kit-managed marketplace add-ons that live OUTSIDE the kit home (the
    #    VS Code extension). Anything under the kit home or the bin dir is
    #    swept by steps 5-6 regardless; a system-installed copy the kit never
    #    managed is not touched (each hook enforces that itself).
    if command -v exakit_marketplace_installed_addons >/dev/null 2>&1; then
        for _un_id in $(exakit_marketplace_installed_addons 2>/dev/null); do
            _un_fn="$(_exakit_addon_fn "$_un_id" uninstall)"
            command -v "$_un_fn" >/dev/null 2>&1 || continue
            "$_un_fn" "$_dry" || warn "Removing the $_un_id add-on reported issues (continuing uninstall)"
        done
    fi

    # 1) Database + all data. Uses the runtime removal helper (always --data),
    #    which for Personal also reaps any orphaned runner daemon on the DB port.
    _type="$(manifest_get runtime.type 2>/dev/null || true)"
    if [ -n "$_type" ]; then
        _step "local Exasol $_type deployment and ALL its data"
        if [ "$_dry" != "1" ]; then
            case "$_type" in
                nano)     nano_teardown --data     || warn "Database removal reported errors (continuing uninstall)" ;;
                personal) personal_teardown --data || warn "Database removal reported errors (continuing uninstall)" ;;
                *)        warn "Unknown runtime type '$_type'; skipping database removal" ;;
            esac
        fi
    fi

    # 2) Managed MCP configuration in the AI clients (Claude, Cursor,
    #    Codex). Best-effort: a failure here must not block the rest.
    if command -v exakit_mcp_operation >/dev/null 2>&1; then
        _step "managed MCP configuration in Claude (desktop + Claude Code CLI), Cursor, and Codex"
        if [ "$_dry" != "1" ]; then
            exakit_mcp_operation uninstall >/dev/null 2>&1 || \
                warn "Removing the managed MCP client config reported issues (continuing uninstall)"
        fi
    fi

    # 3) Installed AI skills (shared with the selectable uninstall menu).
    _exakit_remove_installed_skills "$_dry"

    # 4) exapump profile store (the kit created it; the binary goes in step 6).
    if [ -e "${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}" ]; then
        _step "exapump profiles at ${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}"
        _rm "${EXAKIT_EXAPUMP_CONFIG_DIR:-$HOME/.exapump}"
    fi

    # 5) Kit home: credentials, logs, manifest, cached kit copy, MCP snapshots,
    #    and the pyexasol / marketplace add-on virtual environments and state
    #    (dash-server's venv and instance data live under the kit home too).
    if [ -e "$EXAKIT_HOME" ]; then
        _step "kit home $EXAKIT_HOME (credentials, logs, manifest, snapshots, pyexasol venv, add-ons)"
        _rm "$EXAKIT_HOME"
    fi

    # 6) CLI binaries. Removed last so earlier steps can still call the launcher.
    #    Removing the running exakit binary itself is safe (the inode survives
    #    until the process exits). Marketplace add-on launchers are swept by
    #    registry id — a new add-on needs no edit here, and a machine without
    #    one simply has no file to remove.
    _bins="exasol exakit exapump"
    if command -v exakit_marketplace_addons >/dev/null 2>&1; then
        _bins="$_bins $(exakit_marketplace_addons | cut -d'|' -f1 | tr '\n' ' ')"
    fi
    for _bin in $_bins; do
        if [ -e "$EXAKIT_BIN_DIR/$_bin" ]; then
            _step "CLI binary $EXAKIT_BIN_DIR/$_bin"
            _rm "$EXAKIT_BIN_DIR/$_bin"
        fi
    done
}
