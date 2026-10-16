#!/usr/bin/env bash
# ci-scope.sh: decide which path-scoped PR jobs in ci.yml and ci-tests.yml a
# change can affect.
#
# Reads the changed paths (one per line) on stdin and prints one
# "<scope>=true|false" line per scope, ready for $GITHUB_OUTPUT. Run it from
# the repository root. Pull requests pass the PR's changed paths, pushes to
# main the pushed range's. With --all, prints every scope as true
# (workflow_dispatch, the nightly schedule, an unreadable push range).
#
# A change to this script, to ci.yml/ci-tests.yml or to a local action selects
# every scope. The fast tier and lint are not scoped: they run on every PR
# and every push.
#
#   deployer   ci.yml build-deployer (payload/deployer/Containerfile inputs)
#   app        ci.yml build-app (wootc.exe + Linux dashboard)
#   recipe     ci.yml validate-recipe (fisherman submodule)
#   gui        ci.yml gui-tests (Playwright walkthrough of app/frontend)
#   classic    ci-tests.yml classic-offline (the hash-pinned audit sources)
#   migration  ci-tests.yml integration + gui-shots (payload/migration)
#   partition  ci-tests.yml partition-policy (Windows PowerShell policy)
set -euo pipefail

scopes=(deployer app recipe gui classic migration partition)
declare -A hit=()

select_all() { local s; for s in "${scopes[@]}"; do hit[$s]=1; done; }

if [ "${1:-}" = "--all" ]; then
    select_all
else
    classic_record=docs/experiments/evidence/2026-09-27-esp-orchestrator/offline-prerequisites-provenance.json
    classic_pins=$(jq -r '.sourceHashes | keys[]' "$classic_record")
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$f" in
            .github/scripts/ci-scope.sh | .github/workflows/ci.yml | .github/workflows/ci-tests.yml | .github/actions/*)
                select_all ;;
        esac
        case "$f" in
            fisherman | payload/* | platform/dracut/*) hit[deployer]=1 ;;
        esac
        case "$f" in
            app/* | packaging/*) hit[app]=1 ;;
        esac
        case "$f" in
            fisherman) hit[recipe]=1 ;;
        esac
        case "$f" in
            app/frontend/* | app/branding/* | app/data/* | tests/gui/*) hit[gui]=1 ;;
        esac
        case "$f" in
            tests/audit-classic-offline.py | tests/unit/test_wootc_package_consumer.py | "$classic_record") hit[classic]=1 ;;
        esac
        if grep -qxF -- "$f" <<<"$classic_pins"; then hit[classic]=1; fi
        case "$f" in
            payload/migration/* | tests/migration/* | tests/gui/capture-linux-guis.sh) hit[migration]=1 ;;
        esac
        case "$f" in
            app/partition-policy* | tests/lint-ps1.ps1) hit[partition]=1 ;;
        esac
    done
fi

for s in "${scopes[@]}"; do
    if [ -n "${hit[$s]:-}" ]; then echo "$s=true"; else echo "$s=false"; fi
done
