#!/usr/bin/env bash
# OCI metadata is a byte pin, not a signature or publisher trust assertion.
wootc_bundle_json() {
    local file=$1 limit=$2
    [[ -f "$file" && ! -L "$file" && $(stat -c %s "$file") -le "$limit" ]] || return 1
    wootc-json-check "$limit" < "$file"
}

wootc_bundle_capture() {
    local limit=$1 output result
    shift
    output=$(mktemp) || return 1
    # Read at most bound+1 bytes; pipeline status and the extra byte expose
    # truncation. Do not limit the importer's own database file writes.
    if (set -o pipefail; "$@" | head -c "$((limit+1))" > "$output") &&
        [[ $(stat -c %s "$output") -le "$limit" ]]; then
        result=$(cat "$output")
        rm -f "$output"
        printf '%s' "$result"
    else
        rm -f "$output"
        return 1
    fi
}

wootc_bundle_blob() {
    local layout=$1 digest=$2 bytes=$3 path actual
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ && "$bytes" =~ ^[0-9]+$ ]] || return 1
    path="$layout/blobs/sha256/${digest#sha256:}"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    [[ $(stat -c %s "$path") == "$bytes" ]] || return 1
    actual=$(sha256sum "$path") || return 1
    [[ ${actual%% *} == "${digest#sha256:}" ]]
}

wootc_bundle_walk() {
    local layout=$1 digest=$2 bytes=$3 depth=$4 expected_media=${5-} path media rows child child_bytes child_media
    [[ "$depth" -le 8 ]] || return 1
    WOOTC_BUNDLE_NODES=$((WOOTC_BUNDLE_NODES+1))
    [[ "$WOOTC_BUNDLE_NODES" -le 64 && "$bytes" -le 1048576 ]] || return 1
    wootc_bundle_blob "$layout" "$digest" "$bytes" || return 1
    path="$layout/blobs/sha256/${digest#sha256:}"
    wootc_bundle_json "$path" 1048576 || return 1
    jq -e '.schemaVersion == 2' "$path" >/dev/null || return 1
    media=$(jq -r '.mediaType // empty' "$path") || return 1
    [[ -z "$expected_media" || "$expected_media" == "$media" ]] || return 1
    case "$media" in
        application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
            jq -e '(.manifests | type) == "array" and (.manifests | length) <= 64' "$path" >/dev/null || return 1
            rows=$(jq -r '.manifests[] | select((.platform.os == "linux" and .platform.architecture == "amd64" and (.platform.variant // "") == "") or (.platform == null and (.mediaType == "application/vnd.oci.image.index.v1+json" or .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"))) | [.digest,.size,.mediaType] | @tsv' "$path") || return 1
            [[ -n "$rows" ]] || return 1
            while IFS=$'\t' read -r child child_bytes child_media; do
                [[ "$child_bytes" =~ ^[0-9]+$ ]] || return 1
                wootc_bundle_walk "$layout" "$child" "$child_bytes" "$((depth+1))" "$child_media" || return 1
            done <<< "$rows"
            ;;
        application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json)
            printf '%s\n' "$digest" ;;
        *) return 1 ;;
    esac
}

wootc_bundle_validate() {
    local bundle=$1 selected=$2 layout="$1/oci" digest descriptor bytes manifest kind config layer source_digest source_path leaves
    for kind in "$bundle" "$layout" "$layout/blobs" "$layout/blobs/sha256"; do
        [[ -d "$kind" && ! -L "$kind" ]] || return 1
    done
    for kind in bundle.json oci/index.json oci/oci-layout; do
        [[ -f "$bundle/$kind" && ! -L "$bundle/$kind" && $(stat -c %s "$bundle/$kind") -le 65536 ]] || return 1
    done
    wootc_bundle_json "$bundle/bundle.json" 65536 || return 1
    wootc_bundle_json "$layout/index.json" 65536 || return 1
    wootc_bundle_json "$layout/oci-layout" 65536 || return 1
    jq -e --arg selected "$selected" '.image == $selected and (.digest | test("^sha256:[0-9a-f]{64}$"))' "$bundle/bundle.json" >/dev/null || return 1
    jq -e '.imageLayoutVersion == "1.0.0"' "$layout/oci-layout" >/dev/null || return 1
    digest=$(jq -r '.digest' "$bundle/bundle.json") || return 1
    source_digest=$(jq -r '.sourceDigest // .digest' "$bundle/bundle.json") || return 1
    [[ "$source_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
    if [[ "$selected" == *@* ]]; then
        [[ ${selected##*@} == "$source_digest" ]] || return 1
    fi
    source_path="$layout/blobs/sha256/${source_digest#sha256:}"
    [[ -f "$source_path" && ! -L "$source_path" ]] || return 1
    WOOTC_BUNDLE_NODES=0
    leaves=$(wootc_bundle_walk "$layout" "$source_digest" "$(stat -c %s "$source_path")" 0) || return 1
    [[ "$leaves" == "$digest" ]] || return 1
    jq -e --arg digest "$digest" '.schemaVersion == 2 and (.manifests | length) == 1 and .manifests[0].digest == $digest and (.manifests[0].size | type) == "number" and .manifests[0].size >= 0 and (.manifests[0].size | floor) == .manifests[0].size' "$layout/index.json" >/dev/null || return 1
    bytes=$(jq -r '.manifests[0].size' "$layout/index.json") || return 1
    [[ "$bytes" -le 1048576 ]] || return 1
    wootc_bundle_blob "$layout" "$digest" "$bytes" || return 1
    manifest="$layout/blobs/sha256/${digest#sha256:}"
    wootc_bundle_json "$manifest" 1048576 || return 1
    jq -e '.schemaVersion == 2 and (.config.digest | type) == "string" and (.layers | type) == "array" and (.layers | length) <= 1024 and (.manifests == null) and .config.size <= 16777216 and ([.config] + .layers | all(.size >= 0 and .size <= 34359738368 and (.size | floor) == .size))' "$manifest" >/dev/null || return 1
    descriptor=$(jq -r '[.config] + .layers | .[] | [.digest, .size] | @tsv' "$manifest") || return 1
    while IFS=$'\t' read -r layer bytes; do
        wootc_bundle_blob "$layout" "$layer" "$bytes" || return 1
    done <<< "$descriptor"
    config=$(jq -r '.config.digest' "$manifest") || return 1
    wootc_bundle_json "$layout/blobs/sha256/${config#sha256:}" 16777216 || return 1
    jq -e '.os == "linux" and .architecture == "amd64"' "$layout/blobs/sha256/${config#sha256:}" >/dev/null || return 1
    printf '%s\t%s\n' "$digest" "$config"
}

wootc_bundle_ingest() {
    local bundle=$1 selected=$2 identity digest config imported inspected
    identity=$(wootc_bundle_validate "$bundle" "$selected") || return 1
    IFS=$'\t' read -r digest config <<< "$identity"
    imported=$(wootc_bundle_capture 4096 timeout 1800 podman pull -q "oci:$bundle/oci") || return 1
    [[ "$imported" =~ ^(sha256:)?[0-9a-f]{64}$ ]] || return 1
    inspected=$(wootc_bundle_capture 1048576 timeout 60 podman image inspect "$imported") || return 1
    printf '%s' "$inspected" | wootc-json-check 1048576 || return 1
    jq -e --arg digest "$digest" --arg config "$config" 'length == 1 and .[0].Digest == $digest and (.[0].Id | sub("^sha256:"; "")) == ($config | sub("^sha256:"; ""))' <<< "$inspected" >/dev/null || return 1
    [[ $(wootc_bundle_validate "$bundle" "$selected") == "$identity" ]] || return 1
    # After tag publication is attempted, local reference identity is unknown
    # until its successful exact readback. The caller must stop on status2.
    timeout 60 podman tag "$imported" "$selected" || return 2
    inspected=$(wootc_bundle_capture 1048576 timeout 60 podman image inspect "$selected") || return 2
    printf '%s' "$inspected" | wootc-json-check 1048576 || return 2
    jq -e --arg digest "$digest" --arg config "$config" 'length == 1 and .[0].Digest == $digest and (.[0].Id | sub("^sha256:"; "")) == ($config | sub("^sha256:"; ""))' <<< "$inspected" >/dev/null || return 2
}
