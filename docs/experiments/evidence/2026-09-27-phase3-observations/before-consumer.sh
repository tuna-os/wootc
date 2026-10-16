    P3_NATIVE_PROOF=$(qga_call exec /bin/sh -c \
        'printf "UNAME=%s\n" "$(uname -s)"; printf "CMDLINE="; cat /proc/cmdline; printf "TARGET="; cat /etc/wootc/native-target 2>/dev/null || true' \
        2>/dev/null || true)
    printf '%s\n' "$P3_NATIVE_PROOF"
    if ! echo "$P3_NATIVE_PROOF" | grep -q '^UNAME=Linux$'; then
        fail "Phase 3 target did not boot Linux"
        exit 1
    fi
    if echo "$P3_NATIVE_PROOF" | grep -qE '^CMDLINE=.*(^| )(loop|wootc\.rootdisk)='; then
        product_fail "Phase 3 reboot returned to loopback Phase 2 instead of the native disk"
        exit 1
    fi
    if ! echo "$P3_NATIVE_PROOF" | grep -q "^TARGET=$P3_TARGET$"; then
        product_fail "Phase 3 boot lacks the native-target identity written during graduation"
        exit 1
    fi
    product_pass native-boot "Phase 3 native system booted from the graduated install (non-loopback)"
    # The point of it all: the file seeded in Windows before the deployer ever
    # ran must now live on the NATIVE disk — no NTFS, no loopback, no bind in
    # the chain (the natively-booted system has no /run/wootc/host at all). Content must
    # carry this run's RUN_ID so a leftover from a previous run cannot pass.
    step "Verifying seeded user data persisted onto the native disk..."
    # Read the boot-time /run export, not the home directory itself: the
    # confined guest agent (virt_qemu_ga_t) cannot read user homes AT ALL —
    # run 20260723T0647 failed this gate with the seed file present and
    # correct on the native disk. wootc-e2e-native-probe.service (installed
    # by go-native, dispatcher-gated) cats the file into /run from init's
    # unconfined context; /run is proven agent-readable (the Phase-3
    # graduation result travels the same way). Direct read kept as fallback
    # for unconfined-agent images.
    P3_USERDATA=$(qga_call exec /bin/sh -c \
        'cat /run/wootc-e2e-native-userdata 2>/dev/null; \
         f=$(ls /home/wootc/Documents/wootc-e2e-userdata.txt /var/home/wootc/Documents/wootc-e2e-userdata.txt 2>/dev/null | head -1); \
         [ -n "$f" ] && { printf "SRC=%s\n" "$(findmnt -no SOURCE "$(df -P "$f" | awk "NR==2{print \$6}")" 2>/dev/null)"; cat "$f"; }; :' \
        2>/dev/null || true)
    if printf '%s' "$P3_USERDATA" | grep -q "$RUN_ID"; then
        product_pass native-user-data "User data survived to the native disk: $(printf '%s' "$P3_USERDATA" | grep '^SRC=' | head -1)"
    else
        product_fail "Seeded user data did NOT persist onto the native disk (wanted RUN_ID $RUN_ID)"
        printf '%s\n' "$P3_USERDATA" | sed 's/^/  /'
        exit 1
    fi