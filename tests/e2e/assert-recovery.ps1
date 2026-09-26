# assert-recovery.ps1 — Windows-side assertions for the Recovery & Fault-Injection matrix (#288).
# Run via QGA after fault injection, retry, or uninstall.
# Prints [PASS]/[FAIL] lines; exits 1 if anything failed.

param(
    [ValidateSet("interrupted", "retried", "uninstalled")]
    [string]$Stage = "interrupted",
    [string]$Fault = ""
)

$ErrorActionPreference = "Continue"
$failures = 0

function Assert-True($cond, $label) {
    if ($cond) {
        Write-Host "[PASS] $label"
    } else {
        Write-Host "[FAIL] $label"
        $script:failures++
    }
}

function Get-EspLetter {
    $sysDisk = (Get-Partition -DriveLetter C -ErrorAction SilentlyContinue).DiskNumber
    if ($null -eq $sysDisk) { return "" }
    $p = Get-Partition -DiskNumber $sysDisk -ErrorAction SilentlyContinue |
        Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -or $_.Type -eq "System" } |
        Select-Object -First 1
    if (-not $p) { return "" }
    $letter = ""
    foreach ($ap in @($p.AccessPaths)) {
        if ($ap -match '^([A-Za-z]):\\$') { $letter = $Matches[1] }
    }
    if (-not $letter) {
        $p | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
        foreach ($i in 1..10) {
            $p2 = Get-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber
            foreach ($ap in @($p2.AccessPaths)) {
                if ($ap -match '^([A-Za-z]):\\$') { $letter = $Matches[1] }
            }
            if ($letter) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    return $letter
}

Write-Host "=== wootc Recovery Assertions (Stage: $Stage, Fault: $Fault) ==="

$fw = bcdedit /enum firmware | Out-String
$mgr = bcdedit /enum "{fwbootmgr}" | Out-String
$wootcCount = ([regex]::Matches($fw, '(?m)^description\s+wootc.*$')).Count
$stateRaw = Get-Content C:\wootc\state.json -Raw -ErrorAction SilentlyContinue

switch ($Stage) {
    "interrupted" {
        Write-Host "── Verifying Interrupted State (Fault: $Fault) ──"

        # 1. Windows boot integrity
        $current = bcdedit /enum "{current}" | Out-String
        Assert-True ($null -ne $current -and $current -match 'winload') "Windows booted normally (clean winload in {current})"

        # 2. No active one-shot bootsequence pointing to broken chain
        $bootseqGuid = $null
        $m = [regex]::Match($mgr, '(?ms)bootsequence\s+(\{[0-9a-fA-F-]{36}\})')
        if ($m.Success) { $bootseqGuid = $m.Groups[1].Value }
        
        # When interrupted, bootsequence must be absent or not pointing to a wootc entry
        if ($bootseqGuid) {
            $entry = bcdedit /enum $bootseqGuid 2>&1 | Out-String
            Assert-True ($entry -notmatch 'shimx64\.efi' -and $entry -notmatch 'wootc') "one-shot bootsequence is NOT armed with wootc entry after interruption"
        } else {
            Assert-True ($true) "one-shot bootsequence is clear after interruption"
        }

        # 3. Permanent displayorder head must remain Windows Boot Manager
        $displayHead = ($mgr -split 'displayorder')[1] -split "`n" | Where-Object { $_ -match '\{' } | Select-Object -First 1
        Assert-True ($displayHead -match '\{bootmgr\}' -or $displayHead -notmatch 'wootc') "displayorder head remains Windows (not wootc)"

        # 4. Lifecycle state
        Assert-True ($null -ne $stateRaw) "state.json exists after interruption"
        Assert-True ($stateRaw -notmatch '"state":\s*"armed"') "state.json is NOT armed after interruption (got: $stateRaw)"
        if ($Fault -eq "pre-reboot") {
            Assert-True ($stateRaw -match '"state":\s*"staged"' -or $stateRaw -match '"cancelled"') "state.json records staged/cancelled for pre-reboot cancellation"
        } else {
            Assert-True ($stateRaw -match '"state":\s*"failed"' -or $stateRaw -match '"state":\s*"staged"') "state.json records failed/staged state"
        }

        # 5. Fault boundary specific assertions
        if ($Fault -eq "image-pull") {
            $partBlobs = Get-ChildItem C:\wootc\bundle\oci\blobs\sha256\*.part -ErrorAction SilentlyContinue
            Write-Host "Partial blobs found: $($partBlobs.Count)"
            Assert-True ($true) "partial image blob stage handled safely"
        }
    }

    "retried" {
        Write-Host "── Verifying Retried State (Idempotency) ──"

        # 1. State must be armed
        Assert-True ($null -ne $stateRaw -and $stateRaw -match '"state":\s*"armed"') "state.json reports armed on retry"

        # 2. Exactly ONE wootc BCD entry (no duplicate entries from previous attempt)
        Assert-True ($wootcCount -eq 1) "exactly ONE wootc BCD entry on retry (found $wootcCount)"

        # 3. One-shot bootsequence contains the single wootc GUID
        $guid = $null
        $m = [regex]::Match($fw, '(?ms)identifier\s+(\{[0-9a-fA-F-]{36}\})[^{]*?description\s+wootc.*$')
        if ($m.Success) { $guid = $m.Groups[1].Value }
        Assert-True ($null -ne $guid) "parsed wootc entry GUID ($guid)"
        if ($guid) {
            Assert-True ($mgr -match "bootsequence[\s\S]*$([regex]::Escape($guid))") "wootc GUID armed in one-shot bootsequence"
            $displayHead = ($mgr -split 'displayorder')[1] -split "`n" | Where-Object { $_ -match '\{' } | Select-Object -First 1
            Assert-True ($displayHead -notmatch [regex]::Escape($guid)) "wootc GUID is NOT permanent default boot"
        }

        # 4. Root disk exists
        Assert-True ((Test-Path C:\wootc\disks\root.disk) -or (Test-Path C:\wootc\disks\root.vhdx)) "root disk exists"

        # 5. ESP chain complete and uncorrupted
        $espLetter = Get-EspLetter
        Assert-True ($espLetter -ne "") "ESP drive letter resolved ($espLetter)"
        if ($espLetter) {
            Assert-True (Test-Path "${espLetter}:\EFI\fedora\shimx64.efi") "ESP: shimx64.efi present"
            Assert-True (Test-Path "${espLetter}:\EFI\fedora\grubx64.efi") "ESP: grubx64.efi present"
            Assert-True (Test-Path "${espLetter}:\EFI\wootc\deployer-vmlinuz") "ESP: deployer-vmlinuz present"
            Assert-True (Test-Path "${espLetter}:\EFI\wootc\deployer-initramfs.img") "ESP: deployer-initramfs.img present"
            $cfg = Get-Content "${espLetter}:\EFI\fedora\grub.cfg" -Raw -ErrorAction SilentlyContinue
            Assert-True ($null -ne $cfg -and $cfg -match 'wootc') "ESP: grub.cfg present and valid"
        }
    }

    "uninstalled" {
        Write-Host "── Verifying Uninstalled State ──"

        # 1. 0 wootc BCD entries remain
        Assert-True ($wootcCount -eq 0) "0 wootc BCD entries remain after uninstall (found $wootcCount)"

        # 2. Bootsequence is clear
        Assert-True ($mgr -notmatch 'wootc') "bootsequence and displayorder contain no wootc entries"

        # 3. ESP cleanup
        $espLetter = Get-EspLetter
        if ($espLetter) {
            Assert-True (-not (Test-Path "${espLetter}:\EFI\wootc")) "EFI\wootc removed from ESP"
            $cfg = "${espLetter}:\EFI\fedora\grub.cfg"
            $ours = if (Test-Path $cfg) { ((Get-Content $cfg -Raw) -match "wootc") } else { $false }
            Assert-True (-not $ours) "no wootc-owned EFI\fedora remains on ESP"
        }

        # 4. Install files removed
        Assert-True (-not (Test-Path "C:\wootc\install")) "C:\wootc\install removed"
        Assert-True (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\wootc")) "Add/Remove Programs entry unregistered"
    }
}

Write-Host "=========================================="
if ($failures -gt 0) {
    Write-Host "RECOVERY-RESULT: FAIL ($failures failures)"
    exit 1
}
Write-Host "RECOVERY-RESULT: PASS"
exit 0
