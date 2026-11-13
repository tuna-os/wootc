#!/usr/bin/env bats
# hosted-podman-runtime.bats — every hosted job that runs a container must
# repair podman's OCI runtime first.
#
# Runner image ubuntu24/20260726.254 bumped podman 4.9.3 -> 5.8.4 but left
# /usr/bin/crun at 1.14.1, which podman 5 rejects ("crun: unknown version
# specified"). .github/actions/podman-runtime installs a compatible crun, but it
# only helps the jobs that USE it — and wiring it into "the workflow that was
# failing" left three others latently broken, each passing only while it happened
# to draw a podman-4 runner:
#
#   - ci.yml gui-shots         (found by CI, red on a podman-5 draw)
#   - ci.yml build-deployer    (podman build, never repaired)
#   - e2e-snapshot.yml prime   (runs the full E2E)
#
# The pool is mixed, so a missing wire-up does not fail reliably — it fails
# later, on someone else's PR, looking like a broken package list. This test is
# the systematic sweep that the piecemeal fixes kept missing.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WF="$REPO_ROOT/.github/workflows"
    ACTION="$REPO_ROOT/.github/actions/podman-runtime/action.yml"
}

# Workflows whose jobs run containers on GITHUB-HOSTED runners.
# e2e-kvm.yml is deliberately absent: it runs on self-hosted boxes (himachal,
# dilli) whose podman/crun pair is matched, and the action no-ops there anyway.
hosted_container_workflows() {
    echo ci.yml
    echo e2e-hosted.yml
    echo e2e-snapshot.yml
    echo release.yml
}

@test "every hosted workflow that runs containers wires in the runtime repair" {
    local f
    for f in $(hosted_container_workflows); do
        grep -q 'actions/podman-runtime' "$WF/$f" \
            || { echo "FAIL: $f runs containers on a hosted runner but never uses ./.github/actions/podman-runtime"; return 1; }
    done
}

@test "the repair installs crun over /usr/bin, where podman actually looks" {
    # podman's runtime search order puts /usr/bin/crun FIRST, so a copy in
    # /usr/local/bin is on $PATH but invisible to podman — which is exactly what
    # made a bare `crun --version` report the fixed version while podman kept
    # using the broken one.
    grep -q 'install -m 0755 .* /usr/bin/crun' "$ACTION"
}

@test "the repair proves a container can be created, not just that versions look right" {
    # Version strings are a proxy; a container that starts is the fact.
    grep -q 'podman run --rm' "$ACTION"
    grep -q 'still cannot create containers' "$ACTION"
}

@test "the repair never touches self-hosted runners" {
    # It rewrites /usr/bin on the runner. That is acceptable on a throwaway
    # hosted VM and not on a box we own.
    local guarded
    guarded=$(grep -c "runner.environment == 'github-hosted'" "$ACTION")
    [ "$guarded" -ge 2 ]
}

@test "the #71 arm gate defaults to empty so it can never gate the nightly" {
    grep -q 'require-podman-major' "$ACTION"
    grep -q "require_podman_major: { type: string, default: '' }" "$WF/e2e-hosted.yml"
}
