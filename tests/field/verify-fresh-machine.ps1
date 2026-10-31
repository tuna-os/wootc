#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The trust surface, checked on a Windows machine that has never seen wootc.

.DESCRIPTION
    v1.0 criterion 4 (#241): winget serves the native setup, the published
    setup and legacy assets match their manifests, and the native packages
    carry their own brand names rather than ours.
    The check is about what a stranger's Windows says about these files BEFORE
    anything runs — the one part no E2E run can observe, because the harness
    never asks Windows what it thinks of the binary.

    This grades all four from evidence and writes the checklist. It is expected
    to report ✘ today: code signing is not implemented yet (#229 is the spend
    decision, #230 the pipeline plumbing) and no winget submission has been
    accepted yet (#221). Those ✘s are the point — the checklist is what turns
    "still blocked on signing" into a dated artifact instead of a memory, and
    the day #230 lands this becomes a script run rather than a hand-written
    list.

    Criterion 1 is "winget install resolves AND installs", so the script runs
    a real `winget install TunaOS.wootc` (no -SkipWinget) and checks that the
    native setup installed the shell from this release's setup manifest.

    Run it on a clean Windows 11 VM that has never had wootc installed, and
    again on a real machine.

.EXAMPLE
    .\verify-fresh-machine.ps1 -Tag v1.0.0 -Out C:\fresh-proof

.EXAMPLE
    # Grade artefacts already downloaded, skipping the winget install:
    .\verify-fresh-machine.ps1 -Tag v1.0.0 -Out C:\fresh-proof -Downloaded C:\dl -SkipWinget
#>
[CmdletBinding()]
param(
    # The release to verify, e.g. v1.0.0. Defaults to whatever releases/latest
    # resolves to, which is what a real first-time user gets.
    [string]$Tag,

    [string]$Out = "$env:USERPROFILE\wootc-fresh-proof",

    # Use already-downloaded assets instead of fetching them.
    [string]$Downloaded,

    # winget install mutates the machine; skip it when grading a VM snapshot
    # that must stay pristine. Both winget boxes then stay unticked.
    [switch]$SkipWinget,

    # Where app/branding/<brand>/brand.json lives, so the expected per-brand
    # identity comes from the same file the build wears rather than a copy that
    # can drift. Defaults to this checkout.
    [string]$BrandDir
)

$ErrorActionPreference = 'Stop'
$Repo = 'tuna-os/wootc'

# ── pure logic ───────────────────────────────────────────────────────────────
# Free of Windows APIs so tests/unit/test-verify-fresh-machine.ps1 can drive the
# grading anywhere. The uninstall proof (#238) learned this the hard way: the
# first run of its tests found a bug that would have failed a passing machine.

function Test-AuthenticodeResult {
    <#
        Get-AuthenticodeSignature returns a status, not a boolean, and only
        `Valid` counts. `UnknownError` and `NotSigned` are today's answers;
        `HashMismatch` would mean a tampered download and must never be
        confused with "not signed yet".
    #>
    param([string]$Status, [string]$SignerSubject)

    switch ($Status) {
        'Valid' {
            if (-not $SignerSubject) {
                return [pscustomobject]@{ Pass = $false; Detail = 'signature reports Valid but names no signer — nothing for UAC or SmartScreen to show' }
            }
            return [pscustomobject]@{ Pass = $true; Detail = "signed: $SignerSubject" }
        }
        'NotSigned' {
            return [pscustomobject]@{ Pass = $false; Detail = 'NOT SIGNED — SmartScreen will show the unrecognized-app wall and UAC will say "unknown publisher" (blocked on #229/#230)' }
        }
        'HashMismatch' {
            return [pscustomobject]@{ Pass = $false; Detail = 'HASH MISMATCH — the file does not match its signature. Do not run it; re-download and report this' }
        }
        default {
            return [pscustomobject]@{ Pass = $false; Detail = "signature status '$Status' is not Valid" }
        }
    }
}

function Test-Sha256Manifest {
    <#
        SHA256SUMS is `<hash>  <name>` per line, as sha256sum writes it. A name
        that is absent from the manifest is a failure, not a skip: an asset
        nobody published a hash for is exactly the one worth noticing.
    #>
    param([string]$Manifest, [string]$FileName, [string]$ActualHash)

    $expected = $null
    foreach ($line in ($Manifest -split "\r?\n")) {
        $t = "$line".Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\s+', 2
        if (@($parts).Count -lt 2) { continue }
        if ($parts[1].TrimStart('*') -eq $FileName) { $expected = $parts[0]; break }
    }
    if (-not $expected) {
        return [pscustomobject]@{ Pass = $false; Detail = "$FileName is not listed in SHA256SUMS" }
    }
    if ($expected.ToLowerInvariant() -ne "$ActualHash".ToLowerInvariant()) {
        return [pscustomobject]@{ Pass = $false; Detail = "$FileName hash mismatch: published $expected, downloaded $ActualHash" }
    }
    return [pscustomobject]@{ Pass = $true; Detail = "$FileName matches SHA256SUMS ($($expected.Substring(0, 16))…)" }
}

function Test-BrandIdentity {
    <#
        Criterion 4's fourth item: each branded exe shows ITS OWN identity, no
        "wootc" text. That identity lives in the exe's VERSIONINFO resource —
        the Properties ▸ Details tab, and the program name UAC shows for an
        unsigned binary.

        An EMPTY version info is a failure, not a pass-by-absence. No build in
        this repo carries one today: app/rsrc_windows_amd64.syso is generated by
        `rsrc -ico -manifest`, which emits icon and manifest only, so every exe
        — generic and branded alike — has no ProductName, FileDescription,
        CompanyName or version at all, and the properties dialog this issue
        asks for a screenshot of is blank. Saying so is the whole job here.
    #>
    param(
        [hashtable]$VersionInfo,   # ProductName / FileDescription / CompanyName / ProductVersion
        [string]$ExpectedProduct,
        [string]$ExpectedVersion,
        [switch]$Branded
    )

    if ($null -eq $VersionInfo -or @($VersionInfo.Keys).Count -eq 0 -or
        -not ("$($VersionInfo['ProductName'])$($VersionInfo['FileDescription'])".Trim())) {
        return [pscustomobject]@{
            Pass   = $false
            Detail = 'no VERSIONINFO resource — Properties ▸ Details is blank, so there is no identity to check (the .syso carries icon + manifest only)'
        }
    }

    $problems = @()
    foreach ($field in @('ProductName', 'FileDescription', 'CompanyName', 'ProductVersion')) {
        if (-not "$($VersionInfo[$field])".Trim()) {
            $problems += "$field is missing"
        }
    }
    if ($ExpectedVersion -and "$($VersionInfo['ProductVersion'])".Trim().TrimStart('v') -ne $ExpectedVersion.TrimStart('v')) {
        $problems += "ProductVersion does not match release $ExpectedVersion"
    }
    $product = "$($VersionInfo['ProductName'])".Trim()
    if ($ExpectedProduct -and $product -ne $ExpectedProduct) {
        $problems += "ProductName is '$product', expected '$ExpectedProduct'"
    }
    if ($Branded) {
        foreach ($field in @('ProductName', 'FileDescription', 'CompanyName')) {
            $value = "$($VersionInfo[$field])"
            if ($value -match '(?i)wootc') {
                $problems += "$field says '$value' — a branded build must never surface the project name"
            }
        }
    }
    return [pscustomobject]@{
        Pass   = (@($problems).Count -eq 0)
        Detail = if (@($problems).Count -eq 0) { "identity: '$product'" } else { $problems -join '; ' }
    }
}
function Get-NativeSetupName {
    param([string]$ExeName)
    if ($ExeName -eq 'wootc') { return 'wootc-Installer-Setup.exe' }
    return "$ExeName-Setup.exe"
}

function Test-NativeSetupIdentity {
    param([string]$FileName, [string]$ExpectedExeName)
    $expected = Get-NativeSetupName -ExeName $ExpectedExeName
    if ($FileName -ne $expected) {
        return [pscustomobject]@{ Pass = $false; Detail = "setup is '$FileName', expected '$expected'" }
    }
    return [pscustomobject]@{ Pass = $true; Detail = "native setup identity: '$FileName'" }
}

function Test-WingetPackage {
    <#
        `winget show TunaOS.wootc` output, parsed for the version it would
        install. The criterion is that a fresh machine resolves the package AND
        gets the 1.0-track build — a stale winget manifest resolving to an old
        alpha is a distinct, quieter failure than no package at all.
    #>
    param([string]$ShowOutput, [string]$ExpectedVersion, [int]$ExitCode)

    if ($ExitCode -ne 0 -or -not "$ShowOutput".Trim()) {
        return [pscustomobject]@{ Pass = $false; Detail = 'winget could not resolve TunaOS.wootc (no accepted submission yet?)' }
    }
    $found = $null
    foreach ($line in ($ShowOutput -split "\r?\n")) {
        if ($line -match '^\s*Version:\s*(\S+)') { $found = $Matches[1]; break }
    }
    if (-not $found) {
        return [pscustomobject]@{ Pass = $false; Detail = 'winget resolved the package but reported no Version' }
    }
    $want = "$ExpectedVersion".TrimStart('v')
    if (-not $want) {
        return [pscustomobject]@{ Pass = $false; Detail = 'no release version was resolved for the comparison' }
    }
    if ($found.TrimStart('v') -ne $want) {
        return [pscustomobject]@{ Pass = $false; Detail = "winget serves $found, expected $want — the manifest is behind the release" }
    }
    return [pscustomobject]@{ Pass = $true; Detail = "winget serves TunaOS.wootc $found" }
}

function Test-WingetInstall {
    <#
        `winget install TunaOS.wootc` on a fresh machine. `winget show` only
        proves the manifest resolves; the criterion is that the Inno setup
        succeeds, leaves the protected shell installed, and has this release's
        native manifest hash. The setup itself is hashed from the direct
        release download because Inno does not leave a portable copy in the
        WinGet package cache.
    #>
    param([int]$ExitCode, [string]$InstalledPath, [string]$ActualHash, [string]$Manifest, [string]$FileName = 'wootc-Installer-Setup.exe')

    if ($ExitCode -ne 0) {
        $hex = '0x{0:X8}' -f $ExitCode
        $why = switch ($hex) {
            '0x8A150014' { 'no package matched TunaOS.wootc (no accepted submission yet?)' }
            '0x8A15002B' { 'already installed — this is not a fresh machine' }
            '0x8A150011' { 'installer hash does not match the manifest' }
            default      { 'see winget-install.txt' }
        }
        return [pscustomobject]@{ Pass = $false; Detail = "winget install exited ${hex}: $why" }
    }
    if (-not $InstalledPath) {
        return [pscustomobject]@{ Pass = $false; Detail = 'winget reported success but no installed native shell was found under Program Files' }
    }
    $h = Test-Sha256Manifest -Manifest $Manifest -FileName $FileName -ActualHash $ActualHash
    if (-not $h.Pass) {
        return [pscustomobject]@{ Pass = $false; Detail = "the published ${FileName} does not match the native manifest: $($h.Detail)" }
    }
    return [pscustomobject]@{ Pass = $true; Detail = "winget installed $InstalledPath; the published ${FileName} matches its native manifest" }
}

function Format-Checklist {
    param([System.Collections.IEnumerable]$Results, [hashtable]$Meta)
    $lines = @('## Fresh-machine verification checklist (#241)', '')
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
    $lines += ''
    $lines += 'Screenshots still to attach by hand (nothing can capture these for you):'
    $lines += '- the UAC prompt as it appears on launch'
    $lines += '- the setup/legacy executable Properties ▸ Details tab'
    $lines += '- the SmartScreen interstitial, or its absence'
    return ($lines -join "`n")
}

# ── collection (Windows) ─────────────────────────────────────────────────────

function Get-ExeVersionInfo {
    param([string]$Path)
    $vi = (Get-Item -LiteralPath $Path).VersionInfo
    return @{
        ProductName     = "$($vi.ProductName)"
        FileDescription = "$($vi.FileDescription)"
        CompanyName     = "$($vi.CompanyName)"
        ProductVersion  = "$($vi.ProductVersion)"
    }
}

function Resolve-ReleaseTag {
    # Resolve once so winget, every download, and VERSIONINFO use one release,
    # even if another release is published while the check is running.
    param([string]$RequestedTag)
    if ($RequestedTag) { return $RequestedTag }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    if (-not "$($release.tag_name)".Trim()) { throw 'latest release did not report a tag' }
    return [string]$release.tag_name
}

function Get-ReleaseAsset {
    param([string]$Tag, [string]$Name, [string]$Destination)
    if (-not $Tag) { throw 'Resolve the release tag before downloading assets' }
    $base = "https://github.com/$Repo/releases/download/$Tag"
    $dest = Join-Path $Destination $Name
    Invoke-WebRequest -Uri "$base/$Name" -OutFile $dest -UseBasicParsing
    return $dest
}

function Find-WingetInstalledShell {
    # An Inno package installs the protected shell under Program Files; it
    # does not leave a portable exe in WinGet's package cache.
    param([string]$Brand = 'wootc')
    $programFiles = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $shell = Join-Path $programFiles "wootc Native\$Brand\bundle\Wootc.Shell.exe"
    if (Test-Path -LiteralPath $shell -PathType Leaf) { return $shell }
    return $null
}

function Get-BrandExpectations {
    # productName + exeName straight from the brand configs the build wears, so
    # the expectation cannot drift from the thing it grades.
    param([string]$Dir)
    $brands = @()
    if (-not (Test-Path $Dir)) { return $brands }
    foreach ($d in (Get-ChildItem -Path $Dir -Directory)) {
        $bj = Join-Path $d.FullName 'brand.json'
        if (-not (Test-Path $bj)) { continue }
        $j = Get-Content -Path $bj -Raw | ConvertFrom-Json
        $brands += [pscustomobject]@{
            Id = $d.Name; ExeName = "$($j.exeName)"; ProductName = "$($j.productName)"
        }
    }
    return $brands
}

function Invoke-Verification {
    $Tag = Resolve-ReleaseTag -RequestedTag $Tag
    New-Item -ItemType Directory -Force -Path $Out | Out-Null

    if (-not $BrandDir) {
        $BrandDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'app/branding'
    }
    $brands = @(Get-BrandExpectations -Dir $BrandDir)
    if (@($brands).Count -eq 0) { throw "no brand configs under $BrandDir — pass -BrandDir <checkout>/app/branding" }

    $dl = if ($Downloaded) { $Downloaded } else { Join-Path $Out 'download' }
    New-Item -ItemType Directory -Force -Path $dl | Out-Null

    $results = @()

    $sumsPath = if (Test-Path (Join-Path $dl 'SHA256SUMS')) { Join-Path $dl 'SHA256SUMS' }
                else { Get-ReleaseAsset -Tag $Tag -Name 'SHA256SUMS' -Destination $dl }
    $sums = Get-Content -Path $sumsPath -Raw
    $nativeSumsPath = if (Test-Path (Join-Path $dl 'native-SHA256SUMS')) { Join-Path $dl 'native-SHA256SUMS' }
                      else { Get-ReleaseAsset -Tag $Tag -Name 'native-SHA256SUMS' -Destination $dl }
    $nativeSums = Get-Content -Path $nativeSumsPath -Raw

    # (1) winget resolves the release under test, then installs it.
    if ($SkipWinget) {
        $results += [pscustomobject]@{ Name = 'winget serves the release'; Pass = $false; Detail = 'skipped by -SkipWinget — not verified' }
        $results += [pscustomobject]@{ Name = 'winget installs the release'; Pass = $false; Detail = 'skipped by -SkipWinget — not verified' }
    } else {
        $showOut = ''; $showRc = 1
        try { $showOut = (& winget show TunaOS.wootc --disable-interactivity 2>&1 | Out-String); $showRc = $LASTEXITCODE }
        catch { $showOut = "$_"; $showRc = 1 }
        $w = Test-WingetPackage -ShowOutput $showOut -ExpectedVersion $Tag -ExitCode $showRc
        $results += [pscustomobject]@{ Name = 'winget serves the release'; Pass = $w.Pass; Detail = $w.Detail }
        Set-Content -Path (Join-Path $Out 'winget-show.txt') -Value $showOut -Encoding UTF8

        # No --version: a stranger gets whatever winget picks by default, and
        # the hash check below decides whether that is this release.
        $instOut = ''; $instRc = 1
        try {
            $instOut = (& winget install --exact --id TunaOS.wootc --source winget --accept-package-agreements `
                --accept-source-agreements --disable-interactivity 2>&1 | Out-String)
            $instRc = $LASTEXITCODE
        } catch { $instOut = "$_"; $instRc = 1 }
        Set-Content -Path (Join-Path $Out 'winget-install.txt') -Value $instOut -Encoding UTF8
        $installed = if ($instRc -eq 0) { Find-WingetInstalledShell } else { $null }
        $setupName = 'wootc-Installer-Setup.exe'
        $setupPath = if (Test-Path (Join-Path $dl $setupName)) { Join-Path $dl $setupName }
                     else { Get-ReleaseAsset -Tag $Tag -Name $setupName -Destination $dl }
        $setupHash = Get-FileHash -Path $setupPath -Algorithm SHA256
        $i = Test-WingetInstall -ExitCode $instRc -InstalledPath $installed -ActualHash $setupHash.Hash -Manifest $nativeSums -FileName $setupName
        $results += [pscustomobject]@{ Name = 'winget installs the release'; Pass = $i.Pass; Detail = $i.Detail }
    }

    # (2)+(3) direct download: verify the Wails compatibility asset against
    # SHA256SUMS and every native setup against native-SHA256SUMS.
    $assets = @([pscustomobject]@{ Name = 'wootc-legacy.exe'; Manifest = $sums; Brand = $null })
    $assets += @($brands | ForEach-Object {
        [pscustomobject]@{
            Name = Get-NativeSetupName -ExeName $_.ExeName
            Manifest = $nativeSums
            Brand = $_
        }
    })

    foreach ($asset in $assets) {
        $name = $asset.Name
        $path = if (Test-Path (Join-Path $dl $name)) { Join-Path $dl $name }
                else { Get-ReleaseAsset -Tag $Tag -Name $name -Destination $dl }

        $hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash
        $manifestName = if ($asset.Manifest -eq $nativeSums) { 'native-SHA256SUMS' } else { 'SHA256SUMS' }
        $h = Test-Sha256Manifest -Manifest $asset.Manifest -FileName $name -ActualHash $hash
        $results += [pscustomobject]@{ Name = "$name matches $manifestName"; Pass = $h.Pass; Detail = $h.Detail }

        $sig = Get-AuthenticodeSignature -FilePath $path
        $subject = if ($sig.SignerCertificate) { "$($sig.SignerCertificate.Subject)" } else { '' }
        $s = Test-AuthenticodeResult -Status "$($sig.Status)" -SignerSubject $subject
        $results += [pscustomobject]@{ Name = "$name is Authenticode-signed"; Pass = $s.Pass; Detail = $s.Detail }

        if ($asset.Brand) {
            $b = Test-NativeSetupIdentity -FileName $name -ExpectedExeName $asset.Brand.ExeName
            $results += [pscustomobject]@{ Name = "$name carries its brand name"; Pass = $b.Pass; Detail = $b.Detail }
        } else {
            $vi = Get-ExeVersionInfo -Path $path
            $b = Test-BrandIdentity -VersionInfo $vi -ExpectedProduct 'wootc' -ExpectedVersion $Tag
            $results += [pscustomobject]@{ Name = "$name shows its own identity"; Pass = $b.Pass; Detail = $b.Detail }
        }
    }

    $meta = @{
        'Machine'  = "$((Get-CimInstance Win32_ComputerSystem).Manufacturer) $((Get-CimInstance Win32_ComputerSystem).Model)"
        'Windows'  = "$((Get-CimInstance Win32_OperatingSystem).Caption) ($((Get-CimInstance Win32_OperatingSystem).Version))"
        'Release'  = $Tag
        'Verified' = (Get-Date).ToUniversalTime().ToString('o')
    }
    $report = Format-Checklist -Results $results -Meta $meta
    $reportPath = Join-Path $Out 'checklist.md'
    Set-Content -Path $reportPath -Value $report -Encoding UTF8
    Write-Host $report
    Write-Host ''
    Write-Host "Checklist written to $reportPath — attach it, with the screenshots, to #241."

    if (@($results | Where-Object { -not $_.Pass }).Count -gt 0) { exit 1 }
    exit 0
}

# Dot-sourcing loads the graders without running anything, which is how the
# unit tests reach them off-Windows.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Verification
}
