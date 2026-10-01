# ADR 0005: Add-ons, components and personas are JSON data first

Status: accepted (2026-09-30)

## Context

A marketplace add-on used to cost a bash module, a PowerShell module, two registry lines and two CI guards.

## Decision

`catalog/` holds one JSON file per component, add-on and persona; generic lifecycles (python-venv, binary, host-extension) install them; code (`hooks.py`) exists only for behaviour the generic lifecycles cannot express.

## Consequences

A new persona is one file; a simple add-on is one file plus its help document and skill; validation of the shipped files fails CI.
