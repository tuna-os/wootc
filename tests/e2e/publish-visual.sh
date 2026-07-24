#!/usr/bin/env bash
# publish-visual.sh — refresh the E2E walkthrough shown in the README + on
# GitHub Pages, WITHOUT any self-hosted CI runner.
#
# Every E2E run records a timelapse (record-video.sh, wired into run-e2e.sh) to
#   tests/e2e/storage/artifacts/<run-id>/video/{e2e.webm,preview.webp}
# — locally or on a Tailscale laptop runner. This copies the chosen run's
# assets into pages/e2e/latest/, so a normal `git commit && push` to main
# triggers .github/workflows/pages.yml (GitHub-hosted) to publish them. The
# README hero points at the committed pages/e2e/latest/preview.webp (a relative
# path), so it renders inline on GitHub even before Pages deploys.
#
# Usage:
#   # from a local artifact dir:
#   tests/e2e/publish-visual.sh <artifact-dir-or-video-dir>
#   # or pull the newest recorded run off a remote laptop runner:
#   tests/e2e/publish-visual.sh --from-host himachal
#
# Then:  git add pages && git commit -m 'docs: refresh E2E walkthrough' && git push

set -Eeuo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEST="$REPO_ROOT/pages/e2e/latest"

# The README/Pages hero must ONLY ever show a green run. run-e2e.sh stamps a
# .passed marker beside the recording exclusively on ALL TESTS PASSED, so a
# publish gates on that marker. --allow-red overrides (debugging only) and
# prints a loud warning.
ALLOW_RED=false
ARGS=()
for a in "$@"; do
    [[ "$a" == "--allow-red" ]] && { ALLOW_RED=true; continue; }
    ARGS+=("$a")
done
set -- "${ARGS[@]}"

find_local_video_dir() {
    local base="$1"
    [[ -f "$base/preview.webp" || -f "$base/e2e.webm" ]] && { echo "$base"; return; }
    [[ -d "$base/video" ]] && { echo "$base/video"; return; }
    # otherwise: newest video dir with an assembled preview under an artifacts tree
    find "$base" -type f -name preview.webp -printf '%T@ %h\n' 2>/dev/null \
        | sort -nr | head -1 | cut -d' ' -f2-
}

if [[ "${1:-}" == "--from-host" ]]; then
    host="${2:?--from-host needs a hostname}"
    echo "Finding newest recorded run on $host…"
    # Only consider GREEN runs: a video dir with a .passed marker. Without
    # this, "newest run" is whatever ran last — including a red one.
    if [[ "$ALLOW_RED" == true ]]; then
        vd=$(ssh "$host" 'find ~/wootc/tests/e2e/storage*/artifacts -type f -name preview.webp -printf "%T@ %h\n" 2>/dev/null | sort -nr | head -1 | cut -d" " -f2-')
        echo "⚠️  --allow-red: publishing newest run regardless of pass/fail" >&2
    else
        vd=$(ssh "$host" 'find ~/wootc/tests/e2e/storage*/artifacts -type f -name .passed -printf "%T@ %h\n" 2>/dev/null | sort -nr | head -1 | cut -d" " -f2-')
    fi
    [[ -n "$vd" ]] || { echo "no GREEN run (video dir with a .passed marker) found on $host — run-e2e must exit ALL TESTS PASSED first, or pass --allow-red" >&2; exit 1; }
    echo "Using $host:$vd"
    mkdir -p "$DEST"
    scp -q "$host:$vd/preview.webp" "$DEST/preview.webp"
    scp -q "$host:$vd/e2e.webm"     "$DEST/e2e.webm" || echo "(no e2e.webm; poster-only)"
    ssh "$host" "cat '$(dirname "$vd")/run-e2e.current' 2>/dev/null" > "$DEST/run-e2e.current" 2>/dev/null || true
else
    src="${1:?usage: publish-visual.sh <artifact-dir> | --from-host <host>}"
    vd=$(find_local_video_dir "$src")
    [[ -n "$vd" && -f "$vd/preview.webp" ]] || { echo "no preview.webp under $src" >&2; exit 1; }
    # Green-only gate (same as --from-host): the recording must carry the
    # .passed marker run-e2e.sh writes exclusively on ALL TESTS PASSED.
    if [[ "$ALLOW_RED" != true && ! -f "$vd/.passed" ]]; then
        echo "$vd is not a GREEN run (no .passed marker) — the README timelapse only shows passing runs. Pass --allow-red to override." >&2
        exit 1
    fi
    echo "Using $vd"
    mkdir -p "$DEST"
    cp "$vd/preview.webp" "$DEST/preview.webp"
    [[ -f "$vd/e2e.webm" ]] && cp "$vd/e2e.webm" "$DEST/e2e.webm" || echo "(no e2e.webm; poster-only)"
fi

echo "Updated:"; ls -lh "$DEST"
echo
echo "Next:  git add pages && git commit -m 'docs: refresh E2E walkthrough' && git push origin main"
