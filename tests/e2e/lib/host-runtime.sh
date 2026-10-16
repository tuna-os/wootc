# shellcheck shell=bash
# preflight(storage, reuse, [memory file, KVM path, TUN path]); cache(dir, ISO, storage).
# stop(runtime executable, container, compose file, keep). Source starts no VM.
# Callbacks: info/pass/infra_fail, deadline_in/past_deadline. RAM/disk knobs apply.
host_preflight() {
    local STORAGE_DIR="$1" SKIP_INSTALL="$2"
    local memory_file="${3:-/proc/meminfo}" kvm_path="${4:-/dev/kvm}" tun_path="${5:-/dev/net/tun}"
    # Recalibrated after the pre-deployer snapshot was disabled (1c6d713).
    #
    # 65 GiB was the bare minimum for ONE run, so a run could pass preflight and
    # die mid-deploy, leaving nothing for the next run — runners ratcheted
    # toward full. That was raised to 120, but 120 assumed the snapshot's FULL
    # byte copy of data.qcow2 (reflink is unavailable here, so it doubled an
    # 18-28 GiB file). With the snapshot off, a run's resident footprint is
    # ~45 GiB: data.qcow2 + windows.*.iso (7.4) + custom.iso (7.3) + artifacts.
    #
    # 90 GiB is still roughly two runs' worth on a persistent host, and it fits
    # a GitHub hosted runner, which offers ~114 GiB after its cleanup step and
    # was being rejected by the 120 figure. Override for unusual hosts.
    local mem_available_kib disk_available_kib
    local required_free_gib="${WOOTC_E2E_MIN_FREE_GIB:-90}"
    mem_available_kib=$(awk '/MemAvailable:/ { print $2 }' "$memory_file")
    disk_available_kib=$(df -Pk "$STORAGE_DIR" | awk 'NR == 2 { print $4 }')

    command -v podman >/dev/null || { infra_fail "podman is required"; return 1; }
    command -v python3 >/dev/null || { infra_fail "python3 is required for QGA"; return 1; }
    [ -r "$kvm_path" ] && [ -w "$kvm_path" ] || { infra_fail "/dev/kvm is not accessible"; return 1; }
    [ -c "$tun_path" ] || { infra_fail "/dev/net/tun is unavailable"; return 1; }
    # Memory: a point-in-time MemAvailable sample on a host running sibling
    # instances is transient — a neighbor's build spike or install phase can
    # eat gigabytes for a few minutes. Wait for the dip to pass (10 min)
    # before declaring the host too small. The requirement scales with the
    # configured VM size when dockur's own clamp is disabled (RAM_CHECK=N);
    # otherwise 6 GiB suffices to start a clamp-protected 4 GiB minimum VM.
    local need_mem_mib=6144
    if [ "${WOOTC_E2E_RAM_CHECK:-Y}" = "N" ]; then
        need_mem_mib=$(( $(printf '%s' "${WOOTC_E2E_RAM_SIZE:-8G}" | tr -dc '0-9') * 1024 + 256 ))
    fi
    local mem_deadline; mem_deadline=$(deadline_in 600)
    while [ $(( ${mem_available_kib:-0} / 1024 )) -lt "$need_mem_mib" ]; do
        if past_deadline "$mem_deadline"; then
            infra_fail "Only $((mem_available_kib / 1024)) MiB host RAM available after 10 min; need ${need_mem_mib} MiB before starting Windows"
            return 1
        fi
        info "Waiting for host memory: $((mem_available_kib / 1024)) MiB available, want ${need_mem_mib} MiB..."
        sleep 15
        mem_available_kib=$(awk '/MemAvailable:/ { print $2 }' "$memory_file")
    done
    # These situational adjustments apply only when the caller did NOT set an
    # explicit floor: WOOTC_E2E_MIN_FREE_GIB=45 from the matrix was silently
    # RAISED back to 75 by the iso branch (a leftover windows.*.iso in the
    # instance dir), failing a slot with plenty of room for its case.
    if [ -z "${WOOTC_E2E_MIN_FREE_GIB:-}" ]; then
        # Fresh installation needs room for the installer, pulls, and
        # expanding qcow2. Fresh-run peak drops ~10 GiB when the Windows ISO
        # is already cached (no re-download, custom.iso rebuild reuses the
        # cached extraction).
        if ls "$STORAGE_DIR"/windows.*.iso &>/dev/null; then
            required_free_gib=75
        fi
        # A reuse run already has those and needs only its allocated-extent
        # safety snapshot plus diagnostics.
        [ "$SKIP_INSTALL" = false ] || required_free_gib=55
    fi
    if [ "${disk_available_kib:-0}" -lt $((required_free_gib * 1024 * 1024)) ]; then
        infra_fail "Only $((disk_available_kib / 1024 / 1024)) GiB free under $STORAGE_DIR; need at least $required_free_gib GiB"
        return 1
    fi
    pass "Host preflight: $((mem_available_kib / 1024)) MiB RAM available, $((disk_available_kib / 1024 / 1024)) GiB disk free, KVM/TUN ready"
}

cache_downloaded_iso() {
    local ISO_CACHE_DIR="$1" WINDOWS_ISO_CACHE="$2" STORAGE_DIR="$3"
    [ -n "${ISO_CACHE_DIR:-}" ] || return 0
    [ -f "$WINDOWS_ISO_CACHE" ] && return 0
    local src
    src=$(ls -1 "$STORAGE_DIR"/windows.*.iso 2>/dev/null | head -1 || true)
    [ -n "$src" ] || return 0
    mkdir -p "$ISO_CACHE_DIR" || return 0
    if cp --reflink=auto --sparse=auto "$src" "$WINDOWS_ISO_CACHE.part" 2>/dev/null; then
        mv -f "$WINDOWS_ISO_CACHE.part" "$WINDOWS_ISO_CACHE"
        info "Cached the downloaded Windows ISO for future runs: $WINDOWS_ISO_CACHE"
    else
        rm -f "$WINDOWS_ISO_CACHE.part"
    fi
    return 0
}

host_stop_vm() {
    local runtime="$1" container="$2" compose_file="$3" keep="$4"
    if [ "$keep" = false ]; then
        info "Cleaning up..."
        "$runtime" exec "$container" pkill -9 -f 'process=windows' 2>/dev/null || true
        podman compose -f "$compose_file" down --volumes 2>/dev/null || \
            docker compose -f "$compose_file" down --volumes 2>/dev/null || true
        podman rm -f "$container" 2>/dev/null || true
    else
        info "Container kept (--keep): $container"
    fi
}
