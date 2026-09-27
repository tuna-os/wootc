# Runs only isolated function bodies from setup; never executes OEM setup.
param([Parameter(Mandatory=$true)][string]$SetupPath,
      [string]$StorageRoot = $env:SystemDrive)
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($SetupPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "OEM parse errors: $errors" }
foreach ($name in @('Get-WootcNtfsHostUuid', 'Write-WootcInstallationIdentity')) {
    $function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
    if (-not $function) { throw "Missing OEM function $name" }
    Invoke-Expression $function.Extent.Text
}
function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
# Independent native Windows utility reports the complete NTFS serial.
$actualSerial = Get-WootcNtfsHostUuid -StorageRoot $StorageRoot
$ntfsInfo = (& fsutil fsinfo ntfsinfo $StorageRoot 2>&1) | Out-String
if ($LASTEXITCODE -ne 0) { throw "fsutil failed: $ntfsInfo" }
$serialMatch = [regex]::Match($ntfsInfo, '(?im)^\s*NTFS Volume Serial Number\s*:\s*0x([0-9a-f]{16})\s*$')
Assert-Test $serialMatch.Success 'Cannot independently determine full NTFS serial from fsutil'
Assert-Test ($actualSerial -eq $serialMatch.Groups[1].Value.ToUpperInvariant()) 'FSCTL serial differs from NTFS volume identity'
Write-Output "PASS native FSCTL full NTFS serial: $actualSerial"

# Disposable directory; the production function still invokes the trust check.
# The mock deliberately avoids changing ACLs on user or installer directories.
$script:trustChecks = 0
function Assert-WootcStateTree([string]$Path) { $script:trustChecks++ }
$script:serial = 'AABBCCDD11223344'
function Get-WootcNtfsHostUuid([string]$StorageRoot) {
    Assert-Test ($StorageRoot -eq 'E:') 'OEM used the system drive instead of selected storage'
    return $script:serial
}
$fixtureName = [Guid]::NewGuid().ToString('N')
$fixture = Join-Path ([IO.Path]::GetTempPath()) "$fixtureName-wootc-identity"
[IO.Directory]::CreateDirectory($fixture) | Out-Null
$argsForIdentity = @{ InstallDirectory = $fixture; StorageRoot = 'E:';
    EspPartitionGuid = '{12345678-1234-1234-1234-123456789ABC}';
    LoaderPath = '\EFI\fedora\shimx64.efi'; ImageRef = 'ghcr.io/tuna-os/yellowfin:gnome' }
try {
    $record = Join-Path $fixture 'installed-linux-boot.json'
    $complete = Join-Path $fixture 'installed-linux-boot.complete'
    [IO.File]::WriteAllText($record, 'previous record for diagnosis')
    [IO.File]::WriteAllText($complete, 'old completion')
    Write-WootcInstallationIdentity @argsForIdentity
    $identityPath = Join-Path $fixture 'installation.json'
    $first = Get-Content -Raw -LiteralPath $identityPath | ConvertFrom-Json
    Assert-Test ($first.schemaVersion -eq 1) 'Wrong schema version'
    Assert-Test ($first.installationId -cmatch '^[a-f0-9]{32}$') 'Missing fresh lowerhex installation ID'
    Assert-Test ($first.armedAt -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$') 'Missing RFC3339 arming date'
    Assert-Test ($first.hostUuid -eq 'AABBCCDD11223344') 'Full NTFS UUID was truncated'
    Assert-Test ($first.espPartitionGuid -eq '12345678-1234-1234-1234-123456789abc') 'Staged ESP GUID not normalized'
    Assert-Test ($first.loaderPath -eq $argsForIdentity.LoaderPath) 'Actual loader path changed'
    Assert-Test ($first.imageRef -eq $argsForIdentity.ImageRef) 'Selected image changed'
    Assert-Test ($first.rootDiskPath -eq '/wootc/disks/root.disk') 'Root disk path changed'
    Assert-Test (-not (Test-Path -LiteralPath $complete)) 'Stale completion survived successful arming'
    Assert-Test ([IO.File]::ReadAllText($record) -eq 'previous record for diagnosis') 'Old diagnostic boot record was erased'
    Write-WootcInstallationIdentity @argsForIdentity
    $second = Get-Content -Raw -LiteralPath $identityPath | ConvertFrom-Json
    Assert-Test ($second.installationId -ne $first.installationId) 'Rearming reused the installation ID'
    Write-Output 'PASS fresh identity, selected ESP/storage/image/loader and marker reset'

    $expected = [IO.File]::ReadAllText($identityPath)
    foreach ($badSerial in @('11223344', '', '0000000000000000')) {
        $script:serial = $badSerial
        [IO.File]::WriteAllText($complete, 'old completion')
        $failed = $false
        try { Write-WootcInstallationIdentity @argsForIdentity } catch { $failed = $true }
        Assert-Test $failed 'Missing or truncated UUID was accepted'
        Assert-Test ([IO.File]::ReadAllText($identityPath) -eq $expected) 'Failed serial changed durable identity'
        Assert-Test (Test-Path -LiteralPath $complete) 'Failed serial reset completion marker'
    }
    # A noisy helper must not turn -notmatch into an array filter or choose
    # one of several UUIDs. The production capture collapses all output first.
    $script:serial = @('AABBCCDD11223344', '1122334455667788')
    $failed = $false
    try { Write-WootcInstallationIdentity @argsForIdentity } catch { $failed = $true }
    Assert-Test $failed 'Multiple UUID outputs were accepted'
    Assert-Test ([IO.File]::ReadAllText($identityPath) -eq $expected) 'Multiple UUID outputs changed durable identity'
    Assert-Test (Test-Path -LiteralPath $complete) 'Multiple UUID outputs reset completion marker'
    Write-Output 'PASS multiple UUID outputs refused without changing installation state'
    $script:serial = 'AABBCCDD11223344'
    $argsForIdentity.EspPartitionGuid = [Guid]::Empty.ToString()
    $failed = $false
    try { Write-WootcInstallationIdentity @argsForIdentity } catch { $failed = $true }
    Assert-Test $failed 'Empty ESP identity accepted'
    Assert-Test ([IO.File]::ReadAllText($identityPath) -eq $expected) 'Failed ESP lookup changed durable identity'
    Assert-Test (Test-Path -LiteralPath $complete) 'Failed ESP lookup reset completion marker'
    foreach ($invalidField in @('EspPartitionGuid', 'LoaderPath', 'ImageRef')) {
        $invalidArgs = $argsForIdentity.Clone()
        $invalidArgs.EspPartitionGuid = '12345678-1234-1234-1234-123456789abc'
        $invalidArgs[$invalidField] = ''
        $failed = $false
        try { Write-WootcInstallationIdentity @invalidArgs } catch { $failed = $true }
        Assert-Test $failed "Missing identity field $invalidField accepted"
        Assert-Test ([IO.File]::ReadAllText($identityPath) -eq $expected) 'Missing metadata changed durable identity'
        Assert-Test (Test-Path -LiteralPath $complete) 'Missing metadata reset completion marker'
    }
    Assert-Test ($script:trustChecks -ge 9) 'Identity writes did not inspect the protected directory'
    Assert-Test (@(Get-ChildItem -LiteralPath $fixture -Filter '*.tmp').Count -eq 0) 'Temporary identity files leaked'
    Write-Output 'PASS absent/truncated host UUID and missing ESP fail before changing installation state'
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
