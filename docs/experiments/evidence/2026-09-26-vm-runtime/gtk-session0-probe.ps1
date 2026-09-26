$ErrorActionPreference = 'Stop'
$dir = 'C:\Windows\Temp\wootc-runtime-bundle-probe'
$qemu = "$dir\qemu\qemu-system-x86_64.exe"
$env:PATH = "$dir\qemu;C:\Windows\System32;C:\Windows"
$env:TEMP = $dir
$env:TMP = $dir
$env:HOME = $dir
foreach ($name in @('GTK_PATH','GTK_EXE_PREFIX','GTK_DATA_PREFIX','GIO_EXTRA_MODULES','GIO_MODULE_DIR','GDK_PIXBUF_MODULE_FILE','GDK_PIXBUF_MODULEDIR','QEMU_AUDIO_DRV','QEMU_MODULE_DIR','QEMU_BIOS_DIR','XDG_CONFIG_HOME','XDG_DATA_DIRS')) {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$serial = "$dir\gtk-serial.log"
$arguments = @('-machine','pc','-accel','tcg','-smp','1','-m','128','-display','gtk,window-close=off,show-menubar=off','-monitor','none','-serial',"file:$serial",'-drive',"file=$dir\serial-boot.img,format=raw,if=floppy",'-boot','a')
$timer = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process $qemu -WorkingDirectory $dir -ArgumentList $arguments -RedirectStandardOutput "$dir\gtk-out.log" -RedirectStandardError "$dir\gtk-err.log" -PassThru
$ready = $false
try {
  while (-not $p.HasExited -and $timer.Elapsed.TotalSeconds -lt 30) {
    if ((Test-Path $serial) -and (Select-String -Path $serial -SimpleMatch WOOTC_WHPX_BOOTSECTOR_EXECUTED -Quiet)) { $ready = $true; break }
    Start-Sleep -Milliseconds 100
    $p.Refresh()
  }
  Write-Output "BUNDLE_GTK_BOOT=$ready SECONDS=$($timer.Elapsed.TotalSeconds) SESSION=$($p.SessionId)"
  if (-not $ready) { throw 'Bundled GTK runtime did not execute guest marker' }
  foreach ($module in $p.Modules) {
    $path = $module.FileName
    if (-not $path.StartsWith("$dir\qemu\", [StringComparison]::OrdinalIgnoreCase) -and -not $path.StartsWith('C:\Windows\System32\', [StringComparison]::OrdinalIgnoreCase) -and -not $path.StartsWith('C:\Windows\WinSxS\', [StringComparison]::OrdinalIgnoreCase)) { throw "Module loaded outside runtime or Windows: $path" }
    if ($path.StartsWith("$dir\qemu\", [StringComparison]::OrdinalIgnoreCase)) { Write-Output "BUNDLE_MODULE=$($module.ModuleName)" }
  }
} finally {
  if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
  Get-Content "$dir\gtk-err.log" -ErrorAction SilentlyContinue
  Get-Content $serial -ErrorAction SilentlyContinue
}
