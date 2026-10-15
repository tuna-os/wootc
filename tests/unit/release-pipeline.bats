#!/usr/bin/env bats
# Release pipeline contracts that no other suite owns.

RELEASE=.github/workflows/release.yml
WINGET=.github/workflows/winget-publish.yml

@test "full releases hand the tag to winget-publish themselves" {
    # winget-publish.yml listens on release:published, but every release this
    # pipeline cuts is created with GITHUB_TOKEN — and GitHub never triggers
    # workflows from events its own token caused (recursion guard). The
    # v0.1.0-alpha.1 publish proved the failure mode: release live, zero
    # winget runs. The publish job must therefore dispatch winget-publish
    # explicitly, and only for full releases (prerelease channels stay out
    # of winget by design).
    grep -q 'gh workflow run winget-publish.yml' "$RELEASE"
    grep -q "prerelease == 'false'" "$RELEASE"
    grep -q 'actions: write' "$RELEASE"
    # The receiving side must accept a tag over workflow_dispatch, or the
    # hand-off dispatches into a workflow that cannot use it.
    grep -q 'workflow_dispatch' "$WINGET"
    grep -q "inputs.tag" "$WINGET"
}

# ── narrative release notes gate (#242) ─────────────────────────────────────
CHECK=tools/release/check-notes.sh

notes_root() {
    root="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$root/docs"
}

@test "a final tag without narrative notes cannot publish" {
    notes_root
    run bash "$CHECK" v9.9.9 "$root"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docs/release-notes-v9.9.9.md does not exist"* ]]
}

@test "draft notes block the release, even for a pre-release tag" {
    notes_root
    for tag in v9.9.9 v9.9.9-rc.1; do
        printf '<!-- wootc-release-notes: draft -->\n# notes\n' \
            > "$root/docs/release-notes-$tag.md"
        run bash "$CHECK" "$tag" "$root"
        [ "$status" -eq 1 ]
        [[ "$output" == *"still a draft"* ]]
    done
}

@test "finished notes pass and name the file the publish job appends" {
    notes_root
    printf '# wootc v9.9.9\n' > "$root/docs/release-notes-v9.9.9.md"
    run bash "$CHECK" v9.9.9 "$root"
    [ "$status" -eq 0 ]
    [ "$output" = "docs/release-notes-v9.9.9.md" ]
}

@test "pre-release and auto tags need no notes file" {
    notes_root
    for tag in v9.9.9-rc.1 auto-v20261001-abcdef0 manual-v20261001-abcdef0; do
        run bash "$CHECK" "$tag" "$root"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
}

@test "a tag that is a path is refused" {
    notes_root
    run bash "$CHECK" ../v9.9.9 "$root"
    [ "$status" -eq 1 ]
}

@test "the v1.0.0 notes stay a draft until their evidence exists" {
    # Removing the marker is the act that allows v1.0.0 to publish. Keep
    # this test until #242 lands the last evidence; delete it in that PR.
    run bash "$CHECK" v1.0.0 .
    [ "$status" -eq 1 ]
    [[ "$output" == *"still a draft"* ]]
}

@test "release.yml runs the notes gate before the VM and appends the notes" {
    # Before the E2E gate: the tests job, which e2e-gate needs.
    awk '/^  tests:/,/^  e2e-gate:/' "$RELEASE" | grep -q 'tools/release/check-notes.sh'
    # In the publish body, so the narrative reaches the release page.
    awk '/Record what gated this build/,/body_path/' "$RELEASE" \
        | grep -q 'check-notes.sh "\$RELEASE_TAG"'
}
