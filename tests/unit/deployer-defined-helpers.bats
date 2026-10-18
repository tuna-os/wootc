#!/usr/bin/env bats
# deploy.sh runs under `set -e`: a call to a helper it never defines
# ("command not found") aborts the deploy instead of logging. Two
# best-effort branches once called an undefined `warn`.

DEPLOY="$BATS_TEST_DIRNAME/../../payload/deployer/deploy.sh"

@test "deploy.sh calls only the log helpers it defines" {
    defined=$(grep -oE '^[a-z_]+\(\) *\{' "$DEPLOY" | sed 's/().*//' | sort -u)
    for helper in warn info warning debug; do
        if grep -qE "^[[:space:]]*${helper}[[:space:]]+\"" "$DEPLOY"; then
            printf '%s\n' "$defined" | grep -qx "$helper" ||
                { echo "deploy.sh calls undefined helper '$helper'"; return 1; }
        fi
    done
}
