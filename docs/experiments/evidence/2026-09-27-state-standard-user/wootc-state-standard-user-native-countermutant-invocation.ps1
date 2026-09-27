$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$private=Join-Path $env:TEMP 'wootc-acl-driver-d4a243c64c0847638181311893e6db12'
if(Test-Path -LiteralPath $private) { throw 'Existing source staging' }
[IO.Directory]::CreateDirectory($private) | Out-Null
try {
 $source=Join-Path $private 'driver.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-acl-d4a243c64c0847638181311893e6db12-driver.ps1' -OutFile $source
 if((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -cne '1c159a8697061058c08cadecd4753b0af2e31edf525ac1c6e3c1fa53fc6a1ee8') { throw 'Driver hash mismatch' }
 $tokens=$null; $errors=$null
 [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors) | Out-Null
 if($errors.Count -ne 0) { throw 'Native driver parse failed' }
 Write-Output 'SOURCE 27ebee564e16161279dd4e93167deb7a8344f683 NativeDriverHash 1c159a8697061058c08cadecd4753b0af2e31edf525ac1c6e3c1fa53fc6a1ee8'
 & $source -BinaryUrl 'http://10.104.210.10:8080/wootc-acl-8761a4f89b5d4600ab54261f5186ed34-countermutant.exe' -BinarySha256 'b219f4a2203c5f9ce0a2478aee3f4b06681ccae5d0f81449148896d71dc7c54b'
} finally { Remove-Item -LiteralPath $private -Recurse -Force }
