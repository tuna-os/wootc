#!/usr/bin/env bash
# wootc-phase2-overlay — the early-cpio overlay every Phase-2 initrd carries.
#
# deploy.sh sources this file. Three Phase-2 staging branches (composefs+
# systemd-boot, generic systemd-boot, ostree/grub2 with a target initramfs that
# cannot be regenerated) prepend the same wootc-boot overlay onto the target's
# own initrd. They used to carry three hand-copied variants of this code, and
# two of them looked for ntfs-3g under a /mnt/sysroot that never exists in this
# initramfs — silently falling through to a deployer binary shipped WITHOUT
# its library closure (the exact cross-image soname failure documented in
# docs/agent-lessons.md §8). One implementation, used by all branches.
#
# This is generic orchestration, not provisioner code: it consumes a deployed
# root, it does not create one (docs/architecture-boundary.md).
#
#   stage_wootc_overlay        attach unit, loop script and shutdown hooks
#   stage_ntfs3g_closure       a userspace NTFS driver for kernels without ntfs3
#   stage_qemu_ga_into_target  fallback guest agent for the installed system
#   build_phase2_initrd        pack the overlay in front of the base initrd
#
# Inputs the caller provides (read at call time, never set here):
#   DEPLOY_ROOT   the mounted root of the installed deployment
#   log, err      the deployer's logging functions
#   find_ldso, dso_closure, list_initrd_members  from wootc-initramfs-lib.sh
#
# The file has no top-level code: sourcing it only defines functions.

# stage_wootc_overlay <ovl-dir>
# The attach unit, its wants edge, and the loop script — the minimum that
# makes root.disk appear to the base initrd's ordinary sysroot.mount.
stage_wootc_overlay() {
    local ovl="$1"
    # early_cpio marker: makes lsinitrd/skipcpio recognise this as a leading
    # (early) cpio and skip past it to show the base initrd — honest
    # introspection. Harmless to the kernel (same as microcode).
    : > "$ovl/early_cpio"
    install -D -m0644 /usr/lib/wootc/99wootc-boot/wootc-attach.service \
        "$ovl/usr/lib/systemd/system/wootc-attach.service"
    install -D -m0755 /usr/lib/wootc/99wootc-boot/wootc-attach-loop.sh \
        "$ovl/usr/lib/wootc/wootc-attach-loop.sh"
    mkdir -p "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants"
    ln -sf ../wootc-attach.service \
        "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service"

    # The Phase-2 shutdown pair — the counterpart to this deployer's own
    # "leave the NTFS volume clean before the forced reboot" teardown, which
    # Phase 2 had no equivalent of. Without them Phase 2 reboots with the rw
    # NTFS still mounted and the loop device still attached (systemd: "Not all
    # file systems unmounted, 1 left"), and Windows comes back to a volume it
    # boot-loops on and cannot repair.
    #
    # These are dracut HOOKS, not units, so they go under the hook dirs rather
    # than being wired through systemd. /usr/lib, never /lib: dracut's
    # $hookdir is /lib/dracut/hooks, which is the same path on the usr-merged
    # images this overlay targets, and creating a real /lib directory in an
    # early cpio would collide with the base initrd's /lib -> usr/lib symlink.
    install -D -m0755 /usr/lib/wootc/99wootc-boot/wootc-stage-shutdown.sh \
        "$ovl/usr/lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh"
    install -D -m0755 /usr/lib/wootc/99wootc-boot/wootc-umount-host.sh \
        "$ovl/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh"
}

# stage_ntfs3g_closure <ovl-dir>
# Stage a userspace NTFS driver into the overlay for kernels without ntfs3.
# Source order matters (agent-lessons §8 — never mix libraries across images):
#   1. the TARGET deployment's own ntfs-3g: the binary plus its
#      libntfs-3g/libfuse from the SAME tree. The rest of its closure (libc,
#      loader) is the base initrd's own — coherent, both come from the image.
#   2. the DEPLOYER's ntfs-3g as a COMPLETE private closure: binary, every
#      ldd-resolved library, and the dynamic loader under
#      /usr/lib/wootc/ntfs3g/, invoked through a wrapper. The target's
#      libraries are never mixed in (measured skew that motivated this:
#      libfuse3.so.4 vs .so.3 — lands, then dies exactly like a missing one).
# Returns 0 when a driver was staged, 1 when none was available (the caller
# decides whether kernel ntfs3 makes that survivable).
stage_ntfs3g_closure() {
    local ovl="$1" d tsrc="" lib nbin ldso=""
    for d in /usr/bin /usr/sbin /bin /sbin; do
        [[ -x "$DEPLOY_ROOT$d/ntfs-3g" ]] && { tsrc="$DEPLOY_ROOT$d/ntfs-3g"; break; }
    done
    if [[ -n "$tsrc" ]]; then
        install -D -m0755 "$tsrc" "$ovl/usr/bin/ntfs-3g"
        # Its NTFS/FUSE libraries from the same tree, symlink chains intact
        # (libntfs-3g.so.N is a link to .so.N.0.0 — both must land). $lib is
        # the path with the deployment prefix stripped, so it doubles as the
        # destination inside the overlay.
        while IFS= read -r lib; do
            mkdir -p "$ovl${lib%/*}" 2>/dev/null || true
            cp -a "$DEPLOY_ROOT$lib" "$ovl${lib%/*}/" 2>/dev/null || true
        done < <(find "$DEPLOY_ROOT/usr/lib64" "$DEPLOY_ROOT/lib64" \
                      "$DEPLOY_ROOT/usr/lib" "$DEPLOY_ROOT/lib" \
                      -maxdepth 1 \( -name 'libntfs-3g*' -o -name 'libfuse*' \) \
                      2>/dev/null | sed "s|^$DEPLOY_ROOT||")
        mkdir -p "$ovl/usr/sbin"
        ln -sf /usr/bin/ntfs-3g "$ovl/usr/sbin/mount.ntfs"
        ln -sf /usr/bin/ntfs-3g "$ovl/usr/sbin/mount.ntfs-3g"
        log "  early-cpio: staged the TARGET's own ntfs-3g (+libs) from the deployment"
        return 0
    fi
    nbin=$(command -v ntfs-3g 2>/dev/null || true)
    if [[ -n "$nbin" ]]; then
        local pdir="usr/lib/wootc/ntfs3g"
        install -D -m0755 "$nbin" "$ovl/$pdir/ntfs-3g"
        # Every ldd-resolved dependency AND the loader (the line without "=>").
        while IFS= read -r lib; do
            [[ -f "$lib" ]] || continue
            install -D -m0755 "$lib" "$ovl/$pdir/${lib##*/}"
            case "$lib" in
                */ld-linux*|*/ld64.so*|*/ld.so*) ldso="${lib##*/}" ;;
            esac
        done < <(dso_closure "$nbin")
        if [[ -z "$ldso" ]]; then
            # Best-effort: all three callers fall back to kernel ntfs3 with a
            # [WARN]. Never say [FAIL] for something the deployer survives —
            # run-e2e.sh kills the run on the first [FAIL] on the serial.
            err "  [WARN] early-cpio: no dynamic loader resolved for the deployer's ntfs-3g — cannot build a self-contained closure"
            rm -rf "${ovl:?}/$pdir"
            return 1
        fi
        # PROVE the closure is complete by RUNNING it (ldd reports only the
        # first missing library; execution reports the truth). This is the
        # deployer's own binary on the deployer's own kernel, so it can run
        # here — pinned to the staged loader + staged libs only.
        if ! "$ovl/$pdir/$ldso" --library-path "$ovl/$pdir" "$ovl/$pdir/ntfs-3g" --version >/dev/null 2>&1; then
            err "  [WARN] early-cpio: staged ntfs-3g closure does not execute against its own libraries"
            rm -rf "${ovl:?}/$pdir"
            return 1
        fi
        # The wrapper the attach hook's mount_host() will find as `ntfs-3g`.
        #
        # The '@' argv[0] is load-bearing, not cosmetic:
        # the FUSE daemon this wrapper becomes must carry an argv[0] whose
        # first byte is '@' so systemd's initrd switch-root killing spree
        # spares it (systemd's ROOT STORAGE DAEMONS contract). Without it the
        # daemon is SIGKILLed mid-switch-root and every loop I/O returns EIO,
        # ending in "Failed to execute /sbin/init: Input/output error" — all
        # three el10 cells of run 32534827767. Only this fallback bites: a
        # native ntfs-3g never re-execs, so the '@' mount_host() sets
        # survives, which is why el10 was green while the target-image
        # ntfs-3g install still succeeded.
        #
        # The '@' must be set HERE; propagating the caller's name does not
        # work (run 32538672432 proved it): this is
        # a shebang script, and Linux shebang handling REPLACES argv[0] with
        # the script path when it builds the interpreter's argv — the
        # caller's '@mount.ntfs-3g' is discarded before this script runs, so
        # \$0 is always the plain script path. /proc/PID/cmdline — what the
        # killing spree reads — is fixed at execve time, so the '@'
        # survives both ld.so's argv shift and ntfs-3g's daemonizing fork.
        # Unconditional '@' is harmless in every other context (argv[0] only
        # feeds ntfs-3g's usage messages).
        #
        # POSIX sh, not bash: the base initrd may ship only dash
        # (tunaOS#4818), and sh has no `exec -a`. A shell passes the command
        # word it looked up in PATH as argv[0], so the loader is reached
        # through a symlink named "@ntfs-3g" (same trick as the attach hook's
        # exec_storage_daemon).
        mkdir -p "$ovl/usr/bin" "$ovl/usr/sbin" "$ovl/$pdir/argv0"
        ln -sf "../$ldso" "$ovl/$pdir/argv0/@ntfs-3g"
        cat > "$ovl/usr/bin/ntfs-3g" <<NTFSWRAP
#!/bin/sh
PATH="/$pdir/argv0:\$PATH"
exec @ntfs-3g --library-path /$pdir /$pdir/ntfs-3g "\$@"
NTFSWRAP
        chmod 0755 "$ovl/usr/bin/ntfs-3g"
        ln -sf /usr/bin/ntfs-3g "$ovl/usr/sbin/mount.ntfs"
        ln -sf /usr/bin/ntfs-3g "$ovl/usr/sbin/mount.ntfs-3g"
        log "  early-cpio: staged the DEPLOYER's ntfs-3g as a private closure (loader=$ldso, exec-verified)"
        return 0
    fi
    return 1
}

# stage_qemu_ga_into_target
# Give the deployed system a guest agent the E2E control plane can reach, on
# images that ship none.
#
# The previous implementation wrote the binary to $DEPLOY_ROOT/usr/bin/qemu-ga
# and the unit to $DEPLOY_ROOT/usr/lib/systemd/system/. On a composefs
# deployment both writes SUCCEED and both are INVISIBLE at runtime: the sealed
# .cfs image is mounted over /usr, so the deployment directory's own /usr is
# shadowed. dakota booted Phase 2 all the way to a login prompt carrying
# `systemd.wants=qemu-guest-agent.service`, with no such unit anywhere in the
# booted system, while the deployer logged "[PASS] qemu-guest-agent installed
# from deployer into target" (run 30703716667). The harness then reported
# "the Phase-2 guest agent never answered". A PASS derived from a write
# landing rather than from the runtime seeing it.
#
# /etc and /var ARE the runtime ones under composefs. Ground truth from that
# same boot: wootc-passthrough.service (installed into $DEPLOY_ROOT/etc with
# ExecStart=/var/usrlocal/bin/wootc-mount-user-dirs) started and finished.
# So stage into those, never into /usr:
#   binary + full ldd closure  → /var/usrlocal/lib/wootc-qga/
#   wrapper                    → /var/usrlocal/bin/qemu-ga
#   unit + wants symlink       → /etc/systemd/system/
#
# The closure is the agent-lessons §8 rule that stage_ntfs3g_closure follows:
# never mix the deployer's binary with the target's libraries: ship every
# ldd-resolved library plus the loader, invoke through the staged loader, and
# PROVE it by running it (ldd reports only the first missing library).
#
# The unit is named wootc-qemu-ga.service and gated on
# ConditionPathExists=!/usr/bin/qemu-ga so it can never displace an agent the
# image ships itself. That condition is evaluated in the booted real root,
# the only place where "does this image have qemu-ga" is observable. A chroot
# probe here cannot answer it: under composefs $DEPLOY_ROOT/usr is empty, so
# the probe reports "absent" for every image, including ones that have it.
stage_qemu_ga_into_target() {
    local src pdir="var/usrlocal/lib/wootc-qga" lib ldso=""
    src=$(command -v qemu-ga 2>/dev/null || true)
    if [[ -z "$src" ]]; then
        err "  [WARN] qga: the deployer initramfs carries no qemu-ga to stage"
        return 1
    fi
    rm -rf "${DEPLOY_ROOT:?}/$pdir"
    install -D -m0755 "$src" "$DEPLOY_ROOT/$pdir/qemu-ga"
    while IFS= read -r lib; do
        [[ -f "$lib" ]] || continue
        install -D -m0755 "$lib" "$DEPLOY_ROOT/$pdir/${lib##*/}"
        case "$lib" in
            */ld-linux*|*/ld64.so*|*/ld.so*) ldso="${lib##*/}" ;;
        esac
    done < <(dso_closure "$src")
    if [[ -z "$ldso" ]]; then
        # [WARN], not [FAIL]: the caller continues with "no fallback qemu-ga
        # staged", and run-e2e.sh aborts the deploy on the first [FAIL] it
        # sees on the serial — which is how this line, on its own, ended
        # bluefin-dakota-win11pro in run 30707067821.
        err "  [WARN] qga: no dynamic loader resolved for the deployer's qemu-ga; cannot build a self-contained closure"
        rm -rf "${DEPLOY_ROOT:?}/$pdir"
        return 1
    fi
    if ! "$DEPLOY_ROOT/$pdir/$ldso" --library-path "$DEPLOY_ROOT/$pdir" \
            "$DEPLOY_ROOT/$pdir/qemu-ga" --version >/dev/null 2>&1; then
        err "  [WARN] qga: staged qemu-ga closure does not execute against its own libraries"
        rm -rf "${DEPLOY_ROOT:?}/$pdir"
        return 1
    fi
    install -d -m0755 "$DEPLOY_ROOT/var/usrlocal/bin"
    cat > "$DEPLOY_ROOT/var/usrlocal/bin/qemu-ga" <<QGAWRAP
#!/bin/sh
exec /$pdir/$ldso --library-path /$pdir /$pdir/qemu-ga "\$@"
QGAWRAP
    chmod 0755 "$DEPLOY_ROOT/var/usrlocal/bin/qemu-ga"
    install -d -m0755 "$DEPLOY_ROOT/etc/systemd/system" \
                      "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants"
    cat > "$DEPLOY_ROOT/etc/systemd/system/wootc-qemu-ga.service" <<'QGAUNIT'
[Unit]
Description=QEMU Guest Agent (staged by the wootc deployer)
Documentation=https://github.com/tuna-os/wootc
# Never displace an agent the image ships itself.
ConditionPathExists=!/usr/bin/qemu-ga
ConditionPathExists=!/usr/sbin/qemu-ga
ConditionPathExists=/var/usrlocal/bin/qemu-ga
After=local-fs.target
# The virtio-serial port can appear after this unit is first tried; Restart
# handles that, so the default 5-starts-in-10s limit must not give up on it.
StartLimitIntervalSec=0

[Service]
# A breadcrumb on the console: the serial log is the only Phase-2 evidence the
# harness can read when the agent is the thing that is broken, so "the unit was
# tried" must be distinguishable from "the unit does not exist".
ExecStartPre=/bin/sh -c 'echo "wootc: starting staged qemu-ga" > /dev/kmsg'
ExecStart=/var/usrlocal/bin/qemu-ga --method=virtio-serial --path=/dev/virtio-ports/org.qemu.guest_agent.0
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
QGAUNIT
    ln -sf ../wootc-qemu-ga.service \
        "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-qemu-ga.service"
    # Assert the runtime view, not the writes: the wants symlink must resolve
    # to the unit, and the unit's ExecStart must exist under the deployment.
    if [[ ! -e "$DEPLOY_ROOT/etc/systemd/system/multi-user.target.wants/wootc-qemu-ga.service" ]]; then
        err "  [WARN] qga: multi-user.target.wants/wootc-qemu-ga.service dangles; the agent would never start"
        return 1
    fi
    if [[ ! -x "$DEPLOY_ROOT/var/usrlocal/bin/qemu-ga" ]]; then
        err "  [WARN] qga: /var/usrlocal/bin/qemu-ga is not executable in the deployment"
        return 1
    fi
    log "  [PASS] fallback qemu-ga staged (loader=$ldso, exec-verified) at /var/usrlocal/bin/qemu-ga, enabled as wootc-qemu-ga.service"
    return 0
}

# build_phase2_initrd <ovl-dir> <base-initrd> <out-path> [--overlay-only]
# Pack the overlay ahead of the base initrd and VERIFY the result by
# inspection — "the concatenated file is non-empty" validated nothing (a
# hookless or interpreter-less initramfs is non-empty too, and costs a full
# VM run to diagnose). Fails closed on a defective overlay; base-initrd
# introspection is best-effort (its compression varies by image) and only
# fails when a successful listing PROVES a required piece missing.
#
# --overlay-only writes just the overlay cpio to <out-path>, for a loader
# that is given the overlay and the base as two initrds (GRUB concatenates
# them the same way); the checks, the base's included, are the same.
build_phase2_initrd() {
    local ovl="$1" base="$2" out="$3" overlay_only="${4:-}"
    # The overlay must be verifiably complete BEFORE packing: unit file,
    # wants edge (a dangling wants is a proven silent no-op), executable hook.
    if [[ ! -f "$ovl/usr/lib/systemd/system/wootc-attach.service" ]] || \
       [[ ! -L "$ovl/usr/lib/systemd/system/initrd-root-device.target.wants/wootc-attach.service" ]] || \
       [[ ! -x "$ovl/usr/lib/wootc/wootc-attach-loop.sh" ]]; then
        err "  [FAIL] early-cpio overlay is incomplete (unit/wants/hook) — refusing to build a Phase-2 initrd that cannot attach root.disk"
        return 1
    fi
    # The shutdown pair is checked separately, and separately fatal: an
    # overlay missing it produces a Phase 2 that BOOTS PERFECTLY and then
    # hands Windows back a volume it cannot repair — a failure that costs a
    # full 60-90 minute VM run to see, and looks nothing like its cause.
    if [[ ! -x "$ovl/usr/lib/dracut/hooks/pre-pivot/99-wootc-stage-shutdown.sh" ]] || \
       [[ ! -x "$ovl/usr/lib/dracut/hooks/shutdown/50-wootc-umount-host.sh" ]]; then
        err "  [FAIL] early-cpio overlay carries no Phase-2 shutdown hooks — refusing to build a Phase-2 initrd that would reboot with the Windows NTFS still mounted rw"
        return 1
    fi
    # Nothing at the top-level usr-merge names. On a usr-merged base those are
    # symlinks (lib -> usr/lib), and the kernel unpacks this cpio FIRST: a
    # real directory here cannot be replaced by the base's symlink, so every
    # base file under /lib disappears. Run 44742028340 (grouper): no
    # /lib/dracut-lib.sh, every dracut hook failed, root.disk never attached.
    local top
    for top in bin sbin lib lib64; do
        if [[ -e "$ovl/$top" || -L "$ovl/$top" ]]; then
            err "  [FAIL] early-cpio overlay has a top-level /$top — it would hide the base initrd's /$top (usr-merge symlink); stage under /usr/$top instead"
            return 1
        fi
    done
    local packed="$ovl.cpio"
    [[ "$overlay_only" != --overlay-only ]] || packed="$out"
    if ! ( cd "$ovl" && find . | cpio -o -H newc --quiet ) > "$packed" || \
       { [[ "$packed" != "$out" ]] && ! cat "$packed" "$base" > "$out"; } || [[ ! -s "$out" ]]; then
        rm -f "$ovl.cpio"
        err "  [FAIL] early-cpio: cpio prepend failed — Phase-2 initrd would be hookless"
        return 1
    fi
    rm -f "$ovl.cpio"
    # The overlay supplies unit+hook (+ possibly ntfs-3g); everything else the
    # hook needs at runtime must come from the BASE initrd: its interpreter
    # (sh — the unit runs the hook with /bin/sh), losetup, udevadm, mount.
    # Listing walks every
    # segment of the image; an empty result just means "unverifiable here",
    # which must WARN, not fail a deploy that may be good.
    local listing=""
    listing=$(list_initrd_members "$base")
    if [[ -z "$listing" ]]; then
        log "  [WARN] early-cpio: could not list the base initrd (unknown compression) — interpreter/tool presence unverified"
        return 0
    fi
    # Only a listing that actually holds a root filesystem can prove a tool
    # absent. A microcode-only early-cpio listing has no bin/ tree at all, and
    # calling that proof is how a good initrd got declared unbootable.
    if ! grep -qE '(^|/)(usr/)?s?bin/' <<<"$listing"; then
        log "  [WARN] early-cpio: the base initrd listing holds no bin/ tree (early-cpio segment only?) — tool presence unverified"
        return 0
    fi
    local missing=() tool found
    for tool in sh losetup udevadm mount; do
        found=0
        grep -qE "(^|/)(usr/)?s?bin/$tool$" <<<"$listing" && found=1
        # busybox-style initrds provide tools as applet symlinks with the
        # same basename; the grep above already matches those. A systemd
        # UKI initrd without a shell at all is the real failure mode here.
        [[ "$found" == 1 ]] || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        err "  [FAIL] the target's base initrd lacks: ${missing[*]} — the wootc-attach hook cannot run in Phase 2"
        err "         (every segment listed and a bin/ tree was found, so this is proof, not a probe failure; the image's initrd must ship these or the hook must be rewritten against what it ships)"
        return 1
    fi
    log "  early-cpio: base initrd verified (sh/losetup/udevadm/mount present)"
    return 0
}
