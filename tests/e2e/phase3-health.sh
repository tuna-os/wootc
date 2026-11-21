#!/bin/sh
# Generic post-boot health check for the Phase-3 native system.
#
# Adapted from tuna-os/bootc-migrate tests/e2e-health.sh at
# f05f92d110b64228939defe45c772961d592ff8a. Keep it POSIX-sh compatible.
#
# `baseline` runs read-only in Phase 2 before graduation, through QGA, and
# prints a strict record for the host runner to retain. `phase2-units` runs
# the failed-unit check in Phase 2, also through QGA. `check` receives the
# record after the native boot. It runs there from
# wootc-e2e-native-health.service (wootc-go-native), not through QGA: the
# confined agent on the enforcing native system cannot query systemd.
#
# Exit status: 0 when every check passes, 1 otherwise. Every check runs before
# exit so a single expensive VM boot reports all observed product failures.
set -u
LC_ALL=C
export LC_ALL

capture_baseline() {
    if ! _health_dm=$(systemctl show -p Id --value display-manager.service 2>/dev/null); then
        echo "could not capture the Phase-2 display manager" >&2
        return 1
    fi
    _health_selinux=not-enforcing
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
        _health_selinux=enforcing
    fi
    printf 'SCHEMA=1\nDISPLAY_MANAGER=%s\nSELINUX=%s\n' "$_health_dm" "$_health_selinux"
}

fail=0
bad() { echo "FAIL: $*"; fail=1; }
ok() { echo "OK: $*"; }

# Known failures: a reviewed list of exact unit names, never patterns. Each
# entry is "<unit> <issue URL> <when to remove it>". Any failed unit that is
# not on the list fails the check, in Phase 2 and on the native system.
# mcelog.service: bluefin:stable enables it, and mcelog exits 1 on AMD Zen
# ("AMD Processor family 25: mcelog does not support this processor"), the
# CPU of the hosted runners (probe 44843263310). It is the image's unit, not
# wootc's; the entry expires when the fix ships or on 2027-02-28.
# tuned.service: bluefin:stable's bootc-unified-storage.service runs `bootc
# image set-unified` during first boot (WantedBy=multi-user.target, After=
# local-fs.target only) and holds the ostree sysroot lock for minutes. TuneD's
# start calls `bootc loader-entries set-options-for-source`, waits on that
# lock and hits its start timeout (probe 44878928655: bootc core dump in
# glnx_make_lock_file). It is the image's ordering, not wootc's; utah moved
# the unit to a timer (projectbluefin/utah#1174). Same expiry.
KNOWN_FAILED_UNITS='
mcelog.service https://github.com/ublue-os/bluefin/issues/5197 remove-when-bluefin:stable-ships-the-fix-or-on-2027-02-28-whichever-is-first
tuned.service https://github.com/ublue-os/bluefin/issues/5201 remove-when-bluefin:stable-ships-the-fix-or-on-2027-02-28-whichever-is-first
'

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

check_failed_units() {
    _health_failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')
    _health_unexpected=0
    for _health_unit_name in $_health_failed; do
        _health_known=$(printf '%s\n' "$KNOWN_FAILED_UNITS" | awk -v u="$_health_unit_name" '$1 == u { print $2; exit }')
        if [ -n "$_health_known" ]; then
            echo "  failed unit on the known-failure list: $_health_unit_name ($_health_known)"
            systemctl status --no-pager --lines 5 "$_health_unit_name" 2>&1 | sed 's/^/    /'
        else
            _health_unexpected=1
            bad "unit failed: $_health_unit_name"
            systemctl status --no-pager --lines 15 "$_health_unit_name" 2>&1 | sed 's/^/    /'
            describe_failed_unit "$_health_unit_name"
        fi
    done
    [ "$_health_unexpected" = 0 ] && ok "no failed units outside the known-failure list"
}

case "${1:-check}" in
    baseline)
        capture_baseline
        exit $?
        ;;
    phase2-units)
        # The QGA client stops a guest command after 60 s, and Phase 2 can
        # still be booting for minutes (probe 44852542894: guest-exec timed
        # out in is-system-running --wait). Exit 3 while it boots; the
        # runner asks again.
        _health_state=$(timeout 45 systemctl is-system-running --wait 2>/dev/null)
        case "$_health_state" in
            ''|initializing|starting)
                echo "  Phase 2 is still booting (${_health_state:-no answer within 45 s})"
                exit 3 ;;
        esac
        check_failed_units
        exit "$fail"
        ;;
    check) ;;
    *)
        echo "usage: phase3-health.sh [baseline|phase2-units|check]" >&2
        exit 2
        ;;
esac

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT HUP INT TERM

baseline_payload=${2:-}
printf '%s\n' "$baseline_payload" > "$work/baseline"
if [ "$(grep -c '^SCHEMA=1$' "$work/baseline")" -ne 1 ] \
    || [ "$(grep -c '^DISPLAY_MANAGER=[A-Za-z0-9_.@:-]*$' "$work/baseline")" -ne 1 ] \
    || [ "$(grep -Ec '^SELINUX=(enforcing|not-enforcing)$' "$work/baseline")" -ne 1 ] \
    || grep -Ev '^(SCHEMA=1|DISPLAY_MANAGER=[A-Za-z0-9_.@:-]*|SELINUX=(enforcing|not-enforcing))$' \
        "$work/baseline" >/dev/null; then
    bad "the pre-graduation health baseline is unavailable or invalid"
    expected_dm=
    baseline_selinux=unknown
else
    expected_dm=$(sed -n 's/^DISPLAY_MANAGER=//p' "$work/baseline")
    baseline_selinux=$(sed -n 's/^SELINUX=//p' "$work/baseline")
fi

# ---- 1. Boot completed ------------------------------------------------------
state=$(timeout 300 systemctl is-system-running --wait 2>/dev/null)
echo "  system state: ${state:-<none>}"
case "$state" in
    running) ok "boot completed (running)" ;;
    degraded) echo "  boot completed degraded; failed units are checked below" ;;
    *) bad "boot did not complete (systemctl is-system-running: ${state:-<none>})" ;;
esac

# ---- 2. Failed units ---------------------------------------------------------
check_failed_units

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

    # Graduation applies the target policy to /etc and /var (wootc-go-native
    # runs setfiles), so the native system must have no mislabeled path there
    # at all. Probe 44843263310, before that step: 5943.
    if ! restorecon -Rnv /etc /var/home > "$work/restorecon" 2> "$work/restorecon.err"; then
        sed 's/^/    /' "$work/restorecon.err"
        bad "could not inspect SELinux labels under /etc and /var/home"
    else
        mislabeled=$(grep -c '^Would relabel ' "$work/restorecon")
        if [ "$mislabeled" -gt 0 ]; then
            bad "$mislabeled path(s) under /etc or /var/home have incorrect SELinux labels"
            grep '^Would relabel ' "$work/restorecon" | head -20 | sed 's/^/    /'
        else
            ok "0 mislabeled paths under /etc and /var/home"
        fi
    fi
else
    echo "  SELinux: not enforcing; label checks skipped"
fi

exit "$fail"
