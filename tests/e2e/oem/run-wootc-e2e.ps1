$ErrorActionPreference = "Stop"

$oemDir = "$env:SystemDrive\OEM"
$logPath = Join-Path $oemDir "wootc-e2e.log"
$completePath = Join-Path $oemDir "e2e-setup-complete.txt"
$failedPath = Join-Path $oemDir "e2e-setup-failed.txt"
$snapshotCompletePath = Join-Path $oemDir "e2e-snapshot-complete.txt"

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
    # Safe to ignore: the task may have already been deleted on a previous boot.
    try { schtasks.exe /Delete /TN "wootc-e2e-setup" /F 2>&1 | Out-Null } catch {}
    # A marker from an earlier retained VM must never authorize this run's
    # reboot. The runner writes a fresh marker only after fsfreeze/copy/thaw.
    Remove-Item -Path $snapshotCompletePath -Force -ErrorAction SilentlyContinue
    Write-E2ELog "Starting local OEM setup"

    Write-E2ELog "Invoking setup-wootc payload"
    # Deployer config (image / bootloader / composefs) is written into C:\OEM by
    # run-e2e.sh so the test matrix can drive every bootc base and both
    # bootloaders. Absent the file, fall back to the historical grub2 yellowfin
    # default so a bare run is unchanged.
    $cfg = @{ ImageRef = "ghcr.io/tuna-os/yellowfin:gnome"; Bootloader = "grub2"; ComposeFs = "0" }
    $cfgPath = Join-Path $oemDir "wootc-config.txt"
    if (Test-Path $cfgPath) {
        foreach ($line in Get-Content $cfgPath) {
            if ($line -match '^\s*([^#=]+?)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2] }
        }
    }
    Write-E2ELog ("Deployer config: image={0} bootloader={1} composefs={2}" -f $cfg.ImageRef, $cfg.Bootloader, $cfg.ComposeFs)
    $setupArgs = @{
        ImageRef   = $cfg.ImageRef
        Hostname   = "wootc-test"
        Bootloader = $cfg.Bootloader
        PayloadDir = "$oemDir\payload"
    }
    if ($cfg.ComposeFs -eq "1") { $setupArgs.ComposeFs = $true }
    & "$oemDir\setup-wootc.ps1" @setupArgs *>&1 | Tee-Object -FilePath $logPath -Append

    # Stamp the run id, not a constant. The host barrier requires this to match
    # the run it is currently driving; a bare "ok" is indistinguishable from a
    # marker left behind by an earlier run, which made the barrier pass
    # instantly and the harness monitor a deployer that had never been staged.
    $runId = if ($cfg.ContainsKey("RunId")) { $cfg.RunId } else { "unknown" }
    $runId | Set-Content -Path $completePath -Encoding ASCII
    Write-E2ELog "Setup complete; waiting for host snapshot acknowledgement"
    $snapshotDeadline = (Get-Date).AddMinutes(10)
    while (-not (Test-Path -LiteralPath $snapshotCompletePath)) {
        if ((Get-Date) -ge $snapshotDeadline) {
            throw "Timed out waiting for the host to snapshot the Windows installation"
        }
        Start-Sleep -Seconds 2
    }
    Write-E2ELog "Host snapshot acknowledged; rebooting into the one-shot deployer entry"
    shutdown.exe /r /t 5 /f
} catch {
    $_ | Out-String | Set-Content -Path $failedPath -Encoding UTF8
    Write-E2ELog "Setup failed: $($_.Exception.Message)"
    exit 1
}
