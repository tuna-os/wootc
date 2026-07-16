#!/usr/bin/env bash
# Builds localhost/wootc-e2e-windows-ssh:latest — the dockurr/windows image
# with sshd baked in (key-only auth, dedicated e2e keypair) so debug
# sessions can `ssh` straight into the container instead of nesting
# `podman exec` through heredocs (a real source of quoting bugs during
# E2E debugging).
#
# Recipe: pull the base image, run it with a harmless override entrypoint,
# install+configure openssh-server in that running container, wrap the
# original entrypoint (dockurr/windows's own `tini -s /run/entry.sh`, which
# this script does NOT modify) so sshd starts alongside it, then commit the
# result as a new image. Re-run this script any time the base image updates.
#
# Usage: bash tests/e2e/build-ssh-image.sh [keyfile]
#   keyfile defaults to ~/.ssh/wootc_e2e_ed25519 (created if missing).
#
# After building, run-e2e.sh / compose.yml pick it up automatically
# (compose.yml's `image:` defaults to this tag). Connect with:
#   ssh -i ~/.ssh/wootc_e2e_ed25519 -p 2222 root@localhost
# (see compose.yml's ports: mapping for the published SSH port).

set -Eeuo pipefail

BASE_IMAGE="${WOOTC_E2E_BASE_IMAGE:-dockurr/windows}"
TARGET_IMAGE="localhost/wootc-e2e-windows-ssh:latest"
KEYFILE="${1:-$HOME/.ssh/wootc_e2e_ed25519}"
BUILDER="wootc-ssh-builder"

if [[ ! -f "$KEYFILE" ]]; then
    echo "+ generating dedicated e2e keypair at $KEYFILE"
    ssh-keygen -t ed25519 -N "" -C "wootc-e2e-debug" -f "$KEYFILE"
fi

echo "+ pulling $BASE_IMAGE"
podman pull -q "$BASE_IMAGE" >/dev/null

podman rm -f "$BUILDER" >/dev/null 2>&1 || true
echo "+ starting builder container"
podman run -d --name "$BUILDER" --entrypoint sh "$BASE_IMAGE" -c "sleep infinity"

echo "+ installing openssh-server"
podman exec "$BUILDER" sh -c "apt-get update -qq && apt-get install -y -qq openssh-server >/dev/null"
podman exec "$BUILDER" ssh-keygen -A

echo "+ installing authorized_keys (key-only auth)"
podman exec "$BUILDER" mkdir -p /root/.ssh
podman cp "${KEYFILE}.pub" "$BUILDER:/root/.ssh/authorized_keys"
podman exec "$BUILDER" sh -c "chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys"
podman exec "$BUILDER" sh -c \
    "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/;s/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config"

echo "+ installing entrypoint wrapper (sshd, then chain to the original entrypoint unmodified)"
WRAPPER=$(mktemp)
printf '#!/bin/sh\nmkdir -p /run/sshd\n/usr/sbin/sshd\nexec /usr/bin/tini -s /run/entry.sh\n' > "$WRAPPER"
podman cp "$WRAPPER" "$BUILDER:/usr/local/bin/wootc-entrypoint.sh"
rm -f "$WRAPPER"
podman exec "$BUILDER" chmod +x /usr/local/bin/wootc-entrypoint.sh

echo "+ committing $TARGET_IMAGE"
podman commit \
    --change 'ENTRYPOINT ["/usr/local/bin/wootc-entrypoint.sh"]' \
    --change 'CMD []' \
    "$BUILDER" "$TARGET_IMAGE"
podman rm -f "$BUILDER" >/dev/null

echo "+ done: $TARGET_IMAGE"
podman images "$TARGET_IMAGE"
echo
echo "Connect once the container is running (add \"2222:22\" to compose.yml's ports:):"
echo "  ssh -i $KEYFILE -p 2222 root@localhost"
