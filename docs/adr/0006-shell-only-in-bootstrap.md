# ADR 0006: Only bootstrap/ may contain OS-specific shell, and no lifecycle logic

Status: accepted (2026-09-30)

## Context

Twin implementations drift; the audit found four contract differences between the bash and PowerShell CLIs.

## Decision

`install.sh`, `install.ps1`, `bootstrap/ensure-python.*` and the two launchers are the only shell that remains after Phase D. They detect the machine, fetch the kit, get a Python and hand over. Platform differences inside the kit live in `exakit/adapters/platform/` and `adapters/process/services.py`.

## Consequences

Every behaviour is written once; the shell files are small enough to read whole.
