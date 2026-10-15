$ErrorActionPreference = 'Stop'
$user = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $user) { throw 'No interactive Windows user' }
$taskName = 'wootc-runtime-gtk-probe-20260926'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) { throw 'Existing task; preserve previous run' }
$action = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument '-NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\wootc-runtime-bundle-probe\gtk-interactive.ps1'
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output "STARTED_INTERACTIVE_USER=$user TASK=$taskName"
