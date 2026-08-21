#!/usr/bin/env bash
# make-release-bundle.sh — assemble everything wootc needs to run without
# reaching the network, laid out exactly as it must land on the target machine.
#
# The app looks for these at fixed paths under C:\wootc (see qemuDir() and
# bundleDir() in app/), so this script's real job is producing that layout —
# the installer then copies the tree across verbatim.
#
#   <out>/qemu/qemu-system-x86_64.exe   Try-in-VM + Boot-in-VM   (SPEC 6.1/6.2)
#   <out>/qemu/edk2-x86_64-code.fd      UEFI firmware for those VMs
#   <out>/qemu/builder-vmlinuz          Alpine builder kernel    (Try-in-VM)
#   <out>/qemu/builder-initramfs.img    Alpine builder initramfs
#   <out>/bundle/store/                 pre-staged bootc image   (#177)
#   <out>/bundle/bundle.json            what that store holds
#
# WHY THE PIECES ARE SEPARATE
# Each is independently useful, so each is independently optional:
#   * QEMU + firmware alone           -> "Boot in VM" for an installed system
#   * plus the builder pair           -> "Try in VM" before installing
#   * plus the image store            -> an install that needs no network
# A partial bundle degrades to fewer features rather than failing; the app
# already reports a specific reason for each missing capability.
#
# QEMU IS NOT VENDORED HERE. It is ~100 MB of third-party GPL binaries with
# their own DLL closure, so the path to it is an input, not something this
# script downloads. Point --qemu at an extracted Windows QEMU install.
#
# Usage:
#   make-release-bundle.sh --out <dir> [--qemu <dir>] [--image <ref>] [--builder <dir>]
#
# Example:
#   payload/bundle/make-release-bundle.sh \
#       --out dist/wootc-offline \
#       --qemu /opt/qemu-w64 \
#       --image ghcr.io/tuna-os/yellowfin:gnome

set -Eeuo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

OUT="" QEMU_SRC="" IMAGE="" BUILDER_SRC="$REPO/payload/builder/out"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out)     OUT="$2"; shift 2 ;;
        --qemu)    QEMU_SRC="$2"; shift 2 ;;
        --image)   IMAGE="$2"; shift 2 ;;
        --builder) BUILDER_SRC="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$OUT" ]] || { echo "usage: $0 --out <dir> [--qemu <dir>] [--image <ref>] [--builder <dir>]" >&2; exit 2; }

log()  { printf '[release-bundle] %s\n' "$*" >&2; }
warn() { printf '[release-bundle] WARNING: %s\n' "$*" >&2; }

mkdir -p "$OUT/qemu"

# ── QEMU + firmware ─────────────────────────────────────────────────────────
if [[ -n "$QEMU_SRC" ]]; then
    [[ -d "$QEMU_SRC" ]] || { echo "--qemu directory not found: $QEMU_SRC" >&2; exit 1; }

    exe="$QEMU_SRC/qemu-system-x86_64.exe"
    [[ -f "$exe" ]] || { echo "no qemu-system-x86_64.exe in $QEMU_SRC" >&2; exit 1; }

    # The whole directory, not just the .exe: a Windows QEMU build is a large
    # DLL closure plus BIOS/vgabios/keymap data files, and copying the binary
    # alone produces something that starts and then immediately fails to find
    # its own ROMs.
    log "copying QEMU from ${QEMU_SRC} (full closure — DLLs and ROMs, not just the exe)"
    cp -a "$QEMU_SRC/." "$OUT/qemu/"

    # The app looks for edk2-x86_64-code.fd by that exact name; QEMU builds
    # ship the firmware under several spellings depending on packaging.
    if [[ ! -f "$OUT/qemu/edk2-x86_64-code.fd" ]]; then
        for cand in "$OUT/qemu/share/edk2-x86_64-code.fd" \
                    "$OUT/qemu/share/qemu/edk2-x86_64-code.fd" \
                    "$OUT/qemu/edk2-x86_64-secure-code.fd" \
                    "$OUT/qemu/share/qemu/OVMF_CODE.fd"; do
            if [[ -f "$cand" ]]; then
                log "normalising firmware name: $(basename "$cand") -> edk2-x86_64-code.fd"
                cp "$cand" "$OUT/qemu/edk2-x86_64-code.fd"
                break
            fi
        done
    fi
    [[ -f "$OUT/qemu/edk2-x86_64-code.fd" ]] || \
        warn "no edk2 firmware found — both VM features will refuse to start"
else
    warn "no --qemu given: neither Try-in-VM nor Boot-in-VM will be available"
fi

# ── Try-in-VM builder pair ──────────────────────────────────────────────────
if [[ -f "$BUILDER_SRC/builder-vmlinuz" && -f "$BUILDER_SRC/builder-initramfs.img" ]]; then
    log "copying Try-in-VM builder artifacts from ${BUILDER_SRC}"
    cp "$BUILDER_SRC/builder-vmlinuz" "$BUILDER_SRC/builder-initramfs.img" "$OUT/qemu/"
else
    warn "no builder artifacts in ${BUILDER_SRC} — 'Try in VM' will stay hidden (run: just build-builder)"
fi

# ── Pre-staged bootc image ──────────────────────────────────────────────────
if [[ -n "$IMAGE" ]]; then
    log "staging ${IMAGE} — this is the big one"
    bash "$HERE/make-bundle.sh" "$IMAGE" "$OUT/bundle"
else
    warn "no --image given: the install will download its image as usual"
fi

# ── Report what the bundle can actually do ──────────────────────────────────
log "----------------------------------------------------------------"
log "bundle: $OUT"
[[ -f "$OUT/qemu/qemu-system-x86_64.exe" ]] \
    && log "  [yes] Boot in VM (installed system)" \
    || log "  [no ] Boot in VM — no QEMU"
if [[ -f "$OUT/qemu/builder-vmlinuz" && -f "$OUT/qemu/qemu-system-x86_64.exe" ]]; then
    log "  [yes] Try in VM (preview before installing)"
else
    log "  [no ] Try in VM — needs QEMU + builder artifacts"
fi
[[ -d "$OUT/bundle/store" ]] \
    && log "  [yes] Offline install — the installer will pin itself to the bundled image" \
    || log "  [no ] Offline install — no image staged"
log "----------------------------------------------------------------"
log "Ship this tree beside wootc.exe; it lands at C:\\wootc\\ on the target."
du -sh "$OUT" 2>/dev/null | sed 's/^/[release-bundle] total: /' >&2 || true
