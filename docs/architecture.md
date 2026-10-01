# High-level architecture (proposal for approval)

Status: DRAFT for review. Nothing below is implemented. Low-level design starts
only after this document is approved.

## 1. Goal

One implementation of the Exasol Starter Kit lifecycle, readable and
maintainable by one team, that:

- installs with one command on macOS, Linux, WSL and Windows;
- ships no compiled binary of our own (Defender, WDAC, firewall);
- bootstraps its own Python first, then does everything in Python;
- keeps every published contract: `exakit` commands, `--json` shapes,
  exit codes 0/1/2/3/4/5, `EXAKIT_*` env answers, `manifest.json`,
  `versions.json`;
- arrives on existing installs through `exakit update`;
- makes a persona, an add-on and a new interactive screen each a one-place change.

## 2. The rule that shapes everything

```
Shell exists only until Python exists.  After that, Python owns the kit.
```

The Bash and PowerShell files shrink to one job: get a managed Python onto
the machine and hand over. They never again implement install, update,
marketplace, manifest, status or UI logic.

## 3. Layers

```
+-----------------------------------------------------------------------+
|  bootstrap  (per OS, tiny, no logic)                                  |
|  install.sh  install.ps1  bootstrap/ensure-python.{sh,ps1}            |
|  = preflight, download kit, install uv + CPython, exec `exakit`       |
+-----------------------------------+-----------------------------------+
                                    | python -m exakit <command>
+-----------------------------------v-----------------------------------+
|  cli      argparse; one module per command; --json; exit codes        |
|           (presentation only: parses, calls a use case, renders)      |
+-----------------------------------+-----------------------------------+
|  ui       renderers for the SAME result objects:                      |
|           plain (no tty), ansi (today's look), tui (Textual screens)  |
+-----------------------------------+-----------------------------------+
|  app      use cases = plan -> confirm -> apply -> verify -> record     |
|           install, update, status, marketplace, persona, mcp,         |
|           data, skills, runtime, uninstall                            |
+-----------------------------------+-----------------------------------+
|  domain   pure Python, no IO: Manifest, Versions, Catalog, Component,  |
|           Addon, Persona, Plan, Step, Result, exit-code mapping        |
+-----------------------------------+-----------------------------------+
|  adapters IO boundaries, one per concern, each behind a Protocol:     |
|           platform (macos/linux/wsl/windows), runtime (Exasol         |
|           Personal), net (download, sha256, GitHub/PyPI), clients     |
|           (MCP client config files), fs (paths, atomic write, lock),  |
|           process (run, tail logs, services)                          |
+-----------------------------------+-----------------------------------+
|  data     catalog/ (components, add-ons, personas), help/, skills/,   |
|           data/datasets/, versions.json  -- JSON, validated by schema |
+-----------------------------------------------------------------------+
```

Dependency direction is strictly downward: `cli -> ui/app -> domain`,
`app -> adapters (via Protocols) -> OS`. `domain` imports nothing above it
and nothing from `adapters`. That is what makes it testable without a
machine.

## 4. Folder structure

```
update-path/
|-- install.sh                  bootstrap (macOS, Linux, WSL): preflight, fetch kit, ensure Python, exec exakit
|-- install.ps1                 bootstrap (Windows): same four steps
|-- bootstrap/
|   |-- ensure-python.sh        the ONLY shell that knows how to get uv + CPython 3.12
|   |-- ensure-python.ps1       its Windows twin (the last twin in the repo)
|   |-- exakit                  launcher installed to ~/.local/bin: finds the managed Python, runs `python -m exakit`
|   `-- exakit.cmd              Windows launcher
|
|-- exakit/                     THE KIT (Python 3.11+, standard library only)
|   |-- __main__.py             python -m exakit
|   |-- cli/                    one file per command: status.py, install.py, update.py, marketplace.py,
|   |                           persona.py, mcp.py, data.py, skills.py, runtime.py, uninstall.py, help.py
|   |-- ui/                     render(result): console.py (plain and ansi), silent.py, tui/ (Textual, its own venv)
|   |-- app/                    use cases (plan/apply): install.py, update.py, marketplace.py, persona.py,
|   |                           mcp.py, data.py, skills.py, runtime.py, uninstall.py, status.py
|   |-- domain/                 pure models and rules: manifest.py, versions.py, catalog.py, component.py,
|   |                           addon.py, persona.py, plan.py, result.py, errors.py (exit codes live here)
|   |-- adapters/
|   |   |-- platform/           base.py (Protocol), macos.py, linux.py, wsl.py, windows.py
|   |   |-- runtime/            personal.py (Exasol Personal launcher), podman.py
|   |   |-- net/                download.py, digest.py, github.py, pypi.py
|   |   |-- clients/            MCP client config writers (today's mcp/adapters, moved)
|   |   |-- fs/                 paths.py, atomic.py, lock.py
|   |   `-- process/            run.py, services.py (launchd / systemd / Task Scheduler)
|   `-- lifecycles/             generic add-on lifecycles: python_venv.py, binary.py, host_extension.py
|
|-- catalog/                    DATA that describes the kit (no code)
|   |-- components/             personal.json, exapump.json, mcp.json, pyexasol.json, skills.json
|   |-- addons/<id>/            addon.json (+ lifecycle.py ONLY when a generic lifecycle cannot do it, + skill/)
|   `-- personas/               analyst.json, data-scientist.json, data-engineer.json, minimal.json
|-- versions.json               unchanged: the tested set the maintainers publish
|-- help/                       one JSON document per command and component (moved from setup/help)
|-- skills/                     unchanged
|-- data/datasets/              unchanged
|
|-- tests/
|   |-- unit/                   domain + app with fake adapters (fast, no machine)
|   |-- contract/               golden --json outputs and exit codes per command; the frozen contracts
|   |-- e2e/                    dry-run installs per OS, launcher, update path 0.2.0 -> new
|   `-- legacy/                 the existing shell suites, kept until the code they test is deleted
|
|-- docs/                       requirements, architecture (this), design (low-level), tasks,
|   |                           test-and-acceptance, adr/ (one decision per file)
|-- AGENTS.md README.md ...     user-facing docs, updated in place
`-- setup/                      LEGACY Bash + PowerShell. Frozen. Deleted folder by folder as the Python
                                use cases replace them (strangler migration, section 7).
```

## 5. Cross-cutting rules (apply to every module)

| Rule | Meaning |
|---|---|
| Plan, then apply | Every mutating use case first builds a `Plan` (steps with state done/pending/skipped+reason), shows it, confirms (or `--yes`), applies step by step, verifies, records. `--dry-run` is free. |
| One result shape | Every command returns a `Result` with `installed`, `status`, `remedy` (runnable command or null), plus its own fields. `--json` serialises it; the ansi renderer draws it. |
| Exit codes in one place | `domain/errors.py`: `BadInput=2`, `NotRunning=3`, `NotInstalled=4`, `NotConfirmed=5`, `Failed=1`. CLI maps exceptions to codes. Nowhere else. |
| The manifest is the only state | `domain/manifest.py` is the only reader and writer, with a schema version and forward migrations. |
| Data before code | A component, add-on or persona is a JSON file first. Code is added only for behaviour the generic lifecycles cannot express. |
| Adapters are replaceable | Every adapter is a `Protocol`; tests inject fakes. No `subprocess` or `open()` outside `adapters/`. |
| Names, never numbers | Env answers and menus use ids. Menu order is presentation only. |
| No secrets on stdout or in logs | Passwords live in credential files; results carry paths, never values. |

## 6. Bootstrap flow (the only per-OS shell)

```
curl ... | sh                         irm ... | iex
   |                                     |
   v                                     v
install.sh                            install.ps1
 1. preflight (os, arch, disk, tools)  1. same
 2. fetch kit tarball -> ~/.exasol-starter-kit/kit
 3. bootstrap/ensure-python.sh         3. bootstrap/ensure-python.ps1
    -> uv (astral installer, verified) -> managed CPython 3.12 (never the system one)
 4. exec python -m exakit install      4. same
```

`exakit` on PATH is `bootstrap/exakit` (a 20-line launcher). If the managed
Python is missing (a machine that was updated from 0.2.0 on Windows before the
MCP step ran), the launcher runs `ensure-python` first. Read-only commands
never download anything (`EXAKIT_READONLY_QUERY` rule kept).

## 7. Migration: strangler, contract-first

| Phase | Python takes over | Shell that dies | Gate |
|---|---|---|---|
| A | bootstrap, launcher, `status info version help catalog whats-new`, `persona list/show/plan` | nothing yet | `tests/contract` golden files match today's `--json` byte for byte |
| B | `marketplace`, `skills`, `mcp-*`, `data-load`, `persona apply`, `logs`, `sql` | `setup/lib/{mcp,pyexasol,help}.*`, add-on module pairs | legacy suites for those areas pass against the Python CLI, then are moved to `tests/legacy` and retired |
| C | `install`, `update`, `repair-runtime`, `migrate`, `autostart`, `uninstall` | `setup/setup-*.{sh,ps1}`, `runtime-personal.*`, `common.sh`, `exakit-common.ps1` | e2e dry-run matrix + a real install on each OS |
| D | delete `setup/` | everything | CI green with `tests/legacy` empty |

Each phase ships through `exakit update`. During A to C, one `exakit` command
dispatches to Python for migrated commands and to the legacy shell for the
rest, so users never see two tools.

## 8. Decisions to approve

| # | Decision | Alternative rejected |
|---|---|---|
| A1 | Python 3.11+, standard library only, in the core. | Third-party deps in the core (packaging, offline installs, Defender scanning 12k files on every run). |
| A2 | Managed CPython via uv, never the system Python. | System Python (Xcode stub, Store stub, version drift). |
| A3 | The interactive screens run on Textual (`ui/tui/`), installed by uv into its own venv under the kit home on the first interactive run, behind the same Renderer protocol as the console. The console renderer remains for pipes, `--json`, `EXAKIT_TUI=0`, scripted runs and any machine where Textual cannot be installed: the installer never depends on it, a failed Textual install falls back silently. Textual is never imported by the core (`exakit/ui/tui/` is the one package allowed to), so the stdlib rule of A1 holds everywhere else. (Revised 2026-10-01: was "optional and later".) | A hand-rolled full-screen UI in the core (a second toolkit to maintain); Textual in the core interpreter (a third-party package on the install path); TUI first, blocking the install path. |
| A4 | Strangler migration with golden contract tests, not a rewrite behind a flag. | Big-bang rewrite (no safe update path for existing installs). |
| A5 | Add-ons and personas are JSON in `catalog/`; code only for exceptions. | Module pairs per add-on (today's cost). |
| A6 | Only `bootstrap/` may contain OS-specific shell, and it may contain no lifecycle logic. | Keeping helpers in shell "because they are small". |
