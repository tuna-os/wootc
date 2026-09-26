#!/bin/bash
set -euo pipefail
cd /work
grep -q '^STATUS=SUCCESS' helper-ipc.log
test ! -e installed-monitor.sock
test -e /work/installed-vars.fd || cp /usr/share/OVMF/OVMF_VARS_4M.fd /work/installed-vars.fd
exec timeout 900 qemu-system-x86_64 \
 -accel kvm -cpu host -m 3072 -smp 2 -machine q35 \
 -display none -monitor unix:/work/installed-monitor.sock,server=on,wait=off \
 -serial file:/work/installed-serial.log \
 -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
 -drive if=pflash,format=raw,file=/work/installed-vars.fd \
 -drive file=/work/root.disk,format=raw,if=none,id=root \
 -device virtio-blk-pci,drive=root,serial=wootc-root \
 -device virtio-vga \
 -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
 -device virtio-serial-pci \
 -chardev socket,id=qga,path=/work/installed-qga.sock,server=on,wait=off \
 -device virtserialport,chardev=qga,name=org.qemu.guest_agent.0
