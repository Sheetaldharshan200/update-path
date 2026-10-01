# 0007: The shell tree is deleted; shell survives only in the bootstrap

Date: 2026-09-30. Status: accepted.

## Context

Phases A to C ported every `exakit` command to Python behind the same command
word and the same `--json` contracts. `setup/lib` (about 53,000 lines of Bash
and PowerShell twins), the two legacy CLIs, the three setup scripts and the
forty-odd shell test suites that exercised them were still on disk, reachable
by nothing the `exakit` word runs.

## Decision

Delete them in one commit. Keep exactly two files under `setup/`: the
launcher copies the 0.2.0 self-update installs. Move the assets the Python
kit reads out of `setup/` (`help/`, `help/whats-new.json`, `shim/`). Drop the two Kit 2 scripts
(`upgrade-kit2`, `rollback-kit2`): that add-on is not going to ship. Replace the shell CI rosters with
the three Python suites on ubuntu, macOS and Windows, and point the version
bump workflows at `fallback_version` in the catalog files.

## Consequences

- One implementation to read, fix and test. No twin drift.
- Coverage the shell suites gave to shell-only behaviour (PowerShell 5.1
  parsing, bash 3.2 guards, the table twin) is gone with the code it
  covered. What they proved about behaviour is proved by the Python suites.
- The real-machine acceptance (M-3, M-5) had not been run when this landed;
  it is the first thing to run before tagging 0.3.0.
