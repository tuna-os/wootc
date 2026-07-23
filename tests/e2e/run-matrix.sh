#!/usr/bin/env bash
# run-matrix.sh — run the wootc E2E matrix (matrix.tsv) across runner hosts.
#
# Each case is one Windows edition × bootc image, executed by run-e2e.sh on a
# runner host over ssh. Cases are round-robined across --hosts so hosts run in
# parallel; each host works its cases sequentially. Results (pass/fail/duration)
# are collected into matrix-results.tsv and summarized at the end.
#
# Usage:
#   ./run-matrix.sh --tier smoke                       # himachal, smoke tier
#   ./run-matrix.sh --tier full --hosts "kanpur dilli himachal"
#   ./run-matrix.sh --grep fedora --hosts dilli        # only cases matching name
#   ./run-matrix.sh --tier full --dry-run              # print the plan, run nothing
#
# A runner host is any box with ~/wootc synced and a KVM-capable Podman
# (see justfile remote-sync). Cached ISOs per Windows version (iso-cache/
# windows-<ver>.iso) make matrix reruns fast; the first run of a new version
# downloads it once.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MATRIX="$HERE/matrix.tsv"
RESULTS="$HERE/matrix-results.tsv"

TIER="smoke"; HOSTS="himachal"; GREP=""; DRY=false; PER_CASE_TIMEOUT=4200
JOBS="auto"
while [ $# -gt 0 ]; do
    case "$1" in
        --tier)  TIER="$2"; shift 2 ;;
        --hosts) HOSTS="$2"; shift 2 ;;
        --grep)  GREP="$2"; shift 2 ;;
        --dry-run) DRY=true; shift ;;
        --timeout) PER_CASE_TIMEOUT="$2"; shift 2 ;;
        --jobs)  JOBS="$2"; shift 2 ;;   # VMs per host: N, or "auto" to size from the runner
        --vm-ram) VM_RAM_OVERRIDE="$2"; shift 2 ;;  # GiB per VM, overrides sizing (e.g. leave room for another run)
        --resume) RESUME=true; shift ;;  # skip cases already PASS in matrix-results.tsv
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
RESUME="${RESUME:-false}"
VM_RAM_OVERRIDE="${VM_RAM_OVERRIDE:-}"

# ── size each runner: how many VMs fit? ──────────────────────────────────────
# Budget per concurrent VM: ~6 GiB RAM (dockur clamps QEMU below the host's
# available; Windows 11 setup needs ≥4 GiB after the clamp, so 6 leaves real
# margin), ~5 threads (4 vCPUs + host overhead), ~35 GiB disk (fresh
# data.qcow2 growth + per-instance custom.iso + artifacts). 3 GiB RAM and
# 15 GiB disk stay reserved for the host itself. VM RAM scales down from the
# preferred 8 GiB when slots share a small host — never below 5.
size_host() {  # size_host <host> → echoes "<jobs> <vm_ram_gib>"
    local host="$1" mem cpu disk jobs vm_ram
    read -r mem cpu disk < <(ssh -o ConnectTimeout=8 "$host" \
        'mem=$(awk "/MemTotal/{print int(\$2/1048576)}" /proc/meminfo); \
         cpu=$(nproc); \
         disk=$(df -BG --output=avail ~/wootc/tests/e2e 2>/dev/null | tail -1 | tr -dc "0-9"); \
         echo "$mem $cpu ${disk:-0}"') || { echo "1 8"; return; }
    jobs=$(( (mem - 3) / 6 ))
    [ $(( cpu / 5 )) -lt "$jobs" ] && jobs=$(( cpu / 5 ))
    [ $(( (disk - 15) / 35 )) -lt "$jobs" ] && jobs=$(( (disk - 15) / 35 ))
    [ "$jobs" -lt 1 ] && jobs=1
    [ "$jobs" -gt "${WOOTC_MATRIX_MAX_JOBS:-3}" ] && jobs="${WOOTC_MATRIX_MAX_JOBS:-3}"
    vm_ram=$(( (mem - 3) / jobs ))
    [ "$vm_ram" -gt 8 ] && vm_ram=8
    [ "$vm_ram" -lt 5 ] && { jobs=1; vm_ram=$(( mem - 3 > 8 ? 8 : mem - 3 )); }
    echo "$jobs $vm_ram"
}

# ── select cases ─────────────────────────────────────────────────────────────
# smoke ⊆ full: a "full" run includes the smoke cases too.
mapfile -t CASES < <(awk -F'\t' -v tier="$TIER" -v want="$GREP" '
    /^#/ || NF < 6 { next }
    { t=$1 }
    tier=="full"  || t=="smoke" {
        if (want=="" || index($2, want)) print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7
    }' "$MATRIX")

[ ${#CASES[@]} -gt 0 ] || { echo "No cases match tier=$TIER grep=$GREP" >&2; exit 1; }

# --resume: drop cases already recorded PASS, keep the results file intact.
if [ "$RESUME" = true ] && [ -f "$RESULTS" ]; then
    KEPT=()
    for c in "${CASES[@]}"; do
        n="${c%%$'\t'*}"
        if awk -F'\t' -v n="$n" '$1==n && $3=="PASS"{found=1} END{exit !found}' "$RESULTS"; then
            echo "resume: skipping $n (already PASS)"
        else
            KEPT+=("$c")
        fi
    done
    CASES=("${KEPT[@]}")
    [ ${#CASES[@]} -gt 0 ] || { echo "Nothing left to run — all matching cases already PASS."; exit 0; }
fi
read -ra HOSTARR <<< "$HOSTS"

# One slot = one concurrent VM on a host (instance a, b, …). Each slot gets a
# disjoint --instance in run-e2e.sh: own container name, own storage dir.
LETTERS=(a b c d)
SLOTS=()   # "host<TAB>instance<TAB>vm_ram_gib"
for host in "${HOSTARR[@]}"; do
    read -r n vm_ram < <(size_host "$host")
    [ "$JOBS" != auto ] && n="$JOBS"
    [ -n "$VM_RAM_OVERRIDE" ] && vm_ram="$VM_RAM_OVERRIDE"
    echo "runner $host: $n concurrent VM(s) × ${vm_ram}G RAM"
    for (( s=0; s<n; s++ )); do
        SLOTS+=("$host"$'\t'"${LETTERS[$s]}"$'\t'"$vm_ram")
    done
done

echo "Matrix: ${#CASES[@]} case(s), tier=$TIER, ${#SLOTS[@]} slot(s) on: ${HOSTARR[*]}"
printf '%-24s %-34s %-4s %-6s %s\n' NAME IMAGE VER ED SLOT
i=0
declare -A ASSIGN
for c in "${CASES[@]}"; do
    IFS=$'\t' read -r name image ver ed key opts <<< "$c"
    slot="${SLOTS[$(( i % ${#SLOTS[@]} ))]}"
    IFS=$'\t' read -r shost sinst _ <<< "$slot"
    ASSIGN["$slot"]+="$c"$'\n'
    printf '%-24s %-34s %-4s %-6s %s\n' "$name" "$image" "$ver" "$ed" "$shost/$sinst"
    i=$((i+1))
done
$DRY && { echo "(dry run — nothing launched)"; exit 0; }

if [ "$RESUME" != true ] || [ ! -f "$RESULTS" ]; then
    : > "$RESULTS"
    echo -e "name\thost\tresult\tseconds\timage\twin" >> "$RESULTS"
fi

# ── run one case in a slot, poll to completion ───────────────────────────────
run_case() {
    local host="$1" inst="$2" vm_ram="$3" name="$4" image="$5" ver="$6" ed="$7" key="$8" opts="${9:-}"
    local log="/tmp/wootc-matrix-$name.log" start now result="TIMEOUT"
    local ctr="wootc-e2e-windows-$inst" stordir="storage-$inst"
    start=$(date +%s)
    # Cleanup is strictly slot-scoped: the pkill matches this slot's
    # --instance= flag in the cmdline, never a sibling slot's run.
    ssh -o ConnectTimeout=8 "$host" "bash -s" <<REMOTE >/dev/null 2>&1 || true
set +e
cd ~/wootc/tests/e2e
pkill -9 -f "run-e2e.sh.*--instance=$inst" 2>/dev/null; sleep 1
podman rm -f "$ctr" 2>/dev/null
# dockur's PID-1 supervisor can leave qemu orphaned past podman rm -f; an
# unwatched 6G VM writing to disk melted the host (load 95, sshd starved,
# 2026-07-23 ~18:50). Sweep any qemu whose -pidfile lives in this slot's
# container storage before starting the next case.
for qpid in $(pgrep -f "qemu-system.*process=windows" 2>/dev/null); do
    tr "\0" " " < "/proc/$qpid/cmdline" 2>/dev/null | grep -q "process=windows" && \
        ! podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^wootc-e2e-windows" && \
        sudo kill -9 "$qpid" 2>/dev/null
done
rm -f "$stordir/.run-e2e.lock"
export WOOTC_E2E_WIN_VERSION="$ver" WOOTC_E2E_WIN_EDITION="$ed" WOOTC_E2E_WIN_KEY="$key"
export WOOTC_E2E_RAM_SIZE="${vm_ram}G"
# Concurrent slots share the disk; the single-run 90 GiB preflight would
# refuse a healthy second slot. ~35 GiB/case is the measured fresh-run need.
export WOOTC_E2E_MIN_FREE_GIB="\${WOOTC_E2E_MIN_FREE_GIB:-45}"
# optional per-case knobs, e.g. bitlocker=on (SPEC 3.5 FDE axis),
# phase3=on (rung-3 graduate onto a blank second disk)
case "$opts" in *bitlocker=on*) export WOOTC_E2E_BITLOCKER=on ;; *) export WOOTC_E2E_BITLOCKER=off ;; esac
EXTRA_ARGS=""
case "$opts" in *phase3=on*) EXTRA_ARGS="--phase3" ;; esac
nohup bash run-e2e.sh "$image" --keep --instance=$inst \$EXTRA_ARGS > "$log" 2>&1 &
REMOTE
    while :; do
        now=$(date +%s); [ $((now - start)) -gt "$PER_CASE_TIMEOUT" ] && break
        local s
        # -n: this ssh runs inside slot_worker's while-read loop; without it,
        # ssh slurps the loop's stdin — WHICH IS THE CASE QUEUE — and the
        # worker exits after one case (run 20260723T0953: 1 of 26 ran).
        s=$(ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$host" "
            L=\$(sed -E 's/\x1b\[[0-9;]*m//g' '$log' 2>/dev/null)
            if echo \"\$L\" | grep -qa 'ALL TESTS PASSED'; then echo PASS
            elif echo \"\$L\" | grep -qaE '\[FAIL\]'; then echo \"FAIL:\$(echo \"\$L\"|grep -aE '\[FAIL\]'|tail -1|cut -c1-80)\"
            elif grep -qa 'stage=exited' ~/wootc/tests/e2e/$stordir/run-e2e.current 2>/dev/null; then echo 'EXIT'
            else echo RUN; fi" 2>/dev/null | head -1)
        case "$s" in
            PASS)  result="PASS"; break ;;
            FAIL*) result="$s"; break ;;
            EXIT)  result="EXITED"; break ;;
        esac
        sleep 60
    done
    now=$(date +%s)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$host/$inst" "$result" "$((now-start))" "$image" "$ver-$ed" >> "$RESULTS"
    echo "[$host/$inst] $name → $result ($(( (now-start)/60 ))m)"
}

# ── per-slot worker: run assigned cases sequentially, in the background ───────
slot_worker() {
    local host="$1" inst="$2" vm_ram="$3" queue="$4"
    # Read ALL seven columns. This loop previously read five and passed a
    # stale $opts left over from the planning loop's last iteration — so
    # per-case knobs (bitlocker=on) silently never reached any run.
    local name image ver ed key opts
    while IFS=$'\t' read -r name image ver ed key opts; do
        [ -n "$name" ] || continue
        # set -e must never kill the worker mid-queue: a failing case is a
        # RESULT, not a reason to abandon the remaining cases (a silent
        # worker death after case 3 ended run 20260723T1144's whole queue).
        run_case "$host" "$inst" "$vm_ram" "$name" "$image" "$ver" "$ed" "$key" "$opts" \
            || echo "[worker $host/$inst] run_case rc=$? for $name — continuing"
    done <<< "$queue"
    echo "[worker $host/$inst] queue complete"
}

pids=()
for slot in "${SLOTS[@]}"; do
    [ -n "${ASSIGN[$slot]:-}" ] || continue
    IFS=$'\t' read -r shost sinst sram <<< "$slot"
    slot_worker "$shost" "$sinst" "$sram" "${ASSIGN[$slot]}" &
    pids+=($!)
done
wait "${pids[@]}" 2>/dev/null || true

# ── summary ──────────────────────────────────────────────────────────────────
echo; echo "════════ matrix results ════════"
column -t -s $'\t' "$RESULTS"
passed=$(grep -c $'\tPASS\t' "$RESULTS" || true)
total=$(( $(wc -l < "$RESULTS") - 1 ))
echo "─────────────────────────────────"
echo "PASS: $passed / $total"
[ "$passed" -eq "$total" ]
