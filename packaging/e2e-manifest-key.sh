#!/usr/bin/env bash
# Locate a developer fixture key outside the guest share and repository.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
identity=$(printf '%s' "$root" | sha256sum | cut -d' ' -f1)
key=${WOOTC_E2E_MANIFEST_KEY:-${XDG_STATE_HOME:-$HOME/.local/state}/wootc/e2e-signing/$identity/seed}
if [ "${1:-}" = --create ] && [ ! -f "$key" ]; then
    umask 077
    mkdir -p "$(dirname "$key")"
    (cd "$root/app" && go run ./tools/signmanifest generate "$key" "$key.pub")
fi
[ -f "$key" ] || { echo "Build the fixture executable with its signing key first" >&2; exit 1; }
printf '%s\n' "$key"
