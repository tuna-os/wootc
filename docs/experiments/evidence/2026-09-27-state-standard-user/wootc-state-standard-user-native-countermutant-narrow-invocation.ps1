$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$private=Join-Path $env:TEMP 'wootc-acl-driver-b8e9fe8c39c144f5878ac8fbd004e682'
if(Test-Path -LiteralPath $private) { throw 'Existing source staging' }
[IO.Directory]::CreateDirectory($private) | Out-Null
try {
 $source=Join-Path $private 'driver.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-acl-b8e9fe8c39c144f5878ac8fbd004e682-driver.ps1' -OutFile $source
 if((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -cne '94852531fbe188f399818aa407ba757ab617deebc9ee723356f0c14ea15997ea') { throw 'Driver hash mismatch' }
 $tokens=$null; $errors=$null
 [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors) | Out-Null
 if($errors.Count -ne 0) { throw 'Native driver parse failed' }
 Write-Output 'SOURCE 6336612d263d5f4453b8ce62b748c7a8d139751c NativeDriverHash 94852531fbe188f399818aa407ba757ab617deebc9ee723356f0c14ea15997ea'
 & $source -BinaryUrl 'http://10.104.210.10:8080/wootc-acl-8761a4f89b5d4600ab54261f5186ed34-countermutant.exe' -BinarySha256 'b219f4a2203c5f9ce0a2478aee3f4b06681ccae5d0f81449148896d71dc7c54b'
} finally { Remove-Item -LiteralPath $private -Recurse -Force }
