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
    # An HSM-style credential: the CA file is used as given. (TRUSTEDSIGNING
    # adds the pinned Microsoft root to it; tested below.)
    export WOOTC_SIGN_STORETYPE=PKCS11
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

# ── Azure Trusted Signing over GitHub OIDC (#229) ───────────────────────────

# az stub: logs its argv, prints a token unless told to fail.
az_stub() {
    cat > "$work/bin/az" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "${AZ_ARGS_LOG:-/dev/null}"
if [ -n "${AZ_FAIL:-}" ]; then echo "ERROR: AADSTS70021: No matching federated identity record" >&2; exit 1; fi
echo "WARNING: this goes to stderr and must not become the token" >&2
echo "oidc-token-123"
STUB
    # jsign stub: the store password must be the az token, read from the
    # environment, and never on argv.
    cat > "$work/bin/jsign" <<'STUB'
#!/bin/bash
for last; do :; done
printf '%s\n' "$*" >> "${JSIGN_ARGS_LOG:-/dev/null}"
case "$*" in *oidc-token-123*) echo "token on argv" >&2; exit 9 ;; esac
case "$*" in *"--storepass env:WOOTC_SIGN_STOREPASS"*) ;; *) exit 9 ;; esac
[ "$WOOTC_SIGN_STOREPASS" = oidc-token-123 ] || { echo "storepass is '$WOOTC_SIGN_STOREPASS'" >&2; exit 8; }
printf ' SIGNED' >> "$last"
STUB
    chmod +x "$work/bin/az" "$work/bin/jsign"
    export AZ="$work/bin/az" AZ_ARGS_LOG="$work/az.log" JSIGN_ARGS_LOG="$work/jsign.log"
}

azure_configure() {
    sign_configure
    unset WOOTC_SIGN_STOREPASS
    export WOOTC_SIGN_AZURE_CLIENT_ID=00000000-0000-0000-0000-000000000001 \
           WOOTC_SIGN_AZURE_LOGIN=success
}

@test "sign-exes: Azure variables without a store type still ship unsigned, and az is not called" {
    sign_setup; az_stub
    unset WOOTC_SIGN_STORETYPE
    export WOOTC_SIGN_AZURE_CLIENT_ID=x WOOTC_SIGN_AZURE_LOGIN=skipped
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 0 ]
    grep -qx 'signing=unsigned' "$GITHUB_OUTPUT"
    [ ! -e "$work/az.log" ]
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one" ]
}

@test "sign-exes: Trusted Signing over OIDC signs with a fresh token, Microsoft's TSA and the pinned root" {
    sign_setup; az_stub; azure_configure
    export OSSL_ARGS_LOG="$work/ossl.log"
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 0 ]
    grep -qx 'signing=signed' "$GITHUB_OUTPUT"
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one SIGNED" ]
    [ "$(cat "$work/assets/Bazzite-Installer.exe")" = "MZ two SIGNED" ]
    # One token, for the Trusted Signing audience.
    [ "$(wc -l < "$work/az.log")" -eq 1 ]
    grep -q -- 'account get-access-token --resource https://codesigning.azure.net' "$work/az.log"
    # The configured endpoint and account/profile reach jsign.
    grep -q -- '--storetype TRUSTEDSIGNING --keystore weu.codesigning.azure.net --alias tunaos/wootc' "$work/jsign.log"
    grep -q -- '--tsaurl http://timestamp.acs.microsoft.com' "$work/jsign.log"
    # The token is never printed.
    [[ "$output" != *oidc-token-123* ]]
}

@test "sign-exes: an explicit timestamp server wins over the Trusted Signing default" {
    sign_setup; az_stub; azure_configure
    export WOOTC_SIGN_TSAURL=http://tsa.example
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 0 ]
    grep -q -- '--tsaurl http://tsa.example' "$work/jsign.log"
    ! grep -q 'timestamp.acs.microsoft.com' "$work/jsign.log"
}

@test "sign-exes: Trusted Signing verification trusts the pinned Microsoft root" {
    sign_setup; az_stub; azure_configure
    printf 'SYSTEM-ROOTS\n' > "$work/roots.pem"
    export WOOTC_SIGN_CAFILE="$work/roots.pem"
    # Capture the CA file while it still exists (the script removes its work dir).
    cat > "$work/bin/osslsigncode" <<'STUB'
#!/bin/bash
for last; do :; done
while [ $# -gt 0 ]; do [ "$1" = -CAfile ] && cp "$2" "$CA_COPY"; shift; done
grep -q SIGNED "$last" || exit 1
echo "Subject: /CN=TunaOS"; echo "Timestamp ok"; echo "Signature verification: ok"
STUB
    export CA_COPY="$work/ca-seen.pem"
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 0 ]
    grep -qx 'SYSTEM-ROOTS' "$work/ca-seen.pem"
    pinned=packaging/authenticode-roots/microsoft-identity-verification-root-2020.pem
    grep -qF "$(sed -n 2p "$pinned")" "$work/ca-seen.pem"
}

@test "the pinned Trusted Signing root is Microsoft Identity Verification Root CA 2020" {
    # A swapped root would make verification trust whatever signed the
    # swap. SHA-1 F40042E2... is in Microsoft's authroot CTL; SHA-256 below.
    command -v openssl >/dev/null || skip "openssl not installed"
    pinned=packaging/authenticode-roots/microsoft-identity-verification-root-2020.pem
    run openssl x509 -in "$pinned" -noout -subject -fingerprint -sha256
    [ "$status" -eq 0 ]
    [[ "$output" == *"CN = Microsoft Identity Verification Root Certificate Authority 2020"* ]]
    [[ "$output" == *"53:67:F2:0C:7A:DE:0E:2B:CA:79:09:15:05:6D:08:6B:72:0C:33:C1:FA:2A:26:61:AC:F7:87:E3:29:2E:12:70"* ]]
}

@test "sign-exes: a failed Azure token request fails a tagged release and touches no exe" {
    sign_setup; az_stub; azure_configure
    export AZ_FAIL=1
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 1 ]
    grep -qx 'signing=failed' "$GITHUB_OUTPUT"
    [[ "$output" == *"no Azure access token"*"AADSTS70021"* ]]
    [ ! -e "$work/jsign.log" ]
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one" ]
}

@test "sign-exes: a failed Azure token request leaves an auto pre-release unsigned, not stalled" {
    sign_setup; az_stub; azure_configure
    export AZ_FAIL=1
    run bash packaging/sign-exes.sh auto "$work/assets"
    [ "$status" -eq 0 ]
    grep -qx 'signing=failed' "$GITHUB_OUTPUT"
    [ "$(cat "$work/assets/wootc.exe")" = "MZ one" ]
}

@test "sign-exes: a failed azure/login is a signing failure before any token request" {
    sign_setup; az_stub; azure_configure
    export WOOTC_SIGN_AZURE_LOGIN=failure
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 1 ]
    [[ "$output" == *"azure/login did not succeed (outcome: 'failure')"* ]]
    [ ! -e "$work/az.log" ]
}

@test "sign-exes: an Azure client id with another store type is a configuration error" {
    sign_setup; az_stub; azure_configure
    export WOOTC_SIGN_STORETYPE=PKCS12
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not TRUSTEDSIGNING"* ]]
    [ ! -e "$work/az.log" ]
}

@test "release.yml logs in to Azure with OIDC, in the publish job only, right before signing (#229)" {
    # Pinned by full SHA with a version comment, like every other action.
    grep -qE 'uses: azure/login@[0-9a-f]{40} # v[0-9.]+$' "$RELEASE"
    grep -q 'client-id: ${{ vars.AZURE_CLIENT_ID }}' "$RELEASE"
    grep -q 'tenant-id: ${{ vars.AZURE_TENANT_ID }}' "$RELEASE"
    grep -q 'subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}' "$RELEASE"
    # Variables, not secrets: an OIDC login has no secret to store.
    ! grep -qE 'secrets\.AZURE_' "$RELEASE"
    # Only when configured, and a failed login is the signer's verdict.
    grep -q "if: \${{ vars.WOOTC_SIGN_STORETYPE == 'TRUSTEDSIGNING' && vars.AZURE_CLIENT_ID != '' }}" "$RELEASE"
    awk '/- name: Azure login for Trusted Signing/,/uses: azure\/login/' "$RELEASE" \
        | grep -q 'continue-on-error: true'
    grep -q 'WOOTC_SIGN_AZURE_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}' "$RELEASE"
    grep -q 'WOOTC_SIGN_AZURE_LOGIN: ${{ steps.azure-login.outcome }}' "$RELEASE"
    # Login sits between the build and the signing step: the token is not
    # requested until the exes exist.
    build=$(grep -n -- '- name: Build brand installers' "$RELEASE" | cut -d: -f1)
    login=$(grep -n -- '- name: Azure login for Trusted Signing' "$RELEASE" | cut -d: -f1)
    sign=$(grep -n -- '- name: Authenticode-sign the installers' "$RELEASE" | cut -d: -f1)
    [ "$build" -lt "$login" ] && [ "$login" -lt "$sign" ]
    # id-token: write exactly once, inside the publish job.
    [ "$(grep -c 'id-token: write' "$RELEASE")" -eq 1 ]
    awk '/^  publish:/,/^    steps:/' "$RELEASE" | grep -q 'id-token: write'
    awk '/^  publish:/,/^    steps:/' "$RELEASE" | grep -q 'environment: release'
}

@test "release.yml passes actionlint and yamllint" {
    command -v actionlint >/dev/null || skip "actionlint not installed (lint.yml runs it in CI)"
    command -v yamllint >/dev/null || skip "yamllint not installed (lint.yml runs it in CI)"
    SHELLCHECK_OPTS=--severity=warning run actionlint "$RELEASE"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run yamllint -d '{extends: relaxed, rules: {line-length: disable}}' "$RELEASE"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

teardown() {
    if [ -n "${work:-}" ]; then rm -rf "$work"; fi
}
