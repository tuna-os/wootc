#!/usr/bin/env bats
# Release pipeline contracts that no other suite owns.

RELEASE=.github/workflows/release.yml
WINGET=.github/workflows/winget-publish.yml
WINUI=.github/workflows/winui-preview.yml

@test "a full release becomes latest and goes to winget only after its native setup is attached" {
    # v0.1.0-alpha.2: release.yml published the boot artifacts as the new
    # latest release, and releases/latest/download/TunaOS-Installer.exe gave
    # 404 until winui-preview.yml attached the native setup about an hour
    # later; the winget run it dispatched gave up on the setup after 30 min.
    grep -q 'make_latest: false' "$RELEASE"
    ! grep -q 'gh workflow run winget-publish.yml' "$RELEASE"
    grep -q 'actions: write' "$RELEASE"
    # winui-preview.yml makes it latest after the upload, for full production
    # releases, then dispatches winget (GitHub never triggers workflows from
    # GITHUB_TOKEN events: v0.1.0-alpha.1 had 0 winget runs).
    awk '/^  publish-preview:/,0' "$WINUI" | grep -q 'actions: write'
    grep -q "steps.tag.outputs.prerelease == 'false'" "$WINUI"
    upload=$(grep -n -- '- name: Upload beside the existing release assets' "$WINUI" | cut -d: -f1)
    latest=$(grep -n -- '- name: Make the full release latest and dispatch winget' "$WINUI" | cut -d: -f1)
    [ "$upload" -lt "$latest" ]
    # The receiving side must accept a tag over workflow_dispatch.
    grep -q 'workflow_dispatch' "$WINGET"
    grep -q "inputs.tag" "$WINGET"
}

# Run winui-preview.yml's "make latest" step with gh and curl recording their
# calls in $work/calls. FAKE_LATEST is what releases/latest answers.
run_make_latest() {  # <work dir> <event name> <latest tag>
    local script
    script=$(awk '/- name: Make the full release latest and dispatch winget/{f=1; next}
                  f && /^      - /{exit}
                  f && /^        run: \|/{r=1; next}
                  r && /^          /{sub(/^          /, ""); print}' "$WINUI")
    [ -n "$script" ]
    mkdir -p "$1/bin"
    cat > "$1/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "gh $*" >> "$CALLS"
case "$*" in
    *releases/tags/*) echo 42 ;;
    *releases/latest*) echo "$FAKE_LATEST" ;;
esac
EOF
    printf '#!/usr/bin/env bash\necho "curl ${*: -1}" >> "$CALLS"\n' > "$1/bin/curl"
    chmod +x "$1/bin/gh" "$1/bin/curl"
    (PATH="$1/bin:$PATH" CALLS="$1/calls" FAKE_LATEST=$3 GITHUB_EVENT_NAME=$2 \
        GITHUB_REPOSITORY=o/r TAG=v9 bash -c "set -euo pipefail; $script")
}

@test "make latest: the tag's setup is checked, then latest, then winget is dispatched" {
    work=$(mktemp -d)
    run run_make_latest "$work" workflow_dispatch v9
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run cat "$work/calls"
    [ "${lines[0]}" = "curl https://github.com/o/r/releases/download/v9/TunaOS-Installer.exe" ]
    [[ "${lines[2]}" == "gh api -X PATCH repos/o/r/releases/42 -f make_latest=true" ]]
    [ "${lines[4]}" = "curl https://github.com/o/r/releases/latest/download/TunaOS-Installer.exe" ]
    [ "${lines[5]}" = "gh workflow run winget-publish.yml --repo o/r -f tag=v9" ]
    rm -rf "$work"
}

@test "make latest: a release a person published does not dispatch winget a second time" {
    work=$(mktemp -d)
    run run_make_latest "$work" release v9
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    grep -q 'make_latest=true' "$work/calls"
    ! grep -q 'winget-publish' "$work/calls"
    rm -rf "$work"
}

@test "make latest: latest still naming another release fails before winget" {
    work=$(mktemp -d)
    run run_make_latest "$work" workflow_dispatch v8
    [ "$status" -ne 0 ]
    [[ "$output" == *"releases/latest is v8, not v9"* ]]
    ! grep -q 'winget-publish' "$work/calls"
    rm -rf "$work"
}

@test "release publishes native setup assets and no Wails fallback (#346)" {
    grep -q 'gui_frontend: native' "$RELEASE"
    ! grep -q 'wootc-legacy.exe' "$RELEASE"
    grep -q 'gh workflow run winui-preview.yml' "$RELEASE"
    grep -q '<Product>-Installer-Setup.exe' "$RELEASE"
    grep -q 'native-SHA256SUMS' "$RELEASE"
    grep -q -- '-Mode release' "$WINUI"
    grep -q "'setup.iss'" shell/packaging/compile-preview.ps1
    grep -q 'artifact-public-key.hex' "$WINUI"
    grep -q 'Install and remove the production setup smoke package' "$WINUI"
    grep -q 'wootc-Installer-Setup.exe' "$WINGET"
    grep -q 'InstallerType: inno' packaging/winget/TunaOS.wootc.installer.yaml.in
    grep -q 'InstallerType: inno' packaging/winget/brand/installer.yaml.in
    ! grep -q 'releases/download/\$tag/wootc.exe' "$WINGET"
}

# Run the asset-naming step of winui-preview.yml's publish job against fake
# tested packages, with the real brand list.
run_native_asset_naming() {  # <production true|false>
    local repo=$PWD work script
    work=$(mktemp -d)
    script=$(awk '/- name: Select brands and name the native release assets/{f=1; next}
                  f && /^      - /{exit}
                  f && /^        run: \|/{r=1; next}
                  r && /^          /{sub(/^          /, ""); print}' "$WINUI")
    [ -n "$script" ]
    mkdir -p "$work/packaging"
    printf '#!/usr/bin/env bash\ncd %q && exec bash packaging/brands.sh "$@"\n' "$repo" > "$work/packaging/brands.sh"
    while IFS=$'\t' read -r brand exe; do
        setup="${exe}-Setup.exe"
        [ "$exe" = wootc ] && setup='wootc-Installer-Setup.exe'
        mkdir -p "$work/preview-artifacts/winui-preview-package-$brand/out/release-installer" \
                 "$work/preview-artifacts/winui-preview-package-$brand/out/preview-installer"
        echo "$brand setup" > "$work/preview-artifacts/winui-preview-package-$brand/out/release-installer/$setup"
        echo "$brand preview" > "$work/preview-artifacts/winui-preview-package-$brand/out/preview-installer/$brand-native-preview-abc.exe"
    done < <(bash packaging/brands.sh list)
    (cd "$work" && PRODUCTION=$1 GITHUB_SHA=abc bash -c "set -euo pipefail; $script") >/dev/null
    echo "$work"
}

@test "a production release keeps every brand's earlier <exeName>.exe download name" {
    work=$(run_native_asset_naming true)
    # tunaos.org links releases/latest/download/TunaOS-Installer.exe.
    cmp "$work/preview-assets/TunaOS-Installer.exe" "$work/preview-assets/TunaOS-Installer-Setup.exe"
    cmp "$work/preview-assets/wootc.exe" "$work/preview-assets/wootc-Installer-Setup.exe"
    while IFS=$'\t' read -r _ exe; do
        [ -s "$work/preview-assets/${exe}.exe" ]
        grep -q " ${exe}.exe\$" "$work/preview-assets/native-SHA256SUMS"
    done < <(bash packaging/brands.sh list)
    rm -rf "$work"
}

@test "a preview attachment adds no stable-name copies" {
    work=$(run_native_asset_naming false)
    [ -s "$work/preview-assets/TunaOS-Installer-Native-Preview-Setup.exe" ]
    [ ! -e "$work/preview-assets/TunaOS-Installer.exe" ]
    [ ! -e "$work/preview-assets/wootc.exe" ]
    rm -rf "$work"
}

@test "production native engines derive their stamps from the exact released shim (#688)" {
    run python3 -m unittest discover -s tests/unit -p test_native_release.py
    [ "$status" -eq 0 ]
}

@test "Phase D removes the obsolete CDP GUI job and stages setup E2E" {
    ! grep -q 'gui-cdp-windows' .github/workflows/ci.yml
    ! grep -q 'gui-cdp-windows' tests/ci-gate.sh
    grep -q 'SetupExe' tests/e2e/setup-wootc.ps1
    grep -q '/VERYSILENT' tests/e2e/setup-wootc.ps1
    grep -q 'wootc Native' tests/e2e/setup-wootc.ps1
    grep -q 'SetupAsset' tests/e2e/run-e2e.sh
    grep -q 'WOOTC_E2E_SETUP_EXE' .github/workflows/e2e-hosted.yml
    grep -q 'wootc-Installer-Setup.exe' tests/e2e/setup-wootc.ps1
    grep -q -- '-Mode release' .github/workflows/e2e-hosted.yml
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

# Run the post-publish verification step of release.yml with curl answering
# from $1 (the "published" release) instead of github.com.
run_published_set_check() {  # <published dir> <work dir with release-assets/ and signing/>
    local script
    script=$(awk '/- name: Verify the published boot-artifact set from its public URLs/{f=1; next}
                  f && /^      - /{exit}
                  f && /^        run: \|/{r=1; next}
                  r && /^          /{sub(/^          /, ""); print}' "$RELEASE")
    [ -n "$script" ]
    mkdir -p "$2/bin"
    printf '#!/usr/bin/env bash\nwhile [ "$#" -gt 1 ]; do [ "$1" = -o ] && out=$2; shift; done\ncp "%s/${1##*/}" "$out"\n' "$1" > "$2/bin/curl"
    chmod +x "$2/bin/curl"
    ln -sfn "$PWD/app" "$2/app"
    (cd "$2" && PATH="$2/bin:$PATH" RUNNER_TEMP="$2" GITHUB_REPOSITORY=o/r RELEASE_TAG=v9 \
        WOOTC_SIGNING_DIR="$2/signing" bash -c "set -euo pipefail; $script")
}

# A signed release set as the publish job leaves it, plus its published copy.
make_signed_release() {  # <work dir>
    local work=$1
    mkdir -p "$work/release-assets" "$work/signing" "$work/published"
    echo kernel > "$work/release-assets/deployer-vmlinuz"
    echo shim > "$work/release-assets/shimx64.efi"
    (cd app && go run ./tools/signmanifest generate "$work/signing/seed" "$work/signing/public.hex")
    (cd "$work/release-assets" && sha256sum -- * > SHA256SUMS)
    (cd app && go run ./tools/signmanifest sign "$work/signing/seed" "$work/release-assets/SHA256SUMS" "$work/release-assets/SHA256SUMS.sig")
    cp "$work/signing/public.hex" "$work/release-assets/artifact-public-key.hex"
    cp "$work/release-assets/"* "$work/published/"
}

@test "the published boot-artifact set is verified from its URLs before the dispatches" {
    publish=$(grep -n 'softprops/action-gh-release' "$RELEASE" | cut -d: -f1)
    verify=$(grep -n -- '- name: Verify the published boot-artifact set from its public URLs' "$RELEASE" | cut -d: -f1)
    dispatch=$(grep -n -- '- name: Dispatch native setup packaging' "$RELEASE" | cut -d: -f1)
    [ "$publish" -lt "$verify" ] && [ "$verify" -lt "$dispatch" ]
    work=$(mktemp -d)
    make_signed_release "$work"
    run run_published_set_check "$work/published" "$work"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    rm -rf "$work"
}

@test "a published manifest signed with another key fails the publish job" {
    work=$(mktemp -d)
    make_signed_release "$work"
    other=$(mktemp -d)
    (cd app && go run ./tools/signmanifest generate "$other/seed" "$other/public.hex")
    (cd app && go run ./tools/signmanifest sign "$other/seed" "$work/published/SHA256SUMS" "$work/published/SHA256SUMS.sig")
    run run_published_set_check "$work/published" "$work"
    [ "$status" -ne 0 ]
    rm -rf "$work" "$other"
}

@test "a published asset that does not match the manifest fails the publish job" {
    work=$(mktemp -d)
    make_signed_release "$work"
    echo other-kernel > "$work/published/deployer-vmlinuz"
    run run_published_set_check "$work/published" "$work"
    [ "$status" -ne 0 ]
    [[ "$output" == *"deployer-vmlinuz: FAILED"* ]]
    rm -rf "$work"
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
    # Outside Actions there is no runner to mask it, so it is never printed.
    unset GITHUB_ACTIONS
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

@test "sign-exes: on Actions the token appears only in its ::add-mask:: line" {
    # The runner hides a value from every later log line once it sees
    # ::add-mask::. That line is the one place the token may be printed.
    sign_setup; az_stub; azure_configure
    export GITHUB_ACTIONS=true
    run bash packaging/sign-exes.sh tagged "$work/assets"
    [ "$status" -eq 0 ]
    grep -qx 'signing=signed' "$GITHUB_OUTPUT"
    [ "$(grep -c oidc-token-123 <<< "$output")" -eq 1 ]
    grep -qx '::add-mask::oidc-token-123' <<< "$output"
    ! grep -q oidc-token-123 "$GITHUB_OUTPUT"
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
    # -nameopt oneline pins the "CN = value" spelling; the default subject
    # format differs between OpenSSL releases (3.0 vs 3.5).
    run openssl x509 -in "$pinned" -noout -subject -nameopt oneline -fingerprint -sha256
    [ "$status" -eq 0 ]
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
    # Pinned to an exact release tag, locked to its commit in actions.lock,
    # like every other action.
    grep -qE 'uses: azure/login@v[0-9]+\.[0-9]+\.[0-9]+$' "$RELEASE"
    grep -qE "^    'azure/login@v[0-9]+\.[0-9]+\.[0-9]+':$" .github/workflows/actions.lock
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
    command -v actionlint >/dev/null || skip "actionlint not installed (the lint job in ci.yml runs it in CI)"
    command -v yamllint >/dev/null || skip "yamllint not installed (the lint job in ci.yml runs it in CI)"
    SHELLCHECK_OPTS=--severity=warning run actionlint "$RELEASE"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    run yamllint -d '{extends: relaxed, rules: {line-length: disable}}' "$RELEASE"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

teardown() {
    if [ -n "${work:-}" ]; then rm -rf "$work"; fi
}
