#Requires -Version 7.2
function Wait-ObservedUninstallerRemoval {
    param([Parameter(Mandatory=$true)][string]$Path,
          [Parameter(Mandatory=$true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$Sha256,
          [ValidateRange(1,30)][int]$TimeoutSeconds=30)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try { $attributes=[IO.File]::GetAttributes($Path) }
        catch [IO.FileNotFoundException] { return $clock.ElapsedMilliseconds }
        catch [IO.DirectoryNotFoundException] { return $clock.ElapsedMilliseconds }
        if (($attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) { throw 'Uninstaller identity became nonregular' }
        try { $actual=(Get-FileHash -LiteralPath $Path -ErrorAction Stop).Hash }
        catch {
            # The second phase may remove the file between attribute/hash reads.
            try { $null=[IO.File]::GetAttributes($Path) }
            catch [IO.FileNotFoundException] { return $clock.ElapsedMilliseconds }
            catch [IO.DirectoryNotFoundException] { return $clock.ElapsedMilliseconds }
            throw
        }
        if ($actual -ine $Sha256) { throw 'Uninstaller identity changed before removal' }
        if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Uninstaller self-removal was not observed before its deadline' }
        Start-Sleep -Milliseconds 100
    }
}
