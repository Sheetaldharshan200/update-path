# ADR 0004: Strangler migration with golden contract tests, not a rewrite

Status: accepted (2026-09-30)

## Context

Existing 0.2.0 installs must keep working through every step, and the agent contract (JSON shapes, exit codes, env answers) is published.

## Decision

One `exakit` command dispatches migrated commands to Python and the rest to the legacy shell CLI (`setup/legacy-exakit*`). `tests/contract` pins the shapes. Phases A to D take over command groups; `setup/` is deleted in D.

## Consequences

Two implementations coexist for a while, but every command has exactly one owner at any time, checked by a test.
