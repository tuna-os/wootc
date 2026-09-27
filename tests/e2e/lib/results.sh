# shellcheck shell=bash
# No host/VM action. Arguments supply paths and identity; tests call this API.
WOOTC_RESULT_BACKEND="${WOOTC_RESULT_BACKEND:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/results.py}"
wootc_result_init() { python3 "$WOOTC_RESULT_BACKEND" init "$1" "$2" --scenario "$3" --required "${4:-}"; }
wootc_result_record() { python3 "$WOOTC_RESULT_BACKEND" record "$1" "$2" --kind "$3" --domain "$4" --assertion "$5" --phase "$6" --message "$7"; }
wootc_result_finish() { python3 "$WOOTC_RESULT_BACKEND" finish "$1" "$2" --legacy "$3" --marker "$4" --image "$5"; }
wootc_result_abort() { python3 "$WOOTC_RESULT_BACKEND" abort "$1" "$2" --code "$3"; }
