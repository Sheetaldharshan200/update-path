# ADR 0001: Standard library only in the core

Status: accepted (2026-09-30)

## Context

The kit must run on a machine that has nothing but the managed Python, must install offline from a cached copy, and must not make Defender scan thousands of package files on every command.

## Decision

The `exakit/` package depends on the Python standard library only (3.11+). Optional extras (a TUI) live in the kit venv, never in the core.

## Consequences

No dependency resolution at bootstrap; no third-party CVE surface in the installer; some things (a TUI, rich tables) are written by hand or added later behind an optional import.
