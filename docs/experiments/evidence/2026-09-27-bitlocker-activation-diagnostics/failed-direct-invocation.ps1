$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 'Expected native Windows fixture' }
Write-Output "NATIVE_POWERSHELL $($PSVersionTable.PSVersion)"
$temporaryName=[Guid]::NewGuid().ToString('N')
$temporaryDir=Join-Path $env:TEMP "wootc-activation-diagnostic-$temporaryName"
if (Test-Path -LiteralPath $temporaryDir) { throw 'Refusing existing directory' }
[IO.Directory]::CreateDirectory($temporaryDir) | Out-Null
& icacls.exe $temporaryDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Private temporary ACL failed' }
try {
 $source0=Join-Path $temporaryDir 'wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-0.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-0.ps1' -OutFile $source0
 if ((Get-FileHash -LiteralPath $source0 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'bb5b9bf55b526135a18f45a72b854ee0a7cf732efd8b1a7906134e519d69e688') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.ps1 RAW_SHA256 76127615cdc23adf18af64a1af3a08f117844bc50ba5a563d34049fc242b3cdc STAGED_SHA256 bb5b9bf55b526135a18f45a72b854ee0a7cf732efd8b1a7906134e519d69e688'
 $source1=Join-Path $temporaryDir 'wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-1.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-1.ps1' -OutFile $source1
 if ((Get-FileHash -LiteralPath $source1 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '7253120c3b6fcd0d22ffe67fd41aed9c32cf46b3bf611309b298c47dfe18ca4d') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-protection.ps1 RAW_SHA256 757f6df7ded7afeb6b3dffff1fdb1129dfca908d4438e477dc30fcc7f4d66738 STAGED_SHA256 7253120c3b6fcd0d22ffe67fd41aed9c32cf46b3bf611309b298c47dfe18ca4d'
 $source2=Join-Path $temporaryDir 'wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-2.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-2.ps1' -OutFile $source2
 if ((Get-FileHash -LiteralPath $source2 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '55f945081ad6564a6f8a584941424d7763f6a831a62308ed75ade434808e193c') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.tests.ps1 RAW_SHA256 d269b8272f88171bc2393874ff7d8364bc285738c4d4ffa5229f54cd988c7fd1 STAGED_SHA256 55f945081ad6564a6f8a584941424d7763f6a831a62308ed75ade434808e193c'
 $source3=Join-Path $temporaryDir 'wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-3.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-3.ps1' -OutFile $source3
 if ((Get-FileHash -LiteralPath $source3 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '08ee4ca5f93fc57118cceafa3ae60a9a5a9cb3e88ee78b061e0861fae4180a51') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-protection.tests.ps1 RAW_SHA256 cf9e16d85ea6d842f72fb8d01d31c729f808af09d90ed8761b56642693820a94 STAGED_SHA256 08ee4ca5f93fc57118cceafa3ae60a9a5a9cb3e88ee78b061e0861fae4180a51'
 $source4=Join-Path $temporaryDir 'wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-4.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-4.ps1' -OutFile $source4
 if ((Get-FileHash -LiteralPath $source4 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'd11e40488195976a65d156e38030baf89878902dc938a4d9bd50b98db2da6bd0') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-diagnostics.tests.ps1 RAW_SHA256 d6d9490b569db5e493401c6a19676c551bcdd1d0473ea4e9eefcec29918ec0a3 STAGED_SHA256 d11e40488195976a65d156e38030baf89878902dc938a4d9bd50b98db2da6bd0'
 $source5=Join-Path $temporaryDir 'wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-5.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-09be7dd218f949cc99b2d549a383adb0-5.ps1' -OutFile $source5
 if ((Get-FileHash -LiteralPath $source5 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/lint-ps1.ps1 RAW_SHA256 6f2083b9ed30d7747c6fc3868c3359413cbed2e75c884a7509bdf31af2fef3bf STAGED_SHA256 f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8'
 & $source5 -Files @($source0,$source1,$source2,$source3,$source4)
 if ($LASTEXITCODE -ne 0) { throw 'Native lint failed' }
 & $source2 -HelperPath $source0
 & $source3 -HelperPath $source1 -KeyHelperPath $source0
 & $source4 -KeyHelperPath $source0 -ProtectionHelperPath $source1
 Write-Output 'PASS native isolated activation failure diagnostics'
} finally { Remove-Item -LiteralPath $temporaryDir -Recurse -Force -ErrorAction Stop }
