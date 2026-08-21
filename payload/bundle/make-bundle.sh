#!/usr/bin/env bash
# make-bundle.sh — pre-stage a bootc image so the migration needs no network
# after the initial download (#177).
#
# WHY THIS SHAPE
# The deployer's slowest, most failure-prone step is pulling a multi-gigabyte
# OCI image from inside a stripped initramfs. It is also the step most likely
# to strand a user: a flaky mirror mid-migration is the worst possible moment
# to lose the network.
#
# fisherman already knows how to install from a local store — its recipe takes
# `additionalImageStores`, and bootc.go bind-mounts each path read-only into
# the bootc container, so podman resolves the image from there instead of
# reaching out. This script just produces such a store. No new deployer
# mechanism, no fisherman change, and nothing to keep in sync.
#
# A containers-storage tree is used rather than an `oci:` directory layout
# precisely because that is what additionalImageStores consumes; an OCI layout
# would need an extra conversion inside the initramfs, which is where we have
# the least room to be clever.
#
# Usage:
#   payload/bundle/make-bundle.sh ghcr.io/tuna-os/yellowfin:gnome [outdir]
#
# Output (outdir defaults to ./out/bundle):
#   <outdir>/store/        the read-only image store
#   <outdir>/bundle.json   what is inside, for the installer and for humans
#
# Ship <outdir> next to wootc.exe. The installer stages it to
# C:\wootc\bundle\, and deploy.sh picks it up automatically — see
# "offline image bundle" in payload/deployer/deploy.sh.

set -Eeuo pipefail

IMAGE="${1:-}"
OUT="${2:-$(cd "$(dirname "$0")" && pwd)/out/bundle}"

if [[ -z "$IMAGE" ]]; then
    echo "usage: $0 <image-ref> [outdir]" >&2
    echo "example: $0 ghcr.io/tuna-os/yellowfin:gnome" >&2
    exit 2
fi

log() { printf '[make-bundle] %s\n' "$*" >&2; }

command -v podman >/dev/null || { echo "podman is required" >&2; exit 1; }

STORE="$OUT/store"
mkdir -p "$STORE"

# --root makes this a self-contained store rather than polluting (or depending
# on) the caller's. --storage-driver vfs is deliberate: overlay stores embed
# absolute paths and expect matching kernel/driver support at read time, and
# this tree is going to be read from a completely different machine inside an
# initramfs. vfs is bigger on disk but portable, which is the whole point.
log "pulling ${IMAGE} into a portable store (vfs) — this is the big download"
podman --root "$STORE" --storage-driver vfs pull "$IMAGE"

# Resolve the digest so the bundle records exactly what it holds. A tag can be
# re-pointed upstream; a user installing offline months later should be able to
# tell precisely what they are about to boot.
DIGEST="$(podman --root "$STORE" --storage-driver vfs image inspect \
    --format '{{.Digest}}' "$IMAGE" 2>/dev/null || echo "")"
SIZE_BYTES="$(du -sb "$STORE" | cut -f1)"

cat > "$OUT/bundle.json" <<EOF
{
  "image": "${IMAGE}",
  "digest": "${DIGEST}",
  "storageDriver": "vfs",
  "storeBytes": ${SIZE_BYTES},
  "createdAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

log "bundle ready: $OUT ($(numfmt --to=iec "$SIZE_BYTES" 2>/dev/null || echo "$SIZE_BYTES bytes"))"
log "image:  ${IMAGE}"
log "digest: ${DIGEST:-<unknown>}"
cat "$OUT/bundle.json" >&2
