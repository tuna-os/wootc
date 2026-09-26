$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$dir = 'C:\Windows\Temp\wootc-runtime-bundle-probe'
if (Test-Path $dir) { throw 'Probe directory already exists; preserve previous evidence' }
New-Item -ItemType Directory -Path $dir | Out-Null
Invoke-WebRequest -UseBasicParsing 'http://10.104.210.10:8080/wootc-vm-runtime.zip' -OutFile "$dir\runtime.zip"
if ((Get-FileHash -Algorithm SHA256 "$dir\runtime.zip").Hash.ToLowerInvariant() -ne '7b40edf55a7686cd6e59088432717e3c5293b2378d115c671d922da7c97e869b') { throw 'Runtime ZIP hash mismatch' }
Invoke-WebRequest -UseBasicParsing 'http://10.104.210.10:8080/serial-boot.img' -OutFile "$dir\serial-boot.img"
if ((Get-FileHash -Algorithm SHA256 "$dir\serial-boot.img").Hash.ToLowerInvariant() -ne 'f591bb62b9fce510dc7a4a096940ffbfc596d925739416559017cfb2a92e7195') { throw 'Bootsector hash mismatch' }
Expand-Archive -Path "$dir\runtime.zip" -DestinationPath $dir
$qemu = "$dir\qemu\qemu-system-x86_64.exe"
$env:PATH = "$dir\qemu;C:\Windows\System32;C:\Windows"
$env:TEMP = $dir
$env:TMP = $dir
$env:HOME = $dir
foreach ($name in @('GTK_PATH','GTK_EXE_PREFIX','GTK_DATA_PREFIX','GIO_EXTRA_MODULES','GIO_MODULE_DIR','GDK_PIXBUF_MODULE_FILE','GDK_PIXBUF_MODULEDIR','QEMU_AUDIO_DRV','QEMU_MODULE_DIR','QEMU_BIOS_DIR','XDG_CONFIG_HOME','XDG_DATA_DIRS')) {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
Set-Location $dir
& $qemu '--version'
if ($LASTEXITCODE -ne 0) { throw 'Bundled QEMU cannot load' }
& $qemu '-display' 'help'
if ($LASTEXITCODE -ne 0) { throw 'Bundled QEMU display help failed' }
$serial = "$dir\serial.log"
$arguments = @('-machine','pc','-accel','tcg','-smp','1','-m','128','-display','none','-monitor','none','-serial',"file:$serial",'-drive',"file=$dir\serial-boot.img,format=raw,if=floppy",'-boot','a')
$timer = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process $qemu -WorkingDirectory $dir -ArgumentList $arguments -RedirectStandardOutput "$dir\out.log" -RedirectStandardError "$dir\err.log" -PassThru
$ready = $false
try {
  while (-not $p.HasExited -and $timer.Elapsed.TotalSeconds -lt 30) {
    if ((Test-Path $serial) -and (Select-String -Path $serial -SimpleMatch WOOTC_WHPX_BOOTSECTOR_EXECUTED -Quiet)) { $ready = $true; break }
    Start-Sleep -Milliseconds 100
    $p.Refresh()
  }
  Write-Output "BUNDLE_TCG_BOOT=$ready SECONDS=$($timer.Elapsed.TotalSeconds)"
  if (-not $ready) { throw 'Bundled runtime did not execute the guest marker' }
} finally {
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  Get-Content "$dir\err.log" -ErrorAction SilentlyContinue
  Get-Content $serial -ErrorAction SilentlyContinue
}
