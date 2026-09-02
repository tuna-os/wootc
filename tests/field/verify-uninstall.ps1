#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Proof that "one uninstall puts everything back", collected on the machine.

.DESCRIPTION
    v1.0 criterion 2 (#238) asks for uninstall restoration proven on real
    hardware with "every box ticked". A box a human ticks from memory is not
    proof — the interesting failures here are silent (a firmware entry that
    survives, an ESP file that was not ours, hibernation left off), and the
    baseline they must be compared against is DELETED BY THE UNINSTALL ITSELF.

    So this runs in two phases:

      capture   BEFORE the uninstall. Snapshots the firmware boot entries, the
                whole ESP with per-file hashes, the ESP ownership manifest, the
                live power settings, C:\wootc, the Add/Remove entry — and
                copies out C:\wootc\install\prior-power.txt, the installer's
                record of what hibernation/Fast Startup were before it touched
                them. That file lives inside the directory uninstall removes,
                so without this copy the "restored to the recorded pre-install
                values" check is unverifiable after the fact.

      verify    AFTER the uninstall and the reboots. Re-reads everything,
                diffs it against the capture, prints the checklist with each
                box ticked or not AND the evidence for it, and exits non-zero
                if any box fails. The exit code is the point: a report can be
                pasted, but it cannot be talked into passing.

    Nothing on the machine under test is modified. The script writes only its
    own baseline.json and checklist.md into the directory it is given, and the
    one thing it changes system-side is a temporary drive letter for the ESP,
    removed again before it returns.

.EXAMPLE
    # On the test machine, after the install completed and before uninstalling:
    .\verify-uninstall.ps1 capture -Out C:\wootc-proof

    # ...uninstall (Apps entry or `wootc.exe uninstall`), reboot twice, then:
    .\verify-uninstall.ps1 verify -Baseline C:\wootc-proof -RootDisk keep
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('capture', 'verify')]
    [string]$Mode,

    # capture: where to write the baseline. verify: where to read it from.
    [string]$Out,
    [string]$Baseline,

    # Which uninstall was performed. "keep" is the default the Apps entry and
    # `wootc.exe uninstall` both use; "delete" is the Also-delete-my-Linux-data
    # tick. They have DIFFERENT correct end states, and grading one against the
    # other is the easiest way to record a false ✘.
    [ValidateSet('keep', 'delete')]
    [string]$RootDisk = 'keep',

    # The orphaned-leftovers variant: C:\wootc was deleted by hand before
    # uninstalling. Documents the run; also relaxes the checks that reference
    # files that variant destroys.
    [switch]$Orphaned
)

$ErrorActionPreference = 'Stop'

$EspGptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'

# ── pure logic ───────────────────────────────────────────────────────────────
# Everything below this line down to "collection" is deliberately free of
# Windows APIs so tests/unit/test-verify-uninstall.ps1 can exercise the grading
# on any platform. A checklist generator that is only testable on the hardware
# it grades would be trusted exactly as much as the memory it replaces.

function ConvertTo-EspRelative {
    # ESPs are FAT32: case-insensitive, and written by tools that disagree
    # about slashes. Matches normalizeESPPath in app/esp_ownership.go.
    param([string]$Path)
    $p = $Path -replace '\\', '/'
    return $p.Trim('/').ToLowerInvariant()
}

function Read-OwnershipManifest {
    # The manifest is one ESP-relative path per line; blanks and # comments are
    # skipped. Written one line at a time as each file is created, so it can
    # only ever name a destination wootc was in the act of writing.
    param([string[]]$Lines)
    $owned = @()
    foreach ($line in @($Lines)) {
        $t = "$line".Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $owned += (ConvertTo-EspRelative $t)
    }
    # No unary comma: `return , @()` unrolls to $null in the pipeline, so an
    # EMPTY result would reach `@($x).Count` as 1. Callers wrap in @() instead,
    # which is correct for zero, one and many. The grader reported a phantom
    # firmware entry on a perfectly clean machine until this was fixed.
    return $owned
}

function Compare-EspTrees {
    <#
        The spec's ESP check is two-sided, and the second side is the one that
        matters for a v1.0 data-safety criterion: it is not enough that wootc's
        files are gone, nothing ELSE may have been touched. A dual-boot user's
        Fedora or vendor recovery entry disappearing during our uninstall is
        precisely the failure this criterion exists to rule out.
    #>
    param(
        [hashtable]$Before,        # esp-relative path -> sha256
        [hashtable]$After,
        [string[]]$Owned
    )
    $ownedSet = @{}
    foreach ($o in @($Owned)) { $ownedSet[$o] = $true }

    $ownedRemaining = @()
    $foreignRemoved = @()
    $foreignChanged = @()

    foreach ($path in $Before.Keys) {
        $isOwned = $ownedSet.ContainsKey($path)
        # EFI/wootc is ours by definition — nothing else writes there — so it
        # counts as claimed even when the manifest predates a given file.
        if (-not $isOwned -and $path.StartsWith('efi/wootc/')) { $isOwned = $true }

        if ($isOwned) {
            if ($After.ContainsKey($path)) { $ownedRemaining += $path }
            continue
        }
        if (-not $After.ContainsKey($path)) { $foreignRemoved += $path; continue }
        if ($After[$path] -ne $Before[$path]) { $foreignChanged += $path }
    }

    $added = @()
    foreach ($path in $After.Keys) {
        if (-not $Before.ContainsKey($path)) { $added += $path }
    }

    return [pscustomobject]@{
        OwnedRemaining = @($ownedRemaining | Sort-Object)
        ForeignRemoved = @($foreignRemoved | Sort-Object)
        ForeignChanged = @($foreignChanged | Sort-Object)
        Added          = @($added | Sort-Object)
        Pass           = (@($ownedRemaining).Count -eq 0 -and
                          @($foreignRemoved).Count -eq 0 -and
                          @($foreignChanged).Count -eq 0)
    }
}

function Get-WootcFirmwareEntries {
    <#
        `bcdedit /enum firmware` prints blank-line-separated blocks. An entry is
        wootc's if its description names us or its device/path points into
        EFI\wootc. Returns the identifier of each match, so "no wootc residue"
        is a list a reader can check rather than an assertion.
    #>
    param([string]$BcdText)
    $hits = @()
    $blocks = ($BcdText -split "(\r?\n){2,}") | Where-Object { "$_".Trim() }
    foreach ($block in $blocks) {
        if ($block -notmatch '(?i)wootc|tunaos') { continue }
        $id = '<unidentified entry>'
        foreach ($line in ($block -split "\r?\n")) {
            if ($line -match '(?i)^\s*identifier\s+(\S+)') { $id = $Matches[1]; break }
        }
        $hits += $id
    }
    return $hits   # see Read-OwnershipManifest: no unary comma, callers use @()
}

function Test-PowerRestored {
    <#
        The installer records the pre-install values in
        C:\wootc\install\prior-power.txt and restorePriorPowerState() puts them
        back — but ONLY re-enables, never disables: a value that was 0 before
        must still be 0, and a value that was 1 must be 1 again.

        Missing baseline is NOT a pass. On the orphaned-leftovers run the record
        is destroyed with the folder, and restorePriorPowerState() returns
        early — so hibernation stays off forever and nothing says so. That is a
        real finding, not an excuse to skip the box.
    #>
    param([hashtable]$Prior, [hashtable]$Current)

    if ($null -eq $Prior -or $Prior.Count -eq 0) {
        return [pscustomobject]@{
            Pass    = $false
            Detail  = 'no pre-install record was captured (C:\wootc\install\prior-power.txt) — restoration cannot be verified, and on the orphaned-leftovers path it also cannot happen'
        }
    }
    $problems = @()
    foreach ($key in @('hibernate', 'hiberboot')) {
        $was = "$($Prior[$key])".Trim()
        $now = "$($Current[$key])".Trim()
        if ($was -eq '') { continue }   # installer could not read it either
        if ($was -ne $now) {
            $problems += "$key was '$was' before the install and is '$now' now"
        }
    }
    return [pscustomobject]@{
        Pass   = (@($problems).Count -eq 0)
        Detail = if (@($problems).Count -eq 0) {
            "hibernate=$($Prior['hibernate']) hiberboot=$($Prior['hiberboot']) — both back to their pre-install values"
        } else { $problems -join '; ' }
    }
}

function Test-WootcDirState {
    <#
        `C:\wootc` removed" is only the right expectation for the DELETE
        choice. On the default keep-root.disk uninstall the code removes
        install\ and leaves the folder with disks\root.disk in it, on purpose,
        so a fixed build can retry without re-downloading. Grading a correct
        keep run against "the folder is gone" is how a good machine gets a ✘.
    #>
    param(
        [ValidateSet('keep', 'delete')][string]$Choice,
        [bool]$WootcDirExists,
        [bool]$InstallDirExists,
        [bool]$RootDiskExists
    )
    $problems = @()
    if ($InstallDirExists) { $problems += 'C:\wootc\install still exists' }
    if ($Choice -eq 'delete') {
        if ($WootcDirExists) { $problems += 'C:\wootc still exists after a delete-my-Linux-data uninstall' }
        if ($RootDiskExists) { $problems += 'root.disk still exists after a delete-my-Linux-data uninstall' }
    } else {
        if (-not $RootDiskExists) { $problems += 'root.disk is GONE after a keep uninstall — the keep choice was not honoured' }
    }
    return [pscustomobject]@{
        Pass   = (@($problems).Count -eq 0)
        Detail = if (@($problems).Count -eq 0) {
            if ($Choice -eq 'delete') { 'C:\wootc and root.disk removed, as chosen' }
            else { 'install\ removed; root.disk kept, as chosen' }
        } else { $problems -join '; ' }
    }
}

function Test-CleanBoots {
    <#
        "Windows boots clean twice" — counted from the event log rather than
        attested. Boot events since the uninstall, minus any bugcheck or
        unexpected-shutdown in the same window.
    #>
    param([int]$BootCount, [int]$BugCheckCount, [int]$DirtyShutdownCount, [int]$Required = 2)
    $problems = @()
    if ($BootCount -lt $Required) { $problems += "only $BootCount clean boot(s) recorded since the uninstall, need $Required" }
    if ($BugCheckCount -gt 0) { $problems += "$BugCheckCount bugcheck(s) since the uninstall" }
    if ($DirtyShutdownCount -gt 0) { $problems += "$DirtyShutdownCount unexpected shutdown(s) since the uninstall" }
    return [pscustomobject]@{
        Pass   = (@($problems).Count -eq 0)
        Detail = if (@($problems).Count -eq 0) { "$BootCount boots, no bugchecks, no unexpected shutdowns" } else { $problems -join '; ' }
    }
}

function Format-Checklist {
    <#
        The output is the artifact that gets attached to #238, so it is written
        to be pasted whole: every box carries the evidence that ticked it, and
        a ✘ says what was found instead of just failing.
    #>
    param([System.Collections.IEnumerable]$Results, [hashtable]$Meta)
    $lines = @()
    $lines += '## Uninstall restoration checklist (#238)'
    $lines += ''
    foreach ($k in @($Meta.Keys | Sort-Object)) { $lines += "- **$k**: $($Meta[$k])" }
    $lines += ''
    foreach ($r in $Results) {
        $box = if ($r.Pass) { '[x]' } else { '[ ]' }
        $mark = if ($r.Pass) { '✔' } else { '✘' }
        $lines += "- $box $mark **$($r.Name)** — $($r.Detail)"
    }
    $lines += ''
    $failed = @($Results | Where-Object { -not $_.Pass })
    if (@($failed).Count -eq 0) {
        $lines += '**RESULT: PASS** — every box ticked from collected evidence.'
    } else {
        $lines += "**RESULT: FAIL** — $(@($failed).Count) unticked: $((@($failed).Name) -join ', ')."
    }
    return ($lines -join "`n")
}

# ── collection (Windows) ─────────────────────────────────────────────────────

function Get-EspAccess {
    # Returns @{ Letter; Temporary }. Assigns a temporary letter only when the
    # ESP has none, and the caller always releases it.
    $sysDisk = (Get-Partition -DriveLetter C -ErrorAction Stop).DiskNumber
    $esp = Get-Partition -DiskNumber $sysDisk -ErrorAction Stop |
        Where-Object { $_.GptType -eq $EspGptType } | Select-Object -First 1
    if (-not $esp) { throw "no EFI system partition found on disk $sysDisk" }

    foreach ($ap in @($esp.AccessPaths)) {
        if ($ap -match '^([A-Za-z]):\\$') {
            return @{ Letter = $Matches[1]; Temporary = $false }
        }
    }
    foreach ($candidate in @('S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z')) {
        if (Test-Path "${candidate}:\") { continue }
        Add-PartitionAccessPath -DiskNumber $esp.DiskNumber `
            -PartitionNumber $esp.PartitionNumber -AccessPath "${candidate}:\" -ErrorAction Stop
        return @{ Letter = $candidate; Temporary = $true; Partition = $esp }
    }
    throw 'no free drive letter to mount the ESP'
}

function Remove-EspAccess {
    param($Access)
    if (-not $Access.Temporary) { return }
    Remove-PartitionAccessPath -DiskNumber $Access.Partition.DiskNumber `
        -PartitionNumber $Access.Partition.PartitionNumber `
        -AccessPath "$($Access.Letter):\" -ErrorAction SilentlyContinue
}

function Get-EspFileMap {
    # esp-relative path -> sha256. Hashes, not just names: "nothing else was
    # touched" has to mean the bytes too.
    param([string]$Letter)
    $root = "${Letter}:\"
    $map = @{}
    Get-ChildItem -Path $root -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            $rel = ConvertTo-EspRelative ($_.FullName.Substring($root.Length))
            $map[$rel] = (Get-FileHash -Path $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
        }
    return $map
}

function Get-PowerSettings {
    $hibernate = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' `
        -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    $hiberboot = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' `
        -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    return @{ hibernate = "$hibernate"; hiberboot = "$hiberboot" }
}

function Read-PriorPowerFile {
    # hibernate=<n>\nhiberboot=<n>\n, written by recordPriorPowerState().
    param([string]$Path)
    $prior = @{}
    if (-not (Test-Path $Path)) { return $prior }
    foreach ($line in (Get-Content -Path $Path -ErrorAction SilentlyContinue)) {
        if ("$line" -match '^\s*(hibernate|hiberboot)\s*=\s*(.*)$') {
            $prior[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $prior
}

function Invoke-Capture {
    param([string]$OutDir)
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $access = Get-EspAccess
    try {
        $espMap = Get-EspFileMap -Letter $access.Letter
        $manifestPath = "$($access.Letter):\EFI\wootc\wootc-owned.txt"
        $manifestLines = if (Test-Path $manifestPath) { Get-Content -Path $manifestPath } else { @() }
    } finally {
        Remove-EspAccess -Access $access
    }

    $bcd = (& bcdedit /enum firmware 2>&1 | Out-String)

    # The one file that MUST be copied out: uninstall deletes C:\wootc\install.
    $prior = Read-PriorPowerFile -Path 'C:\wootc\install\prior-power.txt'

    $snapshot = [ordered]@{
        capturedAt     = (Get-Date).ToUniversalTime().ToString('o')
        computer       = $env:COMPUTERNAME
        windows        = (Get-CimInstance Win32_OperatingSystem).Caption
        windowsVersion = (Get-CimInstance Win32_OperatingSystem).Version
        machine        = "$((Get-CimInstance Win32_ComputerSystem).Manufacturer) $((Get-CimInstance Win32_ComputerSystem).Model)"
        firmwareBcd    = $bcd
        wootcEntries   = @(Get-WootcFirmwareEntries -BcdText $bcd)
        espFiles       = $espMap
        espOwned       = @(Read-OwnershipManifest -Lines $manifestLines)
        priorPower     = $prior
        powerNow       = Get-PowerSettings
        wootcDir       = (Test-Path 'C:\wootc')
        installDir     = (Test-Path 'C:\wootc\install')
        rootDisk       = ((Test-Path 'C:\wootc\disks\root.disk') -or (Test-Path 'C:\wootc\disks\root.vhdx'))
        uninstallKey   = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\wootc')
    }
    $file = Join-Path $OutDir 'baseline.json'
    $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $file -Encoding UTF8

    Write-Host "Baseline captured to $file"
    Write-Host "  ESP files hashed : $($espMap.Count)"
    Write-Host "  wootc-claimed    : $(@($snapshot.espOwned).Count)"
    Write-Host "  firmware entries : $(@($snapshot.wootcEntries).Count) ($((@($snapshot.wootcEntries)) -join ', '))"
    if (@($prior.Keys).Count -eq 0) {
        Write-Warning 'C:\wootc\install\prior-power.txt is missing — the power-restore box CANNOT pass. Capture before deleting C:\wootc by hand.'
    } else {
        Write-Host "  prior power      : hibernate=$($prior['hibernate']) hiberboot=$($prior['hiberboot'])"
    }
    Write-Host ''
    Write-Host 'Now uninstall, reboot twice, and run: verify -Baseline ' -NoNewline
    Write-Host $OutDir
}

function Invoke-Verify {
    param([string]$BaselineDir, [string]$Choice, [bool]$WasOrphaned)
    $file = Join-Path $BaselineDir 'baseline.json'
    if (-not (Test-Path $file)) { throw "no baseline at $file — run 'capture' before uninstalling" }
    $base = Get-Content -Path $file -Raw | ConvertFrom-Json

    $access = Get-EspAccess
    try { $espAfter = Get-EspFileMap -Letter $access.Letter }
    finally { Remove-EspAccess -Access $access }

    $bcdNow = (& bcdedit /enum firmware 2>&1 | Out-String)
    $entriesNow = @(Get-WootcFirmwareEntries -BcdText $bcdNow)

    # PSCustomObject -> hashtable for the pure comparators.
    $espBefore = @{}
    foreach ($p in $base.espFiles.PSObject.Properties) { $espBefore[$p.Name] = $p.Value }
    $prior = @{}
    if ($base.priorPower) {
        foreach ($p in $base.priorPower.PSObject.Properties) { $prior[$p.Name] = $p.Value }
    }

    $espResult = Compare-EspTrees -Before $espBefore -After $espAfter -Owned @($base.espOwned)
    $power = Test-PowerRestored -Prior $prior -Current (Get-PowerSettings)
    $dirs = Test-WootcDirState -Choice $Choice `
        -WootcDirExists (Test-Path 'C:\wootc') `
        -InstallDirExists (Test-Path 'C:\wootc\install') `
        -RootDiskExists ((Test-Path 'C:\wootc\disks\root.disk') -or (Test-Path 'C:\wootc\disks\root.vhdx'))

    $since = [datetime]::Parse($base.capturedAt).ToUniversalTime()
    $boots = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Boot'; Id = 20; StartTime = $since } -ErrorAction SilentlyContinue).Count
    if ($boots -eq 0) {
        $boots = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6005; StartTime = $since } -ErrorAction SilentlyContinue).Count
    }
    $bugchecks = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $since } -ErrorAction SilentlyContinue).Count
    $dirty = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue).Count
    $bootRes = Test-CleanBoots -BootCount $boots -BugCheckCount $bugchecks -DirtyShutdownCount $dirty

    $results = @(
        [pscustomobject]@{
            Name = 'Firmware boot entries clean'
            Pass = (@($entriesNow).Count -eq 0)
            Detail = if (@($entriesNow).Count -eq 0) {
                "bcdedit /enum firmware shows no wootc entry (was: $((@($base.wootcEntries)) -join ', '))"
            } else { "still present: $((@($entriesNow)) -join ', ')" }
        }
        [pscustomobject]@{
            Name = 'ESP: every wootc-claimed file gone'
            Pass = (@($espResult.OwnedRemaining).Count -eq 0)
            Detail = if (@($espResult.OwnedRemaining).Count -eq 0) {
                "all $(@($base.espOwned).Count) claimed path(s) removed"
            } else { "left behind: $((@($espResult.OwnedRemaining)) -join ', ')" }
        }
        [pscustomobject]@{
            Name = 'ESP: nothing else touched'
            Pass = (@($espResult.ForeignRemoved).Count -eq 0 -and @($espResult.ForeignChanged).Count -eq 0)
            Detail = if (@($espResult.ForeignRemoved).Count -eq 0 -and @($espResult.ForeignChanged).Count -eq 0) {
                "$($espAfter.Count) file(s) remain, all byte-identical to the capture"
            } else {
                "removed: $((@($espResult.ForeignRemoved)) -join ', '); changed: $((@($espResult.ForeignChanged)) -join ', ')"
            }
        }
        [pscustomobject]@{
            Name = 'Hibernation / Fast Startup restored'
            Pass = $power.Pass
            Detail = $power.Detail
        }
        [pscustomobject]@{
            Name = "C:\wootc state (choice: $Choice)"
            Pass = $dirs.Pass
            Detail = $dirs.Detail
        }
        [pscustomobject]@{
            Name = 'Add/Remove Programs entry gone'
            Pass = (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\wootc'))
            Detail = if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\wootc') {
                'the Uninstall registry key is still registered'
            } else { 'unregistered' }
        }
        [pscustomobject]@{
            Name = 'Windows booted clean twice'
            Pass = $bootRes.Pass
            Detail = $bootRes.Detail
        }
    )

    $meta = @{
        'Machine'   = $base.machine
        'Windows'   = "$($base.windows) ($($base.windowsVersion))"
        'Captured'  = $base.capturedAt
        'Verified'  = (Get-Date).ToUniversalTime().ToString('o')
        'root.disk' = $Choice
        'Variant'   = if ($WasOrphaned) { 'orphaned leftovers (C:\wootc deleted by hand before uninstall)' } else { 'normal' }
    }

    $report = Format-Checklist -Results $results -Meta $meta
    $reportPath = Join-Path $BaselineDir 'checklist.md'
    Set-Content -Path $reportPath -Value $report -Encoding UTF8
    Write-Host $report
    Write-Host ''
    Write-Host "Checklist written to $reportPath — attach it to the field report."

    if (@($results | Where-Object { -not $_.Pass }).Count -gt 0) { exit 1 }
    exit 0
}

# Dot-sourcing (". ./verify-uninstall.ps1") loads the functions without running
# anything, which is how the unit tests reach the grading logic off-Windows.
if ($MyInvocation.InvocationName -ne '.') {
    switch ($Mode) {
        'capture' {
            if (-not $Out) { throw 'capture needs -Out <dir>' }
            Invoke-Capture -OutDir $Out
        }
        'verify' {
            if (-not $Baseline) { throw 'verify needs -Baseline <dir>' }
            Invoke-Verify -BaselineDir $Baseline -Choice $RootDisk -WasOrphaned:$Orphaned.IsPresent
        }
        default {
            Write-Host 'usage: verify-uninstall.ps1 capture -Out <dir>'
            Write-Host '       verify-uninstall.ps1 verify -Baseline <dir> [-RootDisk keep|delete] [-Orphaned]'
            exit 2
        }
    }
}
