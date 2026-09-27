$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 'Expected native Windows fixture' }
Write-Output "NATIVE_POWERSHELL $($PSVersionTable.PSVersion)"
$temporaryName=[Guid]::NewGuid().ToString('N')
$temporaryDir=Join-Path $env:TEMP "wootc-correlated-receipt-$temporaryName"
if (Test-Path -LiteralPath $temporaryDir) { throw 'Refusing existing directory' }
[IO.Directory]::CreateDirectory($temporaryDir) | Out-Null
& icacls.exe $temporaryDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Private temporary ACL failed' }
try {
 $source0=Join-Path $temporaryDir 'wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-0.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-0.ps1' -OutFile $source0
 if ((Get-FileHash -LiteralPath $source0 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '8db4325510069524a52d9bb5b27bd04261fdff8e24fbb70f6febf88f76374eb9') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.ps1 RAW_SHA256 bc1ce871b5d030c26b10715568ef1a02ead79d7ee91db87e471028afa3776fee STAGED_SHA256 8db4325510069524a52d9bb5b27bd04261fdff8e24fbb70f6febf88f76374eb9'
 $source1=Join-Path $temporaryDir 'wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-1.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-1.ps1' -OutFile $source1
 if ((Get-FileHash -LiteralPath $source1 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '3cf5bab722e19a30b3deb5f04db8c9b650171c840c0c1502f9fa461af2d18b10') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-protection.ps1 RAW_SHA256 c2224cf8c619f8e933a6f52467975142a549500ea30ca500863434e1dcfa8462 STAGED_SHA256 3cf5bab722e19a30b3deb5f04db8c9b650171c840c0c1502f9fa461af2d18b10'
 $source2=Join-Path $temporaryDir 'wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-2.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-2.ps1' -OutFile $source2
 if ((Get-FileHash -LiteralPath $source2 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'a526afb7e181c2e572b0212aaeabec96f99603c867a96d32ffb5670047e07be2') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-key.tests.ps1 RAW_SHA256 36ea43ee821b01a055c07401adbf8140223711288a1f3e187565ab4598fdba6c STAGED_SHA256 a526afb7e181c2e572b0212aaeabec96f99603c867a96d32ffb5670047e07be2'
 $source3=Join-Path $temporaryDir 'wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-3.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-3.ps1' -OutFile $source3
 if ((Get-FileHash -LiteralPath $source3 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'ac3d013ff5d98fa7d81f8150656d210b5585adbbcbd378270090804d3d48507c') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-protection.tests.ps1 RAW_SHA256 c449029201f8982b6dc9385354bc2d27bc0c1a11b64c268994c3939f3e7fd156 STAGED_SHA256 ac3d013ff5d98fa7d81f8150656d210b5585adbbcbd378270090804d3d48507c'
 $source4=Join-Path $temporaryDir 'wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-4.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-4.ps1' -OutFile $source4
 if ((Get-FileHash -LiteralPath $source4 -Algorithm SHA256).Hash.ToLowerInvariant() -ne '0a2d73841f04cf47706d7a356277cef21af3b7cc7f76353ced89cee35b9441f3') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/e2e/fixture-bitlocker-diagnostics.tests.ps1 RAW_SHA256 48dbe0292dab223e98b8054347ff6e20217cbabe070ffa092dc70192026310ba STAGED_SHA256 0a2d73841f04cf47706d7a356277cef21af3b7cc7f76353ced89cee35b9441f3'
 $source5=Join-Path $temporaryDir 'wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-5.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-correlated-receipt-a876ab1106f84a428c877c3845b93d72-5.ps1' -OutFile $source5
 if ((Get-FileHash -LiteralPath $source5 -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8') { throw 'Source checksum mismatch' }
 Write-Output 'SOURCE tests/lint-ps1.ps1 RAW_SHA256 6f2083b9ed30d7747c6fc3868c3359413cbed2e75c884a7509bdf31af2fef3bf STAGED_SHA256 f122b8a52d07e877082950d9adfd87726232dddb998b17dcdd1fd0cc990b03b8'
 & $source5 -Files @($source0,$source1,$source2,$source3,$source4)
 if ($LASTEXITCODE -ne 0) { throw 'Native lint failed' }
 & $source2 -HelperPath $source0
 & $source3 -HelperPath $source1 -KeyHelperPath $source0
 & $source4 -KeyHelperPath $source0 -ProtectionHelperPath $source1
 Write-Output 'PASS native isolated activation failure diagnostics'
} finally { Remove-Item -LiteralPath $temporaryDir -Recurse -Force -ErrorAction Stop }
