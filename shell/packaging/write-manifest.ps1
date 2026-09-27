param(
    [Parameter(Mandatory = $true)][string]$PackageDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{40}$')][string]$BuildId,
    [Parameter(Mandatory = $true)][ValidateSet('wootc', 'tunaos', 'aurora', 'bazzite', 'bluefin')][string]$BrandId
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($PackageDirectory)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Preview package directory is absent' }
if ((Get-Item -LiteralPath $root -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point at preview package root' }
$manifestPath = Join-Path $root 'native-package.json'
if (Test-Path -LiteralPath $manifestPath) { throw 'Refusing to overwrite an existing preview manifest' }
$objects = @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)
foreach ($item in $objects) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse point in preview package' }
}
$files = [Collections.Generic.SortedDictionary[string,string]]::new([StringComparer]::Ordinal)
foreach ($item in $objects) {
    if ($item.PSIsContainer) { continue }
    $relative = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
    if ($relative.Contains(':') -or $relative.StartsWith('../')) { throw 'Unsafe preview package path' }
    $files.Add($relative, (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
}
if ($files.Count -gt 4096) { throw 'Preview package exceeds file limit' }
foreach ($required in @('wootc-engine.exe', 'Wootc.Shell.exe', 'Wootc.Shell.dll', 'Wootc.Shell.pri', 'Branding/brand.json')) {
    if (-not $files.ContainsKey($required)) { throw "Preview package missing $required" }
}
$expectedPath = Join-Path $PSScriptRoot "../../app/branding/$BrandId/brand.json"
$actualPath = Join-Path $root 'Branding/brand.json'
$expectedHash = (Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash
$actualHash = (Get-FileHash -LiteralPath $actualPath -Algorithm SHA256).Hash
if ($expectedHash -ne $actualHash) { throw 'Preview branding differs from the selected source brand' }
$manifest = @{ schemaVersion = 1; protocolVersion = 1; buildId = $BuildId; brandId = $BrandId; files = $files }
$json = ConvertTo-Json -InputObject $manifest -Depth 4 -Compress
$bytes = [Text.Encoding]::UTF8.GetBytes($json)
if ($bytes.Length -gt 1048576) { throw 'Preview manifest exceeds size limit' }
$stream = [IO.File]::Open($manifestPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
