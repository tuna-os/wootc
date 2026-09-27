$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 'Expected native Windows fixture' }
$temporaryName = [Guid]::NewGuid().ToString('N')
$temporaryDir = Join-Path $env:TEMP "wootc-oem-identity-$temporaryName"
if (Test-Path -LiteralPath $temporaryDir) { throw 'Refusing existing temporary directory' }
[IO.Directory]::CreateDirectory($temporaryDir) | Out-Null
& icacls $temporaryDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Failed private temporary ACL' }
try {
    Write-Output 'SOURCE_SHA cb02711bca818a174a47ca370653011e4a04f0ad'
    $source0 = Join-Path $temporaryDir 'wootc-firstboot-integrated-oem-8c1c0f698e3f478fbacb3535c0e3bb88-0.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-firstboot-integrated-oem-8c1c0f698e3f478fbacb3535c0e3bb88-0.ps1' -OutFile $source0
    if ((Get-FileHash -LiteralPath $source0 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'b10d68fe66eecd49e4479dfce3fcd110f0d60caedccae3917148aad2f86f8b53') { throw 'Source checksum mismatch' }
    Write-Output 'SOURCE tests/e2e/setup-wootc.ps1 RAW_SHA256 da4610469339ab06636d90268b5a185fbd996444d3a8b0132903586af82f3287 STAGED_SHA256 b10d68fe66eecd49e4479dfce3fcd110f0d60caedccae3917148aad2f86f8b53'
    $source1 = Join-Path $temporaryDir 'wootc-firstboot-integrated-oem-8c1c0f698e3f478fbacb3535c0e3bb88-1.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-firstboot-integrated-oem-8c1c0f698e3f478fbacb3535c0e3bb88-1.ps1' -OutFile $source1
    if ((Get-FileHash -LiteralPath $source1 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '44d02a3650a365e90c020aa51d041a7c36acfec687b0444f05165b5552228fb3') { throw 'Source checksum mismatch' }
    Write-Output 'SOURCE tests/unit/oem-installation-identity.ps1 RAW_SHA256 e633ae6b8b928aa7f3b76698749eaf385c2307bd63b49d84d5d590b2abbc76dd STAGED_SHA256 44d02a3650a365e90c020aa51d041a7c36acfec687b0444f05165b5552228fb3'
    & ([ScriptBlock]::Create([IO.File]::ReadAllText($source1))) -SetupPath $source0
    Write-Output 'PASS OEM native identity suite'
} finally { Remove-Item -LiteralPath $temporaryDir -Recurse -Force }
