#!/usr/bin/env bash
# setup-registry-cache.sh — start a pull-through registry cache for ghcr.io
# on this E2E runner. Concurrent deployers pulling multi-GB images through
# one uplink starve each other (podman exit-125); with the cache every image
# crosses the wifi once and later pulls are LAN-speed. run-e2e.sh detects it
# automatically (mirror.txt hint) — run once per host, survives reboots.
set -euo pipefail
mkdir -p ~/wootc-registry-cache
podman rm -f wootc-registry-cache 2>/dev/null || true
podman run -d --name wootc-registry-cache --restart=always -p 5000:5000 \
    -e REGISTRY_PROXY_REMOTEURL=https://ghcr.io \
    -v ~/wootc-registry-cache:/var/lib/registry \
    docker.io/library/registry:2
sleep 2
curl -fsS -m 5 http://127.0.0.1:5000/v2/ >/dev/null && echo "registry cache up on :5000"
