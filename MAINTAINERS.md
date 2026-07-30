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
2. CI checks it: the canonical formatting, the schema, and (whenever the file
   changes) it **downloads the advertised exapump assets and verifies every
   digest**. A typo cannot reach users.
3. Merge. Installs pick the new version up immediately; existing machines see it
   in `exakit update-check` within `EXAKIT_VERSIONS_TTL` (a day by default).

No tag, no release, no kit change. Tags exist only for kit-script releases (see
below).

### The formatting is an interface, not a style choice

On a machine with no Python runtime, the kit reads this file line by line with
`awk`. That is why CI pins the canonical form: 2-space indent, one key per line,
LF endings, and `"version"` before any nested object inside a block. `python3 -m
json.tool --indent 2` produces exactly what is required.

## Severity: what interrupts people

`severity` is your judgement about urgency, and it is the only thing that lets a
version bump interrupt someone who was doing something else.

| Value | Effect |
|---|---|
| `normal` (or absent) | Shows in `exakit update-check`. Nothing else. Nobody is interrupted. |
| `recommended` | Adds a once-a-day line on `stderr` after unrelated commands. |
| `critical` | The same line, worded as critical. |

Use `normal` for routine bumps. The notice is a budget: spend it and people stop
reading it.

## Rolling a release back

A faulty release is withdrawn by **lowering the advertised version** and saying
why:

```json
"exapump": {
  "version": "0.12.0",
  "severity": "critical",
  "note": "0.13.0 mis-detects CSV headers; 0.12.0 is the tested build."
}
```

Users then see the row flagged `(older)`, with your note under it. Applying it
asks them to confirm — a rollback is never silent — and `EXAKIT_ALLOW_DOWNGRADE=1`
pre-answers that for scripted fleets. Digests are verified in both directions.

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
3. `exakit update exakit` then downloads `main`, validates the staged copy
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
