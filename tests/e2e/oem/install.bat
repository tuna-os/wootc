@echo off
echo [oem] Enabling WinRM...

:: Set network to Private (required for WinRM to accept connections)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private"

:: Enable WinRM
powershell -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force -SkipNetworkProfileCheck"

:: Configure Basic auth + AllowUnencrypted
cmd /c winrm set winrm/config/service/auth @{Basic="true"}
cmd /c winrm set winrm/config/service @{AllowUnencrypted="true"}
cmd /c winrm set winrm/config/client @{TrustedHosts="*"}

:: Firewall rules
netsh advfirewall firewall add rule name="WinRM 5985" dir=in action=allow protocol=TCP localport=5985 profile=any
netsh advfirewall firewall set rule group="remote administration" new enable=yes

:: Set WinRM to auto-start and restart
powershell -NoProfile -ExecutionPolicy Bypass -Command "Set-Service WinRM -StartupType Automatic; Restart-Service WinRM -Force"

echo [oem] WinRM configuration complete
