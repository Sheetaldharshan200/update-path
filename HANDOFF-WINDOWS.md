# Session handoff — Windows / WSL verification

**Read this first if you are a Claude Code session on the Windows laptop.**

This file exists for one reason: a long run of UI and copy changes was made on a
**macOS** machine that has **no PowerShell installed**. The `.ps1` half of this
kit was written but never once executed. You are the first place it runs.

Delete this file once the verification pass is done — it describes a moment, not
the project. The durable documents are `AGENTS.md` (the agent runbook),
`CLAUDE.md` (coding rules for this repo) and `CONTEXT.md` (the product language
glossary — use its terms in anything user-facing you write). This file is
scaffolding.

---

## 1. The two repos

| Repo | Role |
|---|---|
| `krishna-exasol/update-path` | development fork — **all work happens here**, `origin` |
| `exasol-labs/plg-starter-kit` | private mirror of the same code, kept in sync by pushing `main` |
| `exasol-labs/exasol-personal-local-starterkit` | production. **Never open a PR here without asking Krishna first.** |

Docs and install commands in this fork deliberately point at the fork's own URLs
so testing installs the code under test. That is intentional — do not "fix" the
links to point at production.

---

## 2. Hard constraints (these break the build if violated)

- **Shell must stay bash 3.2 compatible** — the macOS system bash. No `declare -A`,
  no `${var^^}`, no `mapfile`.
- **PowerShell must stay 5.1 compatible** — no ternary `? :`, no `??`. This is
  enforced only by a *grep*, so it catches syntax but proves nothing about behaviour.
- **`setup/lib/*.sh` and `setup/lib/*.ps1` are twins.** Change a function in one,
  mirror it in the other. They are not a strict 1:1 map — some helpers live in
  different files on each side.
- **No AI attribution** in commits, PRs, code or docs.

---

## 3. What is actually verified, and what is not

This is the important section. Be precise about this when reporting.

**Never executed anywhere, by anything:**

- `setup/setup-windows-docker.ps1` — the Windows installer itself. 82 lines
  changed this session.
- Every `.ps1` under real **Windows PowerShell 5.1**. CI has **no Windows runner
  at all.**
- A real end-to-end install. `tests/smoke-test.sh` is dry-run unless
  `EXAKIT_SMOKE_FULL=1`, which CI never sets.

**Partly verified:**

- CI runs `pwsh` **7 on Ubuntu** for exactly two suites:
  `tests/noninteractive-answers.ps1` and `tests/uninstall-ps.ps1`. That is
  pwsh 7 on Linux — not 5.1 on Windows.
- Everything else about the `.ps1` files is checked by *text-scanning* guards that
  read them as strings: `tests/ps-table-twin.sh`, `tests/ps-encoding-guard.sh`,
  `tests/lib/ps-uninstall-calls.sh`. These catch drift between the twins and
  unbalanced braces. They cannot catch a runtime error.

**Well verified:** the bash side. All CI suites pass on `ubuntu-latest` and
`macos-latest`, and the macOS install path was exercised by hand repeatedly.

So: **a NameError-class bug in any `.ps1` would have shipped.** That is what you
are looking for.

---

## 4. What changed this session — PRs #169 to #191

23 PRs, all merged to `main` on 2026-09-01. Grouped by what they touched:

**Installer output brevity (steps 1–6).** Each step now narrates on one line
using a spinner instead of printing four to six. Implemented with a quiet flag —
`EXAKIT_QUIET_DETAIL` / `$script:ExakitQuietDetail` — that routes `info`/`ok` to
the logfile while a step is running. `warn` and `error` are deliberately **not**
gated. New primitives that bypass the flag: `ok_step`/`info_step` (shell),
`OkStep`/`InfoStep` (PowerShell), and `heading`/`Write-ExakitHeading`.

**The table component (`ui.sh` / `ui.ps1`, ~300 lines each side).** The largest
and riskiest surface:
- Rows are one line each; the old two-line phase sub-line is gone.
- Two optional columns, `COL2`/`COL3`, appended **last** in the row format so old
  ten-field rows still parse.
- Descriptions **wrap** rather than truncate — `_ui_wrap` / `Split-ExakitWrap`,
  a fork-free greedy wrap that hard-breaks over-long words.
- The tree spine (`├─`, `└─`) now carries down continuation lines of a wrapped
  description; only a tee continues it, since after the corner the tree has ended.
- Rules between columns were added and then removed — the gap is two plain spaces.
- The width decomposition was corrected; the old `11 + name + status + 3` folded
  a gap into the constant and broke once a third column existed.

**Commands removed.** `exakit mcp-validate`, `mcp-remove`, `mcp-restore` are gone
from both sides — deliberate, not an oversight.

**Commands reshaped.** `exakit autostart` is now a single command: it shows the
current state and asks one yes/no question (`EXAKIT_AUTOSTART_CHANGE` pre-answers
it for automation). `exakit repair-runtime` now exports `EXAKIT_REUSE_DB=0`, which
makes the Nano path remove the container **and its volume**. `exakit version`,
`exakit info`, `exakit status`, `exakit catalog` and `exakit help` all had rows or
lines removed.

**Deploy phase labels.** The progress line's phase cell is 30% of the width — 21
columns at 80, 27 at 100, capped at 33. `Getting the Exasol database ready` (33)
was ellipsed on all but the widest terminals and is now `Getting Exasol ready` (20).
Every other phase was shortened to match, so the whole set is 8 to 21
characters and none truncates at any supported width; a guard in
`tests/deploy-progress.sh` measures them and fails on the next one that does not
fit. macOS-only by nature: the Nano runtime reports no progress phases at all.

**Test suites.** Brought from 8 failing to green on both runners, and several
suites that existed but were never wired into CI are now wired in — including the
`mcp/` package's own unittest suite, which meant nothing exercised `mcp/` at all.

---

## 5. What to test here, in priority order

Highest value first — this ordering is by *(lines changed × never executed)*.

1. **The Windows install, end to end.** `setup/setup-windows-docker.ps1`. This has
   literally never run. Watch the step output: each step should narrate on one
   line, and warnings must still appear (they are not gated by the quiet flag).
2. **The marketplace menu.** `exakit marketplace`. This exercises the whole table
   component: three add-ons in a tree, a Version column, and a Description column
   that wraps to multiple lines. Check specifically:
   - the tree spine is **unbroken** from the first add-on to `└─` at the last,
     including alongside a description that wraps;
   - no vertical rule between columns;
   - the box borders line up on every row;
   - it still redraws cleanly when you move the selection.
3. **`exakit mcp-setup`** — `mcp.ps1` had the largest diff of any file (394 lines).
   Run it for at least two clients and confirm the summary panel is right.
4. **`exakit status`, `info`, `version`, `catalog`, `help`** — all had rows removed;
   confirm nothing prints an empty panel or a stray separator.
5. **`exakit autostart`** — should take **no** arguments, show current state, ask
   one yes/no. Passing `on` or `off` must fail with a clear message.
6. **`exakit repair-runtime`** — should replace the Nano container *and* its
   volume, then redeploy. This is destructive to database data by design.
7. **`exakit uninstall -y`** — the uninstall path had its own quieting pass.

**On WSL** run the bash side: `setup/setup-wsl.sh`, then the same commands. WSL and
Windows share the Nano container runtime but not the installer.

---

## 6. Running the suites

The bash suites need WSL (or Git Bash); the PowerShell suites need `pwsh`.

```bash
# In WSL, from the repo root — the full set CI runs:
for t in ps-encoding-guard versions-manifest dry-run-matrix noninteractive-answers \
         marketplace uninstall skills agent-operability reap-orphan-daemon \
         deploy-progress bulk-folder-load dataset-load-progress \
         install-output-brevity ps-table-twin checkbox-group menu-hint \
         mcp-status-clients status-soft-components install-payload \
         uninstall-addons-only whats-new smoke-test; do
  echo "== $t"; bash tests/$t.sh || echo "FAILED: $t"
done
bash tests/lib/ps-uninstall-calls.sh
python3 -m unittest discover -s mcp/tests -t .
python3 tests/test_sample_data_schema.py
```

```powershell
# In PowerShell:
pwsh -NoProfile -File tests/noninteractive-answers.ps1
pwsh -NoProfile -File tests/uninstall-ps.ps1
```

`tests/ps-table-twin.sh` is the guard that keeps `ui.ps1` in step with `ui.sh` —
if you change one side of the table component, it will tell you what the other
side is missing.

---

## 7. Workflow rules Krishna has set

- **Do not run the full suite before raising a PR.** Fix what was reported, raise
  the PR, merge it. Test failures get swept at the end. (Targeted single-suite runs
  are fine and encouraged.)
- **Every fix ships a regression guard**, and the guard is verified by *actually
  reverting the fix* and watching it fail.
- **Never PR from `main`** — always a branch. PRs go to the fork.
- **Mirror after merging:** `git push plg main:main` where `plg` is
  `https://github.com/exasol-labs/plg-starter-kit.git`. Check it is a
  fast-forward first (`git merge-base --is-ancestor plg/main main`).
- For UI and copy changes, **get the exact rendered text approved before writing
  code**, and keep the change to what was asked.
- PRs are for significant improvements — state the measured win, or say it is not
  worth a PR.

---

## 8. Open items, and things that are deliberate

Not bugs — do not "fix" these without asking:

- The MCP health row was removed from `exakit status`; `exakit mcp-doctor` is now
  the only place a warning surfaces. Flagged to Krishna, awaiting a decision.
- Step 6 no longer mentions the login autostart anywhere on screen. Same.
- Em dashes are **not** to be swept from the codebase — two lines match them as
  patterns and a sweep would break them.
- Existing installs need `exakit update exakit` to pick up the help-corpus change.
- `~/Downloads/exakit-feedback-tasks.html` is a status page for Krishna's
  visibility. It lives on the Mac and is a few cards behind.

---

## 9. If you need more detail

The full macOS session transcript is at:

```
~/.claude/projects/-Users-krishna-appili-krishnaDev-update-path/6623d6fa-30f3-4338-b28f-361b20e6c664.jsonl
```

That path is on the **Mac**, not this machine. If something here is ambiguous,
ask Krishna rather than guessing — he was in the loop for every change above.
