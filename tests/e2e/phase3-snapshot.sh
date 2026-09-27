#!/bin/sh
# Read-only current boot, mount, block, projection and exporter observations.
set -eu
action=${1:?Expected native or userdata}
[ "$action" = native ] || [ "$action" = userdata ] || exit 2
os=$(uname -s)
[ "$os" = Linux ] || exit 1
boot_id=$(cat /proc/sys/kernel/random/boot_id)
blocks=$(lsblk --json --paths --output NAME,KNAME,TYPE,MAJ:MIN,PKNAME,UUID)
mounts=$(findmnt --json --output TARGET,SOURCE,FSTYPE,MAJ:MIN,OPTIONS,UUID)
loops=$(losetup --json --output NAME,MAJ:MIN,BACK-FILE)
root_options=$(findmnt --noheadings --raw --output OPTIONS --target /)
loop_files=$(losetup --noheadings --raw --output BACK-FILE)
projection_paths=$(printf '%s\n' "$root_options" | awk -F, '{for(i=1;i<=NF;i++){n=split($i,p,"="); if(n==2 && p[1] ~ /^(lowerdir|datadir|upperdir|workdir)[+]?$/){m=split(p[2],v,":"); for(j=1;j<=m;j++) if(v[j]!="") print v[j]}}}')
paths=$(printf '%s\n%s\n' "$projection_paths" "$loop_files" | sort -u)
resolved_paths=$(printf '%s\n' "$paths" | while IFS= read -r path; do
    [ -n "$path" ] || continue
    count=${count:-0}; count=$((count+1)); [ "$count" -le 512 ]
    if resolved=$(readlink -e -- "$path"); then
        printf '%s\t%s\n' "$path" "$resolved"
    else
        # Unknown is never a successful backing observation, even if stdout
        # looks plausible. Unused unrelated loops need not establish ancestry.
        printf '%s\t-\n' "$path"
    fi
done)
btrfs_members=$(
    filesystems=0
    for fs in /sys/fs/btrfs/*; do
        [ -d "$fs/devinfo" ] || continue
        filesystems=$((filesystems+1)); [ "$filesystems" -le 128 ]
        fsid=${fs##*/}
        infos=0; devices=0; valid=1; majors=""
        for info in "$fs"/devinfo/*; do
            [ -d "$info" ] || continue
            infos=$((infos+1))
            [ "$infos" -le 1024 ]
            missing=$(cat "$info/missing")
            present=$(cat "$info/in_fs_metadata")
            replacing=$(cat "$info/replace_target")
            [ "$missing:$present:$replacing" = 0:1:0 ] || valid=0
        done
        for device in "$fs"/devices/*; do
            [ -e "$device" ] || continue
            major=$(cat "$device/dev")
            devices=$((devices+1))
            [ "$devices" -le 1024 ]
            if [ -n "$majors" ]; then majors="$majors,$major"; else majors="$major"; fi
        done
        [ "$infos" -eq "$devices" ] && [ "$devices" -gt 0 ] || valid=0
        printf '%s\t%s\t%s\n' "$fsid" "$valid" "$majors"
    done
)
blocks64=$(printf '%s' "$blocks" | base64 -w0)
mounts64=$(printf '%s' "$mounts" | base64 -w0)
loops64=$(printf '%s' "$loops" | base64 -w0)
paths64=$(printf '%s' "$resolved_paths" | base64 -w0)
btrfs64=$(printf '%s' "$btrfs_members" | base64 -w0)
if [ "$action" = native ]; then
    cmdline=$(cat /proc/cmdline)
    target=$(cat /etc/wootc/native-target)
    after=$(cat /proc/sys/kernel/random/boot_id)
    [ "$boot_id" = "$after" ]
    printf 'SCHEMA=1\nUNAME=%s\nCMDLINE=%s\nTARGET=%s\nBOOT_ID=%s\nBLOCKS=%s\nMOUNTS=%s\nLOOPS=%s\nPATHS=%s\nBTRFS=%s\n' "$os" "$cmdline" "$target" "$boot_id" "$blocks64" "$mounts64" "$loops64" "$paths64" "$btrfs64"
else
    printf 'SCHEMA=1\nUNAME=%s\nBOOT_ID=%s\nBLOCKS=%s\nMOUNTS=%s\nLOOPS=%s\nPATHS=%s\nBTRFS=%s\n' "$os" "$boot_id" "$blocks64" "$mounts64" "$loops64" "$paths64" "$btrfs64"
    if [ -r /run/wootc-e2e-native-userdata ]; then
        cat /run/wootc-e2e-native-userdata
    else
        f=""
        for candidate in /home/wootc/Documents/wootc-e2e-userdata.txt /var/home/wootc/Documents/wootc-e2e-userdata.txt; do
            if [ -r "$candidate" ]; then f="$candidate"; break; fi
        done
        [ -n "$f" ]
        row=$(findmnt --noheadings --raw --output SOURCE,MAJ:MIN,TARGET --target "$f")
        case "$row" in *\\*) exit 1;; esac
        set -- $row
        [ "$#" -eq 3 ]
        printf 'EXPORT_SCHEMA=1\nEXPORT_BOOT_ID=%s\nSRC=%s\nDATA_MAJ_MIN=%s\nDATA_MOUNT=%s\n' "$boot_id" "$1" "$2" "$3"
        cat "$f"
    fi
    after=$(cat /proc/sys/kernel/random/boot_id)
    [ "$boot_id" = "$after" ]
fi
