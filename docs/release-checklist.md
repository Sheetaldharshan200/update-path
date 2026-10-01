# Release checklist

What has to be true before a kit version is tagged, and the tool that proves
each line. The gates run on every push (`.github/workflows/quality.yml`); the
tagging run adds `--strict` and the scratch-machine install.

## 1. The gates, in order

| # | Gate | Proof | Where it fails the build |
|---|---|---|---|
| 1 | The coding standard: modules at most 400 lines, functions at most 40, cyclomatic complexity at most 12, layers point down only, process/network/files/environment only in `adapters/`, standard library only, the shell layer ASCII | `python3 tools/check_standard.py` | quality: coding standard and lint |
| 2 | The lint, on the SonarQube-aligned rule set (`ruff.toml`), clean | `ruff check exakit mcp tests tools` | quality: coding standard and lint |
| 3 | The shell layer parses and shellcheck is quiet at warning level | `sh -n`, `shellcheck -s sh -S warning` | quality: coding standard and lint |
| 4 | Every suite green on Linux (Python 3.11 and 3.12), macOS and Windows: unit, contract, scenarios, e2e, mcp, sample-data | `python3 tools/run_tests.py --coverage` | quality: tests (matrix) |
| 5 | The bootstrap and the launcher parse under Windows PowerShell 5.1 | quality: tests (windows-latest) | same |
| 6 | Coverage of `exakit/` and `mcp/` at or above the gate in `tools/qa_report.py` | `reports/coverage.xml` | quality: QA report |
| 7 | Versions agree: `exakit.__version__`, `versions.json`, the what's-new card, `sonar-project.properties`; launchers byte-identical; every command documented and handled; the catalog valid; add-on fallbacks equal to the pins; no attribution; no secrets; every variable the code reads documented | `python3 tools/release_check.py` (`--strict` when tagging: the CHANGELOG section must carry the version) | quality: release gate |
| 8 | The real install on a scratch machine: install with a persona, status running, the agent commands, a second run that skips every step, stop/start/update/data-load, uninstall | `gh workflow run real-install.yml` | real install (ubuntu-latest); macOS proves everything but the database |
| 9 | The QA report assembled from every job, attached to the run | `python3 tools/qa_report.py --from artifacts/` | quality: QA report |
| 10 | SonarQube quality gate (when `SONAR_TOKEN` is set) | `sonar-project.properties` | quality: SonarQube |

## 2. The manual rows

From [test-and-acceptance.md](test-and-acceptance.md) section 4: M-1 and M-2
on a developer machine, M-3 through the real-install workflow, M-4 on a
0.2.0 install, M-5 on Windows 11. Record the outcome in that table in the
same commit as the tag.

## 3. Tagging

1. `python3 tools/run_tests.py --coverage && python3 tools/check_standard.py && python3 tools/release_check.py --strict`
2. Rename the `## Unreleased` section of `CHANGELOG.md` to the version and date; add the what's-new card if it is missing.
3. Copy `reports/qa-report.md`, `reports/test-report.md` and `reports/release-check.md` to `docs/reports/` and commit them with the tag.
4. `gh workflow run real-install.yml --ref main`, wait for ubuntu-latest to pass, attach its artifact to the release notes.
5. Tag, push the tag, publish the release; `versions.yml` then re-verifies the pins.

## 4. Where this work lives, and how it moves

`Sheetaldharshan200/exakit-v0.3.0` is the working copy with the full CI. It
carries the whole update-path history, so it merges with update-path by
ancestry, but GitHub treats it as a standalone repository (a repository
cannot be turned into a fork after the fact). The branch that pull requests
and merges go through is therefore on the real fork:

| Remote (in this checkout) | Repository | Role |
|---|---|---|
| `origin` | `Sheetaldharshan200/exakit-v0.3.0` | the working copy; `main` is what the CI runs |
| `fork-update-path` | `Sheetaldharshan200/update-path` | the fork of upstream; branch `python-kit` mirrors `origin/main`; the PR is `main <- python-kit` there |
| `upstream-update-path` | `krishna-exasol/update-path` | upstream, fetched only; never the target of a pull request |

- **Take upstream's changes:** `git fetch upstream-update-path && git merge upstream-update-path/main`. The shell files upstream still edits are gone here; a conflict on one of them is resolved by `git rm` and by carrying the change into the Python kit (the changelog says where).
- **Publish:** `git push origin main && git push fork-update-path main:python-kit`; the draft PR on the fork updates itself.
