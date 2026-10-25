#!/usr/bin/env bats
# The E2E harness's check of the product's first-boot evidence (#332), and the
# run-e2e.sh assertions that use it.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHECK="$REPO_ROOT/tests/e2e/firstboot-evidence-check.py"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    EV="$BATS_TEST_TMPDIR/installed-linux-boot.json"
    BOOT=0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0
    python3 - "$EV" <<'PY'
import json, sys
json.dump({'schema': 1, 'state': 'healthy', 'sequence': 1, 'bootId': '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0',
           'kernel': '6.12.0', 'image': {'ref': 'localhost/wootc-ntfs-injected:latest', 'digest': 'sha256:' + 'a' * 64,
           'sourceRef': 'ghcr.io/projectbluefin/bluefin:lts'},
           'rootDisk': {'path': '/wootc/disks/root.disk', 'hostUuid': '1234567890ABCDEF'},
           'bridge': {'boundFolders': 6, 'matchedUsers': 1, 'bitlockerUnlocked': False}, 'secureBoot': True},
          open(sys.argv[1], 'w'))
PY
}

@test "evidence from this Phase-2 boot of the selected image passes" {
    run python3 "$CHECK" "$EV" ghcr.io/projectbluefin/bluefin:lts "$BOOT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bootId=$BOOT"* ]]
}

@test "evidence from another boot fails" {
    run python3 "$CHECK" "$EV" ghcr.io/projectbluefin/bluefin:lts 11111111-2222-3333-4444-555555555555
    [ "$status" -eq 3 ]
    [[ "$output" == *"not the observed Phase-2 boot"* ]]
}

@test "evidence of another image fails" {
    run python3 "$CHECK" "$EV" ghcr.io/tuna-os/yellowfin:gnome "$BOOT"
    [ "$status" -eq 3 ]
    [[ "$output" == *"not the selected"* ]]
}

@test "the BitLocker cell requires the bridge to have reached an unlocked BitLocker C:" {
    run python3 "$CHECK" "$EV" ghcr.io/projectbluefin/bluefin:lts "$BOOT" off
    [ "$status" -eq 0 ]
    run python3 "$CHECK" "$EV" ghcr.io/projectbluefin/bluefin:lts "$BOOT" on
    [ "$status" -eq 3 ]
    [[ "$output" == *"unlocked BitLocker C:"* ]]
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); r["bridge"]["bitlockerUnlocked"]=True; json.dump(r,open(sys.argv[1],"w"))' "$EV"
    run python3 "$CHECK" "$EV" ghcr.io/projectbluefin/bluefin:lts "$BOOT" on
    [ "$status" -eq 0 ]
    [[ "$output" == *"bitlockerUnlocked=True"* ]]
    run python3 "$CHECK" "$EV" ghcr.io/projectbluefin/bluefin:lts "$BOOT" maybe
    [ "$status" -eq 2 ]
}

@test "missing, malformed and oversized evidence is unreadable, not a pass" {
    run python3 "$CHECK" "$BATS_TEST_TMPDIR/absent.json" ghcr.io/projectbluefin/bluefin:lts "$BOOT"
    [ "$status" -eq 2 ]
    printf '{"state":"healthy"}' > "$EV"
    run python3 "$CHECK" "$EV" ghcr.io/projectbluefin/bluefin:lts "$BOOT"
    [ "$status" -eq 2 ]
    head -c 70000 /dev/zero | tr '\0' ' ' > "$EV"
    run python3 "$CHECK" "$EV" ghcr.io/projectbluefin/bluefin:lts "$BOOT"
    [ "$status" -eq 2 ]
}

@test "run-e2e.sh asserts waiting before, and verified evidence after, the Phase-2 boot" {
    grep -q 'product_pass firstboot-waiting' "$E2E"
    grep -q 'product_pass firstboot-evidence' "$E2E"
    grep -q 'firstboot-evidence-check.py" "$ARTIFACT_DIR/installed-linux-boot.json"' "$E2E"
    grep -q '"verdict"\[\[:space:\]\]\*:\[\[:space:\]\]\*"verified"' "$E2E"
    # The evidence check is an extra assertion: the harness's own healthy and
    # North Star user-data assertions are still required.
    grep -q "'full-cycle': {'deployed', 'linux-root', 'linux-proof', 'user-data', 'windows-return', 'healthy'}" \
        "$REPO_ROOT/tests/e2e/lib/results.py"
    # Waiting is asserted before the Phase-2 boot is scheduled; the evidence
    # is read after Windows returns and before healthy is asserted.
    waiting=$(grep -n 'product_pass firstboot-waiting' "$E2E" | cut -d: -f1)
    schedule=$(grep -n 'step "Scheduling one-shot Phase 2 Linux boot..."' "$E2E" | cut -d: -f1)
    returned=$(grep -n 'product_pass windows-return' "$E2E" | cut -d: -f1)
    evidence=$(grep -n 'product_pass firstboot-evidence' "$E2E" | cut -d: -f1)
    healthy=$(grep -n 'product_pass healthy' "$E2E" | cut -d: -f1)
    [ "$waiting" -lt "$schedule" ]; [ "$returned" -lt "$evidence" ]; [ "$evidence" -lt "$healthy" ]
}
