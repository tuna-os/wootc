#!/usr/bin/env pwsh
<#
.SYNOPSIS
    The trust surface, checked on a Windows machine that has never seen wootc.

.DESCRIPTION
    v1.0 criterion 4 (#241): winget serves the release, the binaries are signed,
    the download matches SHA256SUMS, and each branded exe carries its own
    identity rather than ours. All four are about what a stranger's Windows
    says about our files BEFORE anything runs — which is the one part of the
    product no E2E run can observe, because the harness never asks Windows what
    it thinks of the binary.

    This grades all four from evidence and writes the checklist. It is expected
    to report ✘ today: code signing is not implemented yet (#229 is the spend
    decision, #230 the pipeline plumbing), and no build carries a VERSIONINFO
    resource at all. Those ✘s are the point — the checklist is what turns
    "still blocked on signing" into a dated artifact instead of a memory, and
    the day #230 lands this becomes a script run rather than a hand-written
    list.

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
    # that must stay pristine.
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
    if ($want -and $found.TrimStart('v') -ne $want) {
        return [pscustomobject]@{ Pass = $false; Detail = "winget serves $found, expected $want — the manifest is behind the release" }
    }
    return [pscustomobject]@{ Pass = $true; Detail = "winget serves TunaOS.wootc $found" }
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
    $lines += '- the exe Properties ▸ Details tab'
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

function Get-ReleaseAsset {
    param([string]$Tag, [string]$Name, [string]$Destination)
    $base = if ($Tag) { "https://github.com/$Repo/releases/download/$Tag" }
            else { "https://github.com/$Repo/releases/latest/download" }
    $dest = Join-Path $Destination $Name
    Invoke-WebRequest -Uri "$base/$Name" -OutFile $dest -UseBasicParsing
    return $dest
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
    New-Item -ItemType Directory -Force -Path $Out | Out-Null

    if (-not $BrandDir) {
        $BrandDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'app/branding'
    }
    $brands = @(Get-BrandExpectations -Dir $BrandDir)
    if (@($brands).Count -eq 0) { throw "no brand configs under $BrandDir — pass -BrandDir <checkout>/app/branding" }

    $dl = if ($Downloaded) { $Downloaded } else { Join-Path $Out 'download' }
    New-Item -ItemType Directory -Force -Path $dl | Out-Null

    $results = @()

    # (1) winget resolves and serves the release under test.
    if ($SkipWinget) {
        $results += [pscustomobject]@{ Name = 'winget serves the release'; Pass = $false; Detail = 'skipped by -SkipWinget — not verified' }
    } else {
        $showOut = ''; $showRc = 1
        try { $showOut = (& winget show TunaOS.wootc --disable-interactivity 2>&1 | Out-String); $showRc = $LASTEXITCODE }
        catch { $showOut = "$_"; $showRc = 1 }
        $w = Test-WingetPackage -ShowOutput $showOut -ExpectedVersion $Tag -ExitCode $showRc
        $results += [pscustomobject]@{ Name = 'winget serves the release'; Pass = $w.Pass; Detail = $w.Detail }
        Set-Content -Path (Join-Path $Out 'winget-show.txt') -Value $showOut -Encoding UTF8
    }

    # (2)+(3) direct download: SHA256SUMS and Authenticode on the generic exe.
    $sumsPath = if (Test-Path (Join-Path $dl 'SHA256SUMS')) { Join-Path $dl 'SHA256SUMS' }
                else { Get-ReleaseAsset -Tag $Tag -Name 'SHA256SUMS' -Destination $dl }
    $sums = Get-Content -Path $sumsPath -Raw

    $exeNames = @('wootc.exe') + @($brands | Where-Object { $_.ExeName -and $_.ExeName -ne 'wootc' } |
        ForEach-Object { "$($_.ExeName).exe" })

    foreach ($name in ($exeNames | Select-Object -Unique)) {
        $path = if (Test-Path (Join-Path $dl $name)) { Join-Path $dl $name }
                else { Get-ReleaseAsset -Tag $Tag -Name $name -Destination $dl }

        $hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash
        $h = Test-Sha256Manifest -Manifest $sums -FileName $name -ActualHash $hash
        $results += [pscustomobject]@{ Name = "$name matches SHA256SUMS"; Pass = $h.Pass; Detail = $h.Detail }

        $sig = Get-AuthenticodeSignature -FilePath $path
        $subject = if ($sig.SignerCertificate) { "$($sig.SignerCertificate.Subject)" } else { '' }
        $s = Test-AuthenticodeResult -Status "$($sig.Status)" -SignerSubject $subject
        $results += [pscustomobject]@{ Name = "$name is Authenticode-signed"; Pass = $s.Pass; Detail = $s.Detail }

        # (4) each branded exe carries its own identity.
        $brand = $brands | Where-Object { "$($_.ExeName).exe" -eq $name } | Select-Object -First 1
        if ($brand) {
            $vi = Get-ExeVersionInfo -Path $path
            $isBranded = ($brand.Id -ne 'wootc')
            $b = Test-BrandIdentity -VersionInfo $vi -ExpectedProduct $brand.ProductName -Branded:$isBranded
            $results += [pscustomobject]@{ Name = "$name shows its own identity"; Pass = $b.Pass; Detail = $b.Detail }
        }
    }

    $meta = @{
        'Machine'  = "$((Get-CimInstance Win32_ComputerSystem).Manufacturer) $((Get-CimInstance Win32_ComputerSystem).Model)"
        'Windows'  = "$((Get-CimInstance Win32_OperatingSystem).Caption) ($((Get-CimInstance Win32_OperatingSystem).Version))"
        'Release'  = if ($Tag) { $Tag } else { 'releases/latest' }
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
