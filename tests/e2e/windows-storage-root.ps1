# Read-only actual storage discovery, shared by diagnostics and fixture activation.
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Storage discovery requires Windows identity' }
$storageCandidates = @(Get-PSDrive -PSProvider FileSystem -ErrorAction Stop | Where-Object {
    $drive = [string]$_.Root
    $install = "${drive}wootc\install"
    $disk = "${drive}wootc\disks\root.disk"
    (Test-Path -LiteralPath $install -PathType Container) -and
        (Test-Path -LiteralPath $disk -PathType Leaf)
})
if ($storageCandidates.Count -ne 1) { throw 'Actual storage root is unavailable or ambiguous' }
$letter = [string]$storageCandidates[0].Name
if ($letter -notmatch '^[A-Za-z]$') { throw 'Invalid actual storage drive' }
Write-Output $letter
