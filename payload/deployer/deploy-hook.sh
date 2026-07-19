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
# Dead-man watchdog: late failures (after dracut's root-device timeout puts
# systemd in emergency mode) have wedged the VM with the failure path below
# never reached. A successful deployer reboots the machine well inside this
# window; the watchdog only fires on a hang.
# reboot -f resolves to systemctl reboot -f, which still routes through the
# systemd manager and hangs once emergency mode has been entered; -ff issues
# the syscall directly, with sysrq as a last resort.
force_reboot() {
    sync 2>/dev/null || true
    reboot -ff 2>/dev/null || true
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger 2>/dev/null || true
}
# The watchdog MUST be cancellable, and its pid MUST be known.
#
# Previously this was a fire-and-forget `( sleep 2700; ... ) &`. Nothing ever
# killed it, so when the deployer returned, dracut-initqueue blocked in wait()
# for the leftover 45-minute sleep — and the machine sat idle until the watchdog
# fired and rebooted it. Observed identically on every runner: the journal ends
# mid-verification, `ps` shows only `dracut-initqueue` in do_wait with a single
# `sleep 2700` child, and the box reboots at t=2702s.
#
# The cost was severe: the deploy's real exit status was never printed, Phase-2
# setup never completed, and the harness blamed a "slow deploy" for 90 minutes.
# Watchdog that CANCELS ITSELF. No kill, no wait, no hunting for a pid.
#
# Two failed designs preceded this, both live-observed:
#   1. `( sleep 2700; force_reboot ) &` — never cancelled, so dracut-initqueue
#      blocked in wait() for the full 45 minutes after the deployer returned;
#   2. adding `kill` + `wait` — the wait blocked FOREVER when the kill missed,
#      and wrapping the sleep in `setsid` (to stop it outliving the subshell)
#      put it in its own session where neither the pid kill nor the process
#      GROUP kill could reach it. Strictly worse.
#
# So: poll a flag instead of sleeping blindly. Cancelling is a file touch, the
# loop exits within one tick on its own, and nothing ever needs to wait on or
# signal it. The deadline is still enforced if the deployer really does hang.
WOOTC_DONE_FLAG=/run/wootc-deploy-done
rm -f "$WOOTC_DONE_FLAG" 2>/dev/null || true
(
    deadline=$(( $(date +%s) + 2700 ))
    while [ ! -e "$WOOTC_DONE_FLAG" ]; do
        [ "$(date +%s)" -ge "$deadline" ] || { sleep 10; continue; }
        echo "[wootc] [FAIL] watchdog: deployer hung for 45m; forcing reboot" > /dev/kmsg
        force_reboot
        break
    done
) &
WATCHDOG_PID=$!
cancel_watchdog() {
    # A touch, not a signal. The loop notices within ~10s and exits by itself,
    # so dracut-initqueue has nothing left to block on.
    : > "$WOOTC_DONE_FLAG" 2>/dev/null || true
    WATCHDOG_PID=""
    echo "[wootc] watchdog cancelled" > /dev/kmsg 2>/dev/null || true
}

# This hook is sourced by dracut-initqueue, which may run under set -e: a
# bare failing command would abort the hook before the status capture line.
status=0
/usr/bin/wootc-deploy || status=$?
# Cancel FIRST: until this runs, every line below is racing a 45-minute sleep
# that dracut-initqueue is blocked on.
cancel_watchdog
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
