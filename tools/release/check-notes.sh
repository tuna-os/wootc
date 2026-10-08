#!/usr/bin/env bash
# check-notes.sh — the narrative release-notes gate (#242).
#
# A final tag (vX.Y.Z, no pre-release suffix) is the version a stranger's
# winget pulls. Its release body must tell the story — what the version
# means, each claim linked to its evidence, what is deliberately left out —
# not only the generic "what gated this build" block release.yml writes.
#
#   check-notes.sh <tag> [repo-root]
#
# Exit 0 when the tag may publish, printing the notes path (or nothing when
# the tag has no notes file and does not need one). Exit 1 when:
#   - a final tag has no docs/release-notes-<tag>.md, or
#   - the notes file still carries the draft marker. Draft notes hold
#     "pending" evidence slots; publishing them would claim proof that does
#     not exist yet.
#
# Pre-release tags (v1.0.0-rc.1) and the auto/manual channels need no notes
# file, but a draft one still blocks them.
set -euo pipefail

tag="${1:?usage: check-notes.sh <tag> [repo-root]}"
root="${2:-.}"
if [[ "$tag" == */* || "$tag" == .* ]]; then
    echo "::error::refusing tag '$tag': not a plain release tag." >&2
    exit 1
fi

marker='<!-- wootc-release-notes: draft -->'
notes="docs/release-notes-${tag}.md"

final=false
if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then final=true; fi

if [ ! -f "$root/$notes" ]; then
    if $final; then
        echo "::error::$tag is a final release and $notes does not exist." >&2
        echo "Write the narrative notes first (docs/RELEASING.md#narrative-release-notes)." >&2
        exit 1
    fi
    exit 0
fi

if grep -qF -- "$marker" "$root/$notes"; then
    echo "::error::$notes is still a draft ($marker)." >&2
    echo "Fill every evidence slot, then remove the marker." >&2
    exit 1
fi

echo "$notes"
