#!/usr/bin/env bash
# wootc-flatpak-install — install the Linux equivalents of the Windows apps
# the user confirmed in the installer (SPEC §4.3) into the deployed system.
#
# fisherman's recipe `flatpaks` list cannot do this: it copies the HOST's
# /var/lib/flatpak and downloads nothing, and the deployer initramfs has no
# Flatpaks. So the deployer installs each app itself, with the installed
# image's own flatpak, into the target's system installation.
#
# deploy.sh sources this file and calls install_selected_flatpaks once the
# target is mounted. The functions take their paths as arguments and print
# through the caller's log/err. Tests source this file and replace
# flatpak_in_image and flatpak_image_ready.
#
#   flatpak_target_var        the /var the installed system boots with
#   install_selected_flatpaks read apps.json, install, label, write receipts

WOOTC_FLATHUB_URL=https://dl.flathub.org/repo/flathub.flatpakrepo

# Set by install_selected_flatpaks for the runner below.
FLATPAK_IMAGE=""
FLATPAK_DIR=""
FLATPAK_TMP=""

# flatpak_target_var <sysroot> <deployment root>
# Print the /var the installed system mounts at boot, resolved the way
# fisherman resolves it: the ostree stateroot's var, the composefs
# state/os/default/var, otherwise the deployment's own var.
flatpak_target_var() {
    local sysroot=$1 dep=$2
    if [[ "$dep" == */ostree/deploy/*/deploy/* ]]; then
        printf '%s\n' "${dep%/deploy/*}/var"
    elif [[ -d "$sysroot/state/deploy" ]]; then
        printf '%s\n' "$sysroot/state/os/default/var"
    else
        printf '%s\n' "$dep/var"
    fi
}

# flatpak_in_image <program> [arg...]
# Run <program> in the installed image with the target's Flatpak
# installation at /var/lib/flatpak. --privileged: flatpak runs its install
# triggers under bubblewrap.
#
# /var/tmp is a scratch directory of the deployer's. A bootc image may ship
# an empty /var (bootc's var-tmpfiles rule: tmpfiles.d creates /var/tmp at
# boot), and libostree decompresses each LZMA static-delta part into an
# O_TMPFILE in $TMPDIR or /var/tmp. Without it every Flathub runtime pull
# fails with "open(O_TMPFILE): No such file or directory" (bluefin:stable).
flatpak_in_image() {
    timeout "${WOOTC_FLATPAK_STEP_TIMEOUT:-1800}" podman run --rm --network=host --privileged \
        --security-opt label=disable \
        -v "$FLATPAK_DIR:/var/lib/flatpak" \
        -v "$FLATPAK_TMP:/var/tmp" \
        --entrypoint "$1" "$FLATPAK_IMAGE" "${@:2}"
}

flatpak_image_ready() {
    timeout 120 podman image exists "$FLATPAK_IMAGE" 2>/dev/null
}

# flatpak_reason <file> — the last non-empty line of a command's output, on
# one line and bounded, for a receipt or a serial line.
flatpak_reason() {
    local line
    line=$(awk 'NF { last = $0 } END { print last }' "$1" 2>/dev/null | tr -d '\r' | cut -c1-300)
    printf '%s\n' "${line:-no output}"
}

# flatpak_fail <id> <reason> — record an app that install_selected_flatpaks
# could not install, in that function's failed_ids/failed_reasons.
flatpak_fail() {
    failed_ids+=("$1")
    failed_reasons+=("$2")
    err "  wootc: flatpak FAILED: $1: $2"
}

# flatpak_backoff <attempt> <attempts> — wait before the next attempt, if any.
flatpak_backoff() {
    if (( $1 < $2 )); then
        sleep $(( $1 * ${WOOTC_FLATPAK_BACKOFF:-15} ))
    fi
}

# install_selected_flatpaks <apps.json> <app map> <image> <target var> <target etc> <NTFS receipt>
#
# <apps.json> is the Windows engine's handoff:
#   {"schemaVersion":1,"remote":"flathub","remoteUrl":"…","flatpaks":["id",…]}
# Only IDs in <app map> (app-flatpaks.json) are installed. Each app is
# installed with bounded retries and FAILS SOFT: an app that cannot be
# installed never stops the others or the deploy. An app counts as installed
# only when `flatpak info --system <id>` finds it in the target afterwards;
# the exit status of `flatpak install` is not the evidence.
#
# Writes <target etc>/wootc/flatpaks.list (the requested IDs), and the receipt
#   {"schemaVersion":1,"requested":[…],"installed":[…],"failed":[{"id","error"}]}
# to <target etc>/wootc/flatpak-install.json and to <NTFS receipt>.
# Returns 0 whatever happened to the apps.
install_selected_flatpaks() {
    local apps_json=$1 app_map=$2 image=$3 target_var=$4 target_etc=$5 ntfs_receipt=$6
    local attempts=${WOOTC_FLATPAK_ATTEMPTS:-3}
    local remote url id attempt reason out allowed context receipt i failed_json="[]"
    local -a requested=() pending=() installed=() failed_ids=() failed_reasons=()

    if [[ ! -f "$apps_json" ]]; then
        log "  wootc: no app selection at ${apps_json}; no Flatpaks to install"
        return 0
    fi
    if ! jq -e '.schemaVersion == 1 and (.flatpaks | type == "array") and all(.flatpaks[]; type == "string")' \
            "$apps_json" >/dev/null 2>&1; then
        err "  [WARN] wootc: ${apps_json} is not a schemaVersion 1 app selection; no Flatpaks installed"
        return 0
    fi
    remote=$(jq -r '.remote // "flathub"' "$apps_json")
    url=$(jq -r '.remoteUrl // empty' "$apps_json")
    url=${url:-$WOOTC_FLATHUB_URL}
    # Unique, non-empty, one per line: control characters become '?', which
    # the ID check below then refuses.
    while IFS= read -r id; do
        requested+=("$id")
    done < <(jq -r '.flatpaks | map(select(length > 0) | gsub("[[:cntrl:]]"; "?"))
                    | reduce .[] as $id ([]; if index([$id]) then . else . + [$id] end) | .[]' "$apps_json")

    FLATPAK_IMAGE=$image
    FLATPAK_DIR="$target_var/lib/flatpak"
    FLATPAK_TMP=""
    allowed=$(jq -r '.apps[].flatpak' "$app_map" 2>/dev/null || true)

    for id in "${requested[@]}"; do
        if [[ ! "$id" =~ ^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$ ]]; then
            flatpak_fail "$id" "not a Flatpak application ID"
        elif [[ -z "$allowed" ]]; then
            flatpak_fail "$id" "the wootc app map ${app_map} is missing or unreadable"
        elif ! grep -qxF -- "$id" <<<"$allowed"; then
            flatpak_fail "$id" "not in the wootc app map"
        else
            pending+=("$id")
        fi
    done

    if (( ${#pending[@]} > 0 )); then
        log "  wootc: installing ${#pending[@]} Flatpak app(s) from ${remote} into ${FLATPAK_DIR}"
        out="${TMPDIR:-/tmp}/wootc-flatpak.out"
        reason=""
        if [[ ! "$remote" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ || ! "$url" =~ ^https://[^[:space:]]+$ ]]; then
            reason="invalid remote '${remote}' at '${url}'"
        elif ! mkdir -p "$FLATPAK_DIR"; then
            reason="cannot create ${FLATPAK_DIR}"
        elif ! FLATPAK_TMP=$(mktemp -d "${TMPDIR:-/var/tmp}/wootc-flatpak-tmp.XXXXXX") ||
             ! chmod 1777 "$FLATPAK_TMP"; then
            reason="cannot create a /var/tmp for flatpak under ${TMPDIR:-/var/tmp}"
        elif ! flatpak_image_ready; then
            reason="the installed image ${image} is not in the deployer's container store"
        else
            for (( attempt = 1; attempt <= attempts; attempt++ )); do
                if flatpak_in_image flatpak remote-add --system --if-not-exists "$remote" "$url" >"$out" 2>&1; then
                    reason=""
                    break
                fi
                reason="cannot add the ${remote} remote: $(flatpak_reason "$out")"
                flatpak_backoff "$attempt" "$attempts"
            done
        fi
        if [[ -n "$reason" ]]; then
            for id in "${pending[@]}"; do flatpak_fail "$id" "$reason"; done
            pending=()
        fi
        for id in "${pending[@]}"; do
            for (( attempt = 1; attempt <= attempts; attempt++ )); do
                reason=""
                flatpak_in_image flatpak install --system --noninteractive -y "$remote" "$id" >"$out" 2>&1 \
                    || reason=$(flatpak_reason "$out")
                if flatpak_in_image flatpak info --system "$id" >/dev/null 2>&1; then
                    reason=""
                    break
                fi
                reason=${reason:-"flatpak install exited 0 but flatpak info --system does not find it"}
                log "  wootc: flatpak ${id}: attempt ${attempt}/${attempts} failed: ${reason}"
                flatpak_backoff "$attempt" "$attempts"
            done
            if [[ -z "$reason" ]]; then
                installed+=("$id")
                log "  wootc: flatpak installed: ${id}"
            else
                flatpak_fail "$id" "$reason"
            fi
        done
        rm -f "$out"
    fi

    # Files written from the initramfs carry no SELinux label, and an
    # enforcing first boot cannot run unlabeled app files. Apply the image's
    # own file contexts with setfiles (restorecon is a no-op on the deployer
    # kernel, see the relabel block in deploy.sh), then read a label back.
    if (( ${#installed[@]} > 0 )); then
        # shellcheck disable=SC2016  # expanded by the image's sh
        context=$(flatpak_in_image sh -c '
            for fc in /etc/selinux/*/contexts/files/file_contexts; do
                [ -f "$fc" ] && break
            done
            [ -f "$fc" ] || { echo "no SELinux file_contexts in the image"; exit 3; }
            command -v setfiles >/dev/null 2>&1 || { echo "no setfiles in the image"; exit 4; }
            setfiles -F "$fc" /var/lib/flatpak 2>&1 || exit 5
            ls -Zd /var/lib/flatpak/repo' 2>&1) || true
        context=$(printf '%s\n' "$context" | awk 'NF { last = $0 } END { print last }' | cut -c1-300)
        if [[ "$context" == *:object_r:* ]]; then
            log "  wootc: flatpak SELinux labels applied (${context})"
        elif grep -q '^SELINUX=enforcing' "$target_etc/selinux/config" 2>/dev/null; then
            for id in "${installed[@]}"; do
                flatpak_fail "$id" "installed, but SELinux labels could not be applied (${context:-no output}); it cannot run under enforcing SELinux"
            done
            installed=()
        else
            log "  wootc: flatpak SELinux labels not applied (${context:-no output}); target SELinux is not enforcing"
        fi
    fi
    if [[ -n "$FLATPAK_TMP" ]]; then
        rm -rf "$FLATPAK_TMP"
        FLATPAK_TMP=""
    fi

    for i in "${!failed_ids[@]}"; do
        failed_json=$(jq -c --arg id "${failed_ids[$i]}" --arg error "${failed_reasons[$i]}" \
            '. + [{id: $id, error: $error}]' <<<"$failed_json")
    done
    receipt=$(jq -n --argjson failed "$failed_json" \
        --argjson requested "$(jq -nc '$ARGS.positional' --args "${requested[@]}")" \
        --argjson installed "$(jq -nc '$ARGS.positional' --args "${installed[@]}")" \
        '{schemaVersion: 1, requested: $requested, installed: $installed, failed: $failed}')

    if install -d -m 0755 "$target_etc/wootc" &&
       jq -r '.requested[]' <<<"$receipt" > "$target_etc/wootc/flatpaks.list" &&
       printf '%s\n' "$receipt" > "$target_etc/wootc/flatpak-install.json"; then
        log "  wootc: Flatpak receipt written to /etc/wootc/flatpak-install.json (${#installed[@]} installed, ${#failed_ids[@]} failed)"
    else
        err "  [WARN] wootc: could not write the Flatpak receipt into the target"
    fi
    if mkdir -p "${ntfs_receipt%/*}" 2>/dev/null && printf '%s\n' "$receipt" > "$ntfs_receipt"; then
        log "  wootc: Flatpak receipt written to ${ntfs_receipt}"
    else
        err "  [WARN] wootc: could not write the Flatpak receipt to ${ntfs_receipt}"
    fi
    return 0
}
