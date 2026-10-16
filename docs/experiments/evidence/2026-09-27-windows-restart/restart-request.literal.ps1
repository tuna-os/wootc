
$ErrorActionPreference = "Stop"
cmd.exe /d /c "shutdown.exe /a >NUL 2>&1"
shutdown.exe /r /t 1 /f
if ($LASTEXITCODE -ne 0) { throw "Windows restart request refused" }
Write-Output "windows-restart-requested"
