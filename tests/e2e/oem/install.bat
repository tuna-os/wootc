@echo off
setlocal

rem The E2E answer file schedules this at first automatic logon as SYSTEM.
rem Keep the wootc handoff inside the guest: neither WinRM nor SMB must be
rem available before root.disk, the BCD entry, and the deployer are prepared.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SystemDrive%\OEM\run-wootc-e2e.ps1"
exit /b %ERRORLEVEL%
