# shellcheck shell=bash
# Phase observations use generated IDs/labels. Freeform failure-ledger.txt stays
# available for existing evidence consumers; this structured ledger adds phase
# identity only when the harness has actually observed a catalogued phase.

wootc_phase_record() {
    local kind="$1" phase_id="$2" message="${3:-}" owner label
    case "$kind" in observed|failed) ;; *) return 1 ;; esac
    owner=$(wootc_step_owner "$phase_id") || return 1
    label=$(wootc_step_label "$phase_id") || return 1
    python3 - "$WOOTC_PHASE_LEDGER" "$RUN_ID" "$kind" "$phase_id" "$owner" "$label" "$message" <<'PY'
import datetime,json,sys
path,run,kind,phase_id,owner,label,message=sys.argv[1:]
with open(path,'a',encoding='utf-8') as stream:
    stream.write(json.dumps({'runId':run,'kind':kind,'phaseId':phase_id,'owner':owner,
        'label':label,'message':message,'observedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()})+'\n')
PY
}

# A new guest/boot cannot inherit an earlier phase or an unfinished marker.
wootc_phase_boundary() {
    WOOTC_CURRENT_PHASE_ID=""
    WOOTC_PHASE_CARRY=""
}

wootc_phase_observe_output() {
    local combined complete marker phase_id
    combined="${WOOTC_PHASE_CARRY:-}$1"
    [ -n "$combined" ] || return 0
    if [[ "$combined" != *$'\n'* ]]; then
        WOOTC_PHASE_CARRY=$combined
        WOOTC_CURRENT_PHASE_ID=""
    else
        complete=${combined%$'\n'*}
        WOOTC_PHASE_CARRY=${combined##*$'\n'}
        while IFS= read -r marker; do
            phase_id=${marker#phase: }
            phase_id=$(printf '%s' "$phase_id" | sed 's/[[:space:]]*$//')
            if [[ "$phase_id" != "${WOOTC_CURRENT_PHASE_ID:-}" ]]; then
                wootc_phase_record observed "$phase_id" "$marker" || return 1
                WOOTC_CURRENT_PHASE_ID=$phase_id
            fi
        done < <(printf '%s\n' "$complete" | grep -oE "$WOOTC_DEPLOYER_PHASE_MARKERS|$WOOTC_FIRSTBOOT_PHASE_MARKERS" || true)
        if [ -n "$WOOTC_PHASE_CARRY" ]; then WOOTC_CURRENT_PHASE_ID=""; fi
    fi
    if [ "${#WOOTC_PHASE_CARRY}" -gt 4096 ]; then
        wootc_phase_boundary
        return 1
    fi
}
