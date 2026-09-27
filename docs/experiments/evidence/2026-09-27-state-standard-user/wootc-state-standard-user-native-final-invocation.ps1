$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$private=Join-Path $env:TEMP 'wootc-acl-driver-fa83296950e745ec9c5bb367f21bf923'
if(Test-Path -LiteralPath $private) { throw 'Existing source staging' }
[IO.Directory]::CreateDirectory($private) | Out-Null
try {
 $source=Join-Path $private 'driver.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-acl-fa83296950e745ec9c5bb367f21bf923-driver.ps1' -OutFile $source
 if((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -cne '1c159a8697061058c08cadecd4753b0af2e31edf525ac1c6e3c1fa53fc6a1ee8') { throw 'Driver hash mismatch' }
 $tokens=$null; $errors=$null
 [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors) | Out-Null
 if($errors.Count -ne 0) { throw 'Native driver parse failed' }
 Write-Output 'SOURCE 2daa8d4432cc8802fa8d7a798ad4863957c93282 NativeDriverHash 1c159a8697061058c08cadecd4753b0af2e31edf525ac1c6e3c1fa53fc6a1ee8'
 & $source -BinaryUrl 'http://10.104.210.10:8080/wootc-acl-732e1305ecb7451aafdf8a516d909b43-binary.exe' -BinarySha256 'a6717acab93f0de99d6ab81b29bc1714c438e5ef3f412ec7fa71a937c71d2ea1'
} finally { Remove-Item -LiteralPath $private -Recurse -Force }
