#!/bin/bash
# Sourceable deployer lifecycle writer for the /mnt/ntfs host mount.
# Uses the descriptor-preserving wootc-ntfs-state-write executable; never
# publishes state when the host volume is absent. Callers own mount lifetime.

write_ntfs_state() {
    local state="$1" phase="${2:-}" err_msg="${3:-}"
    mountpoint -q /mnt/ntfs 2>/dev/null || return 0
    mkdir -p /mnt/ntfs/wootc /mnt/ntfs/wootc/install 2>/dev/null || true
    local now
    now=$(date -u +%FT%TZ 2>/dev/null || date)
    local final="/mnt/ntfs/wootc/state.json"
    if [ -n "$phase" ] || [ -n "$err_msg" ]; then
        wootc-ntfs-state-write /mnt/ntfs/wootc/state.json "$final" <<EOF
{
  "state": "$state",
  "phase": "$phase",
  "error": "$err_msg",
  "updatedAt": "$now",
  "updatedBy": "wootc-deployer"
}
EOF
    else
        wootc-ntfs-state-write /mnt/ntfs/wootc/state.json "$final" <<EOF
{
  "state": "$state",
  "updatedAt": "$now",
  "updatedBy": "wootc-deployer"
}
EOF
    fi
}

write_deployer_started() {
    local image="$1"
    mountpoint -q /mnt/ntfs 2>/dev/null || return 0
    mkdir -p /mnt/ntfs/wootc/install 2>/dev/null || true
    local now
    now=$(date -u +%FT%TZ 2>/dev/null || date)
    local final="/mnt/ntfs/wootc/install/deployer-started.json"
    wootc-ntfs-state-write /mnt/ntfs/wootc/state.json "$final" <<EOF
{
  "startedAt": "$now",
  "image": "$image",
  "version": "0.1.0"
}
EOF
}
