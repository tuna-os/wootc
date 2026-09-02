#!/usr/bin/env bats
# Fresh-machine trust surface (#241, v1.0 criterion 4).
#
# What a stranger's Windows says about our files before anything runs. Two of
# the four criteria cannot pass yet — nothing is signed (#229/#230), and no
# build carries a VERSIONINFO resource — so what CI can hold is:
#
#   * the verifier exists, grades all four, and treats ABSENCE as failure
#     (an unsigned binary and an identity-less exe both look like "nothing
#     wrong found" to a naive check),
#   * the elevation manifest survives, because the fix for the second gap means
#     regenerating the resource object that carries it,
#   * and the blockers are written down where the release procedure lives.
#
# The grading logic itself is exercised in tests/unit/test-verify-fresh-machine.ps1.

FIELD=tests/field/verify-fresh-machine.ps1
SYSO=app/rsrc_windows_amd64.syso
MANIFEST=app/build/windows/wootc.manifest

@test "the verifier grades all four criteria" {
    [ -f "$FIELD" ]
    grep -q 'Test-WingetPackage' "$FIELD"
    grep -q 'Test-Sha256Manifest' "$FIELD"
    grep -q 'Test-AuthenticodeResult' "$FIELD"
    grep -q 'Test-BrandIdentity' "$FIELD"
}

@test "an unsigned binary fails instead of reading as 'nothing wrong'" {
    run bash -c "sed -n '/function Test-AuthenticodeResult/,/^}/p' $FIELD"
    [ "$status" -eq 0 ]
    # Only Valid passes...
    [[ "$output" == *"'Valid'"* ]]
    # ...and NotSigned names the consequence and the blocking issues, so the ✘
    # is actionable rather than a shrug.
    [[ "$output" == *"NOT SIGNED"* ]]
    [[ "$output" == *"#229/#230"* ]]
    # A tampered download must never be filed as "not signed yet".
    [[ "$output" == *"HashMismatch"* ]]
}

@test "a missing exe identity fails instead of passing by absence" {
    # No build carries VERSIONINFO today, so this is the box that decides
    # whether the checklist tells the truth about criterion 4's fourth item.
    run bash -c "sed -n '/function Test-BrandIdentity/,/^}/p' $FIELD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"no VERSIONINFO resource"* ]]
    [[ "$output" == *'Pass   = $false'* ]]
    # And a branded exe leaking the project name is the documented rule.
    [[ "$output" == *"must never surface the project name"* ]]
}

@test "the expected per-brand identity comes from brand.json, not a copy" {
    # A hardcoded expectation would drift from the thing it grades.
    grep -q "Join-Path \$d.FullName 'brand.json'" "$FIELD"
    grep -q 'productName' "$FIELD"
    grep -q 'exeName' "$FIELD"
}

@test "an asset absent from SHA256SUMS fails rather than being skipped" {
    run bash -c "sed -n '/function Test-Sha256Manifest/,/^}/p' $FIELD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"is not listed in SHA256SUMS"* ]]
    # sha256sum writes binary-mode entries with a leading *.
    [[ "$output" == *"TrimStart('*')"* ]]
}

@test "a stale winget manifest fails even though the package resolved" {
    run bash -c "sed -n '/function Test-WingetPackage/,/^}/p' $FIELD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"behind the release"* ]]
}

@test "the checklist cannot be talked into passing, and names its manual half" {
    grep -q 'RESULT: PASS' "$FIELD"
    grep -q 'RESULT: FAIL' "$FIELD"
    run bash -c "grep -A3 'Where-Object { -not \$_.Pass }' $FIELD | tail -4"
    [ "$status" -eq 0 ]
    [[ "$output" == *"exit 1"* ]]
    # The three screenshots no script can take.
    grep -q 'UAC prompt' "$FIELD"
    grep -q 'Properties' "$FIELD"
    grep -q 'SmartScreen interstitial' "$FIELD"
}

@test "the elevation manifest is intact in the committed resource object" {
    # Fixing the VERSIONINFO gap means REGENERATING this object with a
    # different tool. If the manifest is lost in that change the installer
    # silently stops elevating and every install fails partway through, which
    # is a far worse outcome than the blank properties dialog being fixed.
    grep -q 'requireAdministrator' "$MANIFEST"
    [ -f "$SYSO" ]
    grep -qa 'requireAdministrator' "$SYSO"
    grep -qa 'assemblyIdentity' "$SYSO"
}

@test "the release doc records both blockers with their issues" {
    grep -q 'Fresh-machine verification' docs/RELEASING.md
    grep -q 'verify-fresh-machine.ps1' docs/RELEASING.md
    # Signing: the decision and the plumbing are separate, open, and named.
    grep -q 'issues/229' docs/RELEASING.md
    grep -q 'issues/230' docs/RELEASING.md
    # The identity gap, with why it has to be per brand.
    grep -q 'VERSIONINFO resource at all' docs/RELEASING.md
    grep -q 'per brand' docs/RELEASING.md
}

@test "the PowerShell graders are actually run by the fast tier" {
    [ -f tests/unit/test-verify-fresh-machine.ps1 ]
    grep -q 'tests/unit/test-\*\.ps1' tests/run.sh
    grep -q 'powershell unit tests' tests/run.sh
}
