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
#
#   --grep is a REGEX over the case name, so an iteration loop can name the few
#   cells that exercise DISTINCT code paths instead of re-running permutations.
#   The 23-cell matrix collapses to five: an ostree baseline (regression
#   detector), win10, composefs, BitLocker, and the bonito bridge. The other 18
#   are ISO-edition, desktop and phase3 variants of those same paths — running
#   them wide while most cells are red costs 4x the runner time for the same two
#   or three causes. Fan out to --tier full to CONFIRM, not to iterate:
#
#     ./run-matrix.sh --tier full --hosts dilli --grep \
#       'el10-gnome-win11pro$|el10-gnome-win10pro$|dakota-win11pro$|el10-gnome-win11pro-bitlocker$|fedora-gnome-win11pro$'
#   ./run-matrix.sh --tier full --dry-run              # print the plan, run nothing
#
# A runner host is any box with ~/wootc synced and a KVM-capable Podman
# (see justfile remote-sync). Cached ISOs per Windows version (iso-cache/
# windows-<ver>.iso) make matrix reruns fast; the first run of a new version
# downloads it once.
set -euo pipefail

# Re-exec from an IMMUTABLE SNAPSHOT. bash reads a script lazily, by byte
# offset, so editing run-matrix.sh while a sweep is running corrupts THAT sweep
# mid-flight. On 2026-07-27 a phase3 sweep died with "line 310: syntax error
# near unexpected token `and`" purely because the file changed underneath it —
# a result that looked like a test failure and was not.
if [ -z "${WOOTC_MATRIX_SNAPSHOT:-}" ]; then
    WOOTC_MATRIX_HOME="$(cd "$(dirname "$0")" && pwd)"
    _snap="$(mktemp "${TMPDIR:-/tmp}/run-matrix.XXXXXX.sh")"
    cp "$0" "$_snap"
    export WOOTC_MATRIX_SNAPSHOT="$_snap" WOOTC_MATRIX_HOME
    exec bash "$_snap" "$@"
fi

# $0 is the snapshot in TMPDIR, so paths must come from the original location.
HERE="${WOOTC_MATRIX_HOME:-$(cd "$(dirname "$0")" && pwd)}"
MATRIX="$HERE/matrix.tsv"
RESULTS="$HERE/matrix-results.tsv"

# PER_CASE_TIMEOUT must exceed the WORST-CASE sum of run-e2e's own stage
# budgets, or the matrix kills healthy runs and calls it a TIMEOUT. At 4200
# (70 min) it was shorter than the deploy stage ALONE
# (WOOTC_E2E_DEPLOY_TIMEOUT_DEFAULT=5400, 90 min), never mind the 45-minute
# Windows install, OEM setup and Phase 2 ahead of it: bluefin-dakota-win11pro
# was declared TIMEOUT at 70m while fisherman was demonstrably working (135%
# guest CPU, 19 GB written, "Deploying... 23m of 90m").
# 45 (install) + 90 (deploy) + ~45 (OEM, Phase 2, verification) ≈ 180 min.
TIER="smoke"; HOSTS="himachal"; GREP=""; DRY=false; PER_CASE_TIMEOUT=11400
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
        if (want=="" || $2 ~ want) print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7
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
# phase3 cases carry a 40 GiB spare disk that dockur formats at start, on top
# of a full Windows install. Two of those on one host is not a throughput win:
# himachal (18 cores, 15 GiB) hit LOAD AVERAGE 100 running two, stopped
# answering ssh, and both runs died at 14 minutes having reached only
# "Waiting for QGA". The hosted matrix skips phase3 for the same disk reasons.
# One VM per host whenever the queue contains any.
PHASE3_IN_QUEUE=false
for c in "${CASES[@]}"; do
    case "$c" in *phase3=on*) PHASE3_IN_QUEUE=true; break ;; esac
done

# Per-host HARD ceiling on concurrent VMs. This is not a hint: it overrides
# size_host's arithmetic AND an explicit --jobs, because the cost of getting it
# wrong is not a slow run, it is a dead machine.
#
# himachal = 1. Two VMs took it to load average 100, then it stopped answering
# ssh entirely and needed a power cycle (2026-07-27). 18 cores made it look like
# it could take two; 15 GiB of RAM and one disk say otherwise.
host_max_jobs() {
    case "$1" in
        himachal) echo 1 ;;
        *)        echo 99 ;;
    esac
}

for host in "${HOSTARR[@]}"; do
    read -r n vm_ram < <(size_host "$host")
    [ "$JOBS" != auto ] && n="$JOBS"
    if [ "$PHASE3_IN_QUEUE" = true ] && [ "$n" -gt 1 ]; then
        echo "runner $host: capping to 1 concurrent VM (phase3 cases are disk-heavy)"
        n=1
    fi
    host_cap=$(host_max_jobs "$host")
    if [ "$n" -gt "$host_cap" ]; then
        echo "runner $host: hard ceiling of $host_cap concurrent VM(s) for this host"
        n="$host_cap"
    fi
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
    # The launch must be VERIFIED, not fired-and-forgotten: a failed launch
    # ssh (loaded host, transient timeout) used to be swallowed by "|| true",
    # leaving the PREVIOUS case's log in place — the poll then instantly
    # "found" the old [FAIL] and the whole queue burned at one verdict per
    # second (run 20260723T1912). The remote script deletes the log first
    # (poll treats a missing log as still-starting) and echoes a nonce that
    # proves the case actually launched; three attempts before giving up.
    local remote_script launched=false attempt
    local unit="wootc-e2e-${inst}"
    remote_script=$(cat <<REMOTE
set +e
cd ~/wootc/tests/e2e
# ARCHIVE, do not delete. The poll treats a missing log as still-starting, so
# the file must go — but deleting it destroyed the previous run's only readable
# record. That happened twice on 2026-07-27: a dakota failure's log was gone
# before its cause had been read, and the relaunch's pkill also pre-empted the
# old run's artifact collection. One generation of history costs nothing.
mv -f "$log" "$log.prev" 2>/dev/null || rm -f "$log"
# Stop any previous run for this slot. Kill legacy nohup processes
# (backward-compatible) and stop the systemd user unit.
pkill -9 -f "run-e2e.sh.*--instance=$inst" 2>/dev/null
systemctl --user stop "$unit" 2>/dev/null
systemctl --user reset-failed "$unit" 2>/dev/null
sleep 1
podman rm -f "$ctr" 2>/dev/null
# dockur's PID-1 supervisor can leave qemu orphaned past podman rm -f; an
# unwatched 6G VM writing to disk melted the host (load 95, sshd starved,
# 2026-07-23 ~18:50). Sweep only when no wootc container exists at all.
for qpid in \$(pgrep -f "qemu-system.*process=windows" 2>/dev/null); do
    podman ps --format "{{.Names}}" 2>/dev/null | grep -q "^wootc-e2e-windows" || sudo kill -9 "\$qpid" 2>/dev/null
done
rm -f "$stordir/.run-e2e.lock"
# The poll concludes on stage=exited, so the PREVIOUS case's state file must
# go with the previous case's log — otherwise the new case is declared
# finished the moment polling starts. A missing file reads as still-starting;
# run-e2e.sh rewrites it with stage=started within seconds of launching.
rm -f "$stordir/run-e2e.current"
# Resolve the user's runtime identity ON THE REMOTE. Rootless podman needs
# XDG_RUNTIME_DIR and HOME set explicitly, or it resolves root storage paths
# and fails with "permission denied" on /run/containers/storage.
# The matrix is precisely the long-running multi-host path where this
# matters most: a lost SSH session kills a nohup child, but a systemd user
# unit survives (AGENTS.md:202-218, docs/agent-lessons.md:126-131).
_uid=\$(id -u)
_home="\$HOME"
systemd-run --user --unit="$unit" --collect \
    --setenv=XDG_RUNTIME_DIR=/run/user/"\$_uid" \
    --setenv=HOME="\$_home" \
    --setenv=WOOTC_E2E_WIN_VERSION="$ver" \
    --setenv=WOOTC_E2E_WIN_EDITION="$ed" \
    --setenv=WOOTC_E2E_WIN_KEY="$key" \
    --setenv=WOOTC_E2E_RAM_SIZE="${vm_ram}G" \
    --setenv=WOOTC_E2E_RAM_CHECK=N \
    --setenv=WOOTC_E2E_MIN_FREE_GIB="\${WOOTC_E2E_MIN_FREE_GIB:-45}" \
    \$(case "$opts" in *bitlocker=on*) echo '--setenv=WOOTC_E2E_BITLOCKER=on' ;; *) echo '--setenv=WOOTC_E2E_BITLOCKER=off' ;; esac) \
    \$(case "$opts" in *fault=*) echo "--setenv=WOOTC_E2E_FAULT_INJECT=\$(echo "$opts" | grep -o 'fault=[^,]*' | cut -d= -f2)" ;; esac) \
    -p StandardOutput=append:"$log" \
    -p StandardError=append:"$log" \
    -p WorkingDirectory="\$_home/wootc/tests/e2e" \
    -- bash run-e2e.sh "$image" --keep --instance=$inst \$(case "$opts" in *phase3=on*) echo '--phase3' ;; esac) \$(case "$opts" in *fault=*) echo "--fault-inject=\$(echo "$opts" | grep -o 'fault=[^,]*' | cut -d= -f2)" ;; esac)
# Verify the unit is actually running: a nonce alone is insufficient —
# nohup proves only that the shell started, not that the durable unit
# remains alive (AGENTS.md rule). The unit must be active.
if systemctl --user is-active "$unit" >/dev/null 2>&1; then
    echo "LAUNCHED-$name"
else
    echo "UNIT-DEAD-$name"
    systemctl --user status "$unit" 2>&1 || true
fi
REMOTE
)
    # Do not pile onto a host that is already struggling. himachal reached LOAD
    # AVERAGE 100 and then froze hard enough to need a power cycle (2026-07-27),
    # which cost the phase3 axis an entire cycle. A busy host is a reason to
    # WAIT, not a reason to add another Windows VM to it.
    local load_wait=0 load1 ncpu
    while [ "$load_wait" -lt "${WOOTC_MATRIX_LOAD_WAIT_S:-1800}" ]; do
        read -r load1 ncpu < <(ssh -n -o ConnectTimeout=10 -o BatchMode=yes "$host" \
            'printf "%s %s" "$(cut -d" " -f1 /proc/loadavg)" "$(nproc)"' 2>/dev/null) || break
        [ -n "${load1:-}" ] && [ -n "${ncpu:-}" ] || break
        # Saturated = 1-minute load at or above the core count.
        awk -v l="$load1" -v c="$ncpu" 'BEGIN{exit !(l < c)}' 2>/dev/null && break
        echo "[$host/$inst] load ${load1} on ${ncpu} cores — waiting before launching $name"
        sleep 120
        load_wait=$((load_wait + 120))
    done

    for attempt in 1 2 3; do
        if ssh -o ConnectTimeout=15 "$host" "bash -s" <<< "$remote_script" 2>/dev/null | grep -q "LAUNCHED-$name"; then
            launched=true; break
        fi
        echo "[$host/$inst] launch attempt $attempt failed for $name — retrying"
        sleep 30
    done
    if [ "$launched" = false ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$host/$inst" "LAUNCH-FAILED" "0" "$image" "$ver-$ed" >> "$RESULTS"
        echo "[$host/$inst] $name → LAUNCH-FAILED"
        return 0
    fi
    while :; do
        now=$(date +%s); [ $((now - start)) -gt "$PER_CASE_TIMEOUT" ] && break
        local s
        # -n: this ssh runs inside slot_worker's while-read loop; without it,
        # ssh slurps the loop's stdin — WHICH IS THE CASE QUEUE — and the
        # worker exits after one case (run 20260723T0953: 1 of 26 ran).
        # Conclude only on a TERMINAL state. Not every '[FAIL]' line ends the
        # run: seed_user_data and friends are called as `... || true`, so a
        # cosmetic failure used to end the poll ~35 minutes early and record
        # that line as the case's verdict while the run was still deploying
        # (bluefin-dakota-win11pro, 20260726T224500Z, "reported" at 2446s).
        # run-e2e.sh stamps stage=exited from an EXIT trap, so a real ending is
        # always observable; the last [FAIL] then supplies the reason.
        s=$(ssh -n -o ConnectTimeout=8 -o BatchMode=yes "$host" "
            L=\$(sed -E 's/\x1b\[[0-9;]*m//g' '$log' 2>/dev/null)
            if echo \"\$L\" | grep -qa 'ALL TESTS PASSED'; then echo PASS
            elif grep -qa 'stage=exited' ~/wootc/tests/e2e/$stordir/run-e2e.current 2>/dev/null; then
                if echo \"\$L\" | grep -qaE '\[FAIL\]'; then echo \"FAIL:\$(echo \"\$L\"|grep -aE '\[FAIL\]'|tail -1|cut -c1-80)\"
                else echo 'EXIT'; fi
            # A dead systemd unit with no stage=exited is an abnormal death
            # (OOM, sigkill, host reboot). Record the unit's exit cause.
            elif systemctl --user is-active '$unit' >/dev/null 2>&1; then echo RUN
            else
                _cause=\$(systemctl --user show '$unit' -p Result -p ExecMainStatus 2>/dev/null || echo 'unknown')
                echo \"DEAD:\$_cause\"
            fi" 2>/dev/null | head -1)
        case "$s" in
            PASS)  result="PASS"; break ;;
            FAIL*) result="$s"; break ;;
            EXIT)  result="EXITED"; break ;;
            DEAD*) result="$s"; break ;;
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
# Workers must not OUTLIVE this script. Killing the matrix parent used to leave
# its slot_worker subshells polling and appending to the shared results file:
# after one such orphan, bluefin-dakota-win11pro was recorded TIMEOUT twice a
# second apart (once by the orphan, once by the new run) and the summary read
# "0 / 2" for a one-case matrix. The stray workers also show up in `ps` as
# extra `run-matrix.sh` entries, which reads exactly like a respawn loop.
cleanup_workers() {
    local p
    for p in "${pids[@]:-}"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    # Same trap: a second `trap ... EXIT` would REPLACE this one, not add to it.
    [ -n "${WOOTC_MATRIX_SNAPSHOT:-}" ] && rm -f "$WOOTC_MATRIX_SNAPSHOT" || true
}
trap 'cleanup_workers' EXIT INT TERM

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
