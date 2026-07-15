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

    # The initial setup never waits on WinRM, but the existing Phase 2
    # assertion reconnects after the deployer returns to Windows. Configure
    # that service from inside the guest rather than racing a host connection
    # during OOBE. A later QEMU Guest Agent path will remove this dependency.
    try {
        winrm quickconfig -quiet | Out-Null
        Set-Service -Name WinRM -StartupType Automatic
        Start-Service -Name WinRM -ErrorAction SilentlyContinue
        netsh advfirewall firewall set rule group="Windows Remote Management" new enable=Yes | Out-Null
        Write-E2ELog "WinRM configured for the later Phase 2 assertion"
    } catch {
        Write-E2ELog "WinRM configuration deferred: $($_.Exception.Message)"
    }

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
