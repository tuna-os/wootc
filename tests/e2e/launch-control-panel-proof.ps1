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
Remove-Item C:\wootc\e2e-drive.json,C:\wootc\e2e-drive-state.json -Force -ErrorAction SilentlyContinue
@'
set WOOTC_E2E_DRIVE=1
set WOOTC_PRELOAD=0
start "" C:\wootc\wootc.exe
'@ | Set-Content C:\wootc\launch-control-proof.cmd -Encoding ascii
Stop-Process -Name wootc -Force -ErrorAction SilentlyContinue
$who = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $who) { throw 'control-panel proof has no interactive Windows session' }
$start = (Get-Date).AddMinutes(1).ToString('HH:mm')
schtasks.exe /Create /TN wootc-control-proof /SC ONCE /ST $start /TR C:\wootc\launch-control-proof.cmd /RU $who /IT /RL HIGHEST /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'control-panel task creation failed' }
schtasks.exe /Run /TN wootc-control-proof | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'control-panel task launch failed' }
