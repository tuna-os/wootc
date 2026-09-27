#!/usr/bin/env bash
# Source-only host VM start adapter. No operation occurs until called.
# Callbacks: warn, infra_fail, step, pass. All runtime mutations target the configured
# container; compose argv and files are supplied by the scenario.
wootc_vm_configure() {
    [ "$#" -ge 5 ] && [ -n "$1" ] && [ -n "$2" ] && [ -n "$3" ] && [ -n "$4" ] && [ -n "$5" ] || return 2
    WOOTC_VM_RUNTIME="$1"; WOOTC_VM_CONTAINER="$2"
    WOOTC_VM_SCRIPT_DIR="$3"; WOOTC_VM_COMPOSE_FILE="$4"
    shift 4
    WOOTC_VM_COMPOSE=("$@")
}
wootc_vm_call() {
    timeout 15 "${WOOTC_VM_RUNTIME:?Configure VM first}" "$@"
}
wootc_vm_remove_owned() {
    local rc=0
    wootc_vm_call container exists "$WOOTC_VM_CONTAINER" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0) wootc_vm_call rm -f "$WOOTC_VM_CONTAINER" ;;
        1) return 0 ;;
        *) infra_fail "Infrastructure: could not determine owned container state ($rc)"; return "$rc" ;;
    esac
}
wootc_vm_compose_up() {
    timeout 180 "${WOOTC_VM_COMPOSE[@]}" -f "${WOOTC_VM_COMPOSE_FILE:?Configure VM first}" up -d windows || return $?
    wootc_vm_call container exists "$WOOTC_VM_CONTAINER" >/dev/null 2>&1 || {
        infra_fail "Infrastructure: compose reported success but the configured container does not exist"
        return 1
    }
}
port_free() {
    local rc=0
    case "$1" in ''|0*|*[!0-9]*) return 2;; esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || return 2
    timeout 2 python3 - "$1" <<'PYPORT' >/dev/null 2>&1 || rc=$?
import errno
import socket
import sys
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
    try:
        # Compose publishes on every IPv4 interface. No SO_REUSEADDR:
        # a merely bound socket is ownership, even without listen().
        probe.bind(('0.0.0.0', int(sys.argv[1])))
    except OSError as error:
        sys.exit(1 if error.errno == errno.EADDRINUSE else 2)
PYPORT
    case "$rc" in
        0|1) return "$rc" ;;
        *) return 2 ;; # timeout or unknown bind error is not availability
    esac
}
pick_free_ports() {
    local var base p reserved=":"
    for pair in "WOOTC_E2E_NOVNC_PORT:8006" "WOOTC_E2E_RDP_PORT:3389" \
                "WOOTC_E2E_VNC_PORT:5900" "WOOTC_E2E_SSH_PORT:2222" \
                "WOOTC_E2E_CDP_PORT:9222"; do
        var="${pair%%:*}"; base="${pair##*:}"
        p="${!var:-$base}"
        case "$p" in ''|0*|*[!0-9]*) infra_fail "Infrastructure: invalid noncanonical host port for $var"; return 2;; esac
        if ! [ "$p" -ge 1 ] || ! [ "$p" -le 65535 ]; then
            infra_fail "Infrastructure: invalid host port range for $var"; return 2
        fi
        if ! port_free "$p" || [[ "$reserved" == *":$p:"* ]]; then
            local alt found=false
            for alt in $(seq $((base + 10000)) $((base + 10050))); do
                port_free "$alt" && [[ "$reserved" != *":$alt:"* ]] && { p="$alt"; found=true; break; }
            done
            if [ "$found" != true ]; then infra_fail "Infrastructure: no free host port for $var"; return 1; fi
            warn "host port $base is in use — mapping $var=$p instead"
        fi
        reserved="$reserved$p:"
        export "$var=$p"
    done
}

# Rebuild the baked-in-sshd image if it went missing (e.g. `podman system
# prune` reclaimed it). Compose then fails trying to pull it from localhost.
rebuild_ssh_image_if_missing() {
    local img="${WOOTC_E2E_IMAGE:-localhost/wootc-e2e-windows-ssh:latest}"
    [[ "$img" == localhost/wootc-e2e-windows-ssh:latest ]] || return 1
    [[ -x "$WOOTC_VM_SCRIPT_DIR/build-ssh-image.sh" ]] || return 1
    warn "e2e ssh image missing — rebuilding via build-ssh-image.sh"
    timeout 1800 bash "$WOOTC_VM_SCRIPT_DIR/build-ssh-image.sh"
}

# Build the e2e ssh image BEFORE compose needs it.
#
# compose.yml references localhost/wootc-e2e-windows-ssh:latest, which only ever
# exists because build-ssh-image.sh made it locally. On any host that has never
# built it — a fresh GitHub hosted runner, or a laptop after `podman system
# prune -af` — compose interprets "localhost/..." as a REGISTRY and tries to
# pull over HTTPS from localhost:443. Recovering after that failure works, but
# recovering from a failure we can trivially prevent is the wrong order.
ensure_ssh_image() {
    local img="${WOOTC_E2E_IMAGE:-localhost/wootc-e2e-windows-ssh:latest}"
    [[ "$img" == localhost/wootc-e2e-windows-ssh:latest ]] || return 0
    local rc=0
    wootc_vm_call image exists "$img" 2>/dev/null || rc=$?
    [ "$rc" -ne 0 ] || return 0
    if [ "$rc" -ne 1 ]; then
        infra_fail "Infrastructure: image inspection failed ($rc); no build or start attempted"
        return "$rc"
    fi
    [[ -x "$WOOTC_VM_SCRIPT_DIR/build-ssh-image.sh" ]] || {
        infra_fail "e2e ssh image $img is missing and build-ssh-image.sh is not executable"
        return 1
    }
    step "Building the e2e ssh image (absent on this host)..."
    timeout 1800 bash "$WOOTC_VM_SCRIPT_DIR/build-ssh-image.sh" || { infra_fail "build-ssh-image.sh failed"; return 1; }
    wootc_vm_call image exists "$img" 2>/dev/null || { infra_fail "build completed but $img still absent"; return 1; }
    pass "e2e ssh image built"
}

compose_up_windows() {
    ensure_ssh_image || return 1
    pick_free_ports || return 1
    wootc_vm_remove_owned || return $?
    local out rc=0
    if out=$(wootc_vm_compose_up 2>&1); then
        printf '%s\n' "$out"
        return 0
    else
        rc=$?
    fi
    printf '%s\n' "$out" >&2
    # A timeout has ambiguous side effects; never replay the start.
    [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] || return "$rc"
    # A failed start does not authorize changing other host networks.
    if printf '%s' "$out" | grep -q "already exists but is a Tun interface"; then
        infra_fail "Infrastructure: conflicting host network state; inspect the configured container network and repair it before a new run. No global network state was changed."
        return 1
    fi
    # (2) the e2e ssh image was pruned — rebuild it, then retry.
    if printf '%s' "$out" | grep -qiE "pinging container registry localhost|no such image|manifest unknown"; then
        rebuild_ssh_image_if_missing && { wootc_vm_compose_up; return $?; }
    fi
    # (3) a port clashed after our pre-check (race) — re-pick and retry once.
    if printf '%s' "$out" | grep -qi "address already in use"; then
        warn "host port clash — re-selecting free ports and retrying"
        wootc_vm_remove_owned || return $?
        pick_free_ports || return 1
        wootc_vm_compose_up
        return $?
    fi
    return 1
}
wootc_vm_positive_budget() {
    case "$1" in ''|*[!0-9]*) return 2;; esac
    [ "$1" -gt 0 ] || return 2
}
qemu_argv_sample() {
    local sample budget="${1-15}"
    wootc_vm_positive_budget "$budget" || return 2
    sample=$(timeout "$budget" "${WOOTC_VM_RUNTIME:?Configure VM first}" exec "$WOOTC_VM_CONTAINER" ps -ef 2>/dev/null) || return 1
    printf '%s\n' "$sample" | grep '[q]emu-system'
}
wootc_vm_wait_argv() {
    local budget="$1" mode="$2" sample="${3:-}" deadline remaining pause
    wootc_vm_positive_budget "$budget" || return 2
    case "$mode" in started|accelerated) :;; *) return 2;; esac
    deadline=$(( $(date +%s) + budget ))
    while :; do
        if [ "$mode" = started ] && [ -n "$sample" ]; then printf '%s\n' "$sample"; return 0; fi
        if [ "$mode" = accelerated ] && [[ ( "$sample" == *"-accel=kvm"* || "$sample" == *"accel=kvm"* ) && "$sample" == *"-enable-kvm"* ]]; then
            printf '%s\n' "$sample"; return 0
        fi
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || return 1
        [ "$remaining" -le 15 ] || remaining=15
        sample=$(qemu_argv_sample "$remaining") || sample=""
        # A failed/empty current sample clears old evidence.
        if [ -n "$sample" ]; then
            if [ "$mode" = started ]; then continue; fi
            if [[ ( "$sample" == *"-accel=kvm"* || "$sample" == *"accel=kvm"* ) && "$sample" == *"-enable-kvm"* ]]; then continue; fi
        fi
        remaining=$((deadline - $(date +%s)))
        [ "$remaining" -gt 0 ] || return 1
        pause=2
        [ "$remaining" -ge "$pause" ] || pause="$remaining"
        sleep "$pause"
    done
}
