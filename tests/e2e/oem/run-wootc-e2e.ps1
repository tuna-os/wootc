$ErrorActionPreference = "Stop"

$oemDir = "$env:SystemDrive\OEM"
$logPath = Join-Path $oemDir "wootc-e2e.log"
$completePath = Join-Path $oemDir "e2e-setup-complete.txt"
$failedPath = Join-Path $oemDir "e2e-setup-failed.txt"

function Write-E2ESerial([string]$Message) {
    # QEMU exposes COM1 in its captured serial stream.  These compact markers
    # keep late OEM failures observable even when WinRM or offline disk reads
    # are unavailable (for example, TPM-backed Windows Device Encryption).
    try {
        $port = New-Object System.IO.Ports.SerialPort
        $port.PortName = "COM1"
        $port.BaudRate = 115200
        $port.Open()
        $port.WriteLine($Message)
        $port.Close()
    } catch {
        # A missing virtual serial port must not block installation.
    }
}

function Write-E2ELog([string]$Message) {
    $line = "$(Get-Date -Format o) [wootc-e2e] $Message"
    Write-Host $line
    Add-Content -Path $logPath -Value $line
    Write-E2ESerial "[wootc-oem] $Message"
}

try {
    # The answer file schedules this task at first logon as SYSTEM. Remove it
    # before doing work so a later Windows boot (including Phase 2) cannot
    # replay the destructive first-install handoff.
    schtasks.exe /Delete /TN "wootc-e2e-setup" /F 2>&1 | Out-Null
    Write-E2ELog "Starting local OEM setup"

    Write-E2ELog "Invoking setup-wootc payload"
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
