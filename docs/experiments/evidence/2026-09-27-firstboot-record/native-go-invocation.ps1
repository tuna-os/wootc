$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$dir=Join-Path $env:TEMP ('wootc-firstboot-audit-'+[guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $dir) { throw 'Audit directory already exists' }
New-Item -ItemType Directory -Path $dir | Out-Null
& icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect native audit directory' }
try {
 $exe=Join-Path $dir 'firstboot-record.test.exe'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-firstboot-record.test.exe' -OutFile $exe
 $actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
 if ($actual -ne '35c89186e07e9b637411e9b7c01ea0905f8e7e54a072a8972470a5afc118c181') { throw 'Native audit binary hash mismatch' }
 Write-Output 'SOURCE_BASE_SHA=ac211264f38d91047c2e15ac65ff3ba6578bbca2; working Go source hashes retained in provenance'
 Write-Output "BINARY_SHA256=$actual"
 & $exe '-test.v' '-test.run' '^(TestLinuxBootEvidence.*|TestBootRecord.*|TestInstallationIdentity.*|TestNTFSHostUUIDMatchesNativeVolume)$'
 $rc=$LASTEXITCODE
 if ($rc -ne 0) { throw "Native artifact authentication checks failed: $rc" }
} finally {
 Remove-Item -LiteralPath $dir -Recurse -Force
}
