#Requires -Version 7.2
$ErrorActionPreference='Stop'
$testRoot=Join-Path $env:TEMP "wootc-preview-manifest-$([guid]::NewGuid().ToString('N'))"
if (Test-Path -LiteralPath $testRoot) { throw 'Existing test root' }
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$buildId='1111111111111111111111111111111111111111'
$writer=Join-Path $PSScriptRoot 'write-manifest.ps1'
function New-PublicPackage {
    param([string]$Name)
    $directory=Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    foreach ($file in @('wootc-engine.exe','Wootc.Shell.exe','Wootc.Shell.dll','Wootc.Shell.pri')) {
        [IO.File]::WriteAllText((Join-Path $directory $file),'public synthetic artifact')
    }
    $branding=Join-Path $directory 'Branding'
    [IO.Directory]::CreateDirectory($branding) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../app/branding/wootc/brand.json') -Destination (Join-Path $branding 'brand.json')
    return $directory
}
function Assert-Refused {
    param([string]$Directory)
    $failed=$false
    try { & $writer -PackageDirectory $Directory -BuildId $buildId -BrandId wootc } catch { $failed=$true }
    if (-not $failed) { throw 'Unsafe synthetic package was accepted' }
}
try {
    $positive=New-PublicPackage -Name 'positive'
    & $writer -PackageDirectory $positive -BuildId $buildId -BrandId wootc
    $manifest=Join-Path $positive 'native-package.json'
    $bytes=[IO.File]::ReadAllBytes($manifest)
    $value=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($value.buildId -cne $buildId -or $value.brandId -cne 'wootc' -or @($value.files.PSObject.Properties).Count -ne 5) { throw 'Actual manifest writer metadata absent' }
    Assert-Refused -Directory $positive
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($manifest)) -cne [Convert]::ToBase64String($bytes)) { throw 'Existing manifest bytes changed' }
    $missing=New-PublicPackage -Name 'missing'
    Remove-Item -LiteralPath (Join-Path $missing 'Wootc.Shell.pri')
    Assert-Refused -Directory $missing
    $wrongBrand=New-PublicPackage -Name 'wrong-brand'
    [IO.File]::WriteAllText((Join-Path $wrongBrand 'Branding/brand.json'),'{}')
    Assert-Refused -Directory $wrongBrand
    $rootTarget=New-PublicPackage -Name 'root-target'
    $link=Join-Path $testRoot 'root-link'
    New-Item -ItemType Junction -Path $link -Target $rootTarget | Out-Null
    try {
        Assert-Refused -Directory $link
        $originalWriter=[IO.File]::ReadAllBytes($writer)
        $writerText=[IO.File]::ReadAllText($writer)
        $guard='if ((Get-Item -LiteralPath $root -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ''Reparse point at preview package root'' }'
        if (-not $writerText.Contains($guard)) { throw 'Root guard mutant could not bind actual source' }
        try {
            [IO.File]::WriteAllText($writer,$writerText.Replace($guard,''),[Text.UTF8Encoding]::new($false))
            & $writer -PackageDirectory $link -BuildId $buildId -BrandId wootc
            if (-not (Test-Path -LiteralPath (Join-Path $rootTarget 'native-package.json'))) { throw 'Root guard removal did not reproduce the unsafe acceptance' }
        } finally {
            [IO.File]::WriteAllBytes($writer,$originalWriter)
            if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($writer)) -cne [Convert]::ToBase64String($originalWriter)) { throw 'Actual writer bytes were not restored' }
        }
        Remove-Item -LiteralPath (Join-Path $rootTarget 'native-package.json') -Force
        Assert-Refused -Directory $link
        Write-Output 'PASS actual root-reparse mutant accepts unsafe path; exact source restored and refuses it'
    } finally { Remove-Item -LiteralPath $link -Force }
    $child=New-PublicPackage -Name 'child-link'
    $childLink=Join-Path $child 'foreign-link'
    New-Item -ItemType Junction -Path $childLink -Target $positive | Out-Null
    try { Assert-Refused -Directory $child } finally { Remove-Item -LiteralPath $childLink -Force }
    Write-Output 'PASS actual manifest writer, exclusive preservation, missing resources, wrong brand, root/child reparse refusals'
} finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop }
