#!/usr/bin/env bash
# run-cdp.sh — rung-3 GUI E2E (Windows half): drive the REAL wootc.exe over
# the Chrome DevTools Protocol inside a kept E2E Windows VM.
#
# What the mock suite (gui.spec.js) cannot cover — genuine Go↔JS binding
# marshalling, WebView2 rendering, real window chrome — this does, using
# cdp.spec.js against the live installer.
#
# Topology:
#   [this box: playwright, no browser needed] --ssh -L 9222--> [runner host]
#     --published port 9222--> [dockur container] --> [Windows guest 9222]
#
# Guest-side specifics this script handles:
#   * WebView2's CDP endpoint binds 127.0.0.1 only → a netsh portproxy
#     (0.0.0.0:9222 → 127.0.0.1:9222) plus a firewall allow rule expose it.
#   * QGA guest-exec runs as SYSTEM in session 0, where a WebView2 window
#     cannot render. The launch goes through an interactive scheduled task
#     (/IT) in the autologged "wootc" session instead.
#   * WOOTC_UI_PREVIEW=1 stubs the destructive pipeline steps, so clicking
#     Install in the real UI cannot arm the machine.
#
# Usage:
#   tests/gui/run-cdp.sh [--host himachal] [--skip-build]
#
# BUILD TAG REQUIRED: native_webview2loader. Wails' default pure-Go WebView2
# loader never reads WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS (verified against
# wails v2.13 + go-webview2 v1.0.22 source), so a default build renders fine
# but exposes no CDP endpoint. The native tag switches to Microsoft's
# official loader, which honors the env var.
#
# Prerequisites: a running wootc-e2e-windows container on the host
# (run-e2e.sh --keep) with QGA responsive and the "wootc" user logged on;
# node+go here for the build (or --skip-build with a staged wootc.exe).

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
APP_DIR="$REPO_ROOT/app"
FILES_DIR="$REPO_ROOT/tests/e2e/wootc-files"
CONTAINER="${WOOTC_E2E_CONTAINER:-wootc-e2e-windows}"
HOST="${WOOTC_E2E_HOST:-himachal}"
CDP_PORT="${WOOTC_E2E_CDP_PORT:-9222}"
SKIP_BUILD=false
while [ $# -gt 0 ]; do
    case "$1" in
        --host) HOST="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
step() { echo -e "${CYAN}[STEP]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

rqga() {  # PowerShell in the guest, via the runner host's container
    ssh -o ConnectTimeout=10 "$HOST" \
        "podman exec $CONTAINER python3 /tmp/qga.py powershell \"\$(cat)\"" <<< "$1"
}

TUNNEL_PID=""
cleanup() {
    [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
    # Best-effort: stop the GUI and remove the temporary guest plumbing.
    rqga 'schtasks /End /TN wootc-gui-cdp 2>$null; schtasks /Delete /TN wootc-gui-cdp /F 2>$null; netsh interface portproxy delete v4tov4 listenport=9222 listenaddress=0.0.0.0 2>$null; netsh advfirewall firewall delete rule name="wootc-cdp" 2>$null; "cleanup-done"' >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── 1. Build the real product ───────────────────────────────────────────────
if [ "$SKIP_BUILD" = false ]; then
    step "Building wootc.exe (frontend + windows/amd64)..."
    (cd "$APP_DIR/frontend" && npm install --silent && npm run build >/dev/null)
    (cd "$APP_DIR" && GOOS=windows GOARCH=amd64 \
        go build -tags desktop,production,native_webview2loader -ldflags "-w -s" -o "$FILES_DIR/wootc.exe" .)
fi
[ -f "$FILES_DIR/wootc.exe" ] || fail "wootc.exe not found in $FILES_DIR"

# ── 2. Sync the binary to the runner host's share ───────────────────────────
step "Syncing wootc.exe to $HOST..."
rsync -a "$FILES_DIR/wootc.exe" "$HOST:wootc/tests/e2e/wootc-files/wootc.exe"

# ── 3. QGA reachable? ───────────────────────────────────────────────────────
step "Probing QGA on $HOST/$CONTAINER..."
rqga '"qga-ok"' | grep -q qga-ok || fail "QGA not responsive in $CONTAINER on $HOST"

# ── 4. Stage + launch the GUI with CDP in the interactive session ───────────
step "Staging wootc.exe and CDP launcher in the guest..."
rqga 'New-Item -ItemType Directory -Force -Path C:\wootc | Out-Null
Copy-Item \\host.lan\Data\wootc.exe C:\wootc\wootc.exe -Force
@"
set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222
set WOOTC_UI_PREVIEW=1
start "" C:\wootc\wootc.exe
"@ | Set-Content -Path C:\wootc\launch-cdp.cmd -Encoding ascii
"staged"' | grep -q staged || fail "staging failed"

step "Exposing CDP (portproxy + firewall) and launching in the wootc session..."
rqga 'netsh interface portproxy delete v4tov4 listenport=9222 listenaddress=0.0.0.0 2>$null
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=9222 connectaddress=127.0.0.1 connectport=9222 | Out-Null
netsh advfirewall firewall delete rule name="wootc-cdp" 2>$null
netsh advfirewall firewall add rule name="wootc-cdp" dir=in action=allow protocol=TCP localport=9222 | Out-Null
# A pre-existing WebView2 browser process for this user data dir absorbs
# new app instances WITHOUT re-reading browser arguments — a stale
# non-debug tree makes the CDP port silently never appear. Clear it.
Stop-Process -Name wootc -Force -ErrorAction SilentlyContinue
Stop-Process -Name msedgewebview2 -Force -ErrorAction SilentlyContinue
schtasks /Delete /TN wootc-gui-cdp /F 2>$null
schtasks /Create /TN wootc-gui-cdp /SC ONCE /ST 00:00 /TR "C:\wootc\launch-cdp.cmd" /RU wootc /IT /RL HIGHEST /F | Out-Null
schtasks /Run /TN wootc-gui-cdp | Out-Null
"launched"' | grep -q launched || fail "guest launch failed"

# ── 5. Tunnel + wait for the endpoint ───────────────────────────────────────
step "Opening tunnel localhost:$CDP_PORT -> $HOST:$CDP_PORT..."
ssh -o ConnectTimeout=10 -N -L "$CDP_PORT:127.0.0.1:$CDP_PORT" "$HOST" &
TUNNEL_PID=$!

step "Waiting for the CDP endpoint..."
CDP_UP=false
for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null 2>&1; then
        CDP_UP=true; break
    fi
    sleep 2
done
$CDP_UP || fail "CDP endpoint never answered — is the container's $CDP_PORT published (WOOTC_E2E_CDP_PORT) and the wootc user logged on?"
pass "CDP endpoint answering: $(curl -fsS "http://127.0.0.1:$CDP_PORT/json/version" | head -c 120)"

# ── 6. Drive the real GUI ───────────────────────────────────────────────────
step "Running cdp.spec.js against the live installer..."
(cd "$SCRIPT_DIR" && WOOTC_CDP_URL="http://127.0.0.1:$CDP_PORT" npx playwright test cdp.spec.js)
pass "GUI-driven E2E (CDP) passed"
