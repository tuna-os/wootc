#!/usr/bin/env bats
#
# bootc on an installed composefs system reads LoaderInfo to decide where its
# boot entries live. Phase 2 boots through the Windows installer's signed
# Fedora GRUB, so bootc looks in /sysroot/boot; `bootc install --bootloader
# systemd` had put them on root.disk's ESP, and `bootc status` stopped with
# "Getting sorted Type1 boot entries: No such file or directory" (grouper run
# 44788137298, flounder:gnome-sid run 44788412620). wootc-cfs-boot moves the
# entries to the GRUB layout and renders them as the Windows ESP's GRUB menu.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CFS="$REPO_ROOT/payload/migration/wootc-cfs-boot"
    DEPLOY="$REPO_ROOT/payload/deployer/deploy.sh"
    export WOOTC_ESP_OWN="$REPO_ROOT/payload/migration/wootc-esp-own"
    T="$BATS_TEST_TMPDIR"
    IMG_ESP="$T/image-esp"     # root.disk's ESP, as bootc installed it
    BOOT="$T/sysroot/boot"     # the physical root's /boot
    HOST_ESP="$T/windows-esp"  # the Windows ESP
    mkdir -p "$BOOT" "$HOST_ESP/EFI/wootc"
    : > "$HOST_ESP/EFI/wootc/wootc-owned.txt"
    echo kernel > "$HOST_ESP/EFI/wootc/deployer-vmlinuz"
    echo overlay > "$HOST_ESP/EFI/wootc/phase2-overlay.cpio"
    A=bootc_composefs-$(printf 'a%.0s' {1..128})
    B=bootc_composefs-$(printf 'b%.0s' {1..128})
}

# image_entry <dir> <file> <version>: an entry as `bootc install --bootloader
# systemd` writes it, with the deployer's loop arguments already appended.
image_entry() {
    local dir="$1" file="$2" version="$3"
    mkdir -p "$IMG_ESP/loader/entries" "$IMG_ESP/EFI/Linux/$dir"
    echo "vmlinuz $dir" > "$IMG_ESP/EFI/Linux/$dir/vmlinuz"
    echo "initrd $dir" > "$IMG_ESP/EFI/Linux/$dir/initrd"
    cat > "$IMG_ESP/loader/entries/$file" <<EOF
title Grouper GNOME
version $version
sort-key bootc-ubuntu-0
linux /EFI/Linux/$dir/vmlinuz
initrd /EFI/Linux/$dir/initrd
options root=UUID=1234 rw composefs=${dir#bootc_composefs-} splash quiet \$tuned_params wootc.host_uuid=0123456789ABCDEF loop=/wootc/disks/root.disk
EOF
}

# boot_entry <dir> <file>: an entry as bootc writes it in the GRUB layout.
boot_entry() {
    local dir="$1" file="$2"
    mkdir -p "$BOOT/loader/entries" "$BOOT/$dir"
    echo "initrd $dir" > "$BOOT/$dir/initrd"
    cat > "$BOOT/loader/entries/$file" <<EOF
title Grouper GNOME
version 1
linux /boot/$dir/vmlinuz
initrd /boot/$dir/initrd
options root=UUID=1234 rw composefs=${dir#bootc_composefs-} loop=/wootc/disks/root.disk
EOF
}

menu_composefs() {  # the composefs= of each Linux menu entry, in order
    grep -o 'composefs=[a-z0-9]*' "$HOST_ESP/EFI/fedora/grub.cfg" | cut -c11-11
}

@test "adopt moves bootc's entry and kernel directory into /boot, the GRUB layout" {
    image_entry "$A" bootc_ubuntu-26.04-1.conf 26.04
    run bash "$CFS" adopt --esp "$IMG_ESP" --boot "$BOOT" \
        --kargs "loop=/wootc/disks/root.disk wootc.host_uuid=0123456789ABCDEF console=ttyS0,115200 selinux=0" \
        --drop "quiet rhgb"
    [ "$status" -eq 0 ]
    local entry="$BOOT/loader/entries/bootc_ubuntu-26.04-1.conf"
    [ -f "$entry" ]
    [ "$(cat "$BOOT/$A/vmlinuz")" = "vmlinuz $A" ]
    [ "$(cat "$BOOT/$A/initrd")" = "initrd $A" ]
    grep -qx "linux /boot/$A/vmlinuz" "$entry"
    grep -qx "initrd /boot/$A/initrd" "$entry"
    # bootc lists GRUB entries only when /boot/grub2 exists.
    [ -d "$BOOT/grub2" ]
    # Nothing left where bootc no longer looks.
    [ ! -e "$IMG_ESP/loader/entries/bootc_ubuntu-26.04-1.conf" ]
    [ ! -e "$IMG_ESP/EFI/Linux/$A" ]
}

@test "adopt adds the Phase-2 arguments once and drops quiet and unexpanded variables" {
    image_entry "$A" bootc_ubuntu-26.04-1.conf 26.04
    bash "$CFS" adopt --esp "$IMG_ESP" --boot "$BOOT" \
        --kargs "loop=/wootc/disks/root.disk wootc.host_uuid=0123456789ABCDEF selinux=0 rd.timeout=120" \
        --drop "quiet rhgb"
    local options
    options=$(sed -n 's/^options //p' "$BOOT/loader/entries/bootc_ubuntu-26.04-1.conf")
    [ "$options" = "root=UUID=1234 rw composefs=$(printf 'a%.0s' {1..128}) splash wootc.host_uuid=0123456789ABCDEF loop=/wootc/disks/root.disk selinux=0 rd.timeout=120" ]
}

@test "adopt leaves root.disk's ESP untouched when an entry is not a bootc Type 1 entry" {
    image_entry "$A" bootc_ubuntu-26.04-1.conf 26.04
    printf 'title other\nlinux /vmlinuz\ninitrd /initrd\noptions ro\n' > "$IMG_ESP/loader/entries/other.conf"
    run bash "$CFS" adopt --esp "$IMG_ESP" --boot "$BOOT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a bootc Type 1 path"* ]]
    [ -f "$IMG_ESP/loader/entries/bootc_ubuntu-26.04-1.conf" ]
    [ -d "$IMG_ESP/EFI/Linux/$A" ]
    [ ! -e "$BOOT/loader" ]
}

@test "adopt refuses an entry whose initrd is missing, before moving anything" {
    image_entry "$A" bootc_ubuntu-26.04-1.conf 26.04
    rm "$IMG_ESP/EFI/Linux/$A/initrd"
    run bash "$CFS" adopt --esp "$IMG_ESP" --boot "$BOOT"
    [ "$status" -ne 0 ]
    [ -f "$IMG_ESP/loader/entries/bootc_ubuntu-26.04-1.conf" ]
    [ ! -e "$BOOT/$A" ]
}

@test "deploy-time sync claims and writes all three wootc grub.cfg paths" {
    boot_entry "$A" bootc_ubuntu-1-1.conf
    run bash "$CFS" sync --install --boot "$BOOT" --esp "$HOST_ESP"
    [ "$status" -eq 0 ]
    local rel
    for rel in EFI/fedora/grub.cfg EFI/redhat/grub.cfg EFI/wootc/grub.cfg; do
        [ "$(head -c 7 "$HOST_ESP/$rel")" = "# wootc" ]
        grep -qx "$(tr 'A-Z' 'a-z' <<<"$rel")" "$HOST_ESP/EFI/wootc/wootc-owned.txt"
    done
    # The entry's initrd is on the ESP and claimed, so uninstall removes it.
    [ "$(cat "$HOST_ESP/EFI/wootc/$A-initrd")" = "initrd $A" ]
    grep -qx "efi/wootc/$A-initrd" "$HOST_ESP/EFI/wootc/wootc-owned.txt"
    local cfg="$HOST_ESP/EFI/fedora/grub.cfg"
    grep -q "linux /EFI/wootc/deployer-vmlinuz root=UUID=1234 rw composefs=a" "$cfg"
    # The overlay loads first, as when it was prepended to one file.
    grep -qx "    initrd /EFI/wootc/phase2-overlay.cpio /EFI/wootc/$A-initrd" "$cfg"
    grep -q "^menuentry 'Windows'" "$cfg"
    grep -q 'chainloader /EFI/Microsoft/Boot/bootmgfw.efi' "$cfg"
}

@test "an upgrade's new entry becomes the default and the booted one the rollback" {
    boot_entry "$A" bootc_ubuntu-1-1.conf
    bash "$CFS" sync --install --boot "$BOOT" --esp "$HOST_ESP"
    # bootc's finalize: the new deployment is "-1" (primary), the booted "-0".
    mv "$BOOT/loader/entries/bootc_ubuntu-1-1.conf" "$BOOT/loader/entries/bootc_ubuntu-1-0.conf"
    boot_entry "$B" bootc_ubuntu-2-1.conf
    run bash "$CFS" sync --boot "$BOOT" --esp "$HOST_ESP"
    [ "$status" -eq 0 ]
    [ "$(menu_composefs | tr -d '\n')" = "ba" ]
    grep -q "^menuentry 'Grouper GNOME (rollback)'" "$HOST_ESP/EFI/fedora/grub.cfg"
    [ -f "$HOST_ESP/EFI/wootc/$A-initrd" ]
    [ -f "$HOST_ESP/EFI/wootc/$B-initrd" ]
}

@test "a rollback reorders the menu, and a deleted deployment's initrd leaves the ESP" {
    # Two builds of one release: bootc's file names differ only in priority.
    boot_entry "$A" bootc_ubuntu-26.04-0.conf
    boot_entry "$B" bootc_ubuntu-26.04-1.conf
    bash "$CFS" sync --install --boot "$BOOT" --esp "$HOST_ESP"
    [ "$(menu_composefs | tr -d '\n')" = "ba" ]
    # `bootc rollback` rewrites the whole directory (rollback.rs names both
    # entries for os id "bootc"): the rollback target gets priority 1.
    rm "$BOOT/loader/entries/"*.conf
    boot_entry "$A" bootc_bootc-26.04-1.conf
    boot_entry "$B" bootc_bootc-26.04-0.conf
    bash "$CFS" sync --boot "$BOOT" --esp "$HOST_ESP"
    [ "$(menu_composefs | tr -d '\n')" = "ab" ]
    # bootc's garbage collection drops B's entry.
    rm "$BOOT/loader/entries/bootc_bootc-26.04-0.conf"
    bash "$CFS" sync --boot "$BOOT" --esp "$HOST_ESP"
    [ "$(menu_composefs | tr -d '\n')" = "a" ]
    [ ! -e "$HOST_ESP/EFI/wootc/$B-initrd" ]
    [ -f "$HOST_ESP/EFI/wootc/$A-initrd" ]
}

@test "the menu follows bootc's GRUB order: file name, descending" {
    # get_sorted_type1_boot_entries orders GRUB entries by file name
    # (bootc-dev/bootc#2221), so a higher version sorts first whatever its
    # priority; the menu must agree with what bootc reports, not improve on it.
    boot_entry "$A" bootc_ubuntu-26.04.1-0.conf
    boot_entry "$B" bootc_ubuntu-26.04-1.conf
    bash "$CFS" sync --install --boot "$BOOT" --esp "$HOST_ESP"
    [ "$(menu_composefs | tr -d '\n')" = "ab" ]
}

@test "without --install only wootc-marked grub.cfg files are rewritten" {
    boot_entry "$A" bootc_ubuntu-1-1.conf
    mkdir -p "$HOST_ESP/EFI/fedora" "$HOST_ESP/EFI/redhat"
    echo '# wootc Phase 2 (old)' > "$HOST_ESP/EFI/fedora/grub.cfg"
    echo 'menuentry "RHEL" {}' > "$HOST_ESP/EFI/redhat/grub.cfg"
    run bash "$CFS" sync --boot "$BOOT" --esp "$HOST_ESP"
    [ "$status" -eq 0 ]
    grep -q phase2-overlay.cpio "$HOST_ESP/EFI/fedora/grub.cfg"
    [ "$(cat "$HOST_ESP/EFI/redhat/grub.cfg")" = 'menuentry "RHEL" {}' ]
    [ ! -e "$HOST_ESP/EFI/wootc/grub.cfg" ]
}

@test "a default entry that cannot be published leaves the ESP as it was" {
    boot_entry "$A" bootc_ubuntu-1-1.conf
    mkdir -p "$HOST_ESP/EFI/fedora"
    echo '# wootc previous menu' > "$HOST_ESP/EFI/fedora/grub.cfg"
    rm "$BOOT/$A/initrd"
    run bash "$CFS" sync --boot "$BOOT" --esp "$HOST_ESP"
    [ "$status" -ne 0 ]
    [ "$(cat "$HOST_ESP/EFI/fedora/grub.cfg")" = '# wootc previous menu' ]
}

@test "sync refuses an ESP without the deployer kernel or the overlay" {
    boot_entry "$A" bootc_ubuntu-1-1.conf
    rm "$HOST_ESP/EFI/wootc/phase2-overlay.cpio"
    run bash "$CFS" sync --install --boot "$BOOT" --esp "$HOST_ESP"
    [ "$status" -ne 0 ]
    [[ "$output" == *"phase2-overlay.cpio is missing"* ]]
    [ ! -e "$HOST_ESP/EFI/fedora/grub.cfg" ]
}

@test "wootc-esp-sync hands a composefs install to wootc-cfs-boot" {
    boot_entry "$A" bootc_ubuntu-1-1.conf
    mkdir -p "$HOST_ESP/EFI/fedora"
    echo '# wootc' > "$HOST_ESP/EFI/fedora/grub.cfg"
    run env WOOTC_ESP_DIR="$HOST_ESP" WOOTC_BOOT_DIR="$BOOT" PHASE2_BOOT=composefs-bls \
        WOOTC_CFS_BOOT="$CFS" bash "$REPO_ROOT/payload/migration/wootc-esp-sync"
    [ "$status" -eq 0 ]
    grep -q "initrd /EFI/wootc/phase2-overlay.cpio /EFI/wootc/$A-initrd" "$HOST_ESP/EFI/fedora/grub.cfg"
    # The kernel-pair route never ran.
    [ ! -e "$HOST_ESP/EFI/wootc/phase2-vmlinuz" ]
}

@test "the shutdown sync runs after bootc finalizes a staged upgrade" {
    local unit="$REPO_ROOT/payload/migration/wootc-esp-sync-shutdown.service"
    # Units stop in reverse order: Before= stops this one after bootc's.
    grep -qx 'Before=bootc-finalize-staged.service' "$unit"
    grep -qx 'ExecStop=/var/usrlocal/bin/wootc-esp-sync' "$unit"
    grep -qx 'RemainAfterExit=yes' "$unit"
    # bootc-finalize-staged.service is Before=basic.target; default
    # dependencies (After=basic.target) would make that an ordering cycle.
    grep -qx 'DefaultDependencies=no' "$unit"
    grep -qx 'RequiresMountsFor=/sysroot /var/usrlocal/bin' "$unit"
}

# loader_info <string>: LoaderInfo as efivarfs presents it, 4 attribute
# bytes and a NUL-terminated UTF-16LE string.
loader_info() {
    { printf '\x06\x00\x00\x00'; printf '%s\0' "$1" | iconv -f UTF-8 -t UTF-16LE; } > "$T/LoaderInfo"
}

@test "the deployer reads its own loader from LoaderInfo" {
    eval "$(sed -n '/^phase2_host_loader() {/,/^}/p' "$DEPLOY")"
    loader_info "GRUB 2.12"
    [ "$(WOOTC_LOADER_INFO="$T/LoaderInfo" phase2_host_loader)" = grub ]
    loader_info "systemd-boot 258.2-1"
    [ "$(WOOTC_LOADER_INFO="$T/LoaderInfo" phase2_host_loader)" = systemd-boot ]
    [ "$(WOOTC_LOADER_INFO="$T/absent" phase2_host_loader)" = unknown ]
}

@test "only a systemd-boot chain keeps bootc's entries on root.disk's ESP" {
    grep -q '\[\[ "$PHASE2_HOST_LOADER" != systemd-boot \]\] || CFS_GRUB=0' "$DEPLOY"
    grep -q 'wootc-cfs-boot adopt --esp "$TESP" --boot /mnt/verify/boot' "$DEPLOY"
    grep -q "PHASE2_BOOT=composefs-bls" "$DEPLOY"
    # The deployer initramfs carries the helper and the unit it installs.
    grep -q 'inst /usr/lib/wootc/migration/wootc-cfs-boot' "$REPO_ROOT/payload/deployer/module-setup.sh"
    grep -q 'inst /usr/lib/wootc/migration/wootc-esp-sync-shutdown.service' "$REPO_ROOT/payload/deployer/module-setup.sh"
}
