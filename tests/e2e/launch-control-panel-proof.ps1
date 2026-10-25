# Dedicated test fixture only: launch the real Wails UI in the logged-on session.
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'control-panel proof requires Windows' }
$runtime = @(
    "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application\*\msedgewebview2.exe",
    "$env:ProgramFiles\Microsoft\EdgeWebView\Application\*\msedgewebview2.exe"
) | ForEach-Object { Get-Item $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
if (-not $runtime) { throw 'control-panel dependency missing: actual WebView2 runtime executable' }
. '\\host.lan\Data\state-trust.ps1'
Initialize-WootcStateDirectory -Path C:\wootc
. '\\host.lan\Data\stage-status-cli.ps1'
Copy-WootcStatusCLI -SourceDirectory '\\host.lan\Data' -Destination 'C:\wootc\wootc.exe'
Remove-Item C:\wootc\e2e-drive.json,C:\wootc\e2e-drive-state.json,C:\wootc\e2e-ready.json -Force -ErrorAction SilentlyContinue
@'
set WOOTC_E2E_DRIVE=1
set WOOTC_PRELOAD=0
start "" C:\wootc\wootc.exe
'@ | Set-Content C:\wootc\launch-control-proof.cmd -Encoding ascii
Stop-Process -Name wootc -Force -ErrorAction SilentlyContinue
$who = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $who) { throw 'control-panel proof has no interactive Windows session' }
# The ONCE trigger is one minute in the PAST so it never fires: /Run is the
# only launch. A trigger at now+1m started a second wootc.exe while the
# harness waited (E2E 39961283836: "control-panel UI process count is not
# one"), the same race the GUI install launch fixed (run-e2e.sh,
# wootc-gui-e2e). schtasks warns about the past time on stderr; cmd.exe keeps
# that warning out of PowerShell's error stream, and the exit code decides.
$start = (Get-Date).AddMinutes(-1).ToString('HH:mm')
$created = cmd.exe /d /c "schtasks.exe /Create /TN wootc-control-proof /SC ONCE /ST $start /TR C:\wootc\launch-control-proof.cmd /RU $who /IT /RL HIGHEST /F 2>&1"
if ($LASTEXITCODE -ne 0) { throw ('control-panel task creation failed: ' + ($created -join ' ')) }
$ran = cmd.exe /d /c "schtasks.exe /Run /TN wootc-control-proof 2>&1"
if ($LASTEXITCODE -ne 0) { throw ('control-panel task launch failed: ' + ($ran -join ' ')) }
Write-Output 'control-panel-task-run'
