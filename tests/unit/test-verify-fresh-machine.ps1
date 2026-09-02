#!/usr/bin/env pwsh
# Grading logic for the fresh-machine trust check (#241).
#
# tests/field/verify-fresh-machine.ps1 decides whether a stranger's Windows
# trusts our release. It runs by hand on machines CI does not have, so the
# grading has to be proven here or the checklist it produces is only as good as
# an untested script — and this checklist's whole job is to be more trustworthy
# than a human ticking boxes.
#
# Every case below is a way the real check must be able to fail. The ones that
# matter most are the two that look like passes: an unsigned binary and an exe
# with no identity at all both produce "nothing wrong found" unless the grader
# treats absence as failure.
#
# Run: pwsh -NoProfile -File tests/unit/test-verify-fresh-machine.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path (Split-Path -Parent $here) 'field/verify-fresh-machine.ps1')

$script:failures = @()
$script:checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) { $script:failures += $Message }
}

# ── Authenticode ─────────────────────────────────────────────────────────────

$r = Test-AuthenticodeResult -Status 'Valid' -SignerSubject 'CN=TunaOS, O=TunaOS, C=GB'
Assert-True $r.Pass 'a Valid signature with a signer passes'
Assert-True ($r.Detail -match 'CN=TunaOS') 'the publisher name is reported — it is what UAC shows'

# Absence must fail. This is today's real answer, and the reason the checklist
# exists: "no signature" has to read as ✘, not as "nothing wrong found".
$r = Test-AuthenticodeResult -Status 'NotSigned' -SignerSubject ''
Assert-True (-not $r.Pass) 'NotSigned must fail'
Assert-True ($r.Detail -match 'SmartScreen') 'the consequence is named, not just the status'
Assert-True ($r.Detail -match '#229|#230') 'the blocking issues are named so the ✘ is actionable'

# A tampered download must never be filed under "not signed yet".
$r = Test-AuthenticodeResult -Status 'HashMismatch' -SignerSubject 'CN=TunaOS'
Assert-True (-not $r.Pass) 'HashMismatch must fail'
Assert-True ($r.Detail -match 'Do not run it') 'a hash mismatch tells the tester to stop'

$r = Test-AuthenticodeResult -Status 'UnknownError' -SignerSubject ''
Assert-True (-not $r.Pass) 'any non-Valid status fails'

# Valid-but-anonymous would leave UAC and SmartScreen with nothing to display.
$r = Test-AuthenticodeResult -Status 'Valid' -SignerSubject ''
Assert-True (-not $r.Pass) 'Valid with no signer must not pass'

# ── SHA256SUMS ───────────────────────────────────────────────────────────────

$manifest = @'
# published with the release
aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111  wootc.exe
bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222  Bazzite-Installer.exe
cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333 *deployer-vmlinuz
'@

$r = Test-Sha256Manifest -Manifest $manifest -FileName 'wootc.exe' `
    -ActualHash 'AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111AAAA1111'
Assert-True $r.Pass 'a matching hash passes, case-insensitively (Get-FileHash returns upper)'

$r = Test-Sha256Manifest -Manifest $manifest -FileName 'wootc.exe' -ActualHash 'deadbeef'
Assert-True (-not $r.Pass) 'a mismatched hash fails'
Assert-True ($r.Detail -match 'hash mismatch') 'the mismatch is named'

# An asset nobody published a hash for is the one worth noticing, not skipping.
$r = Test-Sha256Manifest -Manifest $manifest -FileName 'Aurora-Installer.exe' -ActualHash 'abc'
Assert-True (-not $r.Pass) 'an unlisted file fails rather than passing by absence'
Assert-True ($r.Detail -match 'not listed') 'the reason is that it is unlisted'

# sha256sum writes binary-mode entries with a leading *; both forms are the file.
$r = Test-Sha256Manifest -Manifest $manifest -FileName 'deployer-vmlinuz' `
    -ActualHash 'cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333'
Assert-True $r.Pass 'binary-mode (*name) entries are matched'

# ── per-brand identity ───────────────────────────────────────────────────────

$good = @{ ProductName = 'Bazzite Installer'; FileDescription = 'Bazzite Installer'
           CompanyName = 'Universal Blue'; ProductVersion = '1.0.0' }
$r = Test-BrandIdentity -VersionInfo $good -ExpectedProduct 'Bazzite Installer' -Branded
Assert-True $r.Pass 'a branded exe wearing its own name passes'

# The failure criterion 4 is written to catch.
$leaks = @{ ProductName = 'wootc'; FileDescription = 'wootc'; CompanyName = 'TunaOS'; ProductVersion = '1.0.0' }
$r = Test-BrandIdentity -VersionInfo $leaks -ExpectedProduct 'Bazzite Installer' -Branded
Assert-True (-not $r.Pass) 'a branded exe whose properties say wootc must fail'
Assert-True ($r.Detail -match 'never surface the project name') 'the branding rule is quoted back'

$partial = @{ ProductName = 'Bazzite Installer'; FileDescription = 'wootc installer'
              CompanyName = 'TunaOS'; ProductVersion = '1.0.0' }
$r = Test-BrandIdentity -VersionInfo $partial -ExpectedProduct 'Bazzite Installer' -Branded
Assert-True (-not $r.Pass) 'FileDescription is user-facing too — UAC shows it for an unsigned binary'

# THE case that is true of every build in this repo today: no VERSIONINFO at
# all. An empty identity must be a ✘, or the properties-dialog screenshot this
# issue asks for would be a blank tab under a ticked box.
foreach ($empty in @($null, @{}, @{ ProductName = ''; FileDescription = '' })) {
    $r = Test-BrandIdentity -VersionInfo $empty -ExpectedProduct 'Bazzite Installer' -Branded
    Assert-True (-not $r.Pass) 'missing version info must fail, not pass by absence'
    Assert-True ($r.Detail -match 'no VERSIONINFO') 'the absence is named explicitly'
}

# The generic build may say wootc — it is the only one that owns the word.
$generic = @{ ProductName = 'wootc'; FileDescription = 'wootc'; CompanyName = 'TunaOS'; ProductVersion = '1.0.0' }
$r = Test-BrandIdentity -VersionInfo $generic -ExpectedProduct 'wootc'
Assert-True $r.Pass 'the generic build is allowed its own name'

# A branded exe wearing ANOTHER brand's name is a mispackaged release.
$wrong = @{ ProductName = 'Aurora Installer'; FileDescription = 'Aurora Installer'
            CompanyName = 'Universal Blue'; ProductVersion = '1.0.0' }
$r = Test-BrandIdentity -VersionInfo $wrong -ExpectedProduct 'Bazzite Installer' -Branded
Assert-True (-not $r.Pass) 'the wrong brand identity must fail'

# ── winget ───────────────────────────────────────────────────────────────────

$show = @'
Found wootc [TunaOS.wootc]
Version: 1.0.0
Publisher: TunaOS
'@
$r = Test-WingetPackage -ShowOutput $show -ExpectedVersion 'v1.0.0' -ExitCode 0
Assert-True $r.Pass 'winget serving the expected version passes (v prefix tolerated)'

# The quiet failure: the package resolves, but to last month's alpha.
$stale = "Found wootc [TunaOS.wootc]`nVersion: 0.1.0-alpha.1`n"
$r = Test-WingetPackage -ShowOutput $stale -ExpectedVersion 'v1.0.0' -ExitCode 0
Assert-True (-not $r.Pass) 'a stale winget manifest must fail, not pass because it resolved'
Assert-True ($r.Detail -match 'behind the release') 'the staleness is named'

$r = Test-WingetPackage -ShowOutput '' -ExpectedVersion 'v1.0.0' -ExitCode 1
Assert-True (-not $r.Pass) 'an unresolvable package fails'

$r = Test-WingetPackage -ShowOutput "Found wootc [TunaOS.wootc]`n" -ExpectedVersion 'v1.0.0' -ExitCode 0
Assert-True (-not $r.Pass) 'resolving without a version fails'

# With no expected version, any resolved version is acceptable.
$r = Test-WingetPackage -ShowOutput $stale -ExpectedVersion '' -ExitCode 0
Assert-True $r.Pass 'no expected version means "just resolve"'

# ── the rendered checklist ───────────────────────────────────────────────────

$report = Format-Checklist -Results @(
    [pscustomobject]@{ Name = 'Signed'; Pass = $false; Detail = 'NOT SIGNED' }
    [pscustomobject]@{ Name = 'Hashes'; Pass = $true;  Detail = 'ok' }
) -Meta @{ Release = 'v1.0.0' }
Assert-True ($report -match '\[ \] ✘ \*\*Signed\*\*') 'a failing box is not ticked'
Assert-True ($report -match '\[x\] ✔ \*\*Hashes\*\*') 'a passing box is ticked'
Assert-True ($report -match 'RESULT: FAIL') 'one ✘ fails the report'
Assert-True ($report -match 'UAC prompt') 'the screenshots that cannot be automated are listed'
Assert-True ($report -match 'Properties') 'including the properties dialog'

# ── report ───────────────────────────────────────────────────────────────────

foreach ($f in $script:failures) { Write-Host "FAIL: $f" }
if (@($script:failures).Count -gt 0) {
    Write-Host "FAIL ($($script:checks) checks, $(@($script:failures).Count) failed)"
    exit 1
}
Write-Host "PASS ($($script:checks) checks)"
exit 0
