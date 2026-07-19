#!/bin/bash
# dracut initqueue hook for the one-shot wootc deployer.
# A dracut image always supplies its own /init, so copying a custom /init does
# not make it PID 1. Start the deployer from initqueue after the network is up.

guard=/run/wootc-deployer-started
[ -e "$guard" ] && return 0
: >"$guard"

echo "[wootc] Network is online; starting deployer..."

# Start the QEMU guest agent on the same virtio-serial channel Windows uses:
# the host's qga.py control plane then works during the deployer phase too
# (live guest-exec for df/journalctl, file reads, interactive debugging).
if command -v qemu-ga >/dev/null 2>&1; then
    ga_dev=/dev/virtio-ports/org.qemu.guest_agent.0
    [ -e "$ga_dev" ] || ga_dev=$(ls /dev/vport*p* 2>/dev/null | head -1)
    if [ -n "$ga_dev" ] && [ -e "$ga_dev" ]; then
        qemu-ga --daemonize -m virtio-serial -p "$ga_dev" 2>/dev/null \
            && echo "[wootc] qemu-ga started on $ga_dev" > /dev/kmsg
    fi
fi
# reboot -f resolves to systemctl reboot -f, which still routes through the
# systemd manager and hangs once emergency mode has been entered; -ff issues
# the syscall directly, with sysrq as a last resort.
force_reboot() {
    sync 2>/dev/null || true
    reboot -ff 2>/dev/null || true
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger 2>/dev/null || true
}
# NO in-guest watchdog. Deliberately removed.
#
# It was a dead-man switch for a hung deployer, but it caused three separate
# regressions and never once did its job:
#   1. fire-and-forget `( sleep 2700 ) &` — dracut-initqueue blocked in wait()
#      for 45 minutes after the deployer returned, so Phase-2 setup never ran;
#   2. adding kill+wait — the wait blocked FOREVER when the kill missed;
#   3. setsid on the sleep — put it beyond both pid and process-group kill;
#   4. a self-cancelling flag-file loop — cancellation worked, but the subshell
#      is still a CHILD of dracut-initqueue, which therefore still blocks:
#        454   1   S  do_wait            /usr/bin/sh /usr/bin/dracut-initqueue
#        7365 454   S  hrtimer_nanosleep  sleep 10
#
# The shape of the bug is structural: ANY background job in this hook is a child
# of dracut-initqueue, and dracut-initqueue waits for its children. A watchdog
# here cannot avoid blocking the very thing it is meant to protect.
#
# It is also redundant. The HOST already detects every case it covered, with
# better diagnostics and without touching the guest:
#   * a wall-clock deploy budget (WOOTC_E2E_DEPLOY_TIMEOUT);
#   * "Windows QGA is answering again" -> the deployer is gone (fails fast);
#   * the kernel's "reboot: Restarting system" recorded but NOT taken as success;
#   * serial silence cross-checked against guest CPU (#40).
#
# If an in-guest deadline is ever wanted again, it must NOT be a background job
# in this hook — use a systemd transient unit, or have deploy.sh check its own
# elapsed time between phases.

# This hook is sourced by dracut-initqueue, which may run under set -e: a
# bare failing command would abort the hook before the status capture line.
status=0
/usr/bin/wootc-deploy || status=$?
echo "[wootc] Deployer exited with status $status"
echo "[wootc] Deployer exited with status $status" > /dev/kmsg 2>/dev/null || true

# On success the deployer reboots the machine itself, so reaching this point
# means failure. An interactive shell is only useful with wootc.debug (the
# E2E serial console has no input); otherwise emit the failure marker for the
# serial monitor and return to Windows so QGA-based diagnostics work again.
if grep -q 'wootc\.debug' /proc/cmdline 2>/dev/null; then
    echo "[wootc] wootc.debug set; opening an emergency shell."
    exec /bin/bash
fi

echo "[wootc] [FAIL] deployer failed with status $status; rebooting to Windows in 30s" > /dev/kmsg
sleep 30
force_reboot
