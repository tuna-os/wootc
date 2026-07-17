#!/usr/bin/env bash
# record-video.sh — capture the E2E VM display as a video for PR review.
#
#   start <outdir>     begin capturing frames (2s interval) in background
#   stop <outdir>      stop capture and assemble <outdir>/e2e.webm
#   publish <outdir> <pr-number>
#                      upload the webm to R2 (rclone remote "r2", org
#                      convention) and comment the link on the PR via gh
#
# Frames come from QEMU's HMP `screendump` on /run/shm/monitor.sock inside
# the wootc-e2e-windows container — works for firmware, GRUB, Windows and
# Linux phases alike (it's the emulated display, not a guest agent).
# ffmpeg runs in a container if not installed on the host.

set -Eeuo pipefail
CONTAINER="${WOOTC_E2E_CONTAINER:-wootc-e2e-windows}"
INTERVAL="${WOOTC_VIDEO_INTERVAL:-2}"
cmd="${1:?usage: record-video.sh start|stop|publish <outdir> [pr]}"
outdir="${2:?outdir required}"

snap_loop() {
    local n=0
    mkdir -p "$outdir/frames"
    while :; do
        podman exec "$CONTAINER" python3 - <<PYEOF >/dev/null 2>&1 || true
import socket, time
s = socket.socket(socket.AF_UNIX); s.connect("/run/shm/monitor.sock")
time.sleep(0.2); s.recv(4096)
s.sendall(b"screendump /run/shm/frame.ppm\n"); time.sleep(0.4); s.recv(4096)
PYEOF
        podman cp "$CONTAINER:/run/shm/frame.ppm" \
            "$(printf '%s/frames/f%06d.ppm' "$outdir" "$n")" 2>/dev/null || true
        n=$((n + 1))
        sleep "$INTERVAL"
    done
}

case "$cmd" in
    start)
        mkdir -p "$outdir"
        snap_loop &
        echo $! > "$outdir/.recorder.pid"
        echo "recording (pid $(cat "$outdir/.recorder.pid"), every ${INTERVAL}s) -> $outdir/frames"
        ;;
    stop)
        [ -f "$outdir/.recorder.pid" ] && kill "$(cat "$outdir/.recorder.pid")" 2>/dev/null || true
        rm -f "$outdir/.recorder.pid"
        nframes=$(ls "$outdir/frames" 2>/dev/null | wc -l)
        [ "$nframes" -gt 0 ] || { echo "no frames captured"; exit 1; }
        # 10 fps playback of 2s-interval frames = 20x timelapse.
        FF="ffmpeg"
        command -v ffmpeg >/dev/null || \
            FF="podman run --rm -v $outdir:/work:Z -w /work docker.io/linuxserver/ffmpeg"
        $FF -y -framerate 10 -i "$outdir/frames/f%06d.ppm" \
            -c:v libvpx-vp9 -b:v 1M -pix_fmt yuv420p "$outdir/e2e.webm" </dev/null
        echo "assembled $outdir/e2e.webm ($nframes frames)"
        ;;
    publish)
        pr="${3:?pr number required}"
        [ -f "$outdir/e2e.webm" ] || { echo "run 'stop' first"; exit 1; }
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        dest="r2:wootc-e2e-videos/${stamp}-pr${pr}.webm"
        rclone copyto "$outdir/e2e.webm" "$dest"
        url="https://e2e-videos.tuna-os.org/${stamp}-pr${pr}.webm"
        gh pr comment "$pr" --body "📹 E2E run video (${stamp}): ${url}

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
        echo "published: $url"
        ;;
    *)
        echo "unknown command: $cmd" >&2
        exit 2
        ;;
esac
