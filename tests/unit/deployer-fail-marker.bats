#!/usr/bin/env bats
# `[FAIL]` on the deployer serial is a KILL SWITCH, not a log level.
#
# run-e2e.sh's deploy monitor ends the run on the first match of
#     grep -qE "fatal|panic|kernel panic|\[FAIL\]"
# in a serial chunk. So any [FAIL] deploy.sh prints on a path that then
# CONTINUES is a landmine: the deployer carries on believing the condition was
# survivable, while the harness has already killed the cell and recorded a
# generic "Deployer error" for it.
#
# fedora-gnome-win11pro, run 30707068814, is that shape end to end. The
# deployer's fallback-qemu-ga stager hit
#     [FAIL] qga: ldd ... surfaced no dynamic loader
# returned 1, and its caller absorbed it with
#     [WARN] no fallback qemu-ga staged; Phase 2 is reachable only if the
#            image ships its own agent
# — an explicitly survivable outcome. The run died anyway, 26 minutes in, on
# the [FAIL] one line above the [WARN] that forgave it.
#
# That instance was fixed by hand (deployer-dso-closure.bats). Five more
# non-terminating [FAIL] sites were still armed in the same file. This suite
# makes the invariant structural instead of remembered:
#
#     every [FAIL] deploy.sh prints must end the deploy.
#
# Marker choice is therefore a real decision, made once per site:
#   * fatal        → keep [FAIL], and exit
#   * survivable   → [WARN], and let the downstream observable be the verdict

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DEPLOY="${DEPLOY:-$REPO_ROOT/payload/deployer/deploy.sh}"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    SCANNER="$BATS_TEST_TMPDIR/scan.awk"
    cat > "$SCANNER" <<'AWK'
# Print every [FAIL] emission that does NOT terminate the branch it lives in.
# Indentation delimits the branch: the first following line indented LESS than
# the [FAIL] closes it (fi / else / done / esac / }). Blank and comment lines
# are skipped — their indentation says nothing about block structure.
function indent(s,   n) { n = match(s, /[^ \t]/); return n ? n - 1 : -1 }
{ line[NR] = $0 }
END {
    for (i = 1; i <= NR; i++) {
        l = line[i]
        if (l !~ /\[FAIL\]/) continue
        strip = l; sub(/^[ \t]+/, "", strip)
        if (strip ~ /^#/) continue
        ind = indent(l); ok = 0
        for (j = i + 1; j <= NR; j++) {
            n = line[j]
            s = n; sub(/^[ \t]+/, "", s)
            if (s == "" || s ~ /^#/) continue
            if (indent(n) < ind) break
            if (s ~ /^exit[ \t]+[1-9]/ || s ~ /^return[ \t]+[1-9]/) { ok = 1; break }
        }
        if (!ok) printf "%d: %s\n", i, strip
    }
}
AWK
}

@test "deploy.sh is syntactically valid" {
    run bash -n "$DEPLOY"
    [ "$status" -eq 0 ]
}

@test "the premise holds: run-e2e.sh really does kill the deploy on [FAIL]" {
    # If this ever stops being true, the rest of this suite is enforcing a
    # constraint nothing needs — so pin it rather than assume it.
    run grep -nE 'grep -qE "fatal\|panic\|kernel panic\|\\\[FAIL\\\]"' "$E2E"
    [ "$status" -eq 0 ]
    # …and that the match is what breaks the monitor loop.
    run bash -c "grep -A4 'fatal|panic|kernel panic' '$E2E' | grep -c 'break'"
    [ "$output" -ge 1 ]
}

@test "every [FAIL] in deploy.sh terminates the deploy" {
    run awk -f "$SCANNER" "$DEPLOY"
    [ "$status" -eq 0 ]
    if [ -n "$output" ]; then
        printf 'non-terminating [FAIL] site(s) — each one silently kills a\n' >&2
        printf 'whole cell via run-e2e.sh while the deployer carries on:\n' >&2
        printf '%s\n' "$output" >&2
        printf 'Fix: exit 1 if it is fatal, or say [WARN] if it is not.\n' >&2
        false
    fi
}

@test "the scanner is not vacuous — a planted non-fatal [FAIL] is caught" {
    # The dominant bug class in this repo is a check that would pass even if
    # the thing it asserts never happened. Break the code, confirm it goes red.
    planted="$BATS_TEST_TMPDIR/planted.sh"
    {
        echo 'if [[ -n "$x" ]]; then'
        echo '    err "  [FAIL] something advisory"'
        echo 'fi'
    } > "$planted"
    run awk -f "$SCANNER" "$planted"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'something advisory'

    # …and that the same site with an exit is accepted, so it is not simply
    # flagging every [FAIL] it sees.
    {
        echo 'if [[ -n "$x" ]]; then'
        echo '    err "  [FAIL] something fatal"'
        echo '    exit 1'
        echo 'fi'
    } > "$planted"
    run awk -f "$SCANNER" "$planted"
    [ -z "$output" ]
}

@test "a [FAIL] behind a return needs every call site to exit" {
    # build_phase2_initrd is the one function that prints [FAIL] and returns
    # rather than exiting; the scanner accepts `return 1` for exactly that
    # shape, so the guarantee has to be completed at the call sites.
    sites=$(grep -cE '^[^#]*[^_a-z]build_phase2_initrd "' "$DEPLOY")
    [ "$sites" -ge 3 ]
    # Each call site is a conditional whose failure arm exits within 8 lines
    # (the composefs one reports through an else branch, so it needs the room).
    run bash -c "grep -A8 -E '^[^#]*[^_a-z]build_phase2_initrd \"' '$DEPLOY' \
        | grep -c 'exit 1'"
    [ "$output" -ge "$sites" ]
}

@test "the six sites this suite was written for stayed downgraded" {
    # Named pins: a future edit that reintroduces [FAIL] on any of these
    # survivable conditions rearms the exact landmine, and the generic scan
    # above would only say "line N" long after the reasoning was lost.
    grep -q '\[WARN\] Phase-2 initramfs has no losetup' "$DEPLOY"
    grep -q '\[WARN\] dracut 99wootc-boot module source tree not found' "$DEPLOY"
    grep -q '\[WARN\] Phase-3 request bridge units missing' "$DEPLOY"
    grep -q '\[WARN\] wootc-host-bind.service install failed' "$DEPLOY"
    grep -q '\[WARN\] wootc-passthrough.service install failed' "$DEPLOY"
    # The problem summary keeps [FAIL] — it IS the verdict — and now exits on
    # its own terms instead of leaving the kill to the harness.
    run bash -c "grep -A6 '\[FAIL\] Phase-2 setup completed with' '$DEPLOY' \
        | grep -c '^[[:space:]]*exit 1'"
    [ "$output" -eq 1 ]
}
