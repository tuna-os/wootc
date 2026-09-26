$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = 'C:\Windows\Temp\wootc-phase1-probe'
Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform | Select-Object FeatureName,State | Format-List
Get-CimInstance Win32_ComputerSystem | Select-Object HypervisorPresent,TotalPhysicalMemory,UserName | Format-List
foreach ($mem in @(2048,4096)) {
  $prefix = Join-Path $dir "whpx-$mem"
  $serial = "$prefix-serial.log"
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $args = @('-machine','q35','-accel','whpx','-cpu','max','-smp','2','-m',"$mem",'-nodefaults','-no-reboot','-display','none','-monitor','none','-serial',"file:$serial",'-kernel',"$dir\probe-vmlinuz",'-initrd',"$dir\probe-initramfs.cpio.gz",'-append','"console=ttyS0 panic=-1"')
  $p = Start-Process 'C:\Program Files\qemu\qemu-system-x86_64.exe' -ArgumentList $args -RedirectStandardOutput "$prefix-out.log" -RedirectStandardError "$prefix-err.log" -PassThru
  $ready = $false
  $peak = 0
  while (-not $p.HasExited -and $timer.Elapsed.TotalSeconds -lt 120) {
    $p.Refresh()
    if ($p.WorkingSet64 -gt $peak) { $peak = $p.WorkingSet64 }
    if (-not $ready -and (Test-Path $serial) -and (Select-String -Path $serial -SimpleMatch WOOTC_NESTED_LINUX_PROBE_READY -Quiet)) {
      $ready = $true
      Write-Output "MEM=$mem READY_SECONDS=$($timer.Elapsed.TotalSeconds) WORKING_SET=$($p.WorkingSet64)"
    }
    Start-Sleep -Milliseconds 200
  }
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Write-Output "MEM=$mem TIMED_OUT" }
  $p.WaitForExit()
  Write-Output "MEM=$mem EXIT=$($p.ExitCode) TOTAL_SECONDS=$($timer.Elapsed.TotalSeconds) PEAK_WORKING_SET=$peak READY=$ready"
  if (Test-Path "$prefix-err.log") { Get-Content "$prefix-err.log" }
  if (Test-Path $serial) { Get-Content $serial | Select-Object -Last 30 }
}
