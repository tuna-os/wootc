$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$test = 'C:\Windows\Temp\wootc-runtime-install.test.exe'
Invoke-WebRequest -UseBasicParsing 'http://10.104.210.10:8080/wootc-runtime-install.test.exe' -OutFile $test
if ((Get-FileHash -Algorithm SHA256 $test).Hash.ToLowerInvariant() -ne '2e17329d4c61503268a555deba69b131ccc83e9965ddb639af9aa36490c6b2fc') { throw 'Native test binary hash mismatch' }
$env:WOOTC_TEST_RUNTIME_ARCHIVE = 'C:\Windows\Temp\wootc-runtime-bundle-probe\runtime.zip'
$env:WOOTC_TEST_RUNTIME_PUBLIC_KEY = 'def3840b56c1553b4a4de45f995fa007e30f9ff5763007e142ab924fbaefe661'
& $test '-test.v'
exit $LASTEXITCODE
