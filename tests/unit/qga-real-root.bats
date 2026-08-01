#!/usr/bin/env bats
# The fallback guest agent must land where the BOOTED system looks, not merely
# where the write succeeds.
#
# Context (run 30703716667, bluefin-dakota-win11pro): the deployer wrote
# qemu-ga to $DEPLOY_ROOT/usr/bin and its unit to
# $DEPLOY_ROOT/usr/lib/systemd/system, logged
#   [PASS] qemu-guest-agent installed from deployer into target
# and Phase 2 then booted dakota to a login prompt with no such binary and no
# such unit anywhere in it: the sealed composefs image is mounted over /usr,
# so the deployment directory's own /usr is shadowed at runtime. The harness
# reported "the Phase-2 guest agent never answered".
#
# Every assertion here is about the runtime view: /etc and /var (proven
# runtime-visible under composefs by wootc-passthrough.service running from
# /var/usrlocal/bin in that same boot), never /usr.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="${DEPLOY:-$REPO_ROOT/payload/deployer/deploy.sh}"
}

extract_fn() {
    awk "/^$1\(\) \{/,/^\}/" "$DEPLOY"
}

# Run stage_qemu_ga_into_target for real against a throwaway deployment tree,
# with a dynamically linked stand-in for qemu-ga so the closure logic (ldd,
# loader, exec-verification) is exercised rather than mocked.
run_stager() {
    DEPLOY_ROOT="$BATS_TEST_TMPDIR/root"
    FAKE_BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$DEPLOY_ROOT" "$FAKE_BIN"
    cp "$(type -P true)" "$FAKE_BIN/qemu-ga"
    chmod 0755 "$FAKE_BIN/qemu-ga"
    run env DEPLOY_ROOT="$DEPLOY_ROOT" PATH="$FAKE_BIN:$PATH" bash -c "
        set -euo pipefail
        log() { echo \"\$*\"; }
        err() { echo \"\$*\" >&2; }
        $(extract_fn find_ldso)
        $(extract_fn dso_closure)
        $(extract_fn stage_qemu_ga_into_target)
        stage_qemu_ga_into_target
    "
}

@test "the staged agent is reachable from the booted root, not from /usr" {
    run_stager
    [ "$status" -eq 0 ]

    # The two paths a composefs runtime actually keeps.
    [ -x "$DEPLOY_ROOT/var/usrlocal/bin/qemu-ga" ]
    [ -f "$DEPLOY_ROOT/etc/systemd/system/wootc-qemu-ga.service" ]

    # Enabled the way systemd enables things, and the link must RESOLVE:
    # the old code symlinked into /etc but pointed at /usr, which dangles the
    # moment the composefs image shadows the deployment's /usr.
    [ -L "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-qemu-ga.service" ]
    [ -e "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-qemu-ga.service" ]

    # Nothing may be placed under the deployment's /usr: that is the write
    # that silently disappeared.
    run bash -c "find '$DEPLOY_ROOT/usr' -type f 2>/dev/null"
    [ -z "$output" ]
}

@test "the unit's ExecStart points at the file that was actually staged" {
    run_stager
    [ "$status" -eq 0 ]
    exec_start=$(sed -n 's/^ExecStart=\([^ ]*\).*/\1/p' \
        "$DEPLOY_ROOT/etc/systemd/system/wootc-qemu-ga.service")
    [ "$exec_start" = "/var/usrlocal/bin/qemu-ga" ]
    [ -x "$DEPLOY_ROOT$exec_start" ]

    # And the wrapper points at a closure that is really there: binary,
    # loader, libraries (agent-lessons §8: never the deployer's binary
    # against the target's libraries).
    loader=$(sed -n 's|^exec /\([^ ]*\) --library-path.*|\1|p' \
        "$DEPLOY_ROOT/var/usrlocal/bin/qemu-ga")
    [ -n "$loader" ]
    [ -f "$DEPLOY_ROOT/$loader" ]
    [ -f "$DEPLOY_ROOT/var/usrlocal/lib/wootc-qga/qemu-ga" ]
}

@test "the fallback stands down when the image ships its own agent" {
    run_stager
    [ "$status" -eq 0 ]
    unit="$DEPLOY_ROOT/etc/systemd/system/wootc-qemu-ga.service"
    # Evaluated in the booted real root, the only place where "does this
    # image have qemu-ga" is observable. A chroot probe at deploy time reports
    # "absent" for EVERY composefs image, because that /usr is empty.
    grep -q '^ConditionPathExists=!/usr/bin/qemu-ga$' "$unit"
    grep -q '^ConditionPathExists=!/usr/sbin/qemu-ga$' "$unit"
    # Its own name, so it can never mask an image-provided
    # qemu-guest-agent.service via /etc precedence.
    [ ! -e "$DEPLOY_ROOT/etc/systemd/system/qemu-guest-agent.service" ]
}

@test "an unstageable closure fails loudly and leaves nothing half-installed" {
    # A stand-in with no dynamic loader (a shell script) is the negative
    # control: ldd surfaces no loader, so no self-contained closure exists.
    DEPLOY_ROOT="$BATS_TEST_TMPDIR/root2"
    FAKE_BIN="$BATS_TEST_TMPDIR/bin2"
    mkdir -p "$DEPLOY_ROOT" "$FAKE_BIN"
    printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/qemu-ga"
    chmod 0755 "$FAKE_BIN/qemu-ga"
    run env DEPLOY_ROOT="$DEPLOY_ROOT" PATH="$FAKE_BIN:$PATH" bash -c "
        set -uo pipefail
        log() { echo \"\$*\"; }
        err() { echo \"\$*\" >&2; }
        $(extract_fn find_ldso)
        $(extract_fn dso_closure)
        $(extract_fn stage_qemu_ga_into_target)
        stage_qemu_ga_into_target
    "
    [ "$status" -ne 0 ]
    [ ! -e "$DEPLOY_ROOT/var/usrlocal/lib/wootc-qga" ]
    [ ! -e "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-qemu-ga.service" ]
}

@test "the deployer no longer installs the agent into the shadowed /usr" {
    run grep -nE '^[^#]*DEPLOY_ROOT/usr(/bin/qemu-ga|/lib/systemd/system/qemu)' "$DEPLOY"
    [ "$status" -ne 0 ]
    # And the composefs early-cpio overlay stages no agent either: that tree
    # is the INITRAMFS and is discarded at switch-root, so a qemu-ga in it
    # cannot put an agent in the booted system.
    run grep -nE '^[^#]*\$OVL[^ ]*qemu' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "the real-root stager is called from the post-install stage" {
    [ "$(grep -c '^stage_qemu_ga_into_target() {' "$DEPLOY")" -eq 1 ]
    grep -qE '^[^#]*[!;] *stage_qemu_ga_into_target;' "$DEPLOY"
}
