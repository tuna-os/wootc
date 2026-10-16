# shellcheck shell=bash
# Arguments: storage directory and number of runs to keep. No work on source.
prune_old_artifacts() {
    local base="$1/artifacts" keep="${2:-3}"
    case "$keep" in ''|*[!0-9]*) return 2 ;; esac
    [ "$keep" -ge 1 ] || return 2
    [ -d "$base" ] || return 0
    local evidence="$base/.evidence" ordered d name files file position=0
    local directories=("$base"/*/)
    [ -d "${directories[0]}" ] || return 0
    # Preserve the existing order: newest directory modification time first.
    if ! ordered=$(ls -1dt -- "${directories[@]}"); then
        printf '[FAIL] Cannot enumerate artifact runs; none were deleted\n' >&2
        return 1
    fi
    mkdir -p "$evidence" || return 1
    while IFS= read -r d; do
        [ "$d" != "$evidence/" ] || continue
        position=$((position + 1))
        [ "$position" -gt "$keep" ] || continue
        name=$(basename "$d")
        mkdir -p "$evidence/$name" || return 1
        files=$(mktemp "$evidence/.files.XXXXXX") || return 1
        # Complete enumeration before any copy or deletion.
        if ! find "$d" -maxdepth 1 -type f \( -name '*.log' -o -name 'qemu.pty' -o -name '*.txt' -o -name '*.json' -o -name '*.jsonl' \)             -size -50M -print0 > "$files"; then
            rm -f -- "$files"
            printf '[FAIL] Cannot enumerate evidence for %s; source retained\n' "$name" >&2
            return 1
        fi
        while IFS= read -r -d '' file; do
            if ! cp -- "$file" "$evidence/$name/" || ! cmp -s -- "$file" "$evidence/$name/${file##*/}"; then
                rm -f -- "$files"
                printf '[FAIL] Cannot preserve evidence for %s; source retained\n' "$name" >&2
                return 1
            fi
        done < "$files"
        rm -f -- "$files" || return 1
        rm -rf -- "$d" || return 1
    done <<< "$ordered"
}
