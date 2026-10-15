$ErrorActionPreference='Stop'
$wanted=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('eyJzY2hlbWFWZXJzaW9uIjoxLCJydW5JZCI6InB1YmxpYy1uYXRpdmUtY3VycmVudCIsImRpcmVjdGl2ZUlkIjoiNzljNTRmMzU0MWNjNGNjNWFhMWY4YjQ0MzE4YjUwMGIiLCJhY3Rpb24iOiJpbnN0YWxsIiwiaW1hZ2UiOiJnaGNyLmlvL3R1bmEtb3MveWVsbG93ZmluOmdub21lIiwidXNlcm5hbWUiOiJ3b290YyIsInBhc3N3b3JkIjoid29vdGMtZTJlLXBhc3MiLCJob3N0bmFtZSI6Indvb3RjLXRlc3QifQ=='))
Set-Content -LiteralPath C:\wootc\e2e-drive.json -Value $wanted -Encoding UTF8
$actual=Get-Content -LiteralPath C:\wootc\e2e-drive.json -Raw
if ($actual.TrimEnd([char]13,[char]10) -cne $wanted) { throw 'Directive readback changed' }
Write-Output 'gui-install-directive-written'