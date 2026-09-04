---
name: exasol-scheduler
addon: exasol-scheduler
description: Schedule SQL jobs on the local Exasol database with the Exasol Scheduler add-on — jobs are rows in SCHED.SCHED_TASKS, history is a table, and the whole surface is plain SQL. Covers installing it from the marketplace, the dedicated scheduler_svc user and why the MCP user cannot write tasks, cron schedules with timezones, task chains via AFTER, and the laptop realities: missed runs are never replayed, one instance per task table, the engine restarts itself. Triggers — "schedule a SQL job", "run this query every night", "cron for Exasol", "install exasol-scheduler", "my scheduled job did not run", "SCHED_TASKS", "task history", "chain SQL jobs", "pause a scheduled job".
---

# Exasol Scheduler — SQL jobs on a schedule

`exasol-scheduler` is a **marketplace add-on**: a single small binary that
polls `SCHED.SCHED_TASKS` and runs each due row's `SQL_TEXT` against the local
database. Jobs are defined, paused, chained and audited with **plain SQL** —
no config files, no external state.

It is a SQL scheduler, not a workflow runner: it never invokes a shell, a
Python script, or any external tool. Work that needs an executable belongs
elsewhere; work that is SQL (or `EXECUTE SCRIPT`) belongs here.

## Install

```
exakit marketplace        # Space selects Exasol Scheduler, Enter installs
```

The install creates a dedicated `scheduler_svc` database user, starts the
service, waits for it to bootstrap its `SCHED` schema, then **revokes the
bootstrap privileges again** (upstream's least-privilege posture). It joins
`exakit start/stop/status/autostart/logs` like every service.

## The security boundary — read this before writing tasks

`SCHED_TASKS` is a **code-execution surface**: whoever can INSERT or UPDATE a
row runs arbitrary SQL as `scheduler_svc`. Because of that:

- The kit's read-only MCP user can **see** the table but cannot write it.
  Creating a task goes through the admin path — `exakit sql --write` or
  exapump — and that is deliberate, not a defect to route around.
- `scheduler_svc` starts with **no access to your schemas**. A task that
  touches `MY_SCHEMA` needs a grant first:

```
exakit sql --write 'GRANT SELECT, INSERT ON SCHEMA MY_SCHEMA TO SCHEDULER_SVC'
```

## Define a job

Always double-quote the scheduler's column names.

```
exakit sql --write "INSERT INTO SCHED.SCHED_TASKS (\"TASK_ID\", \"SCHEDULE\", \"SQL_TEXT\")
VALUES ('nightly_cleanup', 'CRON 0 0 2 * * * TZ=UTC',
        'DELETE FROM STARTER_KIT.STAGING WHERE created_at < ADD_DAYS(CURRENT_TIMESTAMP, -7)')"
```

- The scheduler notices new and changed rows on its next poll — no restart.
- Pause without deleting: set `"ENABLED" = FALSE`.
- Chain steps: give the child the parent's `TASK_ID` in `"AFTER"` and a NULL
  `"SCHEDULE"`. Downstream steps are skipped on failure; finalizers always run.
- Audit: `SELECT * FROM SCHED.SCHED_HISTORY ORDER BY 1 DESC LIMIT 20`.

## Laptop realities (say these plainly, they are design, not faults)

- **Missed runs are never replayed.** A machine asleep at 02:00 does not run
  the 02:00 job on wake; the next occurrence is computed from the current
  clock.
- **One instance per task table**, enforced by the launcher — a second copy
  refuses to start, because two pollers would run every job twice.
- **The engine exits on fatal errors** and the kit's launcher restarts it with
  backoff, giving up loudly after five rapid failures. At login it waits
  (bounded) for the database before the first start.
- Schedules carry their own timezone (`TZ=UTC`); the laptop's clock is not the
  schedule's clock.

## Operate

```
exakit status                       # running / stopped, next to the database
exakit logs exasol-scheduler -f     # the engine and its supervisor
exakit update exasol-scheduler      # new binary; jobs and history untouched
```

Uninstall removes the service, binary, credential and database user — and
deliberately **leaves the `SCHED` schema**: job definitions and history are
your data, not part of the add-on.
