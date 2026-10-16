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
set -euo pipefail

budget="${1:-}"
[[ "$budget" =~ ^[0-9]+$ ]] && [ "$#" -ge 2 ] || { echo "usage: wait-run-artifact.sh BUDGET_SECONDS NAME..." >&2; exit 2; }
shift
: "${GITHUB_REPOSITORY:?}" "${GITHUB_RUN_ID:?}"
interval="${WAIT_RUN_ARTIFACT_INTERVAL:-15}"
deadline=$(( $(date +%s) + budget ))
errors=0
while :; do
    for name in "$@"; do
        if count=$(gh api -X GET "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/artifacts" \
                -f name="$name" --jq '.total_count' 2>/dev/null) && [[ "$count" =~ ^[0-9]+$ ]]; then
            if [ "$count" -ge 1 ]; then
                printf '%s\n' "$name"
                exit 0
            fi
        else
            # An API error is not an absent artifact: say so, keep waiting.
            errors=$((errors + 1))
            echo "wait-run-artifact: listing artifacts failed ($errors so far)" >&2
        fi
    done
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "wait-run-artifact: none of [$*] appeared in this run within ${budget}s" >&2
        exit 1
    fi
    sleep "$interval"
done
