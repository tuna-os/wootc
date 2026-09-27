#!/usr/bin/env bash
# Produce a portable plain-file linux/amd64 OCI bundle for offline deployment.
# Prerequisites: skopeo, jq, and wootc-json-check. Build the latter with:
# go build -o /usr/local/bin/wootc-json-check payload/json-check/main.go
set -Eeuo pipefail
IMAGE=${1:?usage: make-bundle.sh image-ref exclusive-output-directory}
OUT=${2:?usage: make-bundle.sh image-ref exclusive-output-directory}
command -v skopeo >/dev/null
command -v wootc-json-check >/dev/null
[[ ! -e "$OUT" ]] || { echo 'output already exists; refuse mixed bundle' >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
mkdir -m 700 "$OUT"
# Preserve source root bytes before platform selection. Raw inspect writes
# exactly the received manifest bytes (skopeo inspect.go raw-output path).
source "$(dirname "$0")/../deployer/offline-bundle.sh"
REGISTRY_IMAGE=${IMAGE#docker://}
ROOT_RAW="$OUT/source.raw"
(set -o pipefail; timeout 120 skopeo inspect --raw "docker://$REGISTRY_IMAGE" | head -c 1048577 > "$ROOT_RAW")
wootc_bundle_json "$ROOT_RAW" 1048576
SOURCE_DIGEST="sha256:$(sha256sum "$ROOT_RAW" | cut -d ' ' -f1)"
if [[ "$REGISTRY_IMAGE" == *@* ]]; then
    [[ ${REGISTRY_IMAGE##*@} == "$SOURCE_DIGEST" ]] || { echo 'source root digest differs from selection' >&2; exit 1; }
fi
timeout 1800 skopeo --override-os linux --override-arch amd64 copy --preserve-digests \
    "docker://$REGISTRY_IMAGE" "oci:$OUT/oci:wootc"
DIGEST=$(jq -er '.manifests | select(length == 1) | .[0].digest' "$OUT/oci/index.json")
cp "$ROOT_RAW" "$OUT/oci/blobs/sha256/${SOURCE_DIGEST#sha256:}"
rm "$ROOT_RAW"
REPOSITORY=${REGISTRY_IMAGE%@*}
[[ ${REPOSITORY##*/} != *:* ]] || REPOSITORY=${REPOSITORY%:*}
FETCH_COUNT=0
FETCH_STARTED=$SECONDS
fetch_selected_metadata() {
    local digest=$1 depth=$2 path media rows child bytes child_media remaining
    FETCH_COUNT=$((FETCH_COUNT+1))
    [[ "$depth" -le 8 && "$FETCH_COUNT" -le 64 ]] || return 1
    remaining=$((600-(SECONDS-FETCH_STARTED)))
    [[ "$remaining" -gt 0 ]] || return 1
    [[ "$remaining" -le 120 ]] || remaining=120
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    path="$OUT/oci/blobs/sha256/${digest#sha256:}"
    if [[ ! -f "$path" ]]; then
        (set -o pipefail; timeout "$remaining" skopeo inspect --raw "docker://$REPOSITORY@$digest" | head -c 1048577 > "$path") || return 1
    fi
    wootc_bundle_json "$path" 1048576 || return 1
    wootc_bundle_blob "$OUT/oci" "$digest" "$(stat -c %s "$path")" || return 1
    media=$(jq -r '.mediaType' "$path") || return 1
    case "$media" in
        application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
            jq -e '(.manifests | type) == "array" and (.manifests | length) <= 64' "$path" >/dev/null || return 1
            rows=$(jq -r '.manifests[] | select((.platform.os == "linux" and .platform.architecture == "amd64" and (.platform.variant // "") == "") or (.platform == null and (.mediaType == "application/vnd.oci.image.index.v1+json" or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"))) | [.digest,.size,.mediaType] | @tsv' "$path") || return 1
            [[ -n "$rows" ]] || return 1
            while IFS=$'\t' read -r child bytes child_media; do
                fetch_selected_metadata "$child" "$((depth+1))" || return 1
                wootc_bundle_blob "$OUT/oci" "$child" "$bytes" || return 1
                [[ $(jq -r .mediaType "$OUT/oci/blobs/sha256/${child#sha256:}") == "$child_media" ]] || return 1
            done <<< "$rows"
            ;;
    esac
}
fetch_selected_metadata "$SOURCE_DIGEST" 0
SIZE_BYTES=$(du -sb "$OUT/oci" | cut -f1)
jq -n --arg image "$IMAGE" --arg digest "$DIGEST" --arg sourceDigest "$SOURCE_DIGEST" --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson bytes "$SIZE_BYTES" '{image:$image,digest:$digest,sourceDigest:$sourceDigest,storeBytes:$bytes,createdAt:$created,format:"oci"}' > "$OUT/bundle.json"
# shellcheck disable=SC1091
source "$(dirname "$0")/../deployer/offline-bundle.sh"
wootc_bundle_validate "$OUT" "$IMAGE" >/dev/null
printf 'Verified OCI bundle: %s (%s)\n' "$IMAGE" "$DIGEST"
