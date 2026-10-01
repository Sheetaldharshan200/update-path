# ADR 0002: A managed CPython installed by uv, never the system Python

Status: accepted (2026-09-30)

## Context

The macOS Xcode stub and the Windows Store stub both exist, are executable and fail; system Pythons drift in version and are often older than 3.11.

## Decision

`bootstrap/ensure-python.*` downloads a pinned uv release archive (digest in `versions.json` `tools.uv`), then `uv python install 3.12` into `$EXAKIT_HOME/python`, and records the interpreter path. The system Python is never used.

## Consequences

One download at first run (about 40 MB); one digest table to maintain; the same Python on every OS.
