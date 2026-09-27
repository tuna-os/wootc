$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
if ($env:OS -ne 'Windows_NT') { throw 'Expected native Windows fixture' }
$temporaryName=[Guid]::NewGuid().ToString('N')
$temporaryDir=Join-Path $env:TEMP "wootc-fixture-readiness-audit-$temporaryName"
if (Test-Path -LiteralPath $temporaryDir) { throw 'Refusing existing directory' }
[IO.Directory]::CreateDirectory($temporaryDir) | Out-Null
& icacls $temporaryDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Private temporary ACL failed' }
try {
 $source0=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-0.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-0.ps1' -OutFile $source0
 if ((Get-FileHash -LiteralPath $source0 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '53af46b855703adbe00d823517f60a88b7000c54a3732102b5b24ffd9b62109e') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.ps1 RAW_SHA256 53f159f7c9aaf7d5015a0e59915791a4536abf16d9f720863960d2ad4b1e7707 STAGED_SHA256 53af46b855703adbe00d823517f60a88b7000c54a3732102b5b24ffd9b62109e'
 $source1=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-1.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-1.ps1' -OutFile $source1
 if ((Get-FileHash -LiteralPath $source1 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '010defb02682eb0405b540d944e836db33bbc99b3feacb6850ed307755169aaa') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.tests.ps1 RAW_SHA256 cc57d2cb87936a4aa6b9d65e0d4a2903c10fb29110f54de14b69d44128f7babf STAGED_SHA256 010defb02682eb0405b540d944e836db33bbc99b3feacb6850ed307755169aaa'
 $source2=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-2.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-2.ps1' -OutFile $source2
 if ((Get-FileHash -LiteralPath $source2 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '18d4464058344c57a108bc96abc7551e76b6129ea1134bfaf2a78ce30b1b1824') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-readiness.ps1 RAW_SHA256 0d9277fed917331851c069bd96242b5debeb35d902a5fedbf167083cc44d4d84 STAGED_SHA256 18d4464058344c57a108bc96abc7551e76b6129ea1134bfaf2a78ce30b1b1824'
 $source3=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-3.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-3.ps1' -OutFile $source3
 if ((Get-FileHash -LiteralPath $source3 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'a9d08110c60b57fe214391e72d2d1dbb98664821b528d76eaf808688a187ecab') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-readiness.tests.ps1 RAW_SHA256 7cfe867828f94cbdeb64b8c9604a67b052853677f08a5b1890bbb5fe1e601833 STAGED_SHA256 a9d08110c60b57fe214391e72d2d1dbb98664821b528d76eaf808688a187ecab'
 $source4=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-4.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-f202f30463654dac89e9f84faa0f7fc5-4.ps1' -OutFile $source4
 if ((Get-FileHash -LiteralPath $source4 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/lint-ps1.ps1 RAW_SHA256 6f2083b9ed30d7747c6fc3868c3359413cbed2e75c884a7509bdf31af2fef3bf STAGED_SHA256 f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8'
 & $source4 -Files @($source0, $source1, $source2, $source3)
 if ($LASTEXITCODE -ne 0) { throw 'Native PS lint failed' }
 & ([ScriptBlock]::Create([IO.File]::ReadAllText($source1))) -HelperPath $source0
 & ([ScriptBlock]::Create([IO.File]::ReadAllText($source3))) -HelperPath $source2
 Write-Output 'PASS native protected fixture key byte audit and readiness mocks'
} finally { Remove-Item -LiteralPath $temporaryDir -Recurse -Force }
