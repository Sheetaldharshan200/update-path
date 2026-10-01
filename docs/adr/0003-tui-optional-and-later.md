# ADR 0003: The interactive front-end is optional and never needed by the installer

Status: accepted (2026-09-30)

## Context

A TUI framework needs Python and a package install before it can draw anything; the installer must work before either exists.

## Decision

Every interactive flow renders a `Plan` through the console renderer. A richer TUI is a Phase D option installed into the kit venv, behind `exakit ui`.

## Consequences

The installer and every command work in a pipe and in CI; the screens look like the 0.2.0 ones.
