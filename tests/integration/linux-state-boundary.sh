#!/bin/bash
set -Eeuo pipefail
# Requires a disposable Windows-formatted VHD with protected wootc/state.json,
# wootc/install and Windows-created Users/fixture/Documents. Never pass a host
# device: this converts the fixture into a private raw copy before mounting it.
repo=$(cd "$(dirname "$0")/../.." && pwd)
driver=${1:?usage: linux-state-boundary.sh DRIVER FIXTURE.vhd}
fixture=${2:?a disposable Windows-created VHD is required}
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
qemu-img convert -f vpc -O raw "$fixture" "$out/disk.raw"
loop=$(sudo losetup --find --show --partscan "$out/disk.raw")
trap 'sudo losetup -d "$loop"; rm -rf "$out"' EXIT
sudo unshare --mount bash -s -- "$repo" "$driver" "${loop}p1" <<'INNER'
set -Eeuo pipefail
repo=$1 driver=$2 device=$3
mount --make-rprivate /
mount -t tmpfs tmpfs /run
mount --make-shared /run
mkdir -p /run/initramfs/wootc-host /run/wootc /run/home/Documents
chmod 0700 /run/initramfs
trap 'umount -R /run/home/Documents 2>/dev/null || true; umount -R /run/wootc/host 2>/dev/null || true; umount -R /run/initramfs/wootc-view-control 2>/dev/null || true; umount /run/initramfs/wootc-host 2>/dev/null || true' EXIT
if [[ "$driver" == lowntfs-3g ]]; then
 lowntfs-3g -o rw,umask=000,ignore_case "$device" /run/initramfs/wootc-host
else
 mount -t "$driver" -o rw,umask=000 "$device" /run/initramfs/wootc-host
fi
bash "$repo/payload/migration/wootc-host-view" start
chown "$(id -u nobody):$(id -g nobody)" /run/home
HOST=/run/initramfs/wootc-host
FOLDERS=(Documents)
bound=0
sel_on() { return 0; }
resolved_folder() { return 0; }
add_host_bookmark() { :; }
log() { echo "$*"; }
warn() { echo "$*" >&2; }
source <(sed -n '/^safe_folder_source()/,/^}/p' "$repo/payload/migration/wootc-mount-user-dirs")
source <(sed -n '/^bind_profile()/,/^}/p' "$repo/payload/migration/wootc-mount-user-dirs")
bind_profile "$HOST/Users/fixture/" nobody /run/home
if sudo -u daemon sh -c 'echo forged > /run/home/Documents/other-user.txt'; then exit 25; fi
chmod 0755 /run/home
sudo -u daemon sh -c 'echo negative-control > /run/home/Documents/other-user.txt'
chmod 0700 /run/home
echo 'NEGATIVE CONTROL PASS: second account can write only without private home boundary' 
stat -c 'documents_mode=%a owner=%u:%g' /run/home/Documents
sudo -u nobody sh -c 'printf selected-user-data > /run/home/Documents/proof.txt'
[[ $(cat /run/initramfs/wootc-host/Users/fixture/Documents/proof.txt) == selected-user-data ]]
printf '{"state":"healthy"}\n' > /run/initramfs/wootc-host/wootc/state.json
printf fixture-secret > /run/initramfs/wootc-host/wootc/install/bitlocker-key.txt
for alias in wootc WOOTC Wootc; do
 if sudo -u nobody cat "/run/wootc/host/$alias/install/bitlocker-key.txt"; then exit 21; fi
 if sudo -u nobody cat "/run/wootc/host/$alias/state.json"; then exit 22; fi
done
if sudo -u nobody cat /run/initramfs/wootc-host/wootc/state.json; then exit 23; fi
if sudo -u nobody sh -c 'echo forged > /run/wootc/host/forged.txt'; then exit 24; fi
# The actual production mask must be responsible for denying disclosure.
umount /run/wootc/host/wootc
[[ $(sudo -u nobody cat /run/wootc/host/wootc/install/bitlocker-key.txt) == fixture-secret ]]
echo 'NEGATIVE CONTROL PASS: without mask the key becomes readable'
mount -o remount,bind,rw /run/wootc/host
sudo -u nobody sh -c 'rm /run/wootc/host/wootc/state.json && echo forged > /run/wootc/host/wootc/state.json'
echo 'NEGATIVE CONTROL PASS: without public RO metadata can be forged'
umount /run/home/Documents
bash "$repo/payload/migration/wootc-host-view" stop
umount /run/initramfs/wootc-host
echo 'PASS actual host-view: private state/key, public RO, selected Documents RW, root metadata write, clean stop'
INNER
