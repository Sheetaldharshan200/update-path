# Skills — AI assistant guidance for the starter kit

> **TL;DR** — These are AI *skills*: small `SKILL.md` recipes that teach an AI
> assistant how to drive this kit. They use the open `SKILL.md` standard that
> **Claude Code, Codex, Cursor, and other compatible agents** read, so the same
> files work everywhere — no per-tool copies.

## What's here

One skill per thing an agent has to operate — so the agent loads only what the
user's request actually needs, not a manual for the whole kit.

**Start here**

| Skill | Use it when… |
|---|---|
| [`local-agent-ready-starter`](local-agent-ready-starter/SKILL.md) | Setting up the kit and running a first trusted, AI-assisted query — install → connect MCP → load data → ask/inspect/run/validate/rerun. |

**The fixed components** — always installed

| Skill | Use it when… |
|---|---|
| [`exasol-runtime`](exasol-runtime/SKILL.md) | Starting, stopping or diagnosing the local database; telling Exasol Personal (macOS, native) from Exasol Nano (container); autostart. |
| [`exasol-exapump`](exasol-exapump/SKILL.md) | Running SQL, opening a SQL shell, bulk-loading CSV/Parquet — and knowing that the `starter-kit` profile is the **admin**, unsandboxed connection. |
| [`exasol-mcp`](exasol-mcp/SKILL.md) | Connecting AI clients over MCP, diagnosing `mcp-doctor`, repairing config drift, proving the read-only user really is read-only. |
| [`exasol-pyexasol`](exasol-pyexasol/SKILL.md) | Querying the database from Python — the right interpreter, the TLS setting the self-signed certificate needs, reading credentials safely. |

**The marketplace** — opt-in add-ons

| Skill | Use it when… |
|---|---|
| [`exasol-marketplace`](exasol-marketplace/SKILL.md) | Choosing, installing, updating or removing add-ons; explaining why one is not offered at all. |
| [`dash-server`](dash-server/SKILL.md) | Building live dashboards the agent drives over an MCP control plane while the user opens a browser URL. |
| [`json-tables`](json-tables/SKILL.md) | Loading JSON into the database (exapump takes CSV and Parquet only); the prebuilt engine that means no Rust toolchain. |
| [`exasol-vscode`](exasol-vscode/SKILL.md) | SQL editing and schema browsing inside VS Code; why the kit refuses to manage a copy the user installed themselves. |

The set is versioned as one component (`components.skills` in `versions.json`),
and `exakit skills` reports when the copies in your agent's folders predate the
kit you have.

Each skill is a directory containing a `SKILL.md`: `name` + `description`
frontmatter, then the instructions. The agent always sees the name and
description, and loads the full body only when it decides the skill is relevant
(progressive disclosure). The `description`'s **"Triggers —"** list is how the
agent decides when to fire it — keep it accurate.

## Seeing what you have

```bash
exakit skills          # every skill, with a summary and whether it is installed
exakit skills --json   # the same, machine-readable
```

States are `installed` (in every discovery folder), `partial` (in some — a
half-finished install or a hand deletion) and `available` (in none).

## How a skill reaches your agent

Skills auto-load only from an agent's discovery folders, **not** from this repo
path. The kit installs them for you:

```bash
exakit skills-install
```

This copies each skill into the standard per-user locations so your CLI agent
finds it automatically:

- **Claude Code** → `~/.claude/skills/<name>/`
- **Codex / Cursor / other open-standard agents** → `~/.agents/skills/<name>/`

Re-running is safe — it refreshes the installed copy. The kit setup also offers
to do this once at the end of an install.

> **Chat-only clients (Claude, Cursor GUI over MCP):** these do not read
> filesystem skills the same way. There, the skill still works as guidance you
> paste in, and the query loop (Step 5) runs against the connected `exasol` MCP
> server. Filesystem auto-discovery is for terminal/CLI agents.

## Too many approval prompts?

An agent driving the kit runs many commands; by default each one asks for
approval. See [reducing-agent-prompts.md](reducing-agent-prompts.md) to
pre-approve the kit's **read-only** commands per agent (Claude Code, Codex,
Cursor) while keeping SQL execution and mutations gated — the split that keeps
the inspect-before-run trust model intact.

## Why this layout (and not a plugin marketplace)

The kit is a **first-touch, low-friction** experience — the goal is time-to-first
value, not a tooling catalog. A plugin-marketplace install would assume the user
already runs Claude Code / Codex with plugin habits and would add steps before
value. Instead the existing installer — the thing the user already runs — places
the skill where agents look. If versioned team distribution is ever needed, a
marketplace wrapper is additive and can be layered on later.

## Adding or editing a skill

Verify with:

```bash
bash tests/skills.sh    # frontmatter, registry, install/state, uninstall scope
```

1. Add or edit a folder under `skills/<skill-name>/SKILL.md`.
2. Keep the `name` / `description` (with `Triggers —`) accurate — that's how the
   agent decides when to fire it.
3. Reference only real kit commands and paths (`exakit …`, `exapump …`,
   `~/.exasol-starter-kit/kit/…`) — never invent commands, flags, or SQL.
4. If you add shared material for multiple skills, keep it once at this folder's
   level and reference it by relative path from each skill.
