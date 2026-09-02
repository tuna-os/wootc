#!/usr/bin/env bats
# Uninstall restoration proof (#238, v1.0 criterion 2).
#
# The proof itself is collected by hand on real machines — nothing in CI has a
# firmware boot menu or a vendor ESP. What CI *can* hold is the contract that
# makes the proof collectable and honest:
#
#   * the ordering that lets the restore happen at all (read the record before
#     deleting the folder it lives in),
#   * the mirror that makes it happen on the orphaned-leftovers path, which the
#     issue tests explicitly and which silently did nothing before,
#   * a grader that is actually run somewhere, so its ✘ means something,
#   * and a documented procedure that grades the keep and delete choices
#     against their own correct end states.
#
# The PowerShell grading logic is exercised for real in
# tests/unit/test-verify-uninstall.ps1; these are the wiring gates.

E2E_APP=app/installer_windows.go
PROBE=app/sysprobe_windows.go
FIELD=tests/field/verify-uninstall.ps1

@test "the power record is read BEFORE the folder holding it is removed" {
    # restorePriorPowerState() reads C:\wootc\install\prior-power.txt, and step
    # 3 of the same function removes C:\wootc\install. Reverse them and the
    # restore silently becomes a no-op on every uninstall.
    local restore_line remove_line
    restore_line=$(grep -n 'restorePriorPowerState()' "$E2E_APP" | grep -v 'func ' | head -1 | cut -d: -f1)
    remove_line=$(grep -n 'os.RemoveAll(filepath.Join(wootcDir(), "install"))' "$E2E_APP" | head -1 | cut -d: -f1)
    [ -n "$restore_line" ]
    [ -n "$remove_line" ]
    [ "$restore_line" -lt "$remove_line" ]
}

@test "the pre-install power state is mirrored where a hand-deleted folder cannot take it" {
    # The orphaned-leftovers path (#238: "delete C:\wootc by hand first, then
    # uninstall") destroys prior-power.txt, so the file alone can never restore
    # that machine. The Add/Remove key survives it and is deleted immediately
    # AFTER the restore runs.
    grep -q 'WootcPriorHibernate' "$PROBE"
    grep -q 'WootcPriorHiberboot' "$PROBE"
    grep -q 'func readPriorPowerMirror' "$PROBE"
    # File first, registry second — the file is authoritative when present.
    run bash -c "sed -n '/func priorPowerValues/,/^}/p' $PROBE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"os.ReadFile(priorPowerPath())"* ]]
    [[ "$output" == *"readPriorPowerMirror()"* ]]
    # And the mirror must outlive the restore that reads it.
    local restore_line unregister_line
    restore_line=$(grep -n 'restorePriorPowerState()' "$E2E_APP" | grep -v 'func ' | head -1 | cut -d: -f1)
    unregister_line=$(grep -n 'unregisterUninstallEntry()' "$E2E_APP" | grep -v 'func ' | head -1 | cut -d: -f1)
    [ "$restore_line" -lt "$unregister_line" ]
}

@test "restoration re-enables only what was on, and reads values not substrings" {
    # A machine that had hibernation off must still have it off afterwards.
    run bash -c "sed -n '/^func restorePriorPowerState/,/^}/p' $PROBE"
    [ "$status" -eq 0 ]
    [[ "$output" == *'hibernate == "1"'* ]]
    [[ "$output" == *'hiberboot == "1"'* ]]
    # The old reader could not tell 1 from 10, nor "was off" from "never read".
    [[ "$output" != *'strings.Contains'* ]]
    grep -q 'func parsePriorPower' app/power_state.go
}

@test "only the FIRST install defines what 'prior' means" {
    # A reinstall after wootc already turned hibernation off must not record
    # the off state as the thing to restore to.
    run bash -c "sed -n '/^func recordPriorPowerState/,/^}/p' $PROBE"
    [ "$status" -eq 0 ]
    [[ "$output" == *'os.Stat(priorPowerPath())'* ]]
    [[ "$output" == *"return"* ]]
}

@test "the field verifier exists and refuses to grade without a baseline" {
    [ -f "$FIELD" ]
    grep -q "run 'capture' before uninstalling" "$FIELD"
    # Capture must copy out the record the uninstall is about to destroy.
    grep -q 'prior-power.txt' "$FIELD"
    # Read-only on the machine under test, apart from the temporary ESP letter.
    grep -q 'Remove-PartitionAccessPath' "$FIELD"
}

@test "the verifier grades keep and delete against different end states" {
    # C:\wootc surviving a keep uninstall is CORRECT; grading it as residue
    # would fail a good machine.
    run bash -c "sed -n '/function Test-WootcDirState/,/^}/p' $FIELD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"root.disk is GONE after a keep uninstall"* ]]
    [[ "$output" == *"still exists after a delete-my-Linux-data uninstall"* ]]
}

@test "a missing power baseline fails the box instead of skipping it" {
    # The orphaned path destroys the record. Passing by default there would
    # hide the exact regression this issue exists to catch.
    run bash -c "sed -n '/function Test-PowerRestored/,/^}/p' $FIELD"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Pass    = $false'* ]]
    [[ "$output" == *"orphaned"* ]]
}

@test "the ESP check is two-sided: ours gone AND nothing else touched" {
    grep -q 'ForeignRemoved' "$FIELD"
    grep -q 'ForeignChanged' "$FIELD"
    # Hashes, not just names — a rewritten foreign file must not read as clean.
    grep -q 'Get-FileHash' "$FIELD"
    grep -q 'ESP: nothing else touched' "$FIELD"
}

@test "the checklist cannot be talked into passing" {
    # Any unticked box exits non-zero, so an attached checklist claiming PASS
    # is a claim the script itself made.
    grep -q 'RESULT: PASS' "$FIELD"
    grep -q 'RESULT: FAIL' "$FIELD"
    run bash -c "grep -A3 'Where-Object { -not \$_.Pass }' $FIELD | tail -5"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit 1"* ]]
}

@test "the PowerShell grading logic is actually run by the fast tier" {
    # A grader nothing exercises is a rubber stamp. The first run of these
    # tests found an empty-array return that made a clean machine report a
    # phantom firmware entry.
    [ -f tests/unit/test-verify-uninstall.ps1 ]
    grep -q 'tests/unit/test-\*\.ps1' tests/run.sh
    grep -q 'powershell unit tests' tests/run.sh
}

@test "manual-testing documents the procedure the issue asks for" {
    grep -q 'Proving the uninstall put everything back' docs/manual-testing.md
    grep -q 'verify-uninstall.ps1 capture' docs/manual-testing.md
    grep -q 'verify-uninstall.ps1 verify' docs/manual-testing.md
    # The two traps a tester would otherwise fall into.
    grep -q 'RootDisk delete' docs/manual-testing.md
    grep -q 'Orphaned' docs/manual-testing.md
    grep -q 'is not always meant to disappear' docs/manual-testing.md
}
