$encoded='eyJzY2hlbWFWZXJzaW9uIjoxLCJydW5JZCI6InB1YmxpYy1uYXRpdmUtY3VycmVudCIsImRpcmVjdGl2ZUlkIjoiNzljNTRmMzU0MWNjNGNjNWFhMWY4YjQ0MzE4YjUwMGIiLCJhY3Rpb24iOiJyZWJvb3QifQ=='

$ErrorActionPreference = "Stop"
$directive = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
Set-Content -LiteralPath C:\wootc\e2e-drive.json -Value $directive -Encoding ascii
$readback = Get-Content -LiteralPath C:\wootc\e2e-drive.json -Raw
if ($readback.Trim() -ne $directive) { throw "GUI reboot directive readback mismatch" }
Write-Output "gui-reboot-directive-written"
