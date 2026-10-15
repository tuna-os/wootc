#!/usr/bin/env bash
# Authenticode-sign every release exe before SHA256SUMS is written (#230).
#
#   packaging/sign-exes.sh <channel> <assets-dir>
#
# <channel> is the release channel from release.yml (tagged | auto | manual).
# The signer is jsign, which talks to every credential #229 is choosing
# between from a Linux runner: Azure Trusted Signing (TRUSTEDSIGNING), an EV
# key in a cloud HSM (AZUREKEYVAULT, GOOGLECLOUD, DIGICERTONE, PKCS11, ...),
# or a plain PKCS12 file for a test credential. Nothing here names one.
#
# Configuration (repository variables, plus one secret):
#   WOOTC_SIGN_STORETYPE   jsign --storetype. Empty = signing not configured.
#   WOOTC_SIGN_KEYSTORE    jsign --keystore (endpoint, vault, or file)
#   WOOTC_SIGN_ALIAS       jsign --alias (key or account/profile)
#   WOOTC_SIGN_STOREPASS   token or password (secret). Passed to jsign as
#                          `env:WOOTC_SIGN_STOREPASS`, never on a command line
#   WOOTC_SIGN_CERTFILE    jsign --certfile (optional; chain for HSM keys)
#   WOOTC_SIGN_TSAURL      RFC 3161 timestamp server (optional; jsign default)
#   WOOTC_SIGN_PUBLISHER   CN the signer certificate must carry (required
#                          once configured; "Valid" alone is not "ours")
#   WOOTC_SIGN_CAFILE      CA bundle for verification (default: system
#                          TLS bundle; release.yml appends vars.WOOTC_SIGN_CA_PEM)
#
# Azure Trusted Signing over GitHub OIDC (#229, the maintainer's choice). No
# stored secret: release.yml runs azure/login with a federated credential,
# and this script asks the Azure CLI for a code-signing access token right
# before the first exe is signed (a token lives about an hour):
#   WOOTC_SIGN_AZURE_CLIENT_ID  vars.AZURE_CLIENT_ID. Non-empty = the store
#                          password is that token, not WOOTC_SIGN_STOREPASS.
#                          Only valid with WOOTC_SIGN_STORETYPE=TRUSTEDSIGNING.
#   WOOTC_SIGN_AZURE_LOGIN the azure/login step's outcome; anything but
#                          `success` is a signing failure.
# For TRUSTEDSIGNING the timestamp server defaults to Microsoft's
# (timestamp.acs.microsoft.com), and verification also trusts the
# in-repo pin packaging/authenticode-roots/microsoft-identity-verification-
# root-2020.pem, which both the signing and the timestamp chains end in.
#
# Outcomes (printed as `signing=<state>` to stdout and $GITHUB_OUTPUT):
#   signed      every exe is signed, timestamped, and verified against the
#               expected publisher; the signed bytes replace the originals.
#   unsigned    signing is not configured (#229 pending). Exit 0.
#   failed      signing or verification failed. Tagged releases exit 1 — a
#               full release never ships unsigned once a credential exists.
#               Auto and manual pre-releases exit 0 with the originals left
#               untouched, so a signing-service outage cannot stall the
#               nightly cadence; release.yml marks the notes loudly.
#
# All or nothing: exes are signed as copies and moved into place only after
# every one verified. A half-signed release is worse than an unsigned one —
# it hides which file the warning is about.
#
# JSIGN, OSSLSIGNCODE and AZ name the commands (tests replace them).
set -euo pipefail

channel=${1:?usage: sign-exes.sh <channel> <assets-dir>}
assets=${2:?usage: sign-exes.sh <channel> <assets-dir>}
JSIGN=${JSIGN:-jsign}
OSSLSIGNCODE=${OSSLSIGNCODE:-osslsigncode}
AZ=${AZ:-az}
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ms_root="$here/authenticode-roots/microsoft-identity-verification-root-2020.pem"
# The audience every Trusted Signing data-plane token is issued for.
trusted_signing_resource=https://codesigning.azure.net

emit() {
    echo "signing=$1"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "signing=$1" >> "$GITHUB_OUTPUT"; fi
}

case "$channel" in
    tagged|auto|manual) ;;
    *) echo "sign-exes: unknown channel '$channel'" >&2; exit 2 ;;
esac

shopt -s nullglob
exes=("$assets"/*.exe)
shopt -u nullglob
if [ "${#exes[@]}" -eq 0 ]; then
    echo "sign-exes: no exe in $assets — refusing to report a signed release of nothing" >&2
    exit 2
fi

if [ -z "${WOOTC_SIGN_STORETYPE:-}" ]; then
    echo "::warning::Authenticode signing is not configured (#229); ${#exes[@]} exe(s) ship unsigned"
    emit unsigned
    exit 0
fi

fail() {
    echo "::error::Authenticode signing failed: $*"
    emit failed
    if [ "$channel" = tagged ]; then exit 1; fi
    echo "::warning::$channel pre-release continues with the unsigned exes"
    exit 0
}

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/wootc-authenticode.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ -n "${WOOTC_SIGN_AZURE_CLIENT_ID:-}" ]; then
    [ "$WOOTC_SIGN_STORETYPE" = TRUSTEDSIGNING ] \
        || fail "AZURE_CLIENT_ID is set, but WOOTC_SIGN_STORETYPE is '$WOOTC_SIGN_STORETYPE', not TRUSTEDSIGNING"
    [ "${WOOTC_SIGN_AZURE_LOGIN:-}" = success ] \
        || fail "azure/login did not succeed (outcome: '${WOOTC_SIGN_AZURE_LOGIN:-}'); check the federated credential"
    # stdout is the token and nothing else; az's warnings go to a file.
    token=$("$AZ" account get-access-token --resource "$trusted_signing_resource" \
                --query accessToken --output tsv 2> "$work/az.err") \
        || fail "no Azure access token for $trusted_signing_resource: $(tail -n 3 "$work/az.err")"
    [ -n "$token" ] || fail "the Azure CLI returned an empty access token"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$token"; fi
    WOOTC_SIGN_STOREPASS=$token
    export WOOTC_SIGN_STOREPASS
    unset token
fi

for var in WOOTC_SIGN_KEYSTORE WOOTC_SIGN_ALIAS WOOTC_SIGN_STOREPASS WOOTC_SIGN_PUBLISHER; do
    [ -n "${!var:-}" ] || fail "$var is empty while WOOTC_SIGN_STORETYPE is set"
done

args=(--storetype "$WOOTC_SIGN_STORETYPE" --keystore "$WOOTC_SIGN_KEYSTORE"
      --alias "$WOOTC_SIGN_ALIAS" --storepass env:WOOTC_SIGN_STOREPASS
      --alg SHA-256 --tsmode RFC3161)
if [ -n "${WOOTC_SIGN_CERTFILE:-}" ]; then args+=(--certfile "$WOOTC_SIGN_CERTFILE"); fi
tsaurl=${WOOTC_SIGN_TSAURL:-}
if [ -z "$tsaurl" ] && [ "$WOOTC_SIGN_STORETYPE" = TRUSTEDSIGNING ]; then
    # Microsoft's own RFC 3161 service, as its signing tools default to. Its
    # chain ends in the same pinned root as the signing certificate.
    tsaurl=http://timestamp.acs.microsoft.com
fi
if [ -n "$tsaurl" ]; then args+=(--tsaurl "$tsaurl"); fi
cafile=${WOOTC_SIGN_CAFILE:-/etc/ssl/certs/ca-certificates.crt}
# The system bundle is TLS roots only. A code-signing root that is not in
# it must come in through WOOTC_SIGN_CAFILE, which release.yml builds from
# vars.WOOTC_SIGN_CA_PEM. Trusted Signing's root is pinned in the repo
# instead: a reviewed file beats a variable nobody sees change.
[ -r "$cafile" ] || fail "CA file $cafile for verification is not readable"
if [ "$WOOTC_SIGN_STORETYPE" = TRUSTEDSIGNING ]; then
    [ -r "$ms_root" ] || fail "pinned Trusted Signing root $ms_root is missing"
    cat "$cafile" "$ms_root" > "$work/verify-roots.pem"
    cafile="$work/verify-roots.pem"
fi

for exe in "${exes[@]}"; do
    name=$(basename "$exe")
    cp "$exe" "$work/$name"
    "$JSIGN" "${args[@]}" "$work/$name" || fail "jsign could not sign $name"
    # Verify the bytes that will ship, not jsign's exit code: chain, digest,
    # timestamp, and that the signer is the publisher we expect.
    report=$("$OSSLSIGNCODE" verify -CAfile "$cafile" -TSA-CAfile "$cafile" \
                -in "$work/$name" 2>&1) || fail "$name does not verify: $(tail -n 3 <<< "$report")"
    grep -q 'Signature verification: ok' <<< "$report" \
        || fail "$name: no 'Signature verification: ok' in the verifier report"
    grep -qiE 'timestamp' <<< "$report" \
        || fail "$name carries no timestamp; it would stop verifying when the certificate expires"
    grep -qF "CN=$WOOTC_SIGN_PUBLISHER" <<< "$report" \
        || fail "$name is not signed by CN=$WOOTC_SIGN_PUBLISHER"
    cmp -s "$exe" "$work/$name" && fail "$name is byte-identical after signing"
    echo "signed and verified $name"
done

for exe in "${exes[@]}"; do
    mv -f "$work/$(basename "$exe")" "$exe"
done
emit signed
