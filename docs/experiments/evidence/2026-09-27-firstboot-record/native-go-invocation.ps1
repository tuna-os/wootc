$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$dir=Join-Path $env:TEMP ('wootc-firstboot-audit-'+[guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $dir) { throw 'Audit directory already exists' }
New-Item -ItemType Directory -Path $dir | Out-Null
& icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect native audit directory' }
try {
 $exe=Join-Path $dir 'firstboot-record.test.exe'
 Invoke-WebRequest -UseBasicParsing -Uri 'http://10.104.210.10:8080/wootc-firstboot-integrated.test.exe' -OutFile $exe
 $actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
 if ($actual -ne '5c6507df051a34e2726b242253d12a1f4ca12f9d174c0fbde0a852859bdca32c') { throw 'Native audit binary hash mismatch' }
 Write-Output 'SOURCE_SHA=cb02711bca818a174a47ca370653011e4a04f0ad'
 Write-Output "BINARY_SHA256=$actual"
 & $exe '-test.v' '-test.run' '^(TestLinuxBootEvidence.*|TestBootRecord.*|TestInstallationIdentity.*|TestNTFSHostUUIDMatchesNativeVolume|TestStatusDiscovery.*|TestStatusAudit.*)$'
 $rc=$LASTEXITCODE
 if ($rc -ne 0) { throw "Native artifact authentication checks failed: $rc" }
} finally {
 Remove-Item -LiteralPath $dir -Recurse -Force
}
