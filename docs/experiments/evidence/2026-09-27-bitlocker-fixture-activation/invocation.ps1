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
 $source0=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-0.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-0.ps1' -OutFile $source0
 if ((Get-FileHash -LiteralPath $source0 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '5d7b0755d9900f1caa2a427047516acf348affb14269c491e2011adb523ebb1e') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.ps1 RAW_SHA256 83436fa6150bba76997faad61661bc1a752ec23ea6a86cef0a5580289be9a227 STAGED_SHA256 5d7b0755d9900f1caa2a427047516acf348affb14269c491e2011adb523ebb1e'
 $source1=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-1.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-1.ps1' -OutFile $source1
 if ((Get-FileHash -LiteralPath $source1 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '15a37ce1282efca5c27e15baa155a8c6ef09d6a33fd9347bd8c0bfa1b74c1ed6') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.tests.ps1 RAW_SHA256 f7ea5c2745c433294f4d7351a457c6af60f0d5c210fe8ad27cb9941f9f6a0661 STAGED_SHA256 15a37ce1282efca5c27e15baa155a8c6ef09d6a33fd9347bd8c0bfa1b74c1ed6'
 $source2=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-2.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-2.ps1' -OutFile $source2
 if ((Get-FileHash -LiteralPath $source2 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '18d4464058344c57a108bc96abc7551e76b6129ea1134bfaf2a78ce30b1b1824') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-readiness.ps1 RAW_SHA256 0d9277fed917331851c069bd96242b5debeb35d902a5fedbf167083cc44d4d84 STAGED_SHA256 18d4464058344c57a108bc96abc7551e76b6129ea1134bfaf2a78ce30b1b1824'
 $source3=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-3.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-3.ps1' -OutFile $source3
 if ((Get-FileHash -LiteralPath $source3 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'a9d08110c60b57fe214391e72d2d1dbb98664821b528d76eaf808688a187ecab') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-readiness.tests.ps1 RAW_SHA256 7cfe867828f94cbdeb64b8c9604a67b052853677f08a5b1890bbb5fe1e601833 STAGED_SHA256 a9d08110c60b57fe214391e72d2d1dbb98664821b528d76eaf808688a187ecab'
 $source4=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-4.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-4.ps1' -OutFile $source4
 if ((Get-FileHash -LiteralPath $source4 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/lint-ps1.ps1 RAW_SHA256 6f2083b9ed30d7747c6fc3868c3359413cbed2e75c884a7509bdf31af2fef3bf STAGED_SHA256 f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8'
 $source5=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-5.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-5.ps1' -OutFile $source5
 if ((Get-FileHash -LiteralPath $source5 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '2aeba2151bf645f85e61588327cad8a7120ba2ff38564f03c560a39fbff35c4f') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-protection.ps1 RAW_SHA256 c7c993df43318987a958c329bff78fd61272eae5656da3c0ae99abc9814d160a STAGED_SHA256 2aeba2151bf645f85e61588327cad8a7120ba2ff38564f03c560a39fbff35c4f'
 $source6=Join-Path $temporaryDir 'wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-6.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-fixture-readiness-audit-0ebbddc797c048a18b4f02a347f64378-6.ps1' -OutFile $source6
 if ((Get-FileHash -LiteralPath $source6 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'c6863aa93e8040232ee6603c0e065356ebe1176b3f1c1301cdf6a58a2d7b9304') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-protection.tests.ps1 RAW_SHA256 9f2ec2c9c8aae8466f04175c95ddc35ca662c3e0b8f49081b4f559f93be2109f STAGED_SHA256 c6863aa93e8040232ee6603c0e065356ebe1176b3f1c1301cdf6a58a2d7b9304'
 & $source4 -Files @($source0, $source1, $source2, $source3, $source5, $source6)
 if ($LASTEXITCODE -ne 0) { throw 'Native PS lint failed' }
 & ([ScriptBlock]::Create([IO.File]::ReadAllText($source1))) -HelperPath $source0
 & ([ScriptBlock]::Create([IO.File]::ReadAllText($source3))) -HelperPath $source2
 & ([ScriptBlock]::Create([IO.File]::ReadAllText($source6))) -HelperPath $source5
 Write-Output 'PASS native protected fixture privacy and provisional activation mocks'
} finally { Remove-Item -LiteralPath $temporaryDir -Recurse -Force }
