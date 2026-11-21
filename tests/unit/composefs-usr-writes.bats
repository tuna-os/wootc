#!/usr/bin/env bats
# On a composefs deployment (bluefin: prepare-root [composefs] enabled) the
# sealed image is mounted over /usr, so anything the deployer writes into the
# deployment's /usr is invisible at runtime. The look data wootc-apply-look
# reads lived in $DEPLOY_ROOT/usr/share/wootc/slurp, so first login found no
# Windows look; the desktop entries, the polkit action and the plugin set
# vanished the same way.

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="$ROOT/payload/deployer/deploy.sh"
}

@test "the deployer installs nothing the running system reads under \$DEPLOY_ROOT/usr" {
    # Allowed: the dracut module (consumed by the deploy-time initramfs
    # rebuild) and /usr/local, a symlink into /var/usrlocal.
    run grep -nE '(install|cp|mig_opt|mkdir|ln)[^#]*"\$DEPLOY_ROOT/usr/' "$DEPLOY"
    offenders=$(printf '%s\n' "$output" | grep -vE 'DEPLOY_ROOT/usr/(lib/dracut/modules\.d/99wootc-boot|local/)' || true)
    [ -z "$offenders" ] || { printf 'runtime payload under /usr:\n%s\n' "$offenders"; false; }
}

@test "apply-look reads the look data where the deployer installs it" {
    grep -q 'mkdir -p "$DEPLOY_ROOT/var/lib/wootc/slurp"' "$DEPLOY"
    grep -q -- '-exec cp -a {} "$DEPLOY_ROOT/var/lib/wootc/slurp/"' "$DEPLOY"
    grep -qx 'SLURP_DIR="${WOOTC_SLURP_DIR:-/var/lib/wootc/slurp}"' "$ROOT/payload/migration/wootc-apply-look"
}

@test "desktop entries and the polkit action land where XDG and polkit read on a sealed image" {
    for name in wootc-import wootc-manifest wootc-user wootc-go-native; do
        grep -q "mig_opt 644 $name.desktop \"\$DEPLOY_ROOT/var/usrlocal/share/applications/$name.desktop\"" "$DEPLOY"
    done
    grep -q '"$DEPLOY_ROOT/etc/polkit-1/actions/org.tunaos.wootc.policy"' "$DEPLOY"
}

@test "wootc-manifest finds the plugin set the deployer installs beside it" {
    tree="$BATS_TEST_TMPDIR/var/usrlocal"
    mkdir -p "$tree/bin" "$tree/lib/wootc/plugins.d"
    cp "$ROOT/payload/migration/wootc-manifest" "$tree/bin/wootc-manifest"
    cp -a "$ROOT/payload/migration/plugins.d/office" "$tree/lib/wootc/plugins.d/office"
    run env -u WOOTC_PLUGINS_DIR HOME="$BATS_TEST_TMPDIR/home" python3 "$tree/bin/wootc-manifest" list-plugins
    [ "$status" -eq 0 ]
    printf '%s' "$output" | python3 -c 'import json,sys; ids={p["id"] for p in json.load(sys.stdin)["plugins"]}; sys.exit(0 if "office" in ids else 1)'
}
