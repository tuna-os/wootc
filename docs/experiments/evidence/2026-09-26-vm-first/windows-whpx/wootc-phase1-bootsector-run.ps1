$ErrorActionPreference = 'Stop'
$dir = 'C:\Windows\Temp\wootc-phase1-probe'
if ((Get-FileHash -Algorithm SHA256 "$dir\serial-boot.img").Hash.ToLowerInvariant() -ne 'f591bb62b9fce510dc7a4a096940ffbfc596d925739416559017cfb2a92e7195') { throw 'bootsector hash mismatch' }
foreach ($accel in @('tcg','whpx,kernel-irqchip=off')) {
  $tag = $accel.Split(',')[0]
  $prefix = "$dir\bootsector-$tag"
  $serial = "$prefix-serial.log"
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $args = @('-machine','pc','-accel',$accel,'-smp','1','-m','128','-display','none','-monitor','none','-serial',"file:$serial",'-drive',"file=$dir\serial-boot.img,format=raw,if=floppy",'-boot','a')
  $p = Start-Process 'C:\Program Files\qemu\qemu-system-x86_64.exe' -ArgumentList $args -RedirectStandardOutput "$prefix-out.log" -RedirectStandardError "$prefix-err.log" -PassThru
  $ready = $false
  while (-not $p.HasExited -and $timer.Elapsed.TotalSeconds -lt 20) {
    if ((Test-Path $serial) -and (Select-String -Path $serial -SimpleMatch WOOTC_WHPX_BOOTSECTOR_EXECUTED -Quiet)) { $ready = $true; break }
    Start-Sleep -Milliseconds 100
  }
  Write-Output "ACCEL=$accel READY=$ready SECONDS=$($timer.Elapsed.TotalSeconds)"
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  Get-Content "$prefix-err.log"
  Get-Content $serial
}
