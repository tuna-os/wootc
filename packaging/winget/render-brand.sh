#!/usr/bin/env bash
# render-brand.sh — the winget manifests for a BRANDED installer, rendered so
# they can be handed to the project whose namespace they would live in (#227).
#
# `Bazzite.Installer` sits in Bazzite's publisher namespace, not ours. The
# useful form of "may we?" is not a description of a package — it is the
# package, rendered, so they can read exactly what would be published under
# their name and either take it over or say no.
#
# This renders; it never submits. Only TunaOS.wootc is submitted automatically
# (.github/workflows/winget-publish.yml), and no branded package is submitted
# anywhere without `winget.identifierAgreed` in that brand's blessing.json.
#
# Usage:
#   render-brand.sh <brand> [version] [url] [sha256]
#
# With no version/url/sha the placeholders stay in place, which is enough to
# show the shape of the package before a release exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec python3 "$ROOT/packaging/winget/render-brand.py" "$@"
