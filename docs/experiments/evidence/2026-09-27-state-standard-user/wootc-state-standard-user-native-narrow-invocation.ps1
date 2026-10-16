$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$private=Join-Path $env:TEMP 'wootc-acl-driver-4fe6fb4390cf4e2a8d775c827a985bed'
if(Test-Path -LiteralPath $private) { throw 'Existing source staging' }
[IO.Directory]::CreateDirectory($private) | Out-Null
try {
 $source=Join-Path $private 'driver.ps1'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-acl-4fe6fb4390cf4e2a8d775c827a985bed-driver.ps1' -OutFile $source
 if((Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() -cne '94852531fbe188f399818aa407ba757ab617deebc9ee723356f0c14ea15997ea') { throw 'Driver hash mismatch' }
 $tokens=$null; $errors=$null
 [Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors) | Out-Null
 if($errors.Count -ne 0) { throw 'Native driver parse failed' }
 Write-Output 'SOURCE 6336612d263d5f4453b8ce62b748c7a8d139751c NativeDriverHash 94852531fbe188f399818aa407ba757ab617deebc9ee723356f0c14ea15997ea'
 & $source -BinaryUrl 'http://10.104.210.10:8080/wootc-acl-732e1305ecb7451aafdf8a516d909b43-binary.exe' -BinarySha256 'a6717acab93f0de99d6ab81b29bc1714c438e5ef3f412ec7fa71a937c71d2ea1'
} finally { Remove-Item -LiteralPath $private -Recurse -Force }
