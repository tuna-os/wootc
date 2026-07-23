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
while [ $# -gt 0 ]; do
    case "$1" in
        --tier)  TIER="$2"; shift 2 ;;
        --hosts) HOSTS="$2"; shift 2 ;;
        --grep)  GREP="$2"; shift 2 ;;
        --dry-run) DRY=true; shift ;;
        --timeout) PER_CASE_TIMEOUT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

# ── select cases ─────────────────────────────────────────────────────────────
# smoke ⊆ full: a "full" run includes the smoke cases too.
mapfile -t CASES < <(awk -F'\t' -v tier="$TIER" -v want="$GREP" '
    /^#/ || NF < 6 { next }
    { t=$1 }
    tier=="full"  || t=="smoke" {
        if (want=="" || index($2, want)) print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7
    }' "$MATRIX")

[ ${#CASES[@]} -gt 0 ] || { echo "No cases match tier=$TIER grep=$GREP" >&2; exit 1; }
read -ra HOSTARR <<< "$HOSTS"

echo "Matrix: ${#CASES[@]} case(s), tier=$TIER, hosts: ${HOSTARR[*]}"
printf '%-24s %-34s %-4s %-6s %s\n' NAME IMAGE VER ED HOST
i=0
declare -A ASSIGN
for c in "${CASES[@]}"; do
    IFS=$'\t' read -r name image ver ed key opts <<< "$c"
    host="${HOSTARR[$(( i % ${#HOSTARR[@]} ))]}"
    ASSIGN["$host"]+="$c"$'\n'
    printf '%-24s %-34s %-4s %-6s %s\n' "$name" "$image" "$ver" "$ed" "$host"
    i=$((i+1))
done
$DRY && { echo "(dry run — nothing launched)"; exit 0; }

: > "$RESULTS"
echo -e "name\thost\tresult\tseconds\timage\twin" >> "$RESULTS"

# ── run one case on a host, poll to completion ───────────────────────────────
run_case() {
    local host="$1" name="$2" image="$3" ver="$4" ed="$5" key="$6" opts="${7:-}"
    local log="/tmp/wootc-matrix-$name.log" start now result="TIMEOUT"
    start=$(date +%s)
    ssh -o ConnectTimeout=8 "$host" "bash -s" <<REMOTE >/dev/null 2>&1 || true
set +e
cd ~/wootc/tests/e2e
pkill -9 -f run-e2e.sh 2>/dev/null; sleep 1
podman rm -f wootc-e2e-windows 2>/dev/null
rm -f storage/.run-e2e.lock
export WOOTC_E2E_WIN_VERSION="$ver" WOOTC_E2E_WIN_EDITION="$ed" WOOTC_E2E_WIN_KEY="$key"
# optional per-case knobs, e.g. bitlocker=on (SPEC 3.5 FDE axis),
# phase3=on (rung-3 graduate onto a blank second disk)
case "$opts" in *bitlocker=on*) export WOOTC_E2E_BITLOCKER=on ;; *) export WOOTC_E2E_BITLOCKER=off ;; esac
EXTRA_ARGS=""
case "$opts" in *phase3=on*) EXTRA_ARGS="--phase3" ;; esac
nohup bash run-e2e.sh "$image" --keep \$EXTRA_ARGS > "$log" 2>&1 &
REMOTE
    while :; do
        now=$(date +%s); [ $((now - start)) -gt "$PER_CASE_TIMEOUT" ] && break
        local s
        s=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$host" "
            L=\$(sed -E 's/\x1b\[[0-9;]*m//g' '$log' 2>/dev/null)
            if echo \"\$L\" | grep -qa 'ALL TESTS PASSED'; then echo PASS
            elif echo \"\$L\" | grep -qaE '\[FAIL\]'; then echo \"FAIL:\$(echo \"\$L\"|grep -aE '\[FAIL\]'|tail -1|cut -c1-80)\"
            elif grep -qa 'stage=exited' ~/wootc/tests/e2e/storage/run-e2e.current 2>/dev/null; then echo 'EXIT'
            else echo RUN; fi" 2>/dev/null | head -1)
        case "$s" in
            PASS)  result="PASS"; break ;;
            FAIL*) result="$s"; break ;;
            EXIT)  result="EXITED"; break ;;
        esac
        sleep 60
    done
    now=$(date +%s)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$host" "$result" "$((now-start))" "$image" "$ver-$ed" >> "$RESULTS"
    echo "[$host] $name → $result ($(( (now-start)/60 ))m)"
}

# ── per-host worker: run assigned cases sequentially, in the background ───────
host_worker() {
    local host="$1"
    # Read ALL seven columns. This loop previously read five and passed a
    # stale $opts left over from the planning loop's last iteration — so
    # per-case knobs (bitlocker=on) silently never reached any run.
    local name image ver ed key opts
    while IFS=$'\t' read -r name image ver ed key opts; do
        [ -n "$name" ] || continue
        run_case "$host" "$name" "$image" "$ver" "$ed" "$key" "$opts"
    done <<< "${ASSIGN[$host]}"
}

pids=()
for host in "${HOSTARR[@]}"; do
    [ -n "${ASSIGN[$host]:-}" ] || continue
    host_worker "$host" &
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
