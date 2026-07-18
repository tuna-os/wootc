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
    vd=$(ssh "$host" 'find ~/wootc/tests/e2e/storage/artifacts -type f -name preview.webp -printf "%T@ %h\n" 2>/dev/null | sort -nr | head -1 | cut -d" " -f2-')
    [[ -n "$vd" ]] || { echo "no assembled preview.webp found on $host" >&2; exit 1; }
    echo "Using $host:$vd"
    mkdir -p "$DEST"
    scp -q "$host:$vd/preview.webp" "$DEST/preview.webp"
    scp -q "$host:$vd/e2e.webm"     "$DEST/e2e.webm" || echo "(no e2e.webm; poster-only)"
    ssh "$host" "cat '$(dirname "$vd")/run-e2e.current' 2>/dev/null" > "$DEST/run-e2e.current" 2>/dev/null || true
else
    src="${1:?usage: publish-visual.sh <artifact-dir> | --from-host <host>}"
    vd=$(find_local_video_dir "$src")
    [[ -n "$vd" && -f "$vd/preview.webp" ]] || { echo "no preview.webp under $src" >&2; exit 1; }
    echo "Using $vd"
    mkdir -p "$DEST"
    cp "$vd/preview.webp" "$DEST/preview.webp"
    [[ -f "$vd/e2e.webm" ]] && cp "$vd/e2e.webm" "$DEST/e2e.webm" || echo "(no e2e.webm; poster-only)"
fi

echo "Updated:"; ls -lh "$DEST"
echo
echo "Next:  git add pages && git commit -m 'docs: refresh E2E walkthrough' && git push origin main"
