#!/bin/sh
# Generic post-boot health check for the Phase-3 native system.
#
# Adapted from tuna-os/bootc-migrate tests/e2e-health.sh at
# f05f92d110b64228939defe45c772961d592ff8a. The runner sends this file to
# /bin/sh through QGA; keep it POSIX-sh compatible.
#
# `baseline` runs read-only in Phase 2 before graduation and prints a strict
# record for the host runner to retain. `check` receives that record after the
# native boot. No guest-side staging is needed from the confined QGA process.
#
# Exit status: 0 when every check passes, 1 otherwise. Every check runs before
# exit so a single expensive VM boot reports all observed product failures.
set -u
LC_ALL=C
export LC_ALL

capture_baseline() {
    _health_tmp=$(mktemp -d) || return 1
    trap 'rm -rf "$_health_tmp"' EXIT HUP INT TERM

    if ! _health_dm=$(systemctl show -p Id --value display-manager.service 2>/dev/null); then
        echo "could not capture the Phase-2 display manager" >&2
        return 1
    fi

    _health_selinux=not-enforcing
    : > "$_health_tmp/label-baseline"
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
        _health_selinux=enforcing
        if ! restorecon -Rnv /etc /var/home > "$_health_tmp/restorecon" 2> "$_health_tmp/restorecon.err"; then
            cat "$_health_tmp/restorecon.err" >&2
            echo "could not capture the Phase-2 SELinux label baseline" >&2
            return 1
        fi
        sed -n 's/^Would relabel \([^ ]*\) from.*/\1/p' "$_health_tmp/restorecon" \
            | sort -u > "$_health_tmp/label-baseline" || return 1
    fi

    printf 'SCHEMA=1\nDISPLAY_MANAGER=%s\nSELINUX=%s\n' "$_health_dm" "$_health_selinux"
    sed 's/^/LABEL=/' "$_health_tmp/label-baseline"
}

case "${1:-check}" in
    baseline)
        capture_baseline
        exit $?
        ;;
    check) ;;
    *)
        echo "usage: phase3-health.sh [baseline|check]" >&2
        exit 2
        ;;
esac

fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "OK: $*"; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT HUP INT TERM

baseline_payload=${2:-}
printf '%s\n' "$baseline_payload" > "$work/baseline"
if [ "$(grep -c '^SCHEMA=1$' "$work/baseline")" -ne 1 ] \
    || [ "$(grep -c '^DISPLAY_MANAGER=[A-Za-z0-9_.@:-]*$' "$work/baseline")" -ne 1 ] \
    || [ "$(grep -Ec '^SELINUX=(enforcing|not-enforcing)$' "$work/baseline")" -ne 1 ] \
    || grep -Ev '^(SCHEMA=1|DISPLAY_MANAGER=[A-Za-z0-9_.@:-]*|SELINUX=(enforcing|not-enforcing)|LABEL=/[^[:cntrl:]]*)$' \
        "$work/baseline" >/dev/null; then
    bad "the pre-graduation health baseline is unavailable or invalid"
    expected_dm=
    baseline_selinux=unknown
    : > "$work/label-baseline"
else
    expected_dm=$(sed -n 's/^DISPLAY_MANAGER=//p' "$work/baseline")
    baseline_selinux=$(sed -n 's/^SELINUX=//p' "$work/baseline")
    sed -n 's/^LABEL=//p' "$work/baseline" | sort -u > "$work/label-baseline"
fi

# Units that fail in the CI VM for reasons unrelated to graduation. Every
# future entry needs a reason beside it; there are intentionally none today.
DEFAULT_ALLOWED_FAILED_UNITS=""
allowed="$DEFAULT_ALLOWED_FAILED_UNITS"

# ---- 1. Boot completed ------------------------------------------------------
state=$(timeout 300 systemctl is-system-running --wait 2>/dev/null)
echo "  system state: ${state:-<none>}"
case "$state" in
    running) ok "boot completed (running)" ;;
    degraded) echo "  boot completed degraded; failed units are checked below" ;;
    *) bad "boot did not complete (systemctl is-system-running: ${state:-<none>})" ;;
esac

# ---- 2. Failed units ---------------------------------------------------------
describe_failed_unit() {
    _health_unit=$1
    echo "    --- journal of $_health_unit (this boot)"
    journalctl -b --no-pager -o short-monotonic -n 40 -u "$_health_unit" 2>&1 | sed 's/^/      /'
    echo "    --- bus activation messages that name ${_health_unit%.service}"
    journalctl -b --no-pager -o short-monotonic -u dbus-broker.service -u dbus.service 2>&1 \
        | grep -iF "${_health_unit%.service}" | tail -15 | sed 's/^/      /'
    _health_since=$(systemctl show -p InactiveExitTimestamp --value "$_health_unit" 2>/dev/null)
    if [ -n "$_health_since" ]; then
        echo "    --- warnings from every unit while $_health_unit was starting (since $_health_since)"
        journalctl -b --no-pager -o short-monotonic -p warning --since "$_health_since" 2>&1 \
            | head -40 | sed 's/^/      /'
    fi
}

failed_units=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')
unexpected=0
for unit in $failed_units; do
    permitted=0
    set -f
    for pattern in $allowed; do
        # shellcheck disable=SC2254 # patterns are globs on purpose
        case "$unit" in $pattern) permitted=1 ;; esac
    done
    set +f
    if [ "$permitted" = 1 ]; then
        echo "  failed unit on the allowlist: $unit"
    else
        unexpected=1
        bad "unit failed: $unit"
        systemctl status --no-pager --lines 15 "$unit" 2>&1 | sed 's/^/    /'
        describe_failed_unit "$unit"
    fi
done
[ "$unexpected" = 0 ] && ok "no unexpected failed units"

# ---- 3. System bus and logind ----------------------------------------------
if systemctl is-active --quiet dbus.service || systemctl is-active --quiet dbus-broker.service; then
    ok "system D-Bus is active"
else
    bad "system D-Bus (dbus.service / dbus-broker.service) is not active"
fi
busctl list --system >/dev/null 2>&1 || bad "the system bus does not answer (busctl list)"
if loginctl list-sessions >/dev/null 2>&1; then
    ok "logind answers over the bus"
else
    bad "logind does not answer (loginctl list-sessions)"
fi

# ---- 4. Graphical session ----------------------------------------------------
default_target=$(systemctl get-default 2>/dev/null)
echo "  default target: ${default_target:-<none>}"
if [ "$default_target" = graphical.target ]; then
    if systemctl is-active --quiet graphical.target; then
        ok "graphical.target reached"
    else
        bad "graphical.target was not reached"
    fi
    dm=$(systemctl show -p Id --value display-manager.service 2>/dev/null)
    echo "  display manager: ${dm:-<none>}"
    if [ -z "$dm" ] || [ "$dm" = display-manager.service ]; then
        bad "no display manager is enabled for the graphical target"
    elif systemctl is-active --quiet display-manager.service; then
        ok "display manager $dm is active"
    else
        bad "display manager $dm is not active"
        systemctl status --no-pager --lines 15 display-manager.service 2>&1 | sed 's/^/    /'
    fi
else
    dm=
fi
if [ -n "$expected_dm" ] && [ "$expected_dm" != display-manager.service ]; then
    if [ "$dm" != "$expected_dm" ]; then
        bad "display manager is ${dm:-<none>}, expected $expected_dm from Phase 2"
    fi
fi

# ---- 5. Accounts the target image declares ----------------------------------
missing=""
for sysusers_file in /usr/lib/sysusers.d/*.conf; do
    [ -f "$sysusers_file" ] || continue
    override=/etc/sysusers.d/$(basename "$sysusers_file")
    [ -f "$override" ] && sysusers_file=$override
    grep -Ev '^[[:space:]]*(#|$)' "$sysusers_file" > "$work/sysusers" || :
    while read -r type name id _; do
        case "$name" in *%*|"") continue ;; esac
        case "$type" in
            u|u!)
                getent passwd "$name" >/dev/null || missing="$missing user:$name"
                case "$id" in
                    *:*) primary=${id#*:}
                         getent group "$primary" >/dev/null || missing="$missing group:$primary" ;;
                    *) getent group "$name" >/dev/null || missing="$missing group:$name" ;;
                esac
                ;;
            g) getent group "$name" >/dev/null || missing="$missing group:$name" ;;
        esac
    done < "$work/sysusers"
done
if [ -n "$missing" ]; then
    bad "accounts the target image declares are missing:$missing"
else
    ok "every user and group in the target's sysusers.d resolves"
fi

# ---- 6. SELinux --------------------------------------------------------------
current_selinux=not-enforcing
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    current_selinux=enforcing
fi
if [ "$baseline_selinux" = enforcing ] && [ "$current_selinux" != enforcing ]; then
    bad "SELinux was enforcing before graduation but is not enforcing on the native system"
fi
if [ "$current_selinux" = enforcing ]; then
    echo "  SELinux: Enforcing"
    denials=$( { journalctl -b --no-pager -o cat 2>/dev/null
                 ausearch -m AVC,USER_AVC -ts boot 2>/dev/null; } \
               | grep -E 'avc: +denied' | sort -u)
    if [ -n "$denials" ]; then
        echo "  AVC denials this boot:"
        printf '%s\n' "$denials" | head -20 | sed 's/^/    /'
    fi
    if printf '%s\n' "$denials" | grep -q 'tcontext=[^ ]*:unlabeled_t:'; then
        bad "SELinux denied access to unlabeled files"
    else
        ok "no SELinux denials against unlabeled files"
    fi

    if ! restorecon -Rnv /etc /var/home > "$work/restorecon" 2> "$work/restorecon.err"; then
        sed 's/^/    /' "$work/restorecon.err"
        bad "could not inspect SELinux labels under /etc and /var/home"
        : > "$work/mislabeled"
    else
        sed -n 's/^Would relabel \([^ ]*\) from.*/\1/p' "$work/restorecon" \
            | sort -u > "$work/mislabeled"
    fi
    comm -23 "$work/mislabeled" "$work/label-baseline" > "$work/new-mislabeled"
    old_count=$(comm -12 "$work/mislabeled" "$work/label-baseline" | wc -l)
    echo "  $old_count mislabeled path(s) were already present in Phase 2 (not counted)"


    if [ -s "$work/new-mislabeled" ]; then
        new_count=$(wc -l < "$work/new-mislabeled")
        bad "$new_count path(s) under /etc or /var/home gained incorrect SELinux labels during graduation"
        head -20 "$work/new-mislabeled" | while IFS= read -r path; do
            grep -F "$path from" "$work/restorecon" | head -1 | sed 's/^/    /'
        done
    else
        ok "graduation introduced no SELinux mislabels under /etc or /var/home"
    fi
else
    echo "  SELinux: not enforcing; label checks skipped"
fi

exit "$fail"
