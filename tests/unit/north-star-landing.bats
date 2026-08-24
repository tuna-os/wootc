#!/usr/bin/env bats
# North Star landing contracts: what greets the user on their new desktop.
# The audit of 2026-08-22 found the first login silent — no welcome, no
# pointer at the migration tools, and everything outside the six bridged
# folders reachable only by typing /run/wootc/host.

DEPLOY="payload/deployer/deploy.sh"
MOUNTDIRS="payload/migration/wootc-mount-user-dirs"
WELCOME="payload/migration/wootc-welcome"

@test "a first-login welcome exists, is visible, and runs once" {
    [ -f "$WELCOME" ]
    [ -f payload/migration/wootc-welcome.desktop ]
    # Visible, unlike apply-look (which is deliberately NoDisplay).
    run grep 'NoDisplay=true' payload/migration/wootc-welcome.desktop
    [ "$status" -ne 0 ]
    # One-shot: a marker file silences every later login.
    grep -q 'welcomed' "$WELCOME"
    grep -q 'exit 0' "$WELCOME"
}

@test "the welcome opens the migration dashboard, with a fallback that still says hello" {
    grep -q 'wootc-manifest-gui' "$WELCOME"
    grep -q 'notify-send' "$WELCOME"
}

@test "the deployer stages the welcome as an autostart — tolerantly, and the initramfs ships it" {
    grep -q 'wootc-welcome.desktop' "$DEPLOY"
    grep -q 'etc/xdg/autostart/wootc-welcome.desktop' "$DEPLOY"
    # Both sides of the contract that killed the whole 7d45616 smoke matrix
    # ("ABORT: line 2616"): the initramfs must actually carry the payload...
    grep -q '^\s*inst /usr/lib/wootc/migration/wootc-welcome$' payload/deployer/module-setup.sh
    grep -q '^\s*inst /usr/lib/wootc/migration/wootc-welcome.desktop$' payload/deployer/module-setup.sh
    # ...and the staging must be mig_opt (WARN), never a bare install (ABORT):
    # a missing welcome screen is not worth a dead migration.
    run grep -E '^\s*install .*wootc-welcome' "$DEPLOY"
    [ "$status" -ne 0 ]
}

@test "every migration payload deploy.sh stages is shipped in the initramfs" {
    # The generalized lesson: deploy.sh referencing /usr/lib/wootc/migration/X
    # that module-setup.sh never inst's means X exists in the repo, passes
    # every static test, and is absent at runtime — an abort (or a silent
    # mig_opt skip) on every real deploy. Scan BOTH reference styles: full
    # paths (install/inst lines) and bare mig_opt names.
    refs=$( { grep -oE 'migration/wootc-[A-Za-z0-9.@_-]+' "$DEPLOY" | sed 's|migration/||';
              grep -oE 'mig_opt [0-9]+ [A-Za-z0-9.@_-]+' "$DEPLOY" | awk '{print $3}'; } | sort -u )
    [ -n "$refs" ]
    missing=""
    for f in $refs; do
        grep -qE "^\s*inst /usr/lib/wootc/migration/${f}$" payload/deployer/module-setup.sh \
            || missing="$missing $f"
    done
    if [ -n "$missing" ]; then
        echo "deploy.sh stages these, but module-setup.sh never puts them in the initramfs:$missing"
        return 1
    fi
}

@test "every bridged home gets a Windows-drive bookmark" {
    # bind_profile is the single shared bridge path (exact-name and
    # single-user fallback), so hooking the bookmark there covers both.
    grep -q 'add_host_bookmark "$home"' "$MOUNTDIRS"
    grep -q 'file:///run/wootc/host Windows drive' "$MOUNTDIRS"
    # Never duplicated across logins, and owned by the user (the unit runs
    # as root — a root-owned ~/.config/gtk-3.0 breaks the file manager).
    grep -q 'grep -qsF' "$MOUNTDIRS"
    grep -q -- '--reference="$home"' "$MOUNTDIRS"
    # Both GTK generations read their own path.
    grep -q 'gtk-3.0 gtk-4.0' "$MOUNTDIRS"
}

@test "the Windows-drive bookmark also reaches KDE's Dolphin" {
    # GTK bookmarks are invisible to Dolphin (KDE — Bazzite's file manager),
    # which reads ~/.local/share/user-places.xbel. Half the catalog is KDE;
    # a GNOME-only bookmark quietly halves the promise.
    grep -q 'add_host_bookmark_kde "$home"' "$MOUNTDIRS"
    grep -q 'user-places.xbel' "$MOUNTDIRS"
    grep -q 'href="file:///run/wootc/host"' "$MOUNTDIRS"
    # Behavior, not just presence: fresh seed, dedupe, and append-into-existing
    # all produce a parseable file with the entry present exactly once.
    local T="$BATS_TEST_TMPDIR/kdebm" fn
    mkdir -p "$T/home"
    fn="$(sed -n '/^add_host_bookmark_kde()/,/^}/p' "$MOUNTDIRS")"
    run bash -c "$fn
        add_host_bookmark_kde '$T/home'
        add_host_bookmark_kde '$T/home'"
    [ "$status" -eq 0 ]
    [ "$(grep -c 'wootc/host' "$T/home/.local/share/user-places.xbel")" -eq 1 ]
    python3 -c "import xml.dom.minidom as m; m.parse('$T/home/.local/share/user-places.xbel')"
    # Append branch: an existing places file keeps its own entries.
    printf '%s\n' '<?xml version="1.0"?>' '<xbel>' ' <bookmark href="file:///home/x"><title>x</title></bookmark>' '</xbel>' \
        > "$T/home/.local/share/user-places.xbel"
    run bash -c "$fn
        add_host_bookmark_kde '$T/home'"
    [ "$status" -eq 0 ]
    grep -q 'file:///home/x' "$T/home/.local/share/user-places.xbel"
    grep -q 'file:///run/wootc/host' "$T/home/.local/share/user-places.xbel"
    python3 -c "import xml.dom.minidom as m; m.parse('$T/home/.local/share/user-places.xbel')"
}

@test "the timelapse demo stages exist and can never fail a run" {
    # The demo segments (migrated files on camera, Windows back untouched)
    # are video-only: gated on the recording, disable-able, and every guest
    # action is best-effort. A demo must never turn a proven-green run red.
    local E2E="tests/e2e/run-e2e.sh"
    grep -q 'demo_linux_userdata' "$E2E"
    grep -q 'demo_windows_untouched' "$E2E"
    # Both bail out unless video is recording, and honor the kill switch.
    [ "$(grep -c 'WOOTC_E2E_DEMO:-1' "$E2E")" -ge 2 ]
    [ "$(grep -c 'VIDEO_STARTED:-false.*= true .* return 0' "$E2E")" -ge 2 ] || \
        [ "$(grep -A2 'WOOTC_E2E_DEMO:-1' "$E2E" | grep -c 'VIDEO_STARTED')" -ge 2 ]
    # Their title cards ship with the repo (record-video mark needs the PNG).
    [ -f tests/e2e/titlecards/userdata.png ]
    [ -f tests/e2e/titlecards/windows.png ]
}

@test "the NTFS-on-Linux doc cites code that still exists" {
    # docs/ntfs-on-linux.md justifies the design hazard-by-hazard, each
    # claim tied to code. A doc that outlives its anchors becomes the kind
    # of reassuring fiction it was written to replace — pin every anchor.
    local DOC=docs/ntfs-on-linux.md
    [ -f "$DOC" ]
    grep -q 'ntfs-on-linux.md' README.md
    # Anchor: container allocation by Windows (SetLength sparse + VDL note).
    grep -q 'SetLength (sparse on NTFS, instant)' app/disk_windows.go
    grep -q 'setvaliddata' app/disk_windows.go
    # Anchor: Fast Startup disabled at install, restored at uninstall.
    grep -q 'func disableFastStartup' app/sysprobe_windows.go
    grep -q 'func restorePriorPowerState' app/sysprobe_windows.go
    # Anchor: the attach hook's driver probe chain, in its documented order.
    local hook=platform/dracut/99wootc-boot/wootc-attach-loop.sh
    grep -q 'mount -t ntfs3' "$hook"
    grep -q 'ntfs-3g lowntfs-3g mount.ntfs-3g' "$hook"
    # Anchor: the deployer's self-contained ntfs-3g closure.
    grep -q 'stage_ntfs3g_closure' payload/deployer/deploy.sh
    # Anchor: the clean-handback contract and its postmortem.
    [ -f tests/unit/phase2-clean-ntfs-umount.bats ]
    [ -f docs/phase2-attach-postmortem.md ]
}
