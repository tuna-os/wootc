# assert-phase1.ps1 — Windows-side assertions for the Phase-1 E2E.
# Run via QGA after `wootc.exe install` (headless). Prints [PASS]/[FAIL]
# lines; exits 1 if anything failed.

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

# ── state.json ───────────────────────────────────────────────────────────────
$stateRaw = Get-Content C:\wootc\state.json -Raw -ErrorAction SilentlyContinue
Assert-True ($null -ne $stateRaw) "state.json exists"
Assert-True ($stateRaw -match '"state":\s*"armed"') "state.json reports armed"

# ── root disk ────────────────────────────────────────────────────────────────
Assert-True (Test-Path C:\wootc\disks\root.vhdx) "root.vhdx exists"

# ── vault ────────────────────────────────────────────────────────────────────
$vault = Get-Content C:\wootc\install\vault.json -Raw -ErrorAction SilentlyContinue
Assert-True ($null -ne $vault) "vault.json exists"
Assert-True ($vault -match '\$6\$') "vault.json contains sha512-crypt hash"
Assert-True ($vault -notmatch 'testpass') "vault.json does not contain the plaintext password"

# ── ESP layout ───────────────────────────────────────────────────────────────
$esp = Get-Partition |
    Where-Object { $_.GptType -eq "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" } |
    Select-Object -First 1
if (-not $esp.DriveLetter) {
    $esp | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
    $esp = Get-Partition -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber
}
$espRoot = "$($esp.DriveLetter):"
Assert-True ($null -ne $esp.DriveLetter) "ESP has a drive letter ($espRoot)"

Assert-True (Test-Path "$espRoot\EFI\fedora\shimx64.efi") "ESP: signed shim present"
Assert-True (Test-Path "$espRoot\EFI\fedora\grubx64.efi") "ESP: signed grub present"
Assert-True (Test-Path "$espRoot\EFI\wootc\deployer-vmlinuz") "ESP: deployer kernel present"
Assert-True (Test-Path "$espRoot\EFI\wootc\deployer-initramfs.img") "ESP: deployer initramfs present"

$grubCfg = Get-Content "$espRoot\EFI\fedora\grub.cfg" -Raw -ErrorAction SilentlyContinue
Assert-True ($grubCfg -match '# wootc deployer') "ESP grub.cfg carries the wootc marker"
Assert-True ($grubCfg -match 'wootc\.image=') "ESP grub.cfg has the image reference"
Assert-True ($grubCfg -match 'wootc\.vault=') "ESP grub.cfg forwards the vault path"

# ── BCD ──────────────────────────────────────────────────────────────────────
$fw = bcdedit /enum firmware | Out-String
Assert-True ($fw -match 'wootc') "BCD has a wootc firmware entry"
Assert-True ($fw -match '\\EFI\\fedora\\shimx64\.efi') "wootc entry points at the signed shim"

# Idempotency: retried installs must not pile up firmware entries.
$wootcCount = ([regex]::Matches($fw, '(?m)^description\s+wootc\s*$')).Count
Assert-True ($wootcCount -eq 1) "exactly one wootc BCD entry (found $wootcCount)"

# The wootc GUID must be armed one-shot (bootsequence) and NOT promoted to
# the permanent default (displayorder head).
$guid = $null
$block = $fw -split "(?ms)(?=Firmware Application)" | Where-Object { $_ -match 'description\s+wootc' } | Select-Object -First 1
if ($block -and $block -match '(\{[0-9a-fA-F-]{36}\})') { $guid = $Matches[1] }
Assert-True ($null -ne $guid) "wootc entry GUID parsed"

$mgr = bcdedit /enum "{fwbootmgr}" | Out-String
if ($guid) {
    Assert-True ($mgr -match "bootsequence[\s\S]*$([regex]::Escape($guid))") "wootc GUID armed in one-shot bootsequence"
    $displayHead = ($mgr -split 'displayorder')[1] -split "`n" | Where-Object { $_ -match '\{' } | Select-Object -First 1
    Assert-True ($displayHead -notmatch [regex]::Escape($guid)) "wootc GUID is NOT the permanent default boot"
}

# ── User Data Bridge preconditions ──────────────────────────────────────────
# Phase 3's bridge binds /host/Users/<linux-username>/ into $HOME. Verify the
# raw material exists now so a rung-3 failure can't be a rung-1 oversight.
$profiles = Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') }
Assert-True ($profiles.Count -ge 1) "at least one real Windows user profile exists"

$withDocs = $profiles | Where-Object { Test-Path (Join-Path $_.FullName 'Documents') }
Assert-True ($withDocs.Count -ge 1) "a Windows profile has a Documents folder to bridge"

# The bridge currently matches by exact username. Warn (not fail) when the
# vault user has no matching Windows profile — a known design gap: the
# dashboard should eventually offer profile *mapping* instead of requiring
# equal names.
$vaultUser = $null
if ($vault -match '"username":\s*"([^"]+)"') { $vaultUser = $Matches[1] }
if ($vaultUser -and -not (Test-Path "C:\Users\$vaultUser")) {
    Write-Host "[WARN] vault user '$vaultUser' has no matching Windows profile — User Data Bridge will not bind for this account (profiles: $($profiles.Name -join ', '))"
}

# ── headless status ──────────────────────────────────────────────────────────
$status = & C:\wootc\wootc.exe status 2>&1 | Out-String
Assert-True ($status -match '"state":\s*"armed"') "wootc.exe status reports armed"

# ── result ───────────────────────────────────────────────────────────────────
if ($failures -gt 0) {
    Write-Host "PHASE1-RESULT: FAIL ($failures failures)"
    exit 1
}
Write-Host "PHASE1-RESULT: PASS"
exit 0
