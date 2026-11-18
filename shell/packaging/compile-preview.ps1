#Requires -Version 7.2
# Compiles the native preview installer (preview.iss), or the production
# setup installer (setup.iss), for one brand from a package whose
# native-package.json is already written. The compiler is the pinned Inno
# Setup release in inno-tool.json, checked by digest, size, Authenticode
# signer and engine version before it runs.
#
# Used by test-installed-preview.ps1 (winui-preview.yml), by the native shell
# E2E (e2e-hosted.yml), and by the release attachment path. A compiler that
# cannot be downloaded at all throws a message that starts with
# "INNO-UNAVAILABLE:"; every other failure, including a digest or signer
# mismatch, is a plain refusal.
param(
    [Parameter(Mandatory=$true)][ValidateSet('wootc','tunaos','aurora','bazzite','bluefin')][string]$BrandId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$BuildId,
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory,
    [Parameter(Mandatory=$true)][string]$ScratchDirectory,
    [ValidateSet('preview','release')][string]$Mode='preview',
    [string]$ReleaseTag=''
)
$ErrorActionPreference='Stop'
$isRelease=$Mode -eq 'release'
if ($isRelease -and $ReleaseTag -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,99}$') { throw 'Release mode needs a valid release tag' }
$package=[IO.Path]::GetFullPath($PackageDirectory)
$output=[IO.Path]::GetFullPath($OutputDirectory)
$scratch=[IO.Path]::GetFullPath($ScratchDirectory)
if (-not (Test-Path -LiteralPath (Join-Path $package 'native-package.json') -PathType Leaf)) { throw 'Native package has no manifest' }
[IO.Directory]::CreateDirectory($output) | Out-Null
[IO.Directory]::CreateDirectory($scratch) | Out-Null

function Invoke-CompilerProcess {
    param([string]$Executable,[string[]]$Arguments,[int]$TimeoutSeconds=180)
    $info=[Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute=$false
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true); $process.WaitForExit(); throw 'Compiler operation exceeded its deadline'
        }
        if ($process.ExitCode -ne 0) { throw "Compiler operation refused with exit $($process.ExitCode)" }
    } finally { $process.Dispose() }
}

$tool=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'inno-tool.json') -Raw | ConvertFrom-Json
$download=Join-Path $scratch 'inno-pinned.exe'
try {
    Invoke-WebRequest -Uri $tool.browser_download_url -OutFile $download
} catch {
    throw "INNO-UNAVAILABLE: the pinned compiler could not be downloaded: $($_.Exception.Message)"
}
$toolHash=(Get-FileHash -LiteralPath $download).Hash.ToLowerInvariant()
if ($toolHash -cne $tool.digest.Substring(7) -or (Get-Item -LiteralPath $download).Length -ne $tool.size) { throw 'Pinned compiler installer digest/size mismatch' }
$signature=Get-AuthenticodeSignature -LiteralPath $download
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B[.]V[.]') { throw 'Pinned compiler installer signer mismatch' }
$toolDirectory=Join-Path $scratch 'compiler'
Invoke-CompilerProcess -Executable $download -Arguments @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-','/NOICONS',"/DIR=$toolDirectory")
$compiler=Join-Path $toolDirectory 'ISCC.exe'
$version=[Diagnostics.FileVersionInfo]::GetVersionInfo($compiler)
$compilerVersion=(& $compiler --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $compilerVersion -cne '7.1.0') { throw 'Compiler engine version differs from pinned release' }
[ordered]@{toolSha256=$toolHash;signer=$signature.SignerCertificate.Subject;peFileVersion=$version.FileVersion;compilerEngineVersion=$compilerVersion} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'compiler-observations.json') -Encoding utf8
$brand=Get-Content -LiteralPath (Join-Path $PSScriptRoot "../../app/branding/$BrandId/brand.json") -Raw | ConvertFrom-Json
$iss=if ($isRelease) { Join-Path $PSScriptRoot 'setup.iss' } else { Join-Path $PSScriptRoot 'preview.iss' }
$setupBaseName=if ($brand.exeName -eq 'wootc') { 'wootc-Installer-Setup' } else { "$($brand.exeName)-Setup" }
$arguments=@("/DSourceDir=$package","/DOutputDir=$output","/DBrandId=$BrandId","/DProductName=$($brand.productName)","/DPublisher=$($brand.publisher)","/DBuildId=$BuildId")
if ($isRelease) {
    $arguments += "/DVersion=$ReleaseTag"
    $arguments += "/DOutputBaseName=$setupBaseName"
} else {
    $arguments += $iss
}
if ($isRelease) { $arguments += $iss }
Invoke-CompilerProcess -Executable $compiler -TimeoutSeconds 300 -Arguments $arguments
$installerName=if ($isRelease) { "$setupBaseName.exe" } else { "$BrandId-native-preview-$BuildId.exe" }
$installer=Join-Path $output $installerName
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "The compiler did not write the $Mode installer" }
[pscustomobject]@{Installer=$installer;Mode=$Mode;ReleaseTag=$ReleaseTag;ToolSha256=$toolHash;Signer=$signature.SignerCertificate.Subject;CompilerVersion=$compilerVersion;PeFileVersion=$version.FileVersion}
