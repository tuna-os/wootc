$ErrorActionPreference = 'Stop'
$originalOS = $env:OS
$private = Join-Path $env:TEMP ([Guid]::NewGuid().ToString('N'))
try {
 [void](New-Item -ItemType Directory -Path $private)
 $acl = New-Object System.Security.AccessControl.DirectorySecurity
 $acl.SetAccessRuleProtection($true, $false)
 foreach ($sidText in @('S-1-5-18','S-1-5-32-544')) {
  $sid = New-Object System.Security.Principal.SecurityIdentifier($sidText)
  $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
  $acl.AddAccessRule($rule)
 }
 Set-Acl -LiteralPath $private -AclObject $acl
 $source = Join-Path $private 'query.ps1'
 [IO.File]::WriteAllBytes($source,[Convert]::FromBase64String('77u/IyBSZWFkLW9ubHkgYWN0dWFsIHN0b3JhZ2UgZGlzY292ZXJ5LCBzaGFyZWQgYnkgZGlhZ25vc3RpY3MgYW5kIGZpeHR1cmUgYWN0aXZhdGlvbi4NCiRFcnJvckFjdGlvblByZWZlcmVuY2UgPSAnU3RvcCcNCmlmICgkZW52Ok9TIC1uZSAnV2luZG93c19OVCcpIHsgdGhyb3cgJ1N0b3JhZ2UgZGlzY292ZXJ5IHJlcXVpcmVzIFdpbmRvd3MgaWRlbnRpdHknIH0NCiRzdG9yYWdlQ2FuZGlkYXRlcyA9IEAoR2V0LVBTRHJpdmUgLVBTUHJvdmlkZXIgRmlsZVN5c3RlbSAtRXJyb3JBY3Rpb24gU3RvcCB8IFdoZXJlLU9iamVjdCB7DQogICAgJGRyaXZlID0gW3N0cmluZ10kXy5Sb290DQogICAgJGluc3RhbGwgPSAiJHtkcml2ZX13b290Y1xpbnN0YWxsIg0KICAgICRkaXNrID0gIiR7ZHJpdmV9d29vdGNcZGlza3Nccm9vdC5kaXNrIg0KICAgIChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICRpbnN0YWxsIC1QYXRoVHlwZSBDb250YWluZXIpIC1hbmQNCiAgICAgICAgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJGRpc2sgLVBhdGhUeXBlIExlYWYpDQp9KQ0KaWYgKCRzdG9yYWdlQ2FuZGlkYXRlcy5Db3VudCAtbmUgMSkgeyB0aHJvdyAnQWN0dWFsIHN0b3JhZ2Ugcm9vdCBpcyB1bmF2YWlsYWJsZSBvciBhbWJpZ3VvdXMnIH0NCiRsZXR0ZXIgPSBbc3RyaW5nXSRzdG9yYWdlQ2FuZGlkYXRlc1swXS5OYW1lDQppZiAoJGxldHRlciAtbm90bWF0Y2ggJ15bQS1aYS16XSQnKSB7IHRocm93ICdJbnZhbGlkIGFjdHVhbCBzdG9yYWdlIGRyaXZlJyB9DQpXcml0ZS1PdXRwdXQgJGxldHRlcg0K'))
 if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne '90d01d78de99e48a706e6453be5d84b15dd1af57ccbcfb6313c153c9d9a48ab3') { throw 'Source hash mismatch' }
 $tokens=$null; $errors=$null
 [void][Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
 if ($errors.Count -ne 0) { throw 'Parser errors' }
 function Get-PSDrive { param($PSProvider,$ErrorAction) @([pscustomobject]@{Root='C:\';Name='C'},[pscustomobject]@{Root='F:\';Name='F'}) }
 function Test-Path { param($LiteralPath,$PathType) if ($PathType -eq 'Container') { return $script:containers -contains $LiteralPath }; if ($PathType -eq 'Leaf') { return $script:leaves -contains $LiteralPath }; throw 'Unexpected PathType' }
 $cases=@(
  @{Name='C-staging-F-disk';Leaves=@('F:\wootc\disks\root.disk');Expected='F';OS='Windows_NT'},
  @{Name='C-only';Leaves=@('C:\wootc\disks\root.disk');Expected='C';OS='Windows_NT'},
  @{Name='both-disks';Leaves=@('C:\wootc\disks\root.disk','F:\wootc\disks\root.disk');Expected=$null;OS='Windows_NT'},
  @{Name='absent-disk';Leaves=@();Expected=$null;OS='Windows_NT'},
  @{Name='directory-disk';Leaves=@();Expected=$null;OS='Windows_NT'},
  @{Name='wrong-OS';Leaves=@('F:\wootc\disks\root.disk');Expected=$null;OS='Linux'}
 )
 foreach ($case in $cases) {
  $script:containers=@('C:\wootc\install','F:\wootc\install')
  if ($case.Name -eq 'directory-disk') { $script:containers += 'F:\wootc\disks\root.disk' }
  $script:leaves=$case.Leaves; $env:OS=$case.OS; $failed=$false; $actual=@()
  try { $actual=@(& ([scriptblock]::Create([IO.File]::ReadAllText($source)))) } catch { $failed=$true; Write-Output "QUERY REFUSAL: $($_.Exception.Message)" }
  if ($null -eq $case.Expected) { if (-not $failed) { throw "Refusal missing: $($case.Name)" } }
  elseif ($failed -or $actual.Count -ne 1 -or $actual[0] -ne $case.Expected) { throw "Selection failed: $($case.Name)" }
  Write-Output "PASS $($case.Name)"
 }
 Write-Output 'Source SHA256: 5e66c107ffcc8729914c643096666176c5d3caae020f36f54aae914efcdd3ac2'
 Write-Output 'Staged SHA256: 90d01d78de99e48a706e6453be5d84b15dd1af57ccbcfb6313c153c9d9a48ab3'
 Write-Output "PowerShell: $($PSVersionTable.PSVersion)"
} finally { $env:OS=$originalOS; if ([IO.Directory]::Exists($private)) { Remove-Item -LiteralPath $private -Recurse -Force } }
