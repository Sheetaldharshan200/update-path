# Maintainer runbook: publishing versions

Every installed kit reads one file to decide what to install and what to offer as
an update: **`versions.json`** at the root of this repository, on `main`.

That is the whole distribution mechanism. There is no server, no release
pipeline, and no per-component ceremony — a version bump is a pull request
against a ~1 KB document, and the fleet picks it up within a day.

```json
{
  "schema_version": 1,
  "updated": "2026-07-29",
  "kit": { "version": "0.2.0" },
  "components": {
    "exapump": { "version": "0.11.2", "severity": "normal", "sha256": { ... } }
  }
}
```

## Bumping a component

1. Open a pull request that edits `versions.json`: the new `version`, the
   `updated` date, and — for exapump — the five `sha256` digests of the new
   release's assets.
2. CI checks it: the canonical formatting, the schema, and — whenever the file
   changes — two upstream checks. It **downloads the advertised exapump assets and
   verifies every digest**, and it confirms **every other advertised version
   actually exists upstream**: the nano tag on Docker Hub (and that it really
   covers both `amd64` and `arm64`, since the kit pulls the plain tag and lets the
   registry choose), the Exasol Personal release tag on GitHub, and the MCP server
   and pyexasol versions on PyPI — including a refusal if a release has been
   **yanked**. A typo, or a version withdrawn after you published it, cannot reach
   users.
3. Merge. Installs pick the new version up immediately; existing machines see it
   in `exakit version` within `EXAKIT_VERSIONS_TTL` (a day by default).

No tag, no release, no kit change. Tags exist only for kit-script releases (see
below).

### The formatting is an interface, not a style choice

On a machine with no Python runtime, the kit reads this file line by line with
`awk`. That is why CI pins the canonical form: 2-space indent, one key per line,
LF endings, and `"version"` before any nested object inside a block. `python3 -m
json.tool --indent 2` produces exactly what is required.

## Letting the bump PR write itself

`.github/workflows/versions-bump.yml` can do step 1 for you. On a schedule it
checks each upstream, and if anything moved it rewrites `versions.json` on one
reusable branch (`chore/versions-bump`) and opens — or updates — a single pull
request. It never merges, never touches `main`, and its PR goes through the same
review and the same CI as one you write by hand.

| Knob | Where |
|---|---|
| On / off | Repository variable `EXAKIT_AUTO_BUMP` (Settings → Secrets and variables → Actions → Variables). `true` runs the schedule; delete it and nothing happens. |
| How often | The `cron:` line in that file. UTC. |
| Run it now | Actions tab → Run workflow. Works whether or not the variable is set. |

What it will and will not do:

- **Stable releases only.** Release candidates, betas, dev builds and
  arch-suffixed container tags are ignored. A nano tag has to carry both `amd64`
  and `arm64` to be considered at all.
- **Recomputes the exapump digests** from the downloaded assets. If any asset
  cannot be fetched it abandons the exapump bump rather than publish stale digests.
- **Sets `severity` to `normal`** on anything it bumps and **drops a stale `note`**
  — urgency is your judgement, and a note written about an older version does not
  describe the new one.
- **Never lowers a version**, and says so in the PR when it leaves something alone
  (an unreachable upstream, or a version shape it does not recognise).

It cannot know whether the set works *together*. That is what the checklist in its
PR body is for.

## Severity: what interrupts people

`severity` is your judgement about urgency, and it is the only thing that lets a
version bump interrupt someone who was doing something else.

| Value | Effect |
|---|---|
| `normal` (or absent) | Shows in `exakit version`. Nothing else. Nobody is interrupted. |
| `recommended` | Adds a once-a-day line on `stderr` after unrelated commands. |
| `critical` | The same line, worded as critical. |

Use `normal` for routine bumps. The notice is a budget: spend it and people stop
reading it.

## Withdrawing a faulty release

**The kit never moves a component backwards.** Lowering the advertised version is
not a rollback lever: machines already on the higher version show the lower number
in the `Tagged` column and an action of `none`, and both `exakit update`
and an explicit `exakit update` leave them alone. There is no
confirmation to give and no env override to set. A user who upgraded a component
themselves keeps what they chose.

So to withdraw a bad release, **publish a higher version** — the fixed build, or
a re-release of the known-good one under a new number — and say why:

```json
"exapump": {
  "version": "0.13.1",
  "severity": "critical",
  "note": "0.13.0 mis-detects CSV headers; 0.13.1 restores the 0.12.0 behaviour."
}
```

Lowering the number still has one legitimate use: correcting a version that was
published in error and that nobody has installed yet. Machines that never took
the bad build simply see the corrected one.

`note` is one line and appears verbatim under the row. It is the only place you
get to explain yourself, so say what broke and what to do.

## Blocking an incompatible component

`min_kit_version` on a component means "this needs at least that kit". Machines
below it are told to update the kit first, and the apply path refuses too, so an
incompatible pair cannot be installed by either route.

## Releasing kit scripts

Kit scripts (everything under `setup/`, `upgrade/`, `mcp/`) ship differently: the
kit copies itself from `main`.

1. Merge the script changes.
2. Bump `kit.version` in `versions.json` in the same pull request, or right after.
3. `exakit update` then downloads `main`, validates the staged copy
   (including that `versions.json` is present), keeps a backup, and swaps it in.

Two things to respect:

- **Never rename or delete the files on the staged-validation list**
  (`setup/exakit`, `setup/lib/common.sh`, `setup/lib/runtime-nano.sh`,
  `setup/lib/runtime-personal.sh`, `setup/lib/exapump.sh`, `setup/lib/mcp.sh`,
  `setup/exakit.ps1`, `setup/lib/exakit-common.ps1`). Kits in the field validate
  exactly those paths and refuse an archive that is missing any of them.
- The raw endpoint can serve a newer `versions.json` than the branch archive for
  a few minutes after a merge. The kit handles it: it records the version that
  actually landed and says the manifest was ahead. Nothing to do, just do not be
  surprised by it.

A GitHub **release tag** is still cut for milestones — v0.1.0 field kits only know
how to self-update from tags, so the release that carries the manifest-based
update model must be tagged.

## Which repository this kit points at

One slug decides where the install command downloads from, where `versions.json`
is fetched, and where `exakit update` self-updates from. It has a baked
default in four places, because the installers bootstrap before any library is
available to ask:

| File | Constant |
| --- | --- |
| `install.sh` | `EXAKIT_REPO` |
| `install.ps1` | `$Repo` |
| `setup/lib/common.sh` | `EXAKIT_KIT_REPO` |
| `setup/lib/exakit-common.ps1` | `$script:KitRepo` |

The same slug is written into the install commands in `README.md`,
`QUICKSTART.md`, `AGENTS.md`, `quickstarts/*.md` and
`skills/local-agent-ready-starter/SKILL.md`.

Retarget all of it in one sweep — a fork, for end-to-end testing of the install
and update paths against real releases. It runs in either direction; set `FROM`
to whichever slug the tree currently carries:

```bash
FROM=krishna-exasol/update-path
TO=owner/fork
git grep -l "$FROM" -- ':!tests' ':!MAINTAINERS.md' \
  | xargs perl -pi -e "s{\Q$FROM\E}{$TO}g"
```

Two rules:

- **The tests must never hardcode the slug.** They read `$EXAKIT_KIT_REPO`, so a
  retarget is a code-and-docs change and no test needs touching. Keep it that way.
- **A pull request to the canonical repository must carry the canonical slug.**
  Run the sweep in reverse before opening it, and check `git grep` comes back
  empty for the fork's name outside `tests/`. A fork slug merged upstream would
  point every new install at the fork.

`EXAKIT_REPO=owner/repo` overrides the default per command, which is enough for a
one-off install, but not for the update paths — `exakit update` on an installed
kit reads the baked constant, so testing those needs the sweep.

## Enabling the Kit 2 add-on

Kit 2 is invisible until `versions.json` carries a `kit2` block. Absence is the
launch switch: no block means no discovery line, no row, and no update target,
anywhere in the CLI. Adding the block — once the `advanced/` assets actually ship
in the kit — is the enablement, and it is deliberately a reviewed change.

```json
"kit2": {
  "version": "0.1.0",
  "min_kit_version": "0.2.0",
  "severity": "normal",
  "note": "Trusted AI Workflow add-on"
}
```

Note that `tests/versions-manifest.sh` asserts the shipped file advertises no Kit
2. Updating that expectation is part of the same pull request that turns it on.

## Adding a marketplace add-on

Optional tools live behind `exakit marketplace`, never in the install flow, and
the component registry handles them generically — no case-statement edits on
either platform. **[MARKETPLACE.md](MARKETPLACE.md) is the full walkthrough,
with skeleton code for both module files.** One pull request adds:

1. **The module pair** `setup/lib/<id>.sh` + `setup/lib/<id>.ps1` (model:
   `dash-server.*`). The bash side defines `<id>_install`, `<id>_validate`,
   `<id>_update` and `<id>_installed_version` (dashes flipped to underscores)
   plus its own `EXAKIT_<ID>_VERSION` / `EXAKIT_<ID>_VERSION_FALLBACK`
   constants; the PowerShell side names its functions in the registry entry.
   Keep the `.ps1` pure ASCII (`tests/ps-encoding-guard.sh` enforces it).
2. **A `components.<id>` block in versions.json** — `version`, `severity`, and
   `repo` (installed from a GitHub release) or `package` (from PyPI); that
   field is what the generic upstream lookup and the auto-bump read.
3. **One registry line each side**: `exakit_marketplace_addons` in
   `setup/lib/common.sh` and `Get-ExakitMarketplaceAddons` in
   `setup/lib/exakit-common.ps1`. Both entries carry the id, a label, and the
   one-line description shown in the menu and the closing offer.

The CI guards move in the same PR: the expected-components set in
`.github/workflows/versions.yml`, an `upstream-exists` stanza there (assert
the advertised release tag / PyPI version is real), and the COUPLED
fallback-constant entry in `versions-bump.yml` pointing at the module files.
From then on the bump automation tracks the add-on's releases like every
other component, and everything user-facing — menu row, post-install offer,
update flow, uninstall sweep — picks the add-on up from the registry line
with no further wiring.

## json-tables: one immutable release per build

json-tables is the one component the kit packages itself. Its release model is
different from every other component's, and it is worth knowing why.

- `.github/workflows/pkg-json-tables.yml` builds the ingest engine for every
  platform, the wheel and the Windows cargo shim, and publishes them as **one
  release per build**, tagged `json-tables-<upstream version>` (a forced
  rebuild of the same upstream version gets `-2`, `-3`, ...). **A published
  release is never rewritten**: the workflow refuses to touch an existing tag.
- The same run then opens a pull request that writes the **whole pin** into
  `components.json-tables`: `version`, `release` (the exact tag), `wheel` (the
  real filename) and a `sha256` map keyed by platform. Nothing else in the kit
  decides what gets installed — the module reads that block and only that.
- CI (`upstream-exists` in versions.yml) refuses the pull request unless the
  named release exists, carries every pinned asset, and each asset's published
  digest equals the pinned one. A hand edit that gets any of it wrong cannot
  merge.

The consequence you rely on: an upstream json-tables release changes nothing
for anyone until the advertise pull request merges. New installs keep pulling
the previous release, which still exists byte for byte, and every pinned
digest keeps verifying. (The earlier single rolling tag broke exactly here —
publishing v0.3 overwrote the v0.2 binaries while versions.json still pinned
their digests, and every install of the add-on failed on checksum until the
pins were fixed by hand.) Never publish to a fixed tag again, and never edit
the json-tables digests by hand: re-run the workflow with `force` and merge
the pull request it opens.

## What users see, and what you can rely on

- Nothing about versions can break a command. Resolution degrades from a fresh
  fetch, to the cached copy, to the copy that shipped with the installed kit, to
  compiled-in fallbacks.
- An unreadable or newer-schema document is refused rather than guessed at, and
  the fallbacks take over.
- A user's own `EXAKIT_*_VERSION` outranks anything you publish, on install and on
  update. That is intentional.
- Cost to you: one ~1 KB request per machine per day against GitHub's raw
  endpoint. Nothing is collected, and nothing needs operating.
