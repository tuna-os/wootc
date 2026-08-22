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
