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

@test "release exes are signed after they are built and before the checksums (#230)" {
    # Authenticode rewrites the exe. A SHA256SUMS written before signing
    # describes bytes nobody downloads, and the installer's fail-closed
    # verification (#53) then refuses every install.
    build=$(grep -n -- '- name: Build brand installers' "$RELEASE" | cut -d: -f1)
    sign=$(grep -n -- '- name: Authenticode-sign the installers' "$RELEASE" | cut -d: -f1)
    sums=$(grep -n -- '- name: Checksums for the release assets' "$RELEASE" | cut -d: -f1)
    [ -n "$build" ] && [ -n "$sign" ] && [ -n "$sums" ]
    [ "$build" -lt "$sign" ] && [ "$sign" -lt "$sums" ]
    grep -q 'bash packaging/sign-exes.sh "$CHANNEL" release-assets' "$RELEASE"
    # The jsign download is pinned by digest, and the notes say so when the
    # exes ship unsigned.
    grep -q 'sha256sum -c' "$RELEASE"
    grep -q 'SIGNING: ${{ steps.authenticode.outputs.signing }}' "$RELEASE"
    grep -q 'Not code-signed' "$RELEASE"
}

# ── packaging/sign-exes.sh behaviour, with jsign and osslsigncode stubbed ──

sign_setup() {
    work=$(mktemp -d)
    mkdir -p "$work/assets" "$work/bin"
    printf 'MZ one' > "$work/assets/wootc.exe"
    printf 'MZ two' > "$work/assets/Bazzite-Installer.exe"
    printf 'boot' > "$work/assets/deployer-vmlinuz"
    # jsign stub: appends a marker unless told to fail on a named file.
    cat > "$work/bin/jsign" <<'STUB'
#!/bin/bash
for last; do :; done
case "$*" in *"--storepass env:WOOTC_SIGN_STOREPASS"*) ;; *) echo "secret on argv" >&2; exit 9 ;; esac
[ -n "${JSIGN_FAIL:-}" ] && [[ "$last" == *"$JSIGN_FAIL" ]] && exit 1
printf ' SIGNED' >> "$last"
STUB
    cat > "$work/bin/osslsigncode" <<'STUB'
#!/bin/bash
for last; do :; done
printf '%s\n' "$*" >> "${OSSL_ARGS_LOG:-/dev/null}"
grep -q SIGNED "$last" || { echo "No signature found"; exit 1; }
echo "Subject: /CN=${VERIFY_CN:-TunaOS}"
echo "Timestamp Server Signature verification: ok"
echo "Signature verification: ok"
STUB
    chmod +x "$work/bin/"*
    export JSIGN="$work/bin/jsign" OSSLSIGNCODE="$work/bin/osslsigncode"
    export GITHUB_OUTPUT="$work/output" RUNNER_TEMP="$work"
}

sign_configure() {
    export WOOTC_SIGN_STORETYPE=TRUSTEDSIGNING WOOTC_SIGN_KEYSTORE=weu.codesigning.azure.net \
           WOOTC_SIGN_ALIAS=tunaos/wootc WOOTC_SIGN_STOREPASS=token WOOTC_SIGN_PUBLISHER=TunaOS
}

@test "sign-exes: unconfigured signing ships unsigned and says so" {
    sign_setup
    unset WOOTC_SIGN_STORETYPE
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 0 ]
    grep -qx 'signing=unsigned' "$GITHUB_OUTPUT"
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one" ]
}

@test "sign-exes: configured signing replaces every exe with verified signed bytes" {
    sign_setup; sign_configure
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 0 ]
    grep -qx 'signing=signed' "$GITHUB_OUTPUT"
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one SIGNED" ]
    [ "$(cat "$work/assets/Bazzite-Installer.exe")" = "MZ two SIGNED" ]
    # Only exes are signed; boot artifacts keep their own signatures.
    [ "$(cat "$work/assets/deployer-vmlinuz")" = "boot" ]
}

@test "sign-exes: a tagged release fails closed and leaves no exe half-signed" {
    sign_setup; sign_configure
    export JSIGN_FAIL=wootc.exe
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 1 ]
    grep -qx 'signing=failed' "$GITHUB_OUTPUT"
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one" ]
    [ "$(cat "$work/assets/Bazzite-Installer.exe")" = "MZ two" ]
}

@test "sign-exes: an auto pre-release survives a signing outage, unsigned" {
    sign_setup; sign_configure
    export JSIGN_FAIL=wootc.exe
    run bash packaging/sign-exes.sh auto "$work/assets"
    [ "$status" -eq 0 ]
    grep -qx 'signing=failed' "$GITHUB_OUTPUT"
    [ "$(cat "$work/assets/Bazzite-Installer.exe")" = "MZ two" ]
}

@test "sign-exes: a valid signature by the wrong publisher is a failure" {
    sign_setup; sign_configure
    export VERIFY_CN=Someone-Else
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not signed by CN=TunaOS"* ]]
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one" ]
}

@test "sign-exes: configured without an expected publisher refuses to sign" {
    sign_setup; sign_configure
    unset WOOTC_SIGN_PUBLISHER
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 1 ]
    [[ "$output" == *"WOOTC_SIGN_PUBLISHER is empty"* ]]
}

@test "release.yml can supply the verify roots and the cert chain from variables (#230)" {
    # osslsigncode verifies against the Ubuntu TLS bundle by default, which
    # lacks the Trusted Signing root. Without a way in, a configured tagged
    # release would fail closed on every run.
    grep -q 'WOOTC_SIGN_CA_PEM: ${{ vars.WOOTC_SIGN_CA_PEM }}' "$RELEASE"
    grep -q 'WOOTC_SIGN_CERTCHAIN_PEM: ${{ vars.WOOTC_SIGN_CERTCHAIN_PEM }}' "$RELEASE"
    grep -q 'export WOOTC_SIGN_CAFILE="$RUNNER_TEMP/sign-ca.pem"' "$RELEASE"
    grep -q 'export WOOTC_SIGN_CERTFILE="$RUNNER_TEMP/sign-chain.pem"' "$RELEASE"
    # Only the signing path may read them: the unconfigured release stays a no-op.
    sign=$(grep -n -- '- name: Authenticode-sign the installers' "$RELEASE" | cut -d: -f1)
    sums=$(grep -n -- '- name: Checksums for the release assets' "$RELEASE" | cut -d: -f1)
    ca=$(grep -n 'export WOOTC_SIGN_CAFILE=' "$RELEASE" | cut -d: -f1)
    [ "$sign" -lt "$ca" ] && [ "$ca" -lt "$sums" ]
}

@test "sign-exes: verification uses the configured CA file and jsign gets the chain" {
    sign_setup; sign_configure
    printf 'ROOT\n' > "$work/roots.pem"; printf 'CHAIN\n' > "$work/chain.pem"
    export WOOTC_SIGN_CAFILE="$work/roots.pem" WOOTC_SIGN_CERTFILE="$work/chain.pem"
    export OSSL_ARGS_LOG="$work/ossl.log"
    cat > "$work/bin/jsign" <<'STUB'
#!/bin/bash
for last; do :; done
case "$*" in *"--certfile $WOOTC_SIGN_CERTFILE"*) ;; *) echo "no certfile" >&2; exit 9 ;; esac
printf ' SIGNED' >> "$last"
STUB
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 0 ]
    grep -q -- "-CAfile $work/roots.pem -TSA-CAfile $work/roots.pem" "$work/ossl.log"
}

@test "sign-exes: an unreadable CA file is a signing failure, not a crash later" {
    sign_setup; sign_configure
    export WOOTC_SIGN_CAFILE="$work/missing.pem"
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not readable"* ]]
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one" ]
}

teardown() {
    if [ -n "${work:-}" ]; then rm -rf "$work"; fi
}
