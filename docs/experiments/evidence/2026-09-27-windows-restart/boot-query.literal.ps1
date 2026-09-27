
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT") { throw "Expected Windows identity" }
$system = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
if ($null -eq $system.LastBootUpTime) { throw "Missing Windows boot observation" }
$bootTime = $system.LastBootUpTime.ToFileTimeUtc()
$record = @{ schemaVersion = 1; os = $env:OS; bootId = "$bootTime" }
$record | ConvertTo-Json -Compress -Depth 3
