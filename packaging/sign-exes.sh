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
#   WOOTC_SIGN_CAFILE      CA bundle for verification (default: system)
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
# JSIGN and OSSLSIGNCODE name the commands (tests replace them).
set -euo pipefail

channel=${1:?usage: sign-exes.sh <channel> <assets-dir>}
assets=${2:?usage: sign-exes.sh <channel> <assets-dir>}
JSIGN=${JSIGN:-jsign}
OSSLSIGNCODE=${OSSLSIGNCODE:-osslsigncode}

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

for var in WOOTC_SIGN_KEYSTORE WOOTC_SIGN_ALIAS WOOTC_SIGN_STOREPASS WOOTC_SIGN_PUBLISHER; do
    [ -n "${!var:-}" ] || fail "$var is empty while WOOTC_SIGN_STORETYPE is set"
done

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/wootc-authenticode.XXXXXX")
trap 'rm -rf "$work"' EXIT

args=(--storetype "$WOOTC_SIGN_STORETYPE" --keystore "$WOOTC_SIGN_KEYSTORE"
      --alias "$WOOTC_SIGN_ALIAS" --storepass env:WOOTC_SIGN_STOREPASS
      --alg SHA-256 --tsmode RFC3161)
if [ -n "${WOOTC_SIGN_CERTFILE:-}" ]; then args+=(--certfile "$WOOTC_SIGN_CERTFILE"); fi
if [ -n "${WOOTC_SIGN_TSAURL:-}" ]; then args+=(--tsaurl "$WOOTC_SIGN_TSAURL"); fi
cafile=${WOOTC_SIGN_CAFILE:-/etc/ssl/certs/ca-certificates.crt}

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
