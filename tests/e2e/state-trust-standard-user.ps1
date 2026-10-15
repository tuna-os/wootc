#Requires -Version 5.1
param(
 [Parameter(Mandatory=$true)][uri]$BinaryUrl,
 [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{64}$')][string]$BinarySha256
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if ($env:OS -ne 'Windows_NT') { throw 'Expected native Windows fixture' }
$id=[Guid]::NewGuid().ToString('N')
$name="wootc_acl_$($id.Substring(0,10))"
$private=Join-Path $env:TEMP "wootc-acl-private-$id"
$public=Join-Path ([Environment]::GetFolderPath('CommonDocuments')) "wootc-acl-public-$id"
$vhd=Join-Path $private 'owned-test.vhd'
$accountSid=$null
foreach ($path in @($private,$public)) { if (Test-Path -LiteralPath $path) { throw 'Existing native ACL fixture path' } }
[IO.Directory]::CreateDirectory($private) | Out-Null
& icacls.exe $private /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' *> $null
if ($LASTEXITCODE -ne 0) { throw 'Private fixture ACL failed' }
try {
 [IO.Directory]::CreateDirectory($public) | Out-Null
 & icacls.exe $public /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)M' *> $null
 if ($LASTEXITCODE -ne 0) { throw 'Public fixture ACL failed' }
 $binary=Join-Path $private 'acl.test.exe'
 Invoke-WebRequest -UseBasicParsing -Uri $BinaryUrl -OutFile $binary
 if ((Get-FileHash -LiteralPath $binary).Hash.ToLowerInvariant() -cne $BinarySha256) { throw 'Native test binary hash mismatch' }
 $occupied=@([IO.Directory]::GetLogicalDrives() | ForEach-Object { $_.Substring(0,1).ToUpperInvariant() })
 $letter=@('Z','Y','X','W','V','U' | Where-Object { $_ -notin $occupied } | Select-Object -First 1)
 if ($letter.Count -ne 1) { throw 'No unused alternate fixture drive letter' }
 $script=Join-Path $private 'create-owned.txt'
 @("create vdisk file=`"$vhd`" maximum=96 type=expandable","select vdisk file=`"$vhd`"",'attach vdisk','create partition primary',"format fs=ntfs quick label=WOOTC_ACL_$($id.Substring(0,8))", "assign letter=$($letter[0])") | Set-Content -LiteralPath $script -Encoding ascii
 & diskpart.exe /s $script | Out-Null
 if ($LASTEXITCODE -ne 0) { throw 'Owned virtual disk command failed' }
 $image=Get-DiskImage -ImagePath $vhd -ErrorAction Stop
 if (-not $image.Attached) { throw 'Owned virtual disk is not attached' }
 $disk=$image | Get-Disk
 $partitions=@($disk | Get-Partition | Where-Object DriveLetter)
 if ($partitions.Count -ne 1 -or $partitions[0].DriveLetter -cne $letter[0]) { throw 'Owned disk has wrong observed partition/letter' }
 $volume=$partitions[0] | Get-Volume
 if ($volume.FileSystem -cne 'NTFS' -or $volume.FileSystemLabel -cne "WOOTC_ACL_$($id.Substring(0,8))") { throw 'Fresh owned NTFS identity mismatch' }
 $mountRoot=$letter[0] + ':\'
 $volumeAcl=Get-Acl -LiteralPath $mountRoot
 if ($volumeAcl.Sddl.Length -gt 4096 -or @($volumeAcl.Access).Count -gt 64) { throw 'Fresh volume ACL exceeds bounded evidence limits' }
 $aclRows=@($volumeAcl.Access | ForEach-Object { [ordered]@{sid=$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;rightsSigned=[int32]$_.FileSystemRights;type=[string]$_.AccessControlType;inheritance=[string]$_.InheritanceFlags;propagation=[string]$_.PropagationFlags;inherited=$_.IsInherited} })
 [ordered]@{schemaVersion=1;freshOwnedNtfsVolume=$true;sddl=$volumeAcl.Sddl;entries=$aclRows} | ConvertTo-Json -Depth 4 -Compress | Write-Output
 $password=[Guid]::NewGuid().ToString('N')+'aA1!'
 $account=New-LocalUser -Name $name -Password (ConvertTo-SecureString $password -AsPlainText -Force) -Description "wootc ACL $($id.Substring(0,16))"
 $accountSid=$account.SID.Value
 Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $account
 $env:WOOTC_ACL_USER=$name; $env:WOOTC_ACL_PASSWORD=$password; $env:WOOTC_ACL_SID=$accountSid
 $env:WOOTC_ACL_FIXTURE=$public; $env:WOOTC_ACL_ALTERNATE=$letter[0] + ':\'
 Write-Output "NATIVE_ACL_INPUT Windows=$($PSVersionTable.PSVersion) BinarySha256=$BinarySha256 FileSystem=$($volume.FileSystem) FreshOwnedVolume=true"
 & $binary '-test.v' '-test.run' '^(TestNativeStateStandardUserAndAlternateVolume|TestState(DescriptorTrust|Tree.*|Drive.*)|TestLiteralVolumeDeleteDoesNotExemptOtherAncestors)$' '-test.timeout' '60s'
 if ($LASTEXITCODE -ne 0) { throw "Actual native ACL controls failed with exit $LASTEXITCODE" }
 } finally {
 $cleanupErrors=[Collections.Generic.List[string]]::new()
 foreach ($key in @('WOOTC_ACL_USER','WOOTC_ACL_PASSWORD','WOOTC_ACL_SID','WOOTC_ACL_FIXTURE','WOOTC_ACL_ALTERNATE')) { [Environment]::SetEnvironmentVariable($key,$null,'Process') }
 try {
  if ($accountSid) {
   $account=Get-LocalUser -Name $name
   if ($account.SID.Value -cne $accountSid) { throw 'Disposable account identity changed' }
   Remove-LocalUser -SID $account.SID
   if (Get-LocalUser -SID $account.SID -ErrorAction SilentlyContinue) { throw 'Disposable account removal not observed' }
  }
 } catch { $cleanupErrors.Add('Disposable account cleanup failed') }
 $diskReleased=$false
 try {
  if (Test-Path -LiteralPath $vhd) {
   $image=Get-DiskImage -ImagePath $vhd
   if ($image.Attached) { Dismount-DiskImage -ImagePath $vhd | Out-Null }
   if ((Get-DiskImage -ImagePath $vhd).Attached) { throw 'Owned virtual disk detach not observed' }
  }
  $diskReleased=$true
 } catch { $cleanupErrors.Add('Owned virtual disk detach failed; backing file retained') }
 try {
  if (Test-Path -LiteralPath $public) { Remove-Item -LiteralPath $public -Recurse -Force }
  if (Test-Path -LiteralPath $public) { throw 'Owned public fixture remains' }
 } catch { $cleanupErrors.Add('Owned public fixture cleanup failed') }
 if ($diskReleased) {
  try {
   if (Test-Path -LiteralPath $private) { Remove-Item -LiteralPath $private -Recurse -Force }
   if (Test-Path -LiteralPath $private) { throw 'Owned private fixture remains' }
  } catch { $cleanupErrors.Add('Owned private fixture cleanup failed') }
 }
 if ($cleanupErrors.Count -gt 0) { throw ($cleanupErrors -join '; ') }
 Write-Output 'PASS native ACL fixture cleanup observed'
}
