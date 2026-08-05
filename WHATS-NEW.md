# What's new

The kit prints the section for your version after an update. Read one any time
with `exakit whats-new`, or a specific one with `exakit whats-new 0.2.0`.

Keep the heading format exactly as it is — `## <version>`, nothing else on the
line. The CLI finds a section by matching that line, so a decorated heading is a
section nobody will ever see.

Start each section's headline changes as a **list**: an installer that moves the
kit version draws a "What's new" box at the end of the run, and it puts the list
items of every version it crossed in that box, one line each. Prose and tables are
left for the full section — so anything that has to survive the upgrade summary
belongs in a bullet.

## 0.2.0

Updates now come from a published list of tested versions instead of asking each
project what its newest release is. The kit reads that list, tells you what is
behind, and applies it without touching your data.

**New commands**

| Command | What it does |
|---|---|
| `exakit update-check [what]` | Compares what is installed against the tested set, with a severity column and the exact command for each row |
| `exakit update [what]` | Applies the tested versions. A database (runtime) change stops the database, so it asks first — `Stop the database and update the runtime now? [y/N]` — and on yes stops it, updates it and brings it back up. A run with no terminal defers it instead of stopping anything; `--yes` opts in |
| `exakit whats-new [version]` | This text |
| `exakit upgrade-kit2` / `rollback-kit2` | Adds or removes the Trusted AI Workflow assets, once they are published |

**Changes**

- `exakit version` reads the versions that are **actually installed** — pyexasol,
  the MCP server, exapump and the runtime are probed on disk, not recalled from
  the install record. Where the two disagree, both are shown, because a component
  you upgraded yourself is still yours.
- The install date is shown in your own timezone, as `July 30, 2026 at 4:53 PM`.
- A pending update is announced after any command, on stderr and never in a log
  or a pipe. `EXAKIT_NO_UPDATE_NOTICE=1` silences it;
  `EXAKIT_NOTICE_INTERVAL=86400` throttles it to once a day.
- **The kit never moves a component backwards.** If you are ahead of the tested
  set, the row says so and nothing is offered. There is no downgrade to confirm.
- A component that fails to install no longer ends the run. The database, the MCP
  server and the `exakit` command still land, and the end of the install names
  what is missing with the one line that repairs it.
- `exakit update exakit` updates the kit itself, on Windows too.
- A starting Docker Desktop can no longer make `exakit version` sit in silence:
  the engine probes give up after 8 seconds and fall back to the record.
- `exakit mcp-doctor` ends with the command that fixes what it found.
- An installer run that moves the kit version ends with a "What's new" box, under
  the connection details, listing what changed in every version it crossed. A
  first install and a re-run at the same version say nothing.

**For maintainers**

Publishing a version set is a pull request against `versions.json`, described in
`MAINTAINERS.md`. CI verifies the exapump digests against the real release assets
and checks that every advertised version exists upstream. A scheduled workflow can
open the bump pull request for you.
