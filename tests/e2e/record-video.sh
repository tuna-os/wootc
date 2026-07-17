#!/usr/bin/env bash
# Capture the E2E VM display through QEMU HMP and assemble a WebM timelapse.
# GitHub publication is intentionally handled by upload-artifact in the
# workflow, so this helper needs no cloud credentials or PR write access.

set -Eeuo pipefail
CONTAINER="${WOOTC_E2E_CONTAINER:-wootc-e2e-windows}"
RUNTIME="${WOOTC_CONTAINER_RUNTIME:-podman}"
INTERVAL="${WOOTC_VIDEO_INTERVAL:-2}"
command="${1:?usage: record-video.sh start|stop <outdir>}"
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

case "$command" in
    start)
        mkdir -p "$outdir"
        snap_loop &
        printf '%s\n' "$!" > "$outdir/.recorder.pid"
        ;;
    stop)
        if [ -f "$outdir/.recorder.pid" ]; then
            kill "$(cat "$outdir/.recorder.pid")" 2>/dev/null || true
            rm -f "$outdir/.recorder.pid"
        fi
        nframes=$(find "$outdir/frames" -maxdepth 1 -type f -name '*.ppm' 2>/dev/null | wc -l)
        printf '%s\n' "$nframes" > "$outdir/frame-count.txt"
        [ "$nframes" -gt 0 ] || exit 0
        if command -v ffmpeg >/dev/null; then
            ffmpeg -y -loglevel warning -framerate 10 \
                -i "$outdir/frames/f%06d.ppm" -c:v libvpx-vp9 -b:v 1M \
                -pix_fmt yuv420p "$outdir/e2e.webm" </dev/null
        else
            "$RUNTIME" run --rm -v "$outdir:/work:Z" -w /work \
                docker.io/linuxserver/ffmpeg -y -loglevel warning -framerate 10 \
                -i frames/f%06d.ppm -c:v libvpx-vp9 -b:v 1M \
                -pix_fmt yuv420p e2e.webm </dev/null
        fi
        ;;
    *) exit 2 ;;
esac
