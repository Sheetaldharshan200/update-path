@echo off
rem exakit.cmd - the Windows shim for the exakit command. Runs exakit.ps1 beside it under
rem Windows PowerShell with the execution policy bypassed for this one call; nothing else.
rem setup\exakit.cmd is a byte-identical copy so the self-update can install this file.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0exakit.ps1" %*
exit /b %ERRORLEVEL%
