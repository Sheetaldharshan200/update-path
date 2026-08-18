# The marketplace: optional add-ons, and how to add one

The marketplace is the kit's home for **optional tools** — things worth having
next to the database but not worth lengthening the install for. dash-server
(the AI dashboard host) is the first one.

This document is two things: a short tour of how the marketplace behaves, and
the **complete walkthrough for adding a new add-on** — which is deliberately
three additive changes with no case-statement surgery anywhere.

For the user-journey view — fresh install, existing kit, update path, every
scenario as a flowchart — see [MARKETPLACE-FLOWS.md](MARKETPLACE-FLOWS.md).

---

## How it behaves (the contract)

- **Never in the install flow.** The setup scripts install nothing from the
  marketplace. After a successful interactive install, the closing screen
  says *"Your Starter Kit installation is done and working"* and asks one
  gate question as a cursor selection — *Do you want to add optional tools?*
  with Yes pre-ticked and No as the opt-out. Yes opens the marketplace
  selection, where the available add-ons come pre-selected (exactly like the
  data-load menu pre-selects pending datasets), so Enter installs them and
  Cancel still backs out; No prints the one command to come back with. No
  typing anywhere.
- **`exakit marketplace`** is the command: every add-on with a one-line
  description, Space selects, Enter installs. Non-interactive runs (agents,
  CI) answer with `EXAKIT_MARKETPLACE_ADDONS=<ids csv | all | none>` instead —
  this also pre-answers the closing offer.
- **Dynamic by applicability.** An add-on that extends something the user does
  not have is not offered at all — no row, no table line, no mention anywhere.
  The VS Code extension is only listed on a machine that has VS Code; naming
  it anyway (`EXAKIT_MARKETPLACE_ADDONS=exasol-vscode`) explains that the host
  app is missing instead of failing deep in the installer. A copy the kit
  already installed stays visible even if the host app disappears later, so it
  can still be updated or removed.
- **Dynamic by presence.** An add-on already on the machine is never
  advertised — whether the kit installed it (shown as *installed (vX)*) or it
  was already on the system outside the kit (shown as *already on this system —
  the kit leaves it alone*; the kit never updates or uninstalls what it did
  not install). When everything is present, the offer and the discovery lines
  disappear entirely.
- **Installed add-ons are full components.** They join `exakit update` /
  `exakit update-check`, report in `exakit version`, pin with
  `EXAKIT_<ID>_VERSION`, and are swept by `exakit uninstall`. Add-ons you never
  picked are never touched by `update all`.

## Where the pieces live

| Piece | bash | PowerShell |
|---|---|---|
| Registry + menu + offer + generic arms | `setup/lib/common.sh` (marketplace block) | `setup/lib/exakit-common.ps1` (marketplace block), registry arms in `setup/exakit.ps1` |
| The add-on itself | `setup/lib/<id>.sh` | `setup/lib/<id>.ps1` |
| CLI entry point | `setup/exakit` (`cmd_marketplace`) | `setup/exakit.ps1` (`Invoke-CmdMarketplace`) |
| Closing offer call | `setup/setup-macos.sh`, `setup/setup-wsl.sh` | `setup/setup-windows-docker.ps1` |

Every registry function — version block, env override, fallback, upstream
lookup, installed probe, update targets and dispatch — resolves a registered
add-on through **one generic arm driven by conventions**, so a new add-on
needs no edits there. The conventions, for an id like `my-tool`:

| Convention | Value for `my-tool` |
|---|---|
| Module functions (bash; dashes → underscores) | `my_tool_install`, `my_tool_validate`, `my_tool_update`, `my_tool_installed_version`, `my_tool_uninstall`; a tool that *runs* adds `my_tool_status`, `my_tool_start`, `my_tool_stop`, `my_tool_autostart_command`, `my_tool_log_path`; a tool that extends a host app adds `my_tool_applicable` (+ `my_tool_applicable_reason`); a tool whose installable version is not a plain upstream release adds `my_tool_latest`; sharpen manual-install detection with `my_tool_system_present` |
| Version env override / fallback (bash) | `EXAKIT_MY_TOOL_VERSION`, `EXAKIT_MY_TOOL_VERSION_FALLBACK` |
| versions.json block | `components.my-tool` (`repo` = GitHub release, `package` = PyPI — the generic upstream lookup reads whichever is present; neither, plus a `my_tool_latest` hook, when the kit repackages the tool itself — see json-tables) |
| Manifest keys | `components.my_tool.*`, `desired.my_tool` |
| Kit-managed state | venv/state under `$EXAKIT_HOME`, launcher at `$EXAKIT_BIN_DIR/my-tool` (swept by uninstall automatically, by registry id) |
| PowerShell functions | named explicitly in the registry entry (no derivation) |

---

## Adding a new add-on: the walkthrough

Three changes, one PR. `setup/lib/dash-server.sh` / `.ps1` are the reference
implementation — copy them when in doubt.

Pick your reference by what the tool is:

- **A Python package with a working wheel** → copy dash-server.
- **An extension to a host application** → copy exasol-vscode (the
  `_applicable` gate, the host-app CLI discovery, the refusal to touch a copy
  the user installed themselves).
- **A tool users cannot install as shipped** (needs a toolchain, ships no
  binaries, hardcodes a build step) → copy **json-tables**: a packaging
  workflow in this repo (`.github/workflows/pkg-json-tables.yml`) builds the
  artifacts once for every platform and publishes them to a `mirror-<id>`
  release here; the module downloads the prebuilt pair digest-verified,
  resolves "latest" from that release (`<id>_latest` hook) so nothing is ever
  advertised before it is built, and the workflow's `advertise` job bumps
  versions.json by pull request only after a successful publish.

### 1. Ship the module pair

**`setup/lib/my-tool.sh`** — the skeleton every add-on follows:

```bash
#!/usr/bin/env bash
# my-tool.sh — my-tool (<one-line purpose>): managed install + validation.
# A MARKETPLACE ADD-ON: never installed by the setup scripts.

# The add-on's version constants live here, next to the code that uses them —
# the generic registry arms find them by the derived-name convention, and the
# versions-bump workflow keeps the fallback in lockstep with versions.json.
EXAKIT_MY_TOOL_VERSION="${EXAKIT_MY_TOOL_VERSION:-}"
EXAKIT_MY_TOOL_VERSION_FALLBACK="${EXAKIT_MY_TOOL_VERSION_FALLBACK:-1.0.0}"
EXAKIT_MY_TOOL_REPO="${EXAKIT_MY_TOOL_REPO:-exasol-labs/my-tool}"

# The live probe: answer with the installed version, FAIL for a provably
# absent install. This is what keeps a stale manifest record from ever
# claiming "installed".
my_tool_installed_version() {
    # e.g. "$venv_python" -c 'from importlib.metadata import version; ...'
    return 1
}

# Soft-fail helper: marketplace installs must never end the caller's run.
_my_tool_not_installed() {
    warn "my-tool was not installed: $1"
    warn "Everything else in the kit is unaffected. Retry with: exakit update my-tool"
    command -v exakit_note_failure >/dev/null 2>&1 && exakit_note_failure "$1"
    manifest_set components.my_tool.validated false
    return 1
}

my_tool_install() {
    # The marketplace path runs from the exakit CLI, where the installer's
    # version resolution has not run — resolve the advertised version here.
    if [ -z "${EXAKIT_MY_TOOL_VERSION:-}" ]; then
        EXAKIT_MY_TOOL_VERSION="$(exakit_component_available my-tool 2>/dev/null || true)"
        [ -n "$EXAKIT_MY_TOOL_VERSION" ] || EXAKIT_MY_TOOL_VERSION="$EXAKIT_MY_TOOL_VERSION_FALLBACK"
        export EXAKIT_MY_TOOL_VERSION
    fi
    # ... install (venv under $EXAKIT_HOME, launcher in $EXAKIT_BIN_DIR) ...
    # On any failure: _my_tool_not_installed "<reason>"; return 1
    manifest_set components.my_tool.version "$EXAKIT_MY_TOOL_VERSION"
}

# Prove it actually works; record validated=true/false. Soft — return 0 even
# when validation fails (the failure has already explained itself).
my_tool_validate() {
    manifest_set components.my_tool.validated true
    return 0
}

# Install the advertised version. Doubles as the repair command; asked for
# explicitly, so a failure here IS a failure (die).
my_tool_update() {
    _available="$(exakit_component_available my-tool 2>/dev/null || true)"
    [ -n "$_available" ] || die "Could not resolve the advertised my-tool version."
    _current="$(my_tool_installed_version 2>/dev/null || true)"
    if [ -n "$_current" ] && [ "$_current" = "$_available" ]; then
        ok "my-tool is already current ($_current)"
        return 0
    fi
    EXAKIT_MY_TOOL_VERSION="$_available"
    export EXAKIT_MY_TOOL_VERSION
    my_tool_install || die "my-tool could not be installed — see the warning above."
    my_tool_validate || true
    manifest_set desired.my_tool "$EXAKIT_MY_TOOL_VERSION"
    ok "my-tool updated; database data was not changed"
}

# Remove what the install put on this machine (with "1": narrate the plan
# only). This one hook folds the add-on into the selectable
# `exakit uninstall` menu AND the full teardown — no other wiring exists.
# Best-effort, idempotent, and it must refuse anything the kit does not
# manage (see exasol_vscode_uninstall for the pattern).
my_tool_uninstall() {
    _dry="${1:-0}"
    # rm the kit-managed artifacts; then:
    # manifest_del components.my_tool; manifest_del desired.my_tool
    return 0
}

# OPTIONAL — only for an add-on that extends a host application. Return
# non-zero when the host is absent and the add-on is hidden everywhere instead
# of being offered and then failing (see exasol_vscode_applicable).
# my_tool_applicable()        { command -v the-host-app >/dev/null 2>&1; }
# my_tool_applicable_reason() { printf '%s\n' "the host app was not found"; }

# OPTIONAL — only for an add-on that RUNS as a service. Defining these four
# folds it into `exakit status`, `exakit start`, `exakit stop` and the boot
# entries (`exakit autostart`) with no wiring anywhere else.
# my_tool_status()            { ... }   # running | stopped | not installed
# my_tool_start()             { ... }   # background it, wait until it answers
# my_tool_stop()              { ... }   # bounded, idempotent
# my_tool_autostart_command() { ... }   # what the boot entry runs
# my_tool_log_path()          { ... }   # what `exakit logs my-tool` shows

# OPTIONAL: sharpen "already on this system" detection beyond the default
# check (the id AND the launcher's basename from EXAKIT_MY_TOOL_BIN on PATH),
# e.g. an import probe for PATH-less pip installs (see json_tables_system_present).
# my_tool_system_present() { ... }

# OPTIONAL — only when "installable" is stricter than "released upstream".
# json-tables is the model: the kit prebuilds its artifacts in a packaging
# workflow, so what CAN be installed is what that workflow has published, not
# what upstream tagged. The generic upstream lookup calls this hook first.
# my_tool_latest() { ... }   # print the newest INSTALLABLE version
```

**`setup/lib/my-tool.ps1`** — the twin. Same shape with the house verbs
(`Install-MyTool`, `Test-MyTool`, `Update-MyTool`, `Get-MyToolInstalledVersion`,
`Write-MyToolNotInstalled`) and its own
`$script:MyToolVersionFallback = if ($env:EXAKIT_MY_TOOL_VERSION_FALLBACK) { $env:EXAKIT_MY_TOOL_VERSION_FALLBACK } else { "1.0.0" }`.

Hard rules for both files (CI enforces them):

- bash stays **3.2**-compatible (macOS default); PowerShell stays **5.1**-
  compatible (no ternary, no `??`).
- The `.ps1` is **pure ASCII** — no em dashes, no box-drawing glyphs
  (`tests/ps-encoding-guard.sh` scans every `.ps1` automatically).
- Install failures are **soft** (warn + `validated=false` + return non-zero),
  never `die` — the marketplace and the closing offer run best-effort.
- Secrets never land in generated files: bake credential-file *paths* into a
  launcher and read them at run time (see `dash_server_write_launcher`).

### 2. Add the versions.json block

```json
"my-tool": {
  "version": "1.0.0",
  "repo": "exasol-labs/my-tool",
  "severity": "normal"
}
```

`repo` for a GitHub-release-installed tool, `package` for a PyPI one — that
field is what the generic upstream lookup (`EXAKIT_VERSION_POLICY=latest`) and
the auto-bump workflow read. Keep the file canonical: `python3 -m json.tool
--indent 2` output, LF-only (CI diffs it).

### 3. Add one registry line each side

`setup/lib/common.sh`, in `exakit_marketplace_addons`:

```bash
printf '%s\n' "my-tool|my-tool (short label)"
```

Two fields, and no description: the one-liner the menu shows is the **About
field of your add-on's own repository**, fetched and cached at runtime (step 4).
Typing a description here is the drift this replaced — it used to be spelled out
in both registries and in the help document, and the three disagreed.

`setup/lib/exakit-common.ps1`, in `Get-ExakitMarketplaceAddons`:

```powershell
[pscustomobject]@{
    Id          = "my-tool"
    Label       = "my-tool (short label)"
    InstallFn   = "Install-MyTool"
    ValidateFn  = "Test-MyTool"
    UpdateFn    = "Update-MyTool"
    VersionFn   = "Get-MyToolInstalledVersion"
    EnvVar      = "EXAKIT_MY_TOOL_VERSION"
    FallbackVar = "MyToolVersionFallback"
}
```

### 4. Ship a help document — and with it, the description

`setup/help/my-tool.json`, alongside the other components' documents. Two of its
fields carry the marketplace:

```json
{
  "schema_version": 1,
  "id": "my-tool",
  "kind": "addon",
  "title": "my-tool",
  "tagline": "What it does, in one clause.",
  "repo": "exasol-labs/my-tool"
}
```

`repo` is where the About is read from — `https://api.github.com/repos/<repo>`,
resolved offline from this document, so a machine with no network still knows
which repository owns the wording. `tagline` is the help screen's own header
line, and it doubles as the answer when the About cannot be reached.

The description therefore needs no maintenance in this repository: write the
one-liner in your add-on's GitHub About and the marketplace picks it up within a
day (`EXAKIT_ABOUT_TTL`, default 86400s). What the kit does to that text before
printing it is not negotiable, though — it is prose from a repository the kit
does not control, so escape sequences and control bytes are stripped, it is
collapsed to one line and capped, on the way into the cache. Keep the About
short: the column is 44 characters and anything longer is truncated on a word
boundary.

Skipping this document is allowed — the row then reads
`Details: exakit help my-tool` — but the screen is worse for it.

### The CI guards (same PR, mechanical)

| File | Change |
|---|---|
| `.github/workflows/versions.yml` | Add `"my-tool"` to the `expected = {...}` components set; add an upstream-exists stanza (assert the release tag / PyPI version is real) |
| `.github/workflows/versions-bump.yml` | Add a `COUPLED` entry pointing at the module files' fallback constants; for a GitHub-release tool, add a bump stanza (copy the dash-server one) |

### What you do NOT touch

The registry line is the switch. The Description column and the checkbox
label's one-liner (both come from the About, cached, with the tagline behind
them), menu row, closing-offer row, presence detection, `exakit update my-tool`, `update all` gating (installed only),
update-check row + discovery line, `exakit version` line,
`EXAKIT_MARKETPLACE_ADDONS` parsing, uninstall sweep of the launcher and the
kit-home state — all generic. `tests/marketplace.sh` asserts `common.sh`
carries **zero** per-add-on case arms, so a regression back to hand-wired
arms fails CI.

---

## Verifying

```bash
bash tests/marketplace.sh        # registry, gating, offer, non-interactive contract
bash tests/dry-run-matrix.sh     # .sh/.ps1 twin parity guards
bash tests/ps-encoding-guard.sh  # the new .ps1 is pure ASCII
bash tests/versions-manifest.sh  # versions.json contract (add your components.my-tool.* paths to the reader-parity list)
bash tests/marketplace-e2e.sh    # sandboxed end-to-end: real install, update flow, uninstall
```

For the new add-on itself, extend `tests/marketplace.sh` sparingly (the
generic layer is already covered — test only what is unique to your module,
e.g. its launcher or validation quirks), and consider a stanza in
`tests/marketplace-e2e.sh` if the tool can prove itself end to end without a
database.

Manual smoke, safely sandboxed:

```bash
EXAKIT_HOME=$(mktemp -d) EXAKIT_BIN_DIR=$(mktemp -d) EXAKIT_MARKETPLACE_ADDONS=my-tool bash setup/exakit marketplace
```
