#!/usr/bin/env bats
# secure-boot-authorities.bats — the shim we stage must be one this firmware
# can launch (#322).
#
# Under Secure Boot the firmware only launches a loader signed by a CA in its
# `db`. Microsoft's third-party authority has two generations: the 2011 CA
# (certificate expired 2026-06-27) and the 2023 CA, which signs everything
# issued now. Firmware ignores expiry, so a 2011-signed shim still boots on a
# machine that holds the 2011 CA — but new machines increasingly ship the 2023
# CA alone, and there a 2011-only shim dies at "bad shim signature" AFTER the
# reboot, with nothing said before it. The release records what it signs, the
# preflight reads what the firmware trusts, and the refusal happens while
# Windows is still on screen.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    RELEASE="$REPO_ROOT/.github/workflows/release.yml"
    E2E="$REPO_ROOT/tests/e2e/run-e2e.sh"
    SA="$REPO_ROOT/packaging/shim-authorities.py"
}

@test "the release stages a DUAL-signed shim, pinned by exact NVR" {
    # Fedora 44's own shim-x64 is 16.1-5, signed only by the 2011 authority.
    # An unpinned 'dnf install shim-x64' is exactly how a single-signed build
    # comes back silently.
    grep -q 'shim-x64-16.1-7' "$RELEASE"
    grep -q 'kojipkgs.fedoraproject.org/packages/shim' "$RELEASE"
    run grep -E 'dnf install -y -q shim-x64 ' "$RELEASE"
    [ "$status" -ne 0 ]
}

@test "the build refuses to publish a shim that 2023-only firmware cannot launch" {
    grep -q 'shim-authorities.py --require 2023' "$RELEASE"
    # The check must run on the binary that is actually published, not on a
    # copy or a name.
    grep -q 'release-assets/shimx64.efi' "$RELEASE"
}

@test "the exe is stamped from the extracted shim, never from a second copy of the pin" {
    # A hardcoded stamp is how an exe starts describing a binary nobody
    # ships. It must be derived from shim-authorities.json.
    grep -q 'X main.shimAuthorities=\$SHIM_AUTHORITIES' "$RELEASE"
    grep -q "SHIM_AUTHORITIES=\$(python3 -c" "$RELEASE"
    run grep -E 'SHIM_AUTHORITIES="2011' "$RELEASE"
    [ "$status" -ne 0 ]
    # ...which requires the artifacts to be built BEFORE the exes.
    local artifacts brands
    artifacts=$(grep -n 'name: Build deployer boot artifacts' "$RELEASE" | cut -d: -f1)
    brands=$(grep -n 'name: Build brand installers' "$RELEASE" | cut -d: -f1)
    [ -n "$artifacts" ] && [ -n "$brands" ]
    [ "$artifacts" -lt "$brands" ]
}

@test "MokManager is NOT graded against the Microsoft CAs" {
    # mmx64.efi is signed by Fedora's key and verified by shim, not by the
    # firmware. Requiring a Microsoft CA on it would fail every build for a
    # reason that is not real.
    run grep -E 'shim-authorities.py.*mmx64' "$RELEASE"
    [ "$status" -ne 0 ]
}

@test "the harness proves the same shim the release ships" {
    # A harness on a 2011-only chain while the release ships dual-signed is
    # testing a different product.
    grep -q 'shim-x64-16.1-7' "$E2E"
    run grep -E 'dnf install -y -q shim-x64 ' "$E2E"
    [ "$status" -ne 0 ]
}

@test "the extractor walks EVERY signature, not just the first" {
    # A dual-signed PE appends a second WIN_CERTIFICATE after the first.
    # Reading only the first would report Fedora's dual-signed shim as
    # 2011-only and re-introduce the whole bug.
    grep -q 'def pkcs7_blobs' "$SA"
    grep -q 'while pos + 8 <= len(blob)' "$SA"
    grep -q 'pos += (length + 7) & ~7' "$SA"
    python3 -c "import ast,sys; ast.parse(open('$SA').read())"
}

@test "the extractor matches on the ISSUER, not the leaf subject" {
    # The leaf is a per-publisher certificate ('Microsoft Windows UEFI Driver
    # Publisher'); the CA above it is what has to be in the firmware's db.
    grep -q 'Issuer:' "$SA"
    grep -q 'Microsoft Corporation UEFI CA 2011' "$SA"
    grep -q 'Microsoft (?:Corporation )?UEFI CA 2023' "$SA"
}

@test "the preflight gates BEFORE anything is written, and only on a known mismatch" {
    local app="$REPO_ROOT/app/app.go"
    # In gateScenario, which runs before the first byte of the install.
    grep -q 'checkSecureBootChain' "$app"
    grep -q 'TrustedUefiAuthorities' "$app"
    # An unreadable db must warn, not refuse: "bad shim signature" costs a
    # reboot back into Windows, and refusing every PC whose SecureBoot module
    # is unavailable would block machines that work today.
    grep -q 'SecureBootChainWarning' "$app"
    grep -q 'Warn:' "$REPO_ROOT/app/secureboot.go"
    grep -q 'secureBootChainWarning' "$REPO_ROOT/app/frontend/src/screens/launchpad.js"
}

@test "the db read is Windows-only and the dev stub gates nothing" {
    grep -q 'func trustedUefiAuthorities' "$REPO_ROOT/app/secureboot_windows.go"
    grep -q 'func trustedUefiAuthorities() \[\]string { return nil }' "$REPO_ROOT/app/secureboot_other.go"
    grep -q 'go:build windows' "$REPO_ROOT/app/secureboot_windows.go"
    grep -q 'go:build !windows' "$REPO_ROOT/app/secureboot_other.go"
}
