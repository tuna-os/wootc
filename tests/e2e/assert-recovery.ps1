# assert-recovery.ps1 — Windows-side assertions for the Recovery & Fault-Injection matrix (#288).
#
# Stages, in the order the harness runs them:
#   baseline     before setup-wootc.ps1 touches anything (run-wootc-e2e.ps1).
#                Records the firmware boot order, the ESP file hashes and the
#                power settings to C:\OEM\recovery-baseline.json. Every later
#                "nothing changed" or "everything restored" claim is graded
#                against this file. Without it, "restored" has no reference.
#   interrupted  after the injected fault (run-e2e.sh, over QGA).
#   retried      after a clean re-run of setup-wootc.ps1.
#   uninstalled  after `wootc.exe uninstall`.
#
# Prints [PASS]/[FAIL] lines and a final RECOVERY-RESULT line; exits 1 if
# anything failed. The pure comparators below take parsed snapshots, so
# tests/unit/test-assert-recovery.ps1 dot-sources this file and proves each
# check can fail without a Windows VM.

param(
    [ValidateSet("baseline", "interrupted", "retried", "uninstalled")]
    [string]$Stage = "interrupted",
    [string]$Fault = "",
    [string]$StateDir = "C:\OEM"
)

$ErrorActionPreference = "Continue"
$script:failures = 0

# Faults that fire before the one-shot entry is armed for a reboot. After one
# of these, the firmware boot configuration must be exactly the baseline: no
# stale entry, no changed order. deploy-failure happens after the reboot, so
# the armed entry may stay. Only the one-shot must be gone.
$PreRebootFaults = @("root-disk", "image-pull", "efi-staging", "bcd-arming", "pre-reboot")

# The files a wootc install stages on the ESP. A retry may add only these
# names, and only once each. A second copy under another name is a duplicate.
$StagedEspFiles = @(
    "efi/fedora/shimx64.efi", "efi/fedora/grubx64.efi", "efi/fedora/mmx64.efi", "efi/fedora/grub.cfg",
    "efi/redhat/grub.cfg", "efi/wootc/grub.cfg",
    "efi/wootc/deployer-vmlinuz", "efi/wootc/deployer-initramfs.img", "efi/wootc/wootc-owned.txt"
)

# Every bcdedit call rewrites the BCD hive on the ESP, so its bytes are not
# evidence of anything. A missing hive still counts.
function Test-VolatileEspFile([string]$Path) {
    return ($Path -match '^efi/microsoft/(boot|recovery)/bcd(\.log\d*)?$')
}

# ── parsing ──────────────────────────────────────────────────────────────────

function ConvertFrom-BcdFirmware {
    <#
        Parses `bcdedit /enum firmware` (English output) into one object per
        block. A value that continues on indented lines (displayorder,
        bootsequence) becomes an array.
    #>
    param([string]$Text)
    $blocks = @()
    $cur = $null
    $key = $null
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match '^\s*$' -or $line -match '^-+\s*$') { $key = $null; continue }
        if ($line -match '^(\S+)\s+(.*\S)\s*$') {
            $key = $Matches[1].ToLowerInvariant()
            $val = $Matches[2]
            if ($key -eq 'identifier') {
                $cur = @{ identifier = $val }
                $blocks += $cur
                continue
            }
            if ($null -ne $cur) { $cur[$key] = @($val) }
            continue
        }
        if ($line -match '^\s+(\S.*\S|\S)\s*$' -and $null -ne $cur -and $key) {
            $cur[$key] = @($cur[$key]) + $Matches[1]
            continue
        }
        $key = $null   # a block title such as "Firmware Boot Manager"
    }
    return $blocks
}

function Get-BootSnapshot {
    # Reduces parsed blocks to what the recovery checks compare.
    param([string]$Text)
    $blocks = @(ConvertFrom-BcdFirmware -Text $Text)
    $fw = $blocks | Where-Object { $_.identifier -eq '{fwbootmgr}' } | Select-Object -First 1
    $entries = @()
    $wootc = @()
    $shim = @()
    foreach ($b in $blocks) {
        if ($b.identifier -eq '{fwbootmgr}') { continue }
        $entries += $b.identifier
        $desc = "$($b['description'])"
        $path = "$($b['path'])"
        if ($desc -match '(?i)wootc|tunaos' -or $path -match '(?i)\\EFI\\wootc\\') { $wootc += $b.identifier }
        if ($path -match '(?i)\\EFI\\fedora\\shimx64\.efi') { $shim += $b.identifier }
    }
    return @{
        entries      = @($entries | Sort-Object)
        wootc        = @($wootc)
        shim         = @($shim)
        displayorder = if ($fw) { @($fw['displayorder'] | Where-Object { $_ }) } else { @() }
        bootsequence = if ($fw) { @($fw['bootsequence'] | Where-Object { $_ }) } else { @() }
    }
}

# ── pure comparators: each returns a list of problems, empty when it passes ──

function Test-BootMatchesBaseline {
    <#
        After a pre-reboot fault or an uninstall, the firmware boot set must be
        the one Windows had before wootc: same entries, same permanent order,
        and no one-shot left armed unless one was there to begin with.
    #>
    param([hashtable]$Baseline, [hashtable]$Current)
    $problems = @()
    $added = @($Current.entries | Where-Object { $Baseline.entries -notcontains $_ })
    $removed = @($Baseline.entries | Where-Object { $Current.entries -notcontains $_ })
    if ($added.Count -gt 0) { $problems += "firmware entries added since baseline: $($added -join ', ')" }
    if ($removed.Count -gt 0) { $problems += "firmware entries removed since baseline: $($removed -join ', ')" }
    if ((@($Baseline.displayorder) -join ' ') -ne (@($Current.displayorder) -join ' ')) {
        $problems += "displayorder changed: was '$(@($Baseline.displayorder) -join ' ')', now '$(@($Current.displayorder) -join ' ')'"
    }
    if (@($Baseline.bootsequence).Count -eq 0 -and @($Current.bootsequence).Count -gt 0) {
        $problems += "one-shot bootsequence left armed: $(@($Current.bootsequence) -join ', ')"
    }
    return $problems
}

function Test-RetryBootEntries {
    <#
        A retry after a failed attempt must end with exactly one new firmware
        entry: the wootc one, pointing at the shim, armed as the one-shot and
        not the permanent default. Two entries means the sweep of the earlier
        attempt's entry did not work.
    #>
    param([hashtable]$Baseline, [hashtable]$Current)
    $problems = @()
    $added = @($Current.entries | Where-Object { $Baseline.entries -notcontains $_ })
    if ($added.Count -ne 1) {
        $problems += "expected exactly 1 new firmware entry after retry, found $($added.Count): $($added -join ', ')"
    }
    $newWootc = @($Current.wootc | Where-Object { $Baseline.entries -notcontains $_ })
    if ($newWootc.Count -ne 1) {
        $problems += "expected exactly 1 wootc firmware entry after retry, found $($newWootc.Count)"
    }
    $newShim = @($Current.shim | Where-Object { $Baseline.entries -notcontains $_ })
    if ($newShim.Count -ne 1) {
        $problems += "expected exactly 1 new entry booting \EFI\fedora\shimx64.efi, found $($newShim.Count)"
    }
    if ($newWootc.Count -eq 1) {
        $g = $newWootc[0]
        if (@($Current.bootsequence) -notcontains $g) { $problems += "wootc entry $g is not armed in the one-shot bootsequence" }
        $head = @($Current.displayorder) | Select-Object -First 1
        if ($head -eq $g) { $problems += "wootc entry $g became the permanent default" }
    }
    $baseHead = @($Baseline.displayorder) | Select-Object -First 1
    $curHead = @($Current.displayorder) | Select-Object -First 1
    if ($baseHead -and $curHead -ne $baseHead) {
        $problems += "permanent default changed from $baseHead to $curHead"
    }
    return $problems
}

function Test-EspAgainstBaseline {
    <#
        Mode 'retried': the only new files allowed are the staged set, each
        once. Mode 'uninstalled': the tree must equal the baseline. In both,
        a file Windows had must still be there with the same bytes.
    #>
    param(
        [hashtable]$Baseline,   # esp-relative path -> sha256
        [hashtable]$Current,
        [ValidateSet('retried', 'uninstalled')][string]$Mode
    )
    $problems = @()
    foreach ($p in $Baseline.Keys) {
        if (-not $Current.ContainsKey($p)) { $problems += "ESP file removed: $p"; continue }
        if ($Current[$p] -ne $Baseline[$p] -and -not (Test-VolatileEspFile $p)) { $problems += "ESP file changed: $p" }
    }
    foreach ($p in $Current.Keys) {
        if ($Baseline.ContainsKey($p)) { continue }
        if ($Mode -eq 'uninstalled') { $problems += "ESP file left behind: $p"; continue }
        if ($StagedEspFiles -notcontains $p) { $problems += "unexpected ESP file after retry (duplicate or stray): $p" }
    }
    return $problems
}

function Test-PowerMatchesBaseline {
    param([hashtable]$Baseline, [hashtable]$Current)
    $problems = @()
    foreach ($k in @('hibernate', 'hiberboot')) {
        if ("$($Baseline[$k])" -ne "$($Current[$k])") {
            $problems += "$k was '$($Baseline[$k])' before the install and is '$($Current[$k])' now"
        }
    }
    return $problems
}

function Test-BlobResume {
    <#
        An interrupted pull leaves verified blobs (named by their sha256) and
        *.part files. After the retry: no *.part may remain, every blob's
        bytes must still hash to its name, and each blob that was verified at
        the interruption must be the same file (same write time), reused and
        not downloaded again.
    #>
    param(
        [hashtable]$Interrupted,    # blob name -> LastWriteTimeUtc ticks
        [object[]]$Current          # @{ Name; Hash; Ticks }
    )
    $problems = @()
    foreach ($b in @($Current)) {
        if ($b.Name -like '*.part') { $problems += "incomplete blob survived the retry: $($b.Name)"; continue }
        if ("$($b.Hash)".ToLowerInvariant() -ne $b.Name) { $problems += "blob $($b.Name) does not hash to its name" }
    }
    foreach ($name in $Interrupted.Keys) {
        $now = @($Current) | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if (-not $now) { $problems += "verified blob $name was discarded instead of reused"; continue }
        if ("$($now.Ticks)" -ne "$($Interrupted[$name])") { $problems += "verified blob $name was rewritten instead of reused" }
    }
    return $problems
}

# ── collection (Windows) ─────────────────────────────────────────────────────

function Assert-True($cond, $label) {
    if ($cond) {
        Write-Host "[PASS] $label"
    } else {
        Write-Host "[FAIL] $label"
        $script:failures++
    }
}

function Assert-NoProblems([string]$Label, [object[]]$Problems) {
    $list = @($Problems | Where-Object { $_ })
    if ($list.Count -eq 0) { Write-Host "[PASS] $Label"; return }
    Write-Host "[FAIL] $Label"
    foreach ($p in $list) { Write-Host "         - $p" }
    $script:failures++
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

function Get-EspFileMap([string]$Letter) {
    $map = @{}
    if (-not $Letter) { return $map }
    $root = $Letter + ':\'
    Get-ChildItem -Path $root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).Replace('\', '/').ToLowerInvariant()
        $map[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    }
    return $map
}

function Get-PowerSettings {
    $hibernate = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -Name HibernateEnabled -ErrorAction SilentlyContinue).HibernateEnabled
    $hiberboot = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    return @{ hibernate = "$hibernate"; hiberboot = "$hiberboot" }
}

function Get-BlobInventory {
    $dir = "C:\wootc\bundle\oci\blobs\sha256"
    $out = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
        $hash = if ($f.Name -like '*.part') { '' } else { (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
        $out += @{ Name = $f.Name; Hash = $hash; Ticks = $f.LastWriteTimeUtc.Ticks }
    }
    return $out
}

function ConvertTo-Hashtable($obj) {
    $h = @{}
    if ($null -eq $obj) { return $h }
    foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Read-Baseline([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
    return @{
        boot  = @{
            entries      = @($raw.boot.entries)
            wootc        = @($raw.boot.wootc)
            shim         = @($raw.boot.shim)
            displayorder = @($raw.boot.displayorder)
            bootsequence = @($raw.boot.bootsequence)
        }
        esp   = ConvertTo-Hashtable $raw.esp
        power = ConvertTo-Hashtable $raw.power
    }
}

function Invoke-Stage {
    $baselinePath = Join-Path $StateDir "recovery-baseline.json"
    $interruptedPath = Join-Path $StateDir "recovery-interrupted.json"

    Write-Host "=== wootc Recovery Assertions (Stage: $Stage, Fault: $Fault) ==="

    $fwText = bcdedit /enum firmware | Out-String
    $boot = Get-BootSnapshot -Text $fwText
    $stateRaw = Get-Content C:\wootc\state.json -Raw -ErrorAction SilentlyContinue

    if ($Stage -eq "baseline") {
        $snapshot = [ordered]@{
            capturedAt = (Get-Date).ToUniversalTime().ToString('o')
            boot       = $boot
            esp        = Get-EspFileMap (Get-EspLetter)
            power      = Get-PowerSettings
        }
        $snapshot | ConvertTo-Json -Depth 6 | Set-Content -Path $baselinePath -Encoding UTF8
        Write-Host "Baseline written to $baselinePath"
        Write-Host "  firmware entries: $(@($boot.entries).Count)  displayorder: $(@($boot.displayorder) -join ' ')"
        Write-Host "  ESP files: $($snapshot.esp.Count)  power: hibernate=$($snapshot.power.hibernate) hiberboot=$($snapshot.power.hiberboot)"
        Assert-True (@($boot.wootc).Count -eq 0) "baseline has no wootc firmware entry (a leftover would hide a stale entry later)"
        return
    }

    $base = Read-Baseline $baselinePath
    Assert-True ($null -ne $base) "pre-install baseline present at $baselinePath"

    switch ($Stage) {
        "interrupted" {
            Write-Host "── Verifying Interrupted State (Fault: $Fault) ──"

            $current = bcdedit /enum "{current}" | Out-String
            Assert-True ($null -ne $current -and $current -match 'winload') "Windows booted normally (clean winload in {current})"

            $armedWootc = @($boot.bootsequence | Where-Object { $boot.wootc -contains $_ -or $boot.shim -contains $_ })
            Assert-True ($armedWootc.Count -eq 0) "no wootc entry left in the one-shot bootsequence (found: $($armedWootc -join ', '))"

            if ($base) {
                $baseHead = @($base.boot.displayorder) | Select-Object -First 1
                $curHead = @($boot.displayorder) | Select-Object -First 1
                Assert-True ($curHead -eq $baseHead) "permanent default unchanged ($curHead, baseline $baseHead)"
                if ($PreRebootFaults -contains $Fault) {
                    Assert-NoProblems "firmware boot configuration equals the baseline (no stale entry)" (Test-BootMatchesBaseline -Baseline $base.boot -Current $boot)
                }
            }

            Assert-True ($null -ne $stateRaw) "state.json exists after interruption"
            Assert-True ($stateRaw -notmatch '"state":\s*"armed"') "state.json is NOT armed after interruption (got: $stateRaw)"
            if ($Fault -eq "pre-reboot") {
                Assert-True ($stateRaw -match '"state":\s*"staged"' -or $stateRaw -match '"cancelled"') "state.json records staged/cancelled for pre-reboot cancellation"
            } else {
                Assert-True ($stateRaw -match '"state":\s*"failed"' -or $stateRaw -match '"state":\s*"staged"') "state.json records failed/staged state"
            }

            # Record which blobs were already verified, so the retried stage
            # can prove they were reused rather than downloaded again.
            $blobs = @(Get-BlobInventory)
            $verified = @{}
            foreach ($b in $blobs) {
                if ($b.Name -notlike '*.part' -and "$($b.Hash)".ToLowerInvariant() -eq $b.Name) { $verified[$b.Name] = $b.Ticks }
            }
            if ($Fault -eq "image-pull") {
                Assert-True (@($blobs | Where-Object { $_.Name -like '*.part' }).Count -gt 0) "interrupted pull left an incomplete (*.part) blob to recover from"
                Assert-True ($verified.Count -gt 0) "interrupted pull left at least one verified blob to reuse"
            }
            @{ fault = $Fault; verifiedBlobs = $verified } | ConvertTo-Json -Depth 4 | Set-Content -Path $interruptedPath -Encoding UTF8
        }

        "retried" {
            Write-Host "── Verifying Retried State (Idempotency) ──"

            Assert-True ($null -ne $stateRaw -and $stateRaw -match '"state":\s*"armed"') "state.json reports armed on retry"
            Assert-True (@($boot.wootc).Count -eq 1) "exactly ONE wootc firmware entry on retry (found $(@($boot.wootc).Count))"
            if ($base) {
                Assert-NoProblems "retry left exactly one armed, non-default wootc entry" (Test-RetryBootEntries -Baseline $base.boot -Current $boot)
            }

            Assert-True ((Test-Path C:\wootc\disks\root.disk) -or (Test-Path C:\wootc\disks\root.vhdx)) "root disk exists"

            $espLetter = Get-EspLetter
            Assert-True ($espLetter -ne "") "ESP drive letter resolved ($espLetter)"
            if ($espLetter) {
                Assert-True (Test-Path "${espLetter}:\EFI\fedora\shimx64.efi") "ESP: shimx64.efi present"
                Assert-True (Test-Path "${espLetter}:\EFI\fedora\grubx64.efi") "ESP: grubx64.efi present"
                Assert-True (Test-Path "${espLetter}:\EFI\wootc\deployer-vmlinuz") "ESP: deployer-vmlinuz present"
                Assert-True (Test-Path "${espLetter}:\EFI\wootc\deployer-initramfs.img") "ESP: deployer-initramfs.img present"
                $cfg = Get-Content "${espLetter}:\EFI\fedora\grub.cfg" -Raw -ErrorAction SilentlyContinue
                Assert-True ($null -ne $cfg -and $cfg -match 'wootc') "ESP: grub.cfg present and valid"
                if ($base) {
                    Assert-NoProblems "ESP: no duplicate or stray files, Windows' files untouched" (Test-EspAgainstBaseline -Baseline $base.esp -Current (Get-EspFileMap $espLetter) -Mode retried)
                }
            }

            $interrupted = $null
            if (Test-Path $interruptedPath) { $interrupted = Get-Content -Path $interruptedPath -Raw | ConvertFrom-Json }
            $verified = if ($interrupted) { ConvertTo-Hashtable $interrupted.verifiedBlobs } else { @{} }
            if ($Fault -eq "image-pull" -or $verified.Count -gt 0) {
                Assert-NoProblems "image blobs: verified reused, incomplete discarded" (Test-BlobResume -Interrupted $verified -Current @(Get-BlobInventory))
            }
        }

        "uninstalled" {
            Write-Host "── Verifying Uninstalled State ──"

            Assert-True (@($boot.wootc).Count -eq 0) "0 wootc firmware entries remain after uninstall (found $(@($boot.wootc).Count))"
            if ($base) {
                Assert-NoProblems "firmware boot configuration restored to the baseline" (Test-BootMatchesBaseline -Baseline $base.boot -Current $boot)
                Assert-NoProblems "hibernation / Fast Startup restored to the baseline" (Test-PowerMatchesBaseline -Baseline $base.power -Current (Get-PowerSettings))
            }

            $espLetter = Get-EspLetter
            if ($espLetter -and $base) {
                Assert-NoProblems "ESP restored to the baseline (nothing left, nothing else touched)" (Test-EspAgainstBaseline -Baseline $base.esp -Current (Get-EspFileMap $espLetter) -Mode uninstalled)
            }

            Assert-True (-not (Test-Path "C:\wootc\install")) "C:\wootc\install removed"
            Assert-True (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\wootc")) "Add/Remove Programs entry unregistered"
        }
    }
}

# Dot-sourcing loads the comparators without touching the machine; that is how
# tests/unit/test-assert-recovery.ps1 reaches them off-Windows.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Stage
    Write-Host "=========================================="
    if ($script:failures -gt 0) {
        Write-Host "RECOVERY-RESULT: FAIL ($($script:failures) failures)"
        exit 1
    }
    Write-Host "RECOVERY-RESULT: PASS"
    exit 0
}
