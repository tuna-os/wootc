#!/usr/bin/env pwsh
# Grading logic for the fault-injection recovery matrix (#288).
#
# tests/e2e/assert-recovery.ps1 runs inside the Windows guest, minutes into a
# VM run, and decides whether an interrupted install, its retry and its
# uninstall left Windows as it was. Its comparators are dot-sourced and driven
# from synthetic snapshots here. Each case is a way the real check must be
# able to fail; a check that cannot fail proves nothing.
#
# Run: pwsh -NoProfile -File tests/unit/test-assert-recovery.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path (Split-Path -Parent $here) 'e2e/assert-recovery.ps1')

$script:failed = @()
$script:checks = 0

function Expect {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { $script:failed += $Message }
}

function Expect-Clean([object[]]$Problems, [string]$Message) {
    $list = @($Problems | Where-Object { $_ })
    Expect ($list.Count -eq 0) "$Message (got: $($list -join ' | '))"
}

function Expect-Flagged([object[]]$Problems, [string]$Pattern, [string]$Message) {
    $hit = @($Problems | Where-Object { "$_" -match $Pattern })
    Expect ($hit.Count -gt 0) "$Message (wanted /$Pattern/, got: $(@($Problems) -join ' | '))"
}

# ── bcdedit parsing ──────────────────────────────────────────────────────────

$baseText = @'
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {bootmgr}
                        {aaaaaaaa-0000-0000-0000-000000000001}
timeout                 0

Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=\Device\HarddiskVolume1
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {aaaaaaaa-0000-0000-0000-000000000001}
description             UEFI QEMU HARDDISK
'@

$wootcGuid = '{bbbbbbbb-0000-0000-0000-000000000002}'
$armedText = @"
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {bootmgr}
                        {aaaaaaaa-0000-0000-0000-000000000001}
bootsequence            $wootcGuid
timeout                 0

Windows Boot Manager
--------------------
identifier              {bootmgr}
path                    \EFI\Microsoft\Boot\bootmgfw.efi
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {aaaaaaaa-0000-0000-0000-000000000001}
description             UEFI QEMU HARDDISK

Firmware Application (101fffff)
-------------------------------
identifier              $wootcGuid
path                    \EFI\fedora\shimx64.efi
description             wootc Deployer
"@

$base = Get-BootSnapshot -Text $baseText
Expect (@($base.entries).Count -eq 2) "baseline parses 2 firmware entries, got $(@($base.entries).Count)"
Expect ((@($base.displayorder) -join ' ') -eq '{bootmgr} {aaaaaaaa-0000-0000-0000-000000000001}') "multi-line displayorder parsed in order, got '$(@($base.displayorder) -join ' ')'"
Expect (@($base.bootsequence).Count -eq 0) 'no bootsequence in the baseline'
Expect (@($base.wootc).Count -eq 0) 'no wootc entry in the baseline'

$armed = Get-BootSnapshot -Text $armedText
Expect (@($armed.wootc) -contains $wootcGuid) 'wootc entry recognised by description'
Expect (@($armed.shim) -contains $wootcGuid) 'wootc entry recognised by shim path'
Expect (@($armed.bootsequence) -contains $wootcGuid) 'bootsequence parsed'

# ── interrupted / uninstalled: boot set equals the baseline ──────────────────

Expect-Clean (Test-BootMatchesBaseline -Baseline $base -Current $base) 'identical boot set passes'
$p = Test-BootMatchesBaseline -Baseline $base -Current $armed
Expect-Flagged $p 'added since baseline' 'a stale wootc entry is caught'
Expect-Flagged $p 'bootsequence left armed' 'a stale one-shot is caught'

$reordered = Get-BootSnapshot -Text ($baseText -replace '(?m)^displayorder\s+\{bootmgr\}\r?\n(\s+)(\{aaaaaaaa[^}]*\})', "displayorder            `$2`n`$1{bootmgr}")
Expect-Flagged (Test-BootMatchesBaseline -Baseline $base -Current $reordered) 'displayorder changed' 'a changed permanent boot order is caught'

$lost = Get-BootSnapshot -Text ($baseText -replace '(?ms)\r?\n\r?\nFirmware Application.*$', '')
Expect-Flagged (Test-BootMatchesBaseline -Baseline $base -Current $lost) 'removed since baseline' 'an entry deleted by mistake is caught'

# ── retried: exactly one new, armed, non-default wootc entry ────────────────

Expect-Clean (Test-RetryBootEntries -Baseline $base -Current $armed) 'a clean retry passes'

$dup = Get-BootSnapshot -Text ($armedText + @'


Firmware Application (101fffff)
-------------------------------
identifier              {cccccccc-0000-0000-0000-000000000003}
path                    \EFI\fedora\shimx64.efi
description             wootc Deployer
'@)
$p = Test-RetryBootEntries -Baseline $base -Current $dup
Expect-Flagged $p 'exactly 1 new firmware entry' 'a duplicate entry from the first attempt is caught'
Expect-Flagged $p 'exactly 1 wootc' 'a duplicate wootc entry is caught'

$unarmed = Get-BootSnapshot -Text ($armedText -replace "(?m)^bootsequence.*\r?\n", '')
Expect-Flagged (Test-RetryBootEntries -Baseline $base -Current $unarmed) 'not armed' 'a retry that never armed the one-shot is caught'

$default = Get-BootSnapshot -Text ($armedText -replace 'displayorder            \{bootmgr\}', "displayorder            $wootcGuid`n                        {bootmgr}")
$p = Test-RetryBootEntries -Baseline $base -Current $default
Expect-Flagged $p 'permanent default' 'wootc as the permanent default is caught'

# ── ESP ──────────────────────────────────────────────────────────────────────

$espBase = @{
    'efi/microsoft/boot/bootmgfw.efi' = 'W1'
    'efi/microsoft/boot/bcd'          = 'H1'
    'efi/boot/bootx64.efi'            = 'W2'
}
$espRetried = $espBase.Clone()
$espRetried['efi/microsoft/boot/bcd'] = 'H2'   # bcdedit rewrote the hive
foreach ($f in @('efi/fedora/shimx64.efi', 'efi/fedora/grubx64.efi', 'efi/fedora/grub.cfg', 'efi/wootc/deployer-vmlinuz', 'efi/wootc/deployer-initramfs.img')) {
    $espRetried[$f] = 'S'
}
Expect-Clean (Test-EspAgainstBaseline -Baseline $espBase -Current $espRetried -Mode retried) 'staged files plus a rewritten BCD hive pass on retry'

$espDup = $espRetried.Clone()
$espDup['efi/wootc/deployer-vmlinuz.old'] = 'S'
Expect-Flagged (Test-EspAgainstBaseline -Baseline $espBase -Current $espDup -Mode retried) 'duplicate or stray' 'a second copy of a staged file is caught'

$espClobbered = $espRetried.Clone()
$espClobbered['efi/boot/bootx64.efi'] = 'X'
Expect-Flagged (Test-EspAgainstBaseline -Baseline $espBase -Current $espClobbered -Mode retried) 'changed: efi/boot/bootx64.efi' 'an overwritten Windows file is caught'

$espUninstalled = $espBase.Clone()
$espUninstalled['efi/microsoft/boot/bcd'] = 'H3'
Expect-Clean (Test-EspAgainstBaseline -Baseline $espBase -Current $espUninstalled -Mode uninstalled) 'a clean uninstall passes'
Expect-Flagged (Test-EspAgainstBaseline -Baseline $espBase -Current $espRetried -Mode uninstalled) 'left behind' 'staged files left after uninstall are caught'

$espGone = $espBase.Clone()
$espGone.Remove('efi/microsoft/boot/bcd')
Expect-Flagged (Test-EspAgainstBaseline -Baseline $espBase -Current $espGone -Mode uninstalled) 'removed: efi/microsoft/boot/bcd' 'a deleted BCD hive is caught even though its bytes are volatile'

# ── power ───────────────────────────────────────────────────────────────────

Expect-Clean (Test-PowerMatchesBaseline -Baseline @{ hibernate = '1'; hiberboot = '1' } -Current @{ hibernate = '1'; hiberboot = '1' }) 'restored power passes'
Expect-Flagged (Test-PowerMatchesBaseline -Baseline @{ hibernate = '1'; hiberboot = '1' } -Current @{ hibernate = '1'; hiberboot = '0' }) 'hiberboot' 'Fast Startup left off is caught'

# ── blob resume ─────────────────────────────────────────────────────────────

$good = 'a' * 64
$interrupted = @{ $good = 100 }
Expect-Clean (Test-BlobResume -Interrupted $interrupted -Current @(@{ Name = $good; Hash = $good.ToUpperInvariant(); Ticks = 100 })) 'reused verified blob passes'
Expect-Flagged (Test-BlobResume -Interrupted $interrupted -Current @(@{ Name = $good; Hash = $good; Ticks = 100 }, @{ Name = ('0' * 64) + '.part'; Hash = ''; Ticks = 5 })) 'incomplete blob survived' 'a surviving .part is caught'
Expect-Flagged (Test-BlobResume -Interrupted $interrupted -Current @()) 'discarded instead of reused' 'a verified blob thrown away is caught'
Expect-Flagged (Test-BlobResume -Interrupted $interrupted -Current @(@{ Name = $good; Hash = $good; Ticks = 200 })) 'rewritten instead of reused' 'a verified blob downloaded again is caught'
Expect-Flagged (Test-BlobResume -Interrupted @{} -Current @(@{ Name = $good; Hash = 'b' * 64; Ticks = 1 })) 'does not hash to its name' 'a corrupt blob is caught'

# ── result ──────────────────────────────────────────────────────────────────

if ($script:failed.Count -gt 0) {
    Write-Host "test-assert-recovery: $($script:failed.Count) of $($script:checks) checks FAILED"
    foreach ($f in $script:failed) { Write-Host "  ✘ $f" }
    exit 1
}
Write-Host "test-assert-recovery: all $($script:checks) checks passed"
exit 0
