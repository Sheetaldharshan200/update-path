---
name: exasol-mcp
description: Connect AI clients to the local Exasol database over MCP and keep that connection healthy — running mcp-setup for Claude, Claude Code, Codex, Cursor, GitHub Copilot, Gemini CLI, OpenCode and Continue, diagnosing with mcp-doctor, repairing config drift, and understanding the dedicated read-only database user that makes MCP querying safe. Triggers — "connect my AI to Exasol", "set up MCP", "my assistant cannot see the database", "mcp-doctor reports problems", "the exasol MCP server is missing", "repair my MCP config", "which AI clients are supported", "is the MCP user really read-only".
---

# MCP — connecting AI clients to the database

MCP is how an AI client queries the local Exasol database. The kit configures
the client for you, provisions a least-privilege database user for it, and
gives you diagnostics for when it drifts.

## The commands

```bash
exakit mcp-setup              # configure MCP in supported clients (the main one)
exakit mcp-doctor             # diagnose problems; --json for raw per-client results
exakit mcp-status [clients]   # managed MCP state for every supported client
exakit mcp-validate [clients] # validate configs and test connectivity
exakit mcp-repair [clients]   # repair config drift back to the known-good state
exakit mcp-remove [clients]   # remove the managed config
exakit mcp-restore [snapshot] # restore the latest (or a chosen) config snapshot
```

Start with `mcp-doctor`. It checks the **database is running first**, so a
stopped database is diagnosed as "run `exakit start`" (exit `3`) rather than
failing deep inside a user-creation step and blaming the wrong subsystem.

Exit codes on `mcp-doctor`: `0` healthy, `3` database not running, `4` kit not
installed.

## Supported clients — and how to name them

Eight clients are supported:

```
claude_desktop  claude_code  cursor  codex
vscode_copilot  gemini_cli   opencode  continue
```

Interactively, `exakit mcp-setup` presents a **checkbox multi-select**. Clients
already connected, or not installed on this machine, are greyed out with the
reason and cannot be picked; **every selectable client is pre-selected**, so
Enter accepts and Cancel backs out.

Non-interactively — which is how *you* should drive it — answer with names:

```bash
EXAKIT_MCP_CLIENTS=claude,codex exakit mcp-setup
```

| Value | Means |
|---|---|
| `claude` | the desktop app **and** the Claude Code CLI |
| `claude_desktop` / `claude_code` | just one of them |
| `copilot` / `gemini` | aliases for `vscode_copilot` / `gemini_cli` |
| `all` | every supported client found |
| `skip` | configure none now |

**Always use names, never menu numbers** — numbers change between releases.

`exakit mcp-setup` edits the selected client config files directly, taking a
backup of each first (backups live under the kit's `mcp/` directory; the live
configs stay inside each client's own config file — `exakit mcp-status` lists
where). **The user must restart or reload the client afterwards.**

## What the connection actually is

After setup, the client starts an MCP server named **`exasol`** on demand over
stdio. It is **not** a background service — nothing is listening between calls.

The login is a **dedicated, read-only database user**. It can read every schema
in the database but cannot write, and that limit is **enforced by the database**,
not by trust or by prompt wording.

### Prove the boundary rather than asserting it

Two distinct layers stop a write, and you can observe each:

1. The **MCP tool gate** rejects a non-SELECT before it ever reaches the
   database. The message `The query is invalid or not a SELECT statement` comes
   from the tool, not the engine.
2. Beneath it, the **privilege gate** holds even if a statement got through.
   Run this as the MCP user any time:

```sql
SELECT PRIVILEGE FROM SYS.EXA_USER_SYS_PRIVS
```

It returns exactly `CREATE SESSION`, `SELECT ANY TABLE`, `USE ANY SCHEMA` — no
write privilege exists to misuse.

> Use that system table. The natural guess `EXA_SESSION_PRIVILEGES` does not
> exist and will error.

## Diagnosing "my assistant cannot see the database"

In this order:

1. **Is the database up?** `exakit status` (exit `3` = stopped → `exakit start`).
2. **Is MCP configured?** `exakit mcp-doctor` — it names the problem per client.
3. **Was the client restarted?** A config change does not reach a running
   client. This is the single most common cause.
4. **Has the config drifted?** `exakit mcp-repair` puts it back to the
   known-good state. `exakit mcp-restore` recovers from a snapshot if a repair
   is not enough.
5. Still stuck → `exakit logs`, then re-run the installer (safe and resumable).

For scripted checks, `exakit mcp-doctor --json` prints the raw per-client
result and nothing else on stdout.

## The server itself

The client runs the server on demand as `uvx exasol-mcp-server@<version>`. An
HTTP mode also exists (`exasol-mcp-server-http --host <h> --port <p>`) but the
kit configures **stdio**, which is what the supported clients expect.

Update it like any other component:

```bash
exakit update-check mcp
exakit update mcp
```

## Guardrails

- **Read-only means read-only.** Never try to satisfy a write request through
  the MCP path, and never fall back to `exapump -p starter-kit` (which connects
  as **admin** and is *not* sandboxed) to get around an MCP rejection.
- **Do not hand-edit client config files.** `mcp-setup` and `mcp-repair` own
  them and keep backups; a hand edit is what `mcp-doctor` will later report as
  drift.
- **Never print or log** the password files under
  `~/.exasol-starter-kit/credentials/` — including the MCP user's.
- **Do not invent** client ids, config paths or MCP tool names. `exakit
  mcp-status` lists the real locations.
