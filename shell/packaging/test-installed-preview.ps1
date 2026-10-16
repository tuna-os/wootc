#Requires -Version 7.2
param(
    [Parameter(Mandatory=$true)][ValidateSet('wootc','tunaos','aurora','bazzite','bluefin')][string]$BrandId,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{40}$')][string]$BuildId,
    [Parameter(Mandatory=$true)][string]$PackageDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'wait-uninstaller-removal.ps1')
$package=[IO.Path]::GetFullPath($PackageDirectory)
$output=[IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($output) | Out-Null
$unique=[guid]::NewGuid().ToString('N')
$private=Join-Path $env:TEMP "wootc-preview-packaging-$unique"
if (Test-Path -LiteralPath $private) { throw 'Existing packaging scratch' }
[IO.Directory]::CreateDirectory($private) | Out-Null
$destination=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) "wootc Native Preview/$BrandId-$unique"
if (Test-Path -LiteralPath $destination) { throw 'Existing preview destination' }
$verifiedUninstall=$false
function Write-CleanupInventory {
    param([string]$Observation)
    $entries=@()
    if ([IO.Directory]::Exists($destination)) {
        foreach ($entry in @(Get-ChildItem -LiteralPath $destination -Recurse -Force -ErrorAction Stop | Sort-Object FullName)) {
            if ($entries.Count -ge 4096) { throw 'Cleanup inventory exceeds its bound' }
            $reparse=($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            $digest=$null
            if (-not $entry.PSIsContainer -and -not $reparse) { $digest=(Get-FileHash -LiteralPath $entry.FullName).Hash }
            $entries += [ordered]@{path=[IO.Path]::GetRelativePath($destination,$entry.FullName);directory=[bool]$entry.PSIsContainer;reparse=$reparse;sha256=$digest}
        }
    }
    [ordered]@{schemaVersion=1;buildId=$BuildId;brandId=$BrandId;observation=$Observation;entries=$entries} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output "cleanup-$Observation.json") -Encoding utf8
}
function Remove-ObservedEmptyDirectory {
    param([string]$Path)
    if (-not [IO.Directory]::Exists($Path)) { return }
    try { [IO.Directory]::Delete($Path,$false) } catch [IO.DirectoryNotFoundException] {
        if ([IO.Directory]::Exists($Path)) { throw }
    }
    if ([IO.Directory]::Exists($Path)) { throw 'Owned empty directory removal was not observed' }
}
function Invoke-OwnedNative {
    param([string]$Executable,[string[]]$Arguments,[int]$TimeoutSeconds=180,[switch]$AllowRefusal)
    $info=[Diagnostics.ProcessStartInfo]::new($Executable)
    $info.UseShellExecute=$false
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process=[Diagnostics.Process]::Start($info)
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true); $process.WaitForExit(); throw 'Owned preview operation exceeded its deadline'
        }
        $code=$process.ExitCode
        if (-not $AllowRefusal -and $code -ne 0) { throw "Owned preview operation refused with exit $code" }
        return $code
    } finally { $process.Dispose() }
}
function StateHashes {
    $state=Join-Path ([IO.Path]::GetPathRoot($destination)) 'wootc'
    $result=[ordered]@{}
    if (Test-Path -LiteralPath $state) {
        foreach ($file in @(Get-ChildItem -LiteralPath $state -File -Recurse -Force -ErrorAction Stop | Sort-Object FullName)) {
            $result[$file.FullName]=(Get-FileHash -LiteralPath $file.FullName).Hash
        }
    }
    return $result
}
try {
    & (Join-Path $PSScriptRoot 'test-manifest.ps1')
    & (Join-Path $PSScriptRoot 'test-uninstaller-removal.ps1')
    & (Join-Path $PSScriptRoot 'write-manifest.ps1') -PackageDirectory $package -BuildId $BuildId -BrandId $BrandId
    $compiled=& (Join-Path $PSScriptRoot 'compile-preview.ps1') -BrandId $BrandId -BuildId $BuildId -PackageDirectory $package -OutputDirectory $output -ScratchDirectory $private
    $installer=$compiled.Installer
    $toolHash=$compiled.ToolSha256
    $compilerVersion=$compiled.CompilerVersion
    $brandPath=Join-Path $PSScriptRoot "../../app/branding/$BrandId/brand.json"
    $arguments=@('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=$destination","/GROUP=wootc Preview Test $unique")
    # A real installer refusal must preserve an existing foreign destination.
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    $sentinel=Join-Path $destination 'public-foreign-file.txt'
    [IO.File]::WriteAllText($sentinel,'public foreign bytes')
    $foreignHash=(Get-FileHash -LiteralPath $sentinel).Hash
    $refusal=Invoke-OwnedNative -Executable $installer -Arguments $arguments -AllowRefusal
    if ($refusal -eq 0 -or (Get-FileHash -LiteralPath $sentinel).Hash -cne $foreignHash -or (Test-Path -LiteralPath (Join-Path $destination 'bundle'))) { throw 'Existing destination refusal did not preserve foreign data' }
    Remove-Item -LiteralPath $sentinel -Force
    Remove-Item -LiteralPath $destination -Force
    $null=Invoke-OwnedNative -Executable $installer -Arguments $arguments
    $bundle=Join-Path $destination 'bundle'
    $env:WOOTC_NATIVE_INSTALLED_EXE=Join-Path $bundle 'Wootc.Shell.exe'
    $env:WOOTC_NATIVE_BRAND_SOURCE=[IO.Path]::GetFullPath($brandPath)
    $beforeStartup=StateHashes
    $stateRoot=Join-Path ([IO.Path]::GetPathRoot($destination)) 'wootc'
    if (Test-Path -LiteralPath (Join-Path $stateRoot 'disks/root.disk')) { throw 'Disposable packaging host unexpectedly has an installation disk' }
    # Which fixed volumes the engine can offer for a plan: it lists only NTFS
    # basic-data partitions on GPT disks. Recorded so a runner without room
    # for a plan says why (docs/winui-shell.md, Hosted plan check).
    foreach ($volume in @(Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter })) {
        try {
            $part=Get-Partition -DriveLetter $volume.DriveLetter -ErrorAction Stop
            $style=(Get-Disk -Number $part.DiskNumber -ErrorAction Stop).PartitionStyle
            Write-Output "volume $($volume.DriveLetter): $($volume.FileSystem), disk $style, partition type $($part.GptType), $([math]::Floor($volume.SizeRemaining/1GB)) GB free"
        } catch { Write-Output "volume $($volume.DriveLetter): not observed ($($_.Exception.Message))" }
    }
    # The engine's plan check can take two minutes (a second elevation, then
    # PrepareNativeInstall), so the test gets more than that on top of startup.
    $null=Invoke-OwnedNative -Executable 'dotnet' -TimeoutSeconds 420 -Arguments @('test',(Join-Path $PSScriptRoot '../Wootc.Shell.UiTests'),'--configuration','Release','--filter','FullyQualifiedName~InstalledPreviewTests','--logger',"trx;LogFileName=installed-$BrandId.trx",'--logger','console;verbosity=normal')
    & (Join-Path $PSScriptRoot 'test-uac-refusal.ps1') -Executable $env:WOOTC_NATIVE_INSTALLED_EXE -BrandSource $env:WOOTC_NATIVE_BRAND_SOURCE -OutputDirectory $output -BrandId $BrandId
    if (@(Get-Process -Name 'wootc-engine' -ErrorAction SilentlyContinue).Count -ne 0) { throw 'An engine process survived the refused elevation' }
    $afterStartup=StateHashes
    $owned=@(Get-ChildItem -LiteralPath $bundle -File -Recurse -Force | Select-Object -ExpandProperty FullName)
    $foreignRoot=Join-Path $destination 'public-preserved-root.txt'
    $foreignBundle=Join-Path $bundle 'public-preserved-bundle.txt'
    foreach ($path in @($foreignRoot,$foreignBundle)) { [IO.File]::WriteAllText($path,'public foreign bytes') }
    $uninstallers=@(Get-ChildItem -LiteralPath $destination -File -Filter 'unins*.exe')
    if ($uninstallers.Count -ne 1) { throw 'Actual preview uninstaller absent/ambiguous' }
    if (($uninstallers[0].Attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) { throw 'Actual preview uninstaller is nonregular' }
    $uninstallerHash=(Get-FileHash -LiteralPath $uninstallers[0].FullName).Hash
    $null=Invoke-OwnedNative -Executable $uninstallers[0].FullName -Arguments @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART')
    $uninstallerRemovalMs=Wait-ObservedUninstallerRemoval -Path $uninstallers[0].FullName -Sha256 $uninstallerHash
    foreach ($path in $owned) { if (Test-Path -LiteralPath $path) { throw 'Recorded preview artifact remains after uninstall' } }
    foreach ($path in @($foreignRoot,$foreignBundle)) { if ((Get-FileHash -LiteralPath $path).Hash -cne $foreignHash) { throw 'Preview uninstall changed foreign bytes' } }
    $afterUninstall=StateHashes
    if (($afterStartup | ConvertTo-Json -Compress) -cne ($afterUninstall | ConvertTo-Json -Compress)) { throw 'Preview uninstall changed engine installation state' }
    $record=[ordered]@{schemaVersion=1;buildId=$BuildId;brandId=$BrandId;toolSha256=$toolHash;toolSigner=$compiled.Signer;toolVersion=$compilerVersion;peFileVersion=$compiled.PeFileVersion;installerSha256=(Get-FileHash -LiteralPath $installer).Hash;manifestSha256=(Get-FileHash -LiteralPath (Join-Path $package 'native-package.json')).Hash;beforeStartup=$beforeStartup;afterStartup=$afterStartup;afterUninstall=$afterUninstall;existingDestinationRefused=$true;foreignFilesPreserved=$true;actualInstalledStartupRpc=$true;actualUacRefusal=$true;uninstallerRemovalObserved=$true;uninstallerRemovalMilliseconds=$uninstallerRemovalMs;interactiveUacProved=$false;offlineRuntimeProved=$false;minimumOsProved=$false}
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $output 'packaging-observations.json') -Encoding utf8
    $verifiedUninstall=$true
} finally {
    # After the preservation assertions, dispose only the exact public fixtures
    # and empty directories. An absent child cannot break recursive enumeration.
    if ($verifiedUninstall) {
        Write-CleanupInventory -Observation before
        foreach ($path in @($foreignRoot,$foreignBundle)) {
            if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path).Hash -cne $foreignHash) { throw 'Public foreign fixture disappeared before its explicit disposal' }
            [IO.File]::Delete($path)
        }
        Remove-ObservedEmptyDirectory -Path $bundle
        Write-CleanupInventory -Observation after-public-fixtures
        Remove-ObservedEmptyDirectory -Path $destination
    } elseif ([IO.Directory]::Exists($destination)) { [IO.Directory]::Delete($destination,$true) }
    if ([IO.Directory]::Exists($private)) { [IO.Directory]::Delete($private,$true) }
}

if ([IO.Directory]::Exists($destination) -or [IO.Directory]::Exists($private)) { throw 'Owned preview test cleanup incomplete' }
[ordered]@{schemaVersion=1;buildId=$BuildId;brandId=$BrandId;ownedScratchRemovalObserved=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'packaging-cleanup.json') -Encoding utf8
Write-Output "PASS actual $BrandId preview compile/install/brand/startup RPC/uninstall with foreign-file preservation and observed test cleanup"
