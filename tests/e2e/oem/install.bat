@echo off
setlocal

rem The E2E answer file schedules this at first automatic logon as SYSTEM.
rem Keep the wootc handoff inside the guest: neither WinRM nor SMB must be
rem available before root.disk, the BCD entry, and the deployer are prepared.
if exist "%SystemDrive%\OEM\qemu-ga-x86_64.msi" (
    rem Install QGA first so the host can observe and control the rest of
    rem setup even when Windows networking or credentials are unavailable.
    msiexec.exe /i "%SystemDrive%\OEM\qemu-ga-x86_64.msi" /qn /norestart
    if errorlevel 1 exit /b %ERRORLEVEL%
    sc.exe start QEMU-GA >nul 2>&1
)
rem The runner starts run-wootc-e2e.ps1 through QGA after guest-ping works.
rem Keeping this bootstrap limited to the MSI makes the control boundary
rem deterministic and gives the host a direct way to capture setup output.
exit /b 0
