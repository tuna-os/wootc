#!/usr/bin/env pwsh
# Grading logic for the uninstall restoration proof (#238).
#
# tests/field/verify-uninstall.ps1 decides whether a real machine's uninstall
# put everything back. It runs once per test machine, by hand, on hardware
# nobody in CI has — so the grading itself has to be proven somewhere else, or
# the report it produces is only as trustworthy as an untested script.
#
# The pure comparators are dot-sourced and driven from synthetic snapshots
# here, on any platform. Each case below is a way the real check has to be able
# to fail; a grader that cannot produce a ✘ is a rubber stamp.
#
# Run: pwsh -NoProfile -File tests/unit/test-verify-uninstall.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path (Split-Path -Parent $here) 'field/verify-uninstall.ps1')

$script:failures = @()
$script:checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { $script:failures += $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $script:checks++
    if ("$Expected" -ne "$Actual") { $script:failures += "$Message (expected '$Expected', got '$Actual')" }
}

# ── the ESP diff ─────────────────────────────────────────────────────────────

$before = @{
    'efi/wootc/shimx64.efi'      = 'AAA'
    'efi/wootc/grubx64.efi'      = 'BBB'
    'efi/fedora/grub.cfg'        = 'CCC'
    'efi/microsoft/boot/bcd'     = 'DDD'   # Windows' own — must survive untouched
    'efi/boot/bootx64.efi'       = 'EEE'
}
$owned = @('EFI\wootc\shimx64.efi', 'EFI\wootc\grubx64.efi', 'EFI/fedora/grub.cfg')

# A clean uninstall: ours gone, everyone else's byte-identical.
$clean = @{ 'efi/microsoft/boot/bcd' = 'DDD'; 'efi/boot/bootx64.efi' = 'EEE' }
$r = Compare-EspTrees -Before $before -After $clean -Owned $owned
Assert-True $r.Pass 'clean uninstall should pass the ESP diff'
Assert-Equal 0 @($r.OwnedRemaining).Count 'clean uninstall leaves no claimed file'

# Ours left behind — the "residue" half of the check.
$residue = @{
    'efi/wootc/shimx64.efi'  = 'AAA'
    'efi/microsoft/boot/bcd' = 'DDD'
    'efi/boot/bootx64.efi'   = 'EEE'
}
$r = Compare-EspTrees -Before $before -After $residue -Owned $owned
Assert-True (-not $r.Pass) 'a wootc file left on the ESP must fail'
Assert-Equal 'efi/wootc/shimx64.efi' (@($r.OwnedRemaining) -join ',') 'the residue must be named'

# Somebody ELSE's file removed. This is the one that matters for a data-safety
# criterion: a dual-boot user's entry disappearing during our uninstall.
$collateral = @{ 'efi/boot/bootx64.efi' = 'EEE' }
$r = Compare-EspTrees -Before $before -After $collateral -Owned $owned
Assert-True (-not $r.Pass) 'removing a file we never claimed must fail'
Assert-Equal 'efi/microsoft/boot/bcd' (@($r.ForeignRemoved) -join ',') 'the collateral damage must be named'

# Somebody else's file rewritten in place — same name, different bytes. A
# name-only diff would call this clean.
$rewritten = @{ 'efi/microsoft/boot/bcd' = 'XXX'; 'efi/boot/bootx64.efi' = 'EEE' }
$r = Compare-EspTrees -Before $before -After $rewritten -Owned $owned
Assert-True (-not $r.Pass) 'rewriting a foreign file must fail'
Assert-Equal 'efi/microsoft/boot/bcd' (@($r.ForeignChanged) -join ',') 'the modified file must be named'

# EFI\wootc is ours by definition, even for a path the manifest never listed.
$unlisted = @{ 'efi/wootc/extra.efi' = 'ZZZ'; 'efi/boot/bootx64.efi' = 'EEE' }
$r = Compare-EspTrees -Before (@{ 'efi/wootc/extra.efi' = 'ZZZ'; 'efi/boot/bootx64.efi' = 'EEE' }) `
    -After $unlisted -Owned @()
Assert-True (-not $r.Pass) 'an unlisted file under EFI\wootc still counts as ours and must be gone'

# ── manifest parsing ─────────────────────────────────────────────────────────

$parsed = Read-OwnershipManifest -Lines @(
    '# written one line at a time',
    'EFI\wootc\shimx64.efi',
    '',
    'EFI/Fedora/GRUB.CFG',
    '   '
)
Assert-Equal 2 @($parsed).Count 'comments and blanks are skipped'
Assert-True ($parsed -contains 'efi/fedora/grub.cfg') 'separators and case are normalised'

# ── firmware entries ─────────────────────────────────────────────────────────

$bcdWithWootc = @'
Firmware Boot Manager
---------------------
identifier              {fwbootmgr}
displayorder            {bootmgr}
                        {b3b1a1d0-0000-0000-0000-000000000001}

Windows Boot Manager
--------------------
identifier              {bootmgr}
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {b3b1a1d0-0000-0000-0000-000000000001}
description             wootc
path                    \EFI\wootc\shimx64.efi
'@
$hits = Get-WootcFirmwareEntries -BcdText $bcdWithWootc
Assert-Equal 1 @($hits).Count 'the wootc firmware entry is found'
Assert-Equal '{b3b1a1d0-0000-0000-0000-000000000001}' (@($hits)[0]) 'the entry identifier is reported'

$bcdClean = @'
Windows Boot Manager
--------------------
identifier              {bootmgr}
description             Windows Boot Manager

Firmware Application (101fffff)
-------------------------------
identifier              {c0000001-0000-0000-0000-000000000002}
description             Fedora
path                    \EFI\fedora\shimx64.efi
'@
Assert-Equal 0 @(Get-WootcFirmwareEntries -BcdText $bcdClean).Count `
    'a clean firmware list reports nothing — and a real Fedora entry is not ours'

# ── power restoration ────────────────────────────────────────────────────────

$r = Test-PowerRestored -Prior @{ hibernate = '1'; hiberboot = '1' } -Current @{ hibernate = '1'; hiberboot = '1' }
Assert-True $r.Pass 'both values back on = restored'

$r = Test-PowerRestored -Prior @{ hibernate = '0'; hiberboot = '0' } -Current @{ hibernate = '0'; hiberboot = '0' }
Assert-True $r.Pass 'a machine that had them off must stay off — restore is not "turn on"'

$r = Test-PowerRestored -Prior @{ hibernate = '1'; hiberboot = '1' } -Current @{ hibernate = '0'; hiberboot = '0' }
Assert-True (-not $r.Pass) 'hibernation left off after uninstall must fail'
Assert-True ($r.Detail -match 'hibernate') 'the failing value is named'

# The orphaned-leftovers path destroys the record. Missing baseline is a ✘,
# never a silent skip: on that path the restore provably does not happen.
$r = Test-PowerRestored -Prior @{} -Current @{ hibernate = '0'; hiberboot = '0' }
Assert-True (-not $r.Pass) 'no pre-install record must fail, not pass by default'
Assert-True ($r.Detail -match 'orphaned') 'the reason names the orphaned path'

# ── C:\wootc end state, which differs by choice ──────────────────────────────

$r = Test-WootcDirState -Choice keep -WootcDirExists $true -InstallDirExists $false -RootDiskExists $true
Assert-True $r.Pass 'keep: folder and root.disk remain, install\ gone — this is CORRECT'

$r = Test-WootcDirState -Choice keep -WootcDirExists $true -InstallDirExists $false -RootDiskExists $false
Assert-True (-not $r.Pass) 'keep: a deleted root.disk means the choice was not honoured'

$r = Test-WootcDirState -Choice delete -WootcDirExists $false -InstallDirExists $false -RootDiskExists $false
Assert-True $r.Pass 'delete: everything gone'

$r = Test-WootcDirState -Choice delete -WootcDirExists $true -InstallDirExists $false -RootDiskExists $true
Assert-True (-not $r.Pass) 'delete: a surviving root.disk must fail'

$r = Test-WootcDirState -Choice keep -WootcDirExists $true -InstallDirExists $true -RootDiskExists $true
Assert-True (-not $r.Pass) 'install\ surviving either choice must fail'

# ── clean boots ──────────────────────────────────────────────────────────────

Assert-True (Test-CleanBoots -BootCount 2 -BugCheckCount 0 -DirtyShutdownCount 0).Pass 'two clean boots pass'
Assert-True (-not (Test-CleanBoots -BootCount 1 -BugCheckCount 0 -DirtyShutdownCount 0).Pass) 'one boot is not two'
Assert-True (-not (Test-CleanBoots -BootCount 2 -BugCheckCount 1 -DirtyShutdownCount 0).Pass) 'a bugcheck is not a clean boot'
Assert-True (-not (Test-CleanBoots -BootCount 3 -BugCheckCount 0 -DirtyShutdownCount 1).Pass) 'an unexpected shutdown is not clean'

# ── the rendered checklist ───────────────────────────────────────────────────

$report = Format-Checklist -Results @(
    [pscustomobject]@{ Name = 'Alpha'; Pass = $true;  Detail = 'all good' }
    [pscustomobject]@{ Name = 'Beta';  Pass = $false; Detail = 'left behind: x' }
) -Meta @{ Machine = 'ACME 1'; Variant = 'normal' }
Assert-True ($report -match '\[x\] ✔ \*\*Alpha\*\*') 'a passing box is ticked'
Assert-True ($report -match '\[ \] ✘ \*\*Beta\*\*') 'a failing box is NOT ticked'
Assert-True ($report -match 'RESULT: FAIL') 'one failure fails the whole report'
Assert-True ($report -match 'Beta') 'the failing box is named in the result line'

$allPass = Format-Checklist -Results @(
    [pscustomobject]@{ Name = 'Alpha'; Pass = $true; Detail = 'ok' }
) -Meta @{ Machine = 'ACME 1' }
Assert-True ($allPass -match 'RESULT: PASS') 'all boxes ticked passes'

# ── report ───────────────────────────────────────────────────────────────────

foreach ($f in $script:failures) { Write-Host "FAIL: $f" }
if (@($script:failures).Count -gt 0) {
    Write-Host "FAIL ($($script:checks) checks, $(@($script:failures).Count) failed)"
    exit 1
}
Write-Host "PASS ($($script:checks) checks)"
exit 0
