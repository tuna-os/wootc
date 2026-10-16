#!/usr/bin/env bash
# Print the brand whose installer a real user of IMAGE downloads.
#
# A bluefin run drives the Bluefin-branded installer, exactly what a real user
# downloads, so the walkthrough shows that installer and not the generic one.
# An image can belong to a brand's catalog without a brand of its own (dakota
# ships inside the Bluefin installer), so a brand whose catalog lists the
# image id claims it too. No claim: the generic build.
#
# Usage: e2e-brand.sh IMAGE_REF   (prints the brand id on stdout, notes on stderr)
set -euo pipefail
image="${1:?usage: e2e-brand.sh IMAGE_REF}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
name=$(basename "${image%:*}")
if [ -n "$name" ] && [ -d "$root/app/branding/$name" ]; then
    echo "branded installer: $name" >&2
    printf '%s\n' "$name"
    exit 0
fi
for b in "$root"/app/branding/*/; do
    if grep -Fq "\"$name\"" "$b/brand.json" 2>/dev/null; then
        echo "branded installer: $(basename "$b") (its catalog carries '$name')" >&2
        basename "$b"
        exit 0
    fi
done
echo "no brand claims '$name': generic installer" >&2
printf '%s\n' wootc
