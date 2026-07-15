#!/bin/bash
# dracut initqueue hook for the one-shot wootc deployer.
# A dracut image always supplies its own /init, so copying a custom /init does
# not make it PID 1. Start the deployer from initqueue after the network is up.

guard=/run/wootc-deployer-started
[ -e "$guard" ] && return 0
: >"$guard"

echo "[wootc] Network is online; starting deployer..."
/usr/bin/wootc-deploy
status=$?
echo "[wootc] Deployer exited with status $status"

# On success the deployer reboots the machine itself, so reaching this point
# means failure. An interactive shell is only useful with wootc.debug (the
# E2E serial console has no input); otherwise emit the failure marker for the
# serial monitor and return to Windows so QGA-based diagnostics work again.
if grep -q 'wootc\.debug' /proc/cmdline 2>/dev/null; then
    echo "[wootc] wootc.debug set; opening an emergency shell."
    exec /bin/bash
fi

echo "[wootc] [FAIL] deployer failed with status $status; rebooting to Windows in 30s"
sleep 30
reboot -f
