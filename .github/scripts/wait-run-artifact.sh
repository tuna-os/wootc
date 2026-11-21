#!/usr/bin/env bash
# wait-run-artifact.sh BUDGET_SECONDS NAME...
#
# Two jobs of one workflow run hand files to each other while both are still
# running (e2e-hosted.yml: the Linux E2E job builds the native engine with a
# signing key that never leaves it, and the Windows native-shell job compiles
# the preview installer around that engine). `needs:` cannot express a
# handoff in both directions, so each side waits here for the other's
# artifact, then downloads it with actions/download-artifact.
#
# Prints the first NAME that exists as an artifact of this run and exits 0.
# Exits 1 when none appears within BUDGET_SECONDS, 2 on bad arguments.
# Needs GH_TOKEN (actions: read), GITHUB_REPOSITORY and GITHUB_RUN_ID.
#
# WAIT_RUN_ARTIFACT_PEER names the job (its last name segment, as in
# "E2E gate (real Windows VM) / native-shell") that publishes NAME. When that
# job has already finished in this run attempt and none of NAME exists, the
# wait stops at once (exit 1) instead of spending its budget. That is the
# re-run-failed-jobs case: GitHub carries a succeeded peer over from the
# earlier attempt without running it again, so it never publishes this
# attempt's artifact (release run 44920191678 attempt 2). With one such job
# in the attempt, that is the peer; with several (a matrix calling the
# reusable workflow more than once), the peer is the one in the same call as
# the job running this script, found by RUNNER_NAME. Needs GITHUB_RUN_ATTEMPT.
set -euo pipefail

budget="${1:-}"
[[ "$budget" =~ ^[0-9]+$ ]] && [ "$#" -ge 2 ] || { echo "usage: wait-run-artifact.sh BUDGET_SECONDS NAME..." >&2; exit 2; }
shift
: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"
peer="${WAIT_RUN_ARTIFACT_PEER:-}"
[ -z "$peer" ] || : "${GITHUB_RUN_ATTEMPT:?}"
interval="${WAIT_RUN_ARTIFACT_INTERVAL:-15}"
deadline=$(( $(date +%s) + budget ))
errors=0

# Prints the first NAME present; returns 1 when none is.
present() {
    local name count
    for name in "$@"; do
        if count=$(gh api -X GET "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts" \
                -f name="$name" --jq '.total_count' 2>/dev/null) && [[ "$count" =~ ^[0-9]+$ ]]; then
            if [ "$count" -ge 1 ]; then
                printf '%s\n' "$name"
                return 0
            fi
        else
            # An API error is not an absent artifact: say so, keep waiting.
            errors=$((errors + 1))
            echo "wait-run-artifact: listing artifacts failed ($errors so far)" >&2
        fi
    done
    return 1
}

# Succeeds when the peer job of this attempt has finished. An API error or a
# peer it cannot single out proves nothing, so the wait goes on.
peer_finished() {
    [ -n "$peer" ] || return 1
    local jobs
    jobs=$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs?per_page=100" \
        --paginate --jq '.jobs[] | [.name, .status, (.runner_name // "")] | @tsv' 2>/dev/null) || return 1
    awk -F'\t' -v p="$peer" -v r="${RUNNER_NAME:-}" '
        function last(n) { sub(/.* \/ /, "", n); return n }
        last($1) == p { k++; name[k] = $1; state[k] = $2 }
        r != "" && $3 == r && $2 == "in_progress" { self = $1 }
        END {
            if (k == 1) exit (state[1] != "completed")
            if (self == "") exit 1
            want = substr(self, 1, length(self) - length(last(self))) p
            for (i = 1; i <= k; i++) if (name[i] == want) exit (state[i] != "completed")
            exit 1
        }' <<<"$jobs"
}

while :; do
    present "$@" && exit 0
    if peer_finished; then
        # It may have published between the two checks.
        present "$@" && exit 0
        echo "::error::wait-run-artifact: job '$peer' already finished in attempt $GITHUB_RUN_ATTEMPT without publishing any of [$*]." \
             "A job carried over from an earlier attempt (re-run of failed jobs only) cannot pair with this one: its artifacts hold that attempt's manifest-signing key. Re-run all jobs." >&2
        exit 1
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "wait-run-artifact: none of [$*] appeared in this run within ${budget}s" >&2
        exit 1
    fi
    sleep "$interval"
done
