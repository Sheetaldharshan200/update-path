---
name: exasol-marketplace
description: Browse and install the starter kit's optional add-ons through exakit marketplace — dash-server (agent-built dashboards), Exasol for VS Code (editor extension) and JSON Tables (JSON ingestion) — including how to answer the menu non-interactively, why an add-on may not be offered at all, and how installed add-ons join the normal update and uninstall flows. Triggers — "what optional tools can I add", "exakit marketplace", "install an add-on", "add dashboards to my kit", "why is an add-on not listed", "remove an add-on", "update my add-ons".
---

# The marketplace — optional add-ons

The marketplace is where the kit keeps **optional tools**: worth having next to
the database, not worth lengthening the install for. Nothing here is ever
installed by the setup scripts.

```bash
exakit marketplace       # browse: Space selects, Enter installs
```

Non-interactively — which is how you should drive it — answer with ids:

```bash
EXAKIT_MARKETPLACE_ADDONS=dash-server exakit marketplace   # ids csv, or all / none
```

The same variable pre-answers the one-question offer that follows a successful
interactive install ("Do you want to add optional tools?").

## What is on offer

| Id | What it gives the user | Skill with the detail |
|---|---|---|
| `dash-server` | Agent-built live dashboards on the local database, driven through its own MCP control plane | `dash-server` |
| `exasol-vscode` | Exasol SQL editing and schema browsing inside VS Code | `exasol-vscode` |
| `json-tables` | Ingest, query and reshape JSON-shaped data; the engine ships prebuilt, no Rust toolchain | `json-tables` |

Each has its own skill — load that one when the user wants to *use* the tool.
This skill is about choosing and managing them.

## Why an add-on might not appear

Two independent filters run before anything is listed, and both are deliberate:

**Applicability.** An add-on that extends software the user does not have is
not offered at all — no row, no mention. `exasol-vscode` is only listed on a
machine that has VS Code. Naming it anyway explains that the host app is
missing, instead of failing deep in an installer:

```bash
EXAKIT_MARKETPLACE_ADDONS=exasol-vscode exakit marketplace
# -> explains VS Code was not found, rather than half-installing
```

**Presence.** An add-on already on the machine is never advertised again:

- installed *by the kit* → shown as `installed (vX)`
- already on the system *outside* the kit → shown as `already on this system —
  the kit leaves it alone`

That second case is a promise: **the kit never updates or uninstalls what it
did not install.** When everything is present, the offer disappears entirely.

So "it is not in the list" almost always means *already there* or *not
applicable* — check before concluding something is broken.

## After installing

An installed add-on becomes a **full component** of the kit:

```bash
exakit update-check dash-server    # is a newer version advertised?
exakit update dash-server          # apply it
exakit update                      # covers every INSTALLED add-on
exakit version                     # add-ons report their versions here
```

Add-ons you never picked are never touched by `exakit update`.

Add-ons that **run as a service** (today: `dash-server`) are managed like the
database itself:

```bash
exakit status        # shows running / stopped per service
exakit start         # database AND every installed service
exakit stop
exakit autostart on  # services come back after a reboot
exakit logs          # each service's log is listed
```

## Removing one

```bash
exakit uninstall     # a selection: Skip (safe default), each component,
                     # each add-on on its own, or EVERYTHING
```

Each add-on is individually selectable, the plan is shown back as a summary,
and a typed gate confirms. `exakit uninstall --dry-run` previews the full plan
without touching anything — prefer it when you are unsure.

Pin a specific version at install or update time with the per-add-on variable,
e.g. `EXAKIT_DASH_SERVER_VERSION=<version>`.

## Guardrails

- **Never install an add-on during a kit install.** The marketplace is the only
  install path, by design — do not shortcut it by calling module functions
  directly.
- **Never manage a copy the kit did not install.** If an add-on shows as
  "already on this system", leave it alone; do not update or remove it.
- **Prefer `--dry-run` before any uninstall**, and never run
  `exakit uninstall --yes` (the scripted *full* teardown) unless the user asked
  for exactly that.
- **Adding a NEW add-on to the marketplace is development work, not an install
  step.** The walkthrough with skeleton code lives in the kit's
  `MARKETPLACE.md`; do not improvise a module.
