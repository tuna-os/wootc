#!/usr/bin/env bats
# Wiring checks complement oem-installation-identity.ps1's native behavior.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }
@test "OEM records the staged ESP and chosen storage before its recovery guard" {
    run python3 - "$ROOT/tests/e2e/setup-wootc.ps1" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
arming = s[s.index('# ── Step 8b:'):s.index('# ── Step 9:')]
assert '$espGuid = [string]$espPart.Guid' in arming
assert 'Get-Partition' not in arming
call = arming.index('Write-WootcInstallationIdentity -InstallDirectory $installDir -StorageRoot $storageRoot')
assert call < arming.index('$armedObj =')
assert "-EspPartitionGuid $espGuid -LoaderPath '\\EFI\\fedora\\shimx64.efi' -ImageRef $ImageRef" in arming
assert 'bcdedit /set $newGuid path "\\EFI\\fedora\\shimx64.efi"' in s
PY
    [ "$status" -eq 0 ]
}
@test "native identity test covers FSCTL full serial and stale completion refusal" {
    # Native-only API behavior is tested by the PowerShell fixture on Windows.
    run python3 - "$ROOT/tests/e2e/setup-wootc.ps1" "$ROOT/tests/unit/oem-installation-identity.ps1" <<'PY'
from pathlib import Path
import sys
s, test = (Path(p).read_text() for p in sys.argv[1:])
assert 'public ulong VolumeSerialNumber;' in s
assert '0x00090064' in s and 'DeviceIoControl(handle' in s
assert 'VolumeSerialNumber.ToString("X16")' in s
assert 'fsutil fsinfo ntfsinfo' in test
assert "@('11223344', '', '0000000000000000')" in test
assert 'second.installationId -ne $first.installationId' in test
assert 'Failed serial reset completion marker' in test
assert s.index('$stream.Flush($true)') < s.index('[IO.File]::Replace(') < s.index("'installed-linux-boot.complete'")
PY
    [ "$status" -eq 0 ]
}
