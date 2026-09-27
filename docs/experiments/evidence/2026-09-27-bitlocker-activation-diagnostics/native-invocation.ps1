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
 $source0=Join-Path $temporaryDir 'wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-0.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-0.ps1' -OutFile $source0
 if ((Get-FileHash -LiteralPath $source0 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '7d70cbcf9d2f67470f86b9a42c9370ee375e0c4d1246048a2d337370ece38878') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.ps1 RAW_SHA256 fa9c9901ff3488e23e3e0b866ea8842af569404481074238e94ef0df161a9f45 STAGED_SHA256 7d70cbcf9d2f67470f86b9a42c9370ee375e0c4d1246048a2d337370ece38878'
 $source1=Join-Path $temporaryDir 'wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-1.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-1.ps1' -OutFile $source1
 if ((Get-FileHash -LiteralPath $source1 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'cbbdf64bcb2bfbd6cb4631a50f08dce4d2f3d2a5c66f93501178b3dfa7d3192c') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-protection.ps1 RAW_SHA256 8973a28a75e18361822bf7b8b879b9527c9421b3d819ff115936aa060e8c9f4a STAGED_SHA256 cbbdf64bcb2bfbd6cb4631a50f08dce4d2f3d2a5c66f93501178b3dfa7d3192c'
 $source2=Join-Path $temporaryDir 'wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-2.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-2.ps1' -OutFile $source2
 if ((Get-FileHash -LiteralPath $source2 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'a526afb7e181c2e572b0212aaeabec96f99603c867a96d32ffb5670047e07be2') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.tests.ps1 RAW_SHA256 36ea43ee821b01a055c07401adbf8140223711288a1f3e187565ab4598fdba6c STAGED_SHA256 a526afb7e181c2e572b0212aaeabec96f99603c867a96d32ffb5670047e07be2'
 $source3=Join-Path $temporaryDir 'wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-3.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-3.ps1' -OutFile $source3
 if ((Get-FileHash -LiteralPath $source3 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'ac3d013ff5d98fa7d81f8150656d210b5585adbbcbd378270090804d3d48507c') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-protection.tests.ps1 RAW_SHA256 c449029201f8982b6dc9385354bc2d27bc0c1a11b64c268994c3939f3e7fd156 STAGED_SHA256 ac3d013ff5d98fa7d81f8150656d210b5585adbbcbd378270090804d3d48507c'
 $source4=Join-Path $temporaryDir 'wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-4.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-4.ps1' -OutFile $source4
 if ((Get-FileHash -LiteralPath $source4 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '7343dc8c4841503fba57d3c5ba7be893f95828169f44db320e9df61cceedb78d') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-diagnostics.tests.ps1 RAW_SHA256 9910053784a6875f4f6f13a75888b120731c6c502ba0cfb78d57dfc96535bffb STAGED_SHA256 7343dc8c4841503fba57d3c5ba7be893f95828169f44db320e9df61cceedb78d'
 $source5=Join-Path $temporaryDir 'wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-5.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-activation-diagnostic-d6732cb6e31144e4b8eeac83a4d7b8cd-5.ps1' -OutFile $source5
 if ((Get-FileHash -LiteralPath $source5 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/lint-ps1.ps1 RAW_SHA256 6f2083b9ed30d7747c6fc3868c3359413cbed2e75c884a7509bdf31af2fef3bf STAGED_SHA256 f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8'
 & $source5 -Files @($source0,$source1,$source2,$source3,$source4)
 if ($LASTEXITCODE -ne 0) { throw 'Native lint failed' }
 & $source2 -HelperPath $source0
 & $source3 -HelperPath $source1 -KeyHelperPath $source0
 & $source4 -KeyHelperPath $source0 -ProtectionHelperPath $source1
 Write-Output 'PASS native isolated activation failure diagnostics'
} finally { Remove-Item -LiteralPath $temporaryDir -Recurse -Force -ErrorAction Stop }
