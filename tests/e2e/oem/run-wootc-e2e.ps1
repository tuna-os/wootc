$ErrorActionPreference = "Stop"

$oemDir = "$env:SystemDrive\OEM"
$logPath = Join-Path $oemDir "wootc-e2e.log"
$completePath = Join-Path $oemDir "e2e-setup-complete.txt"
$failedPath = Join-Path $oemDir "e2e-setup-failed.txt"

function Write-E2ELog([string]$Message) {
    $line = "$(Get-Date -Format o) [wootc-e2e] $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line
}

try {
    Write-E2ELog "Starting local OEM setup"
    & "$oemDir\setup-wootc.ps1" `
        -ImageRef "ghcr.io/tuna-os/yellowfin:gnome" `
        -Hostname "wootc-test" `
        -PayloadDir "$oemDir\payload" *>&1 |
        Tee-Object -FilePath $logPath -Append

    "ok" | Set-Content -Path $completePath -Encoding ASCII
    Write-E2ELog "Setup complete; rebooting into the one-shot deployer entry"
    shutdown.exe /r /t 5 /f
} catch {
    $_ | Out-String | Set-Content -Path $failedPath -Encoding UTF8
    Write-E2ELog "Setup failed: $($_.Exception.Message)"
    exit 1
}
