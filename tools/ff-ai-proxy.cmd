@echo off
REM ============================================================================
REM  Flash Forensics - AI proxy launcher for locked-down environments.
REM
REM  Runs tools\ff-ai-proxy.ps1 even where PowerShell SCRIPT FILES (.ps1) are
REM  blocked by ExecutionPolicy (Restricted / AllSigned). ExecutionPolicy governs
REM  script FILES, not commands - so this loads the script's text and runs it as
REM  a command block instead of executing the file by name.
REM
REM  Double-click to run on port 8000, or pass args through, e.g.:
REM      ff-ai-proxy.cmd -Port 8080
REM      ff-ai-proxy.cmd -Insecure
REM ============================================================================
powershell -NoProfile -Command "$sb=[ScriptBlock]::Create((Get-Content -Raw '%~dp0ff-ai-proxy.ps1')); & $sb %*"
