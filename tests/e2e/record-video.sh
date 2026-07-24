#!/usr/bin/env bash
# Capture the E2E VM display through QEMU HMP and assemble a WebM timelapse
# with title cards between phases. GitHub publication is handled by
# upload-artifact in the workflow, so this helper needs no cloud credentials.
#
# The captured frames are the QEMU VGA framebuffer, so the recording already
# shows the real wootc.exe GUI (drive mode) and the Linux desktop whenever
# they are on screen. The deployer used to be a black screen (its output goes
# to the serial console); the E2E deployer now also renders phase banners on
# tty0 (wootc.e2e_video=1), so the deploy shows progress here too.
#
# Commands:
#   record-video.sh start <outdir>
#   record-video.sh mark  <outdir> <card>     # card = phase1|deploy|phase2|phase3
#   record-video.sh stop  <outdir>

set -Eeuo pipefail
CONTAINER="${WOOTC_E2E_CONTAINER:-wootc-e2e-windows}"
RUNTIME="${WOOTC_CONTAINER_RUNTIME:-podman}"
INTERVAL="${WOOTC_VIDEO_INTERVAL:-2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARDS_DIR="$SCRIPT_DIR/titlecards"
CARD_HOLD="${WOOTC_VIDEO_CARD_HOLD:-16}"   # frames a title card is held (~1.6s @10fps)
command="${1:?usage: record-video.sh start|mark|stop <outdir> [card]}"
outdir="${2:?outdir required}"

snap_loop() {
    local n=0 frame
    mkdir -p "$outdir/frames"
    while :; do
        "$RUNTIME" exec "$CONTAINER" python3 -c \
            'import socket,time; s=socket.socket(socket.AF_UNIX); s.connect("/run/shm/monitor.sock"); time.sleep(.2); s.recv(4096); s.sendall(b"screendump /run/shm/frame.ppm\n"); time.sleep(.4); s.recv(4096); s.close()' \
            >/dev/null 2>&1 || true
        frame=$(printf '%s/frames/f%06d.ppm' "$outdir" "$n")
        "$RUNTIME" cp "$CONTAINER:/run/shm/frame.ppm" "$frame" 2>/dev/null || true
        n=$((n + 1))
        sleep "$INTERVAL"
    done
}

# Build a title-card PPM at the capture resolution from the pre-rendered PNG
# (no runtime text rendering — the PNGs are committed). Echoes the path, or
# nothing if it cannot be produced (→ that mark is simply skipped).
make_card() {
    local card="$1" w="$2" h="$3" src="$CARDS_DIR/$1.png" dst="$outdir/cards/$1.ppm"
    [ -f "$src" ] || { echo ""; return; }
    mkdir -p "$outdir/cards"
    if command -v magick >/dev/null 2>&1; then
        magick "$src" -resize "${w}x${h}!" "$dst" 2>/dev/null && { echo "$dst"; return; }
    elif command -v convert >/dev/null 2>&1; then
        convert "$src" -resize "${w}x${h}!" "$dst" 2>/dev/null && { echo "$dst"; return; }
    else
        # No ImageMagick: let ffmpeg do the scale into a PPM.
        if command -v ffmpeg >/dev/null 2>&1; then
            ffmpeg -y -loglevel error -i "$src" -vf "scale=${w}:${h}" -frames:v 1 "$dst" </dev/null 2>/dev/null \
                && { echo "$dst"; return; }
        fi
    fi
    echo ""
}

# Assemble the final numbered sequence: copy captured frames in order and, at
# each marked frame index, splice CARD_HOLD copies of that card first. Returns
# the directory to feed ffmpeg (seq/ with cards, or frames/ unchanged).
build_sequence() {
    local markers="$outdir/markers.txt"
    [ -s "$markers" ] || { echo "$outdir/frames"; return; }
    local first w h
    first=$(find "$outdir/frames" -maxdepth 1 -name 'f*.ppm' | sort | head -1)
    [ -n "$first" ] || { echo "$outdir/frames"; return; }
    if command -v identify >/dev/null 2>&1; then
        read -r w h < <(identify -format '%w %h' "$first" 2>/dev/null) || true
    fi
    # Fallback: parse the PPM header (P6\n[W H]\n255).
    [ -n "${w:-}" ] || read -r w h < <(sed -n '2p' "$first" 2>/dev/null)
    [ -n "${w:-}" ] && [ -n "${h:-}" ] || { echo "$outdir/frames"; return; }

    # marker line: "<frameindex>\t<card>"
    declare -A CARD_AT
    while IFS=$'\t' read -r fidx card; do
        [ -n "$fidx" ] && CARD_AT["$fidx"]="$card"
    done < "$markers"

    mkdir -p "$outdir/seq"; rm -f "$outdir/seq"/*.ppm 2>/dev/null || true
    local out=0 idx=0 f cardppm
    for f in $(find "$outdir/frames" -maxdepth 1 -name 'f*.ppm' | sort); do
        if [ -n "${CARD_AT[$idx]:-}" ]; then
            cardppm=$(make_card "${CARD_AT[$idx]}" "$w" "$h")
            if [ -n "$cardppm" ]; then
                local k=0
                while [ "$k" -lt "$CARD_HOLD" ]; do
                    cp -f "$cardppm" "$(printf '%s/seq/f%06d.ppm' "$outdir" "$out")"
                    out=$((out + 1)); k=$((k + 1))
                done
            fi
        fi
        cp -l "$f" "$(printf '%s/seq/f%06d.ppm' "$outdir" "$out")" 2>/dev/null \
            || cp -f "$f" "$(printf '%s/seq/f%06d.ppm' "$outdir" "$out")"
        out=$((out + 1)); idx=$((idx + 1))
    done
    [ "$out" -gt 0 ] && echo "$outdir/seq" || echo "$outdir/frames"
}

assemble() {  # assemble <framedir>
    local fdir="$1"
    if command -v ffmpeg >/dev/null; then
        ffmpeg -y -loglevel warning -framerate 10 \
            -i "$fdir/f%06d.ppm" -c:v libvpx-vp9 -b:v 1M \
            -pix_fmt yuv420p "$outdir/e2e.webm" </dev/null
        ffmpeg -y -loglevel warning -framerate 10 \
            -i "$fdir/f%06d.ppm" \
            -vf 'fps=5,scale=640:-2:flags=lanczos' -loop 0 \
            -c:v libwebp -quality 60 -compression_level 6 \
            "$outdir/preview.webp" </dev/null || true
    else
        local rel="${fdir#"$outdir/"}"
        "$RUNTIME" run --rm -v "$outdir:/work:Z" -w /work \
            docker.io/linuxserver/ffmpeg -y -loglevel warning -framerate 10 \
            -i "$rel/f%06d.ppm" -c:v libvpx-vp9 -b:v 1M \
            -pix_fmt yuv420p e2e.webm </dev/null
        "$RUNTIME" run --rm -v "$outdir:/work:Z" -w /work \
            docker.io/linuxserver/ffmpeg -y -loglevel warning -framerate 10 \
            -i "$rel/f%06d.ppm" \
            -vf 'fps=5,scale=640:-2:flags=lanczos' -loop 0 \
            -c:v libwebp -quality 60 -compression_level 6 \
            preview.webp </dev/null || true
    fi
}

case "$command" in
    start)
        mkdir -p "$outdir"
        : > "$outdir/markers.txt"
        snap_loop &
        printf '%s\n' "$!" > "$outdir/.recorder.pid"
        ;;
    mark)
        # Record the current frame index against a title card, atomically.
        card="${3:?mark needs a card name}"
        n=$(find "$outdir/frames" -maxdepth 1 -name 'f*.ppm' 2>/dev/null | wc -l)
        printf '%s\t%s\n' "$n" "$card" >> "$outdir/markers.txt"
        ;;
    stop)
        if [ -f "$outdir/.recorder.pid" ]; then
            kill "$(cat "$outdir/.recorder.pid")" 2>/dev/null || true
            rm -f "$outdir/.recorder.pid"
        fi
        nframes=$(find "$outdir/frames" -maxdepth 1 -type f -name '*.ppm' 2>/dev/null | wc -l)
        printf '%s\n' "$nframes" > "$outdir/frame-count.txt"
        [ "$nframes" -gt 0 ] || exit 0
        # Splice title cards (never fatal — fall back to raw frames).
        seqdir=$(build_sequence 2>/dev/null || echo "$outdir/frames")
        [ -n "$seqdir" ] && [ -d "$seqdir" ] || seqdir="$outdir/frames"
        assemble "$seqdir"
        ;;
    *) exit 2 ;;
esac
