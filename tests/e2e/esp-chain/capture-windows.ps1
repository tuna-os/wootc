param([Parameter(Mandatory=$true)][string]$ScratchId,
      [Parameter(Mandatory=$true)][string]$AfterLinuxBootId,
      [Parameter(Mandatory=$true)][string]$TransportNonce,
      [Parameter(Mandatory=$true)][string]$Volume)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Current guest is not Windows' }
if ($Volume -notmatch '^[A-Za-z]:$') { throw 'Invalid volume' }
$RootDisk = "$Volume\wootc\disks\root.disk"
if (-not (Test-Path -LiteralPath $RootDisk -PathType Leaf)) { throw 'Actual root.disk absent on queried volume' }
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class WootcQaNtfs {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFile(string name, uint access, uint share,
    IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool DeviceIoControl(SafeFileHandle handle, uint code,
    IntPtr input, uint inputSize, byte[] output, uint outputSize,
    out uint returned, IntPtr overlapped);
  public static string Serial(string volume) {
    using (SafeFileHandle handle = CreateFile(@"\\.\" + volume, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
      if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception();
      byte[] data = new byte[96]; uint returned;
      if (!DeviceIoControl(handle, 0x00090064, IntPtr.Zero, 0, data, 96, out returned, IntPtr.Zero) || returned < 96)
        throw new System.ComponentModel.Win32Exception();
      return BitConverter.ToUInt64(data, 0).ToString("X16");
    }
  }
}
'@
$VmUuid = (Get-CimInstance Win32_ComputerSystemProduct).UUID.ToLowerInvariant()
$HostUuid = [WootcQaNtfs]::Serial($Volume)
[ordered]@{ schemaVersion = 1; scratchId = $ScratchId; vmUuid = $VmUuid;
  transportNonce = $TransportNonce; os = $env:OS; hostUuid = $HostUuid; afterLinuxBootId = $AfterLinuxBootId;
  capturedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
