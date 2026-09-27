#!/usr/bin/env bats
# Docs truth pass (#233) — the claims most likely to rot, pinned to the source.
#
# A doc that lies costs more than a doc that is missing: the reader acts on it.
# The 2026-09-02 pass found nine wrong claims in the shipped docs, and every
# one of them was checkable from this repository without a VM — a path that had
# moved, a screen quoted from dead code, a default image that changed, a gate
# the docs said was open, evidence claimed on hardware nobody had tested on.
#
# So the discovery is the test. Each assertion below is one claim from the pass,
# tied to the file it must agree with, so the NEXT drift fails here instead of
# in front of a user. See docs/docs-truth-pass.md for the full checklist.
#
# What these deliberately do NOT cover: anything that needs a running Windows
# VM (timings, SmartScreen behaviour, real Add/Remove rendering). Those are the
# RC walk, and the pass record says so rather than pretending a grep proved it.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    cd "$REPO_ROOT" || return 1
}

@test "E2E stages the GRUB configuration embedded by the application" {
    run grep -F 'cp "$REPO_ROOT/app/grub/"*.cfg' "$REPO_ROOT/tests/e2e/run-e2e.sh"
    [ "$status" -eq 0 ]

    run grep -F 'cp app/grub/*.cfg' "$REPO_ROOT/tests/e2e/setup-kvm-runner.sh"
    [ "$status" -eq 0 ]

    [ ! -e "$REPO_ROOT/platform/grub/wubildr.cfg" ]
    [ ! -e "$REPO_ROOT/platform/grub/wubildr-bootstrap.cfg" ]
}

# ── paths ────────────────────────────────────────────────────────────────────

@test "docs point at the state file that actually exists" {
    # manual-testing.md sends a bug reporter to collect this; C:\wootc\install\
    # exists (wifi/, slurp/) so the wrong path looked plausible for months.
    grep -q 'filepath.Join(wootcDir(), "state.json")' app/state.go
    grep -q 'C:\\wootc\\state.json' docs/manual-testing.md
    ! grep -q 'C:\\wootc\\install\\state.json' docs/manual-testing.md
}

@test "every C:\\wootc path the docs name is one the code builds" {
    # The docs' whole reversibility promise is "it all lives in one folder", so
    # a path claim that has drifted undermines the claim it was making.
    local doc
    for doc in README.md docs/getting-started.md docs/user-guide.md \
               docs/manual-testing.md docs/branding.md \
               docs/branding-and-distribution.md docs/RELEASING.md; do
        while read -r claimed; do
            [ -n "$claimed" ] || continue
            # Strip the C:\wootc prefix and any trailing separator; what is
            # left must appear as a path segment somewhere in the Go/shell.
            local leaf="${claimed#C:\\wootc}"
            leaf="${leaf#\\}"
            leaf="${leaf%\\}"
            [ -n "$leaf" ] || continue          # bare C:\wootc is the root
            local first="${leaf%%\\*}"
            grep -rqF "\"$first\"" app/*.go ||
                grep -rqF "$first" app/*.go payload/deployer/deploy.sh ||
                { echo "$doc claims C:\\wootc\\$leaf but nothing builds '$first'"; return 1; }
        done < <(grep -ohE 'C:\\wootc[\\A-Za-z0-9_.-]*' "$doc" 2>/dev/null | sort -u)
    done
}

# ── exe names and packaging ──────────────────────────────────────────────────

@test "the branded exe names the docs advertise are the ones brand.json builds" {
    local doc exe
    for exe in $(jq -r '.exeName' app/branding/*/brand.json); do
        [ "$exe" = "wootc" ] && continue
        for doc in README.md docs/getting-started.md; do
            grep -qF "$exe.exe" "$doc" ||
                { echo "$doc never mentions $exe.exe"; return 1; }
        done
    done
    # ...and the docs must not advertise an exe no brand produces.
    local built
    built=$(jq -r '.exeName' app/branding/*/brand.json | sort -u)
    for exe in $(grep -ohE '[A-Za-z]+-Installer\.exe' README.md docs/getting-started.md docs/RELEASING.md | sort -u); do
        printf '%s\n' "$built" | grep -qx "${exe%.exe}" ||
            { echo "docs advertise $exe but no brand.json builds it"; return 1; }
    done
}

@test "RELEASING does not claim a single published artifact" {
    # release.yml publishes one exe PER BRAND plus the shared boot artifacts
    # and SHA256SUMS. "The published artifact is wootc.exe" was true once.
    grep -q 'full artifact set' docs/RELEASING.md
    ! grep -qE 'The published artifact is `wootc\.exe`' docs/RELEASING.md
}

@test "docs do not link to files that are not in the tree" {
    # INSTALL.md was referenced by RELEASING.md and has never existed here.
    local doc target missing=0
    for doc in README.md docs/getting-started.md docs/user-guide.md \
               docs/manual-testing.md docs/branded-walkthroughs.md \
               docs/branding.md docs/branding-and-distribution.md docs/RELEASING.md; do
        while read -r target; do
            [ -n "$target" ] || continue
            [ -e "$(dirname "$doc")/$target" ] || {
                echo "$doc links to missing $target"; missing=1; }
        done < <(grep -ohE '\]\([A-Za-z0-9_./-]+\.(md|png|webp)[^)]*\)' "$doc" 2>/dev/null |
                 sed 's/](//; s/)$//; s/#.*//' | sort -u)
    done
    [ "$missing" -eq 0 ]
}

# ── channel behaviour ────────────────────────────────────────────────────────

@test "no doc promises BitLocker works while the channel gate refuses it" {
    # alpha AND beta ship BitLockerSupported:false and StartInstall hard-refuses.
    # The user guide told a BitLocker reader "BitLocker is fine too" — they would
    # download, run, and hit a wall the docs said was not there.
    grep -q 'BitLockerSupported: false' app/app.go
    # Wherever the docs make the BitLocker promise, the gate must be named too.
    grep -q 'not proven green yet' docs/user-guide.md
    grep -q 'Not yet available in the alpha' docs/user-guide.md
    grep -q 'Gated off in' README.md
    ! grep -q '\*\*BitLocker\*\* is fine too' docs/user-guide.md
}

@test "the documented default channel is the one the code defaults to" {
    grep -q 'return "alpha"' app/app.go
    grep -q 'else the built-in default (`alpha`)' docs/RELEASING.md
}

@test "the image the docs call the alpha default is the one that gets selected" {
    # main.js pre-selects images[0]; in alpha GetImages returns green images in
    # file order, so the first green entry in images.json IS the default. The
    # guide named Yellowfin GNOME long after that stopped being true.
    local first
    first=$(jq -r '[.[] | select(.status == "green")][0].name' app/data/images.json)
    grep -qF "$first" docs/user-guide.md ||
        { echo "user-guide does not name the pre-selected image ($first)"; return 1; }
    ! grep -q 'The default (Yellowfin GNOME)' docs/user-guide.md
}

@test "the free-space figure is the one the launchpad enforces" {
    # 20 GB minimum + DISK_HEADROOM_GB. Two docs disagreed with the code and
    # with each other (~40 vs 35).
    grep -q 'const DISK_HEADROOM_GB = 15' app/frontend/src/screens/launchpad.js
    grep -q 'maxDiskSizeGB() < 20' app/frontend/src/screens/launchpad.js
    grep -q '35 GB' docs/manual-testing.md
    grep -q '35 GB' docs/user-guide.md
    grep -q '35 GB' docs/RELEASING.md
}

# ── on-screen strings ────────────────────────────────────────────────────────

@test "the first screen the docs quote is the one the build renders" {
    # launchpad.js renders `state.brand.tagline`, and defaultBranding() always
    # sets one — so the JS fallback string can never appear, and getting-started
    # quoted exactly that dead fallback.
    local tagline
    tagline=$(jq -r '.tagline' app/branding/wootc/brand.json)
    grep -qF "$tagline" docs/getting-started.md ||
        { echo "getting-started does not quote the shipping tagline: $tagline"; return 1; }
    grep -q 'state.brand?.tagline' app/frontend/src/screens/launchpad.js
}

@test "the uninstall entry the docs name is the one the installer registers" {
    # Generic build registers "<Name> (wootc)"; three docs send users to it.
    grep -q 'displayName = b.Name + " (wootc)"' app/installer_windows.go
    local name
    name=$(jq -r '.name' app/branding/wootc/brand.json)
    grep -qF "$name (wootc)" docs/user-guide.md
    grep -qF "$name (wootc)" docs/manual-testing.md
    grep -qF "$name (wootc)" docs/getting-started.md
}

@test "the migration dashboard is called what the app calls it" {
    # The Linux-side window title and .desktop Name are the user-visible label;
    # the guide had invented "Bring your setup over".
    grep -q 'Name=Bring Over From Windows' payload/migration/wootc-manifest.desktop
    grep -qi 'Bring Over From Windows' docs/user-guide.md
    ! grep -q 'Bring your setup over' docs/user-guide.md
}

@test "documented buttons and toggles exist in the frontend" {
    grep -q 'Restart into ' app/frontend/src/screens/control.js
    grep -q 'Restart into ' docs/manual-testing.md
    grep -q "'Also delete my Linux data'" app/frontend/src/screens/control.js
    grep -q 'Also delete my Linux data' docs/user-guide.md
    grep -q 'Make it feel like Windows' app/frontend/src/screens/launchpad.js
    grep -q 'Make it feel like Windows' docs/user-guide.md
}

# ── evidence ─────────────────────────────────────────────────────────────────

@test "no doc claims real-hardware verification before the ladder banks it" {
    # ROADMAP names "Proven on real hardware" as the v0.2.0-alpha gate, and
    # status.md rests everything on the KVM rig. The user guide's footer had
    # already declared the gate met.
    grep -q 'Proven on real hardware' ROADMAP.md
    grep -q 'KVM E2E rig' docs/status.md
    ! grep -q 'verified' <(grep -A1 'back-to-Windows loop is' docs/user-guide.md | grep 'real hardware') ||
        { echo "user-guide still claims real-hardware verification"; return 1; }
    grep -q 'KVM E2E rig' docs/user-guide.md
}

@test "every branded walkthrough has its four screenshots on disk" {
    local brand shot
    for brand in $(ls -d app/branding/*/ | xargs -n1 basename); do
        grep -qi "^## " docs/branded-walkthroughs.md || return 1
        for shot in 01-launchpad 02-progress 03-done 04-manage; do
            [ -f "docs/screenshots/brands/$brand/$shot.png" ] ||
                { echo "missing docs/screenshots/brands/$brand/$shot.png"; return 1; }
        done
    done
}

@test "guide describes the explicit Windows-side Linux boot choice" {
    grep -q 'BootIntoLinux' app/frontend/src/screens/control.js
    grep -q 'Restart into' app/frontend/src/screens/control.js
    grep -q 'Windows normally returns after that one-time boot' docs/user-guide.md
    grep -q 'choose it to schedule a Linux boot' docs/user-guide.md
    ! grep -q 'reboots into your new desktop' docs/user-guide.md
}

@test "guide discloses Firefox profile passwords instead of blanket secret exclusion" {
    grep -q 'Firefox passwords came across with the profile' payload/migration/wootc-import-browser
    grep -q 'Firefox imports a complete profile, which can include saved passwords' docs/user-guide.md
    ! grep -q 'never silently copies passwords' docs/user-guide.md
}

@test "guide describes Windows removal as a plan without a consumer execution path" {
    grep -q 'graduate_plan || reclaim_plan' payload/migration/wootc-go-native
    grep -q 'die "in-place (shrink Windows) graduate runs from the graduate-deployer' payload/migration/wootc-go-native
    grep -q 'The app cannot execute those plans for normal use' docs/user-guide.md
    ! grep -q 'This deletes the Windows partition and grows' docs/user-guide.md
}

@test "guide qualifies uninstall restoration and preserves old section anchors" {
    grep -q 'uninstall cleanup incomplete' app/installer_windows.go
    grep -q 'An incomplete cleanup can leave files or boot state behind' docs/user-guide.md
    ! grep -q 'your Windows install is back exactly as it' docs/user-guide.md
    for anchor in 2-install-linux-phase-1 3-first-boot-into-linux-phase-2 8-go-linux-only-phase-3 9-uninstall--put-everything-back 10-troubleshooting; do
        grep -q "id=\"$anchor\"" docs/user-guide.md
    done
}

@test "release guide matches the tagged native graduation gate and its waiver" {
    local gate
    gate=$(sed -n '/^  e2e-gate:/,/^  publish:/p' .github/workflows/release.yml)
    printf '%s\n' "$gate" | grep -q 'gui_install: true'
    printf '%s\n' "$gate" | grep -q 'phase3: true'
    printf '%s\n' "$gate" | grep -q "bitlocker: 'off'"
    grep -q 'Phase 3 native system booted from the graduated install (non-loopback)' tests/e2e/run-e2e.sh
    grep -q 'It ends in graduated Linux' docs/RELEASING.md
    grep -q 'Windows return after graduation' docs/RELEASING.md
    grep -q 'stages selected by that run' docs/RELEASING.md
    grep -q 'skip_e2e.*can waive the gate' docs/RELEASING.md
    ! grep -q 'has migrated to Linux and back on a hosted runner' docs/RELEASING.md
}

@test "release user instructions disclose Install writes before reboot" {
    grep -q 'createRootDisk(cfg.DiskSizeGB)' app/app.go
    grep -q 'configureBCD(cfg)' app/app.go
    grep -q 'Install creates the Linux disk file and changes the boot setup before you' docs/RELEASING.md
    ! grep -q 'Nothing on.*your PC changes until' <(tr '\n' ' ' < docs/RELEASING.md)
}

@test "release user instructions describe Windows return and explicit Linux boot" {
    grep -q 'BootIntoLinux' app/frontend/src/screens/control.js
    grep -q 'Windows normally returns after' docs/RELEASING.md
    grep -q 'Restart into Bluefin' docs/RELEASING.md
    ! grep -q "When it finishes you're in Linux" docs/RELEASING.md
}

@test "release user instructions qualify cleanup and disclose the data choice" {
    grep -q 'uninstall cleanup incomplete' app/installer_windows.go
    grep -q "'Also delete my Linux data'" app/frontend/src/screens/control.js
    grep -q 'cleanup can leave files or boot state behind' docs/RELEASING.md
    grep -q 'is a separate choice' docs/RELEASING.md
    ! grep -q 'Uninstalling is always' docs/RELEASING.md
}

@test "getting started discloses preparation beyond a folder and boot entry" {
    grep -q 'disableFastStartup()' app/app.go
    grep -q 'setupESP(cfg)' app/app.go
    grep -q 'Install.*button starts changes before you restart' docs/getting-started.md
    grep -q 'copies boot files to the EFI system partition' docs/getting-started.md
    grep -q 'changes Windows startup settings' docs/getting-started.md
    ! grep -q 'Everything wootc does before the first reboot lives in one folder' docs/getting-started.md
}

@test "getting started qualifies cleanup and exposes its data choice" {
    grep -q 'uninstall cleanup incomplete' app/installer_windows.go
    grep -q "'Also delete my Linux data'" app/frontend/src/screens/control.js
    grep -q 'Cleanup can fail and leave files or boot state behind' docs/getting-started.md
    grep -q 'Linux data removal is a separate choice in Manage' docs/getting-started.md
    ! grep -q 'Uninstall.*puts things back' <(tr '\n' ' ' < docs/getting-started.md)
}

@test "getting started qualifies reputation prompts instead of promising bypass" {
    grep -q 'Windows policy can prevent continuation' docs/getting-started.md
    grep -q 'unknown or negative reputation' docs/getting-started.md
    grep -q 'learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation' docs/getting-started.md
    ! grep -q 'warnings you.*will' docs/getting-started.md
    ! grep -q 'pre-register software with Microsoft' docs/getting-started.md
    ! grep -q 'and nothing more' docs/getting-started.md
}

@test "getting started distinguishes checksums from publisher identity" {
    grep -q 'artifactauth.Verify(artifactPublicKey, data, sig)' app/artifact_manifest.go
    grep -q 'It does not identify the publisher' docs/getting-started.md
    grep -q 'checks hashes and a signed manifest for its boot artifacts' docs/getting-started.md
    ! grep -q 'same verification on every boot artifact' docs/getting-started.md
}

@test "startup guides disclose the Windows WebView2 runtime dependency" {
    grep -q 'wv2.exe /silent /install' tests/e2e/run-e2e.sh
    grep -q 'EdgeUpdate.*Clients' tests/e2e/run-e2e.sh
    grep -q 'interface needs the WebView2 runtime' docs/RELEASING.md
    grep -q 'interface needs the WebView2 runtime' docs/getting-started.md
    ! grep -q 'no runtime depend' docs/RELEASING.md
    ! grep -q 'There is nothing to "install"' docs/getting-started.md
}

@test "roadmap separates native preview work from complete consumer proof" {
    grep -q 'JSON-RPC' app/serve.go
    grep -q 'Phase B (#343) has a draft native preview and hosted component proof' ROADMAP.md
    grep -q 'Phase C (#344) still needs the complete native consumer and VM journey' ROADMAP.md
    ! grep -q 'Phases B.*not yet started' ROADMAP.md
}

@test "roadmap separates restoration requirement from current partial cleanup" {
    grep -q 'uninstall cleanup incomplete' app/installer_windows.go
    grep -q 'Evidence must prove that uninstall restores the machine' ROADMAP.md
    grep -q 'Uninstall tries cleanup; complete restoration still needs proof' ROADMAP.md
    ! grep -q 'uninstall that restores machine state' ROADMAP.md
}

@test "roadmap requires a SmartScreen observation beyond a valid signature" {
    grep -q 'Windows policy can prevent continuation' docs/getting-started.md
    grep -q 'A valid signature alone does not guarantee' ROADMAP.md
    grep -q 'fresh-machine SmartScreen behavior (#230)' ROADMAP.md
    grep -q 'Signed binaries must pass the SmartScreen gate on a fresh machine' ROADMAP.md
    ! grep -q 'kills the SmartScreen wall' ROADMAP.md
}

@test "README qualifies the VM goal against current desktop evidence" {
    grep -q 'No complete Windows-hosted target desktop proof yet' docs/status.md
    grep -q 'Current releases do not yet provide the complete Linux-inside-Windows journey' README.md
    grep -q 'VM-first goal' README.md
    ! grep -q 'Try before you reboot.*boot the result' <(tr '\n' ' ' < README.md)
}

@test "README exposes preparation settings and normal Windows return" {
    grep -q 'disableFastStartup()' app/app.go
    grep -q 'setupESP(cfg)' app/app.go
    grep -q 'changes Windows startup settings' README.md
    grep -q 'Windows normally returns after deployment' README.md
    grep -q 'Manage offers an explicit Linux boot choice' README.md
    ! grep -q 'Nothing else on the machine is touched' README.md
}

@test "README separates cleanup from restoration and Linux data removal" {
    grep -q 'uninstall cleanup incomplete' app/installer_windows.go
    grep -q "'Also delete my Linux data'" app/frontend/src/screens/control.js
    grep -q 'Uninstall tries cleanup; it can leave files or boot state behind' README.md
    grep -q 'Linux data removal is a separate choice' README.md
    ! grep -q 'uninstall and leave no trace' README.md
    ! grep -q 'uninstalling is deleting a folder' README.md
}

@test "README matches release graduation and its manual waiver" {
    grep -q 'phase3: true' .github/workflows/release.yml
    grep -q 'Emergency: publish WITHOUT the E2E gate' .github/workflows/release.yml
    grep -q 'does not prove a Windows return after graduation' README.md
    grep -q 'manual emergency waiver remains' README.md
    ! grep -q 'returns to Windows cleanly' README.md
}

@test "README qualifies browser secrets instead of a blanket exclusion" {
    grep -q 'Firefox passwords came across with the profile' payload/migration/wootc-import-browser
    grep -q 'A complete Firefox profile can include saved passwords' README.md
    ! grep -q 'passwords, keys, and tokens stay' README.md
}

@test "README discloses runtime and distinguishes hashes from signed manifests" {
    grep -q 'artifactauth.Verify(artifactPublicKey, data, sig)' app/artifact_manifest.go
    grep -q 'wv2.exe /silent /install' tests/e2e/run-e2e.sh
    grep -q 'checks hashes, and verifies a signed manifest' README.md
    grep -q 'Wails interface needs the WebView2 runtime' README.md
    grep -q 'Policy can prevent continuation' README.md
}

@test "E2E architecture separates historical native diagrams from current acceptance" {
    grep -q 'They do not prove Linux inside Windows or the WinUI journey' docs/e2e-architecture.md
    grep -q 'status.md#buildtest-matrix' docs/e2e-architecture.md
    ! grep -q 'Everything here was validated live' docs/e2e-architecture.md
}

@test "E2E architecture follows the actual sourced runner boundaries" {
    for module in qga-transport host-runtime retention vm-start; do
        grep -q "source .*lib/$module.sh" tests/e2e/run-e2e.sh
        grep -q "$module.sh" docs/e2e-architecture.md
    done
    grep -q 'Neither probe accepts a token when its command fails' docs/e2e-architecture.md
    ! grep -q 'transport,.*still need separate modules' docs/e2e-architecture.md
}

@test "E2E architecture does not claim an atomic deployer menu handoff" {
    grep -q 'for gd in "$TARGET_VENDOR" fedora wootc' payload/deployer/deploy.sh
    grep -Fq '> "/mnt/esp/EFI/$gd/grub.cfg"' payload/deployer/deploy.sh
    grep -q 'this is not an atomic handoff' docs/e2e-architecture.md
    grep -q 'An interrupted update can leave partial boot state' docs/e2e-architecture.md
    ! grep -q 'atomically with a successful deployment' docs/e2e-architecture.md
}

@test "E2E architecture distinguishes a QGA service request from a working channel" {
    grep -Fq 'MGMT_KARG="systemd.wants=qemu-guest-agent.service"' payload/deployer/deploy.sh
    grep -q 'That request alone does not prove the service exists or runs' docs/e2e-architecture.md
    ! grep -q 'deployed system is given a control channel' docs/e2e-architecture.md
}

@test "release rollback distinguishes remote withdrawal from signed local cache" {
    # The current engine authenticates local metadata first. Deleting a release
    # cannot recall valid cached inputs, and preparation precedes downloads.
    grep -q 'readLocalMetadata(path, artifactauth.MaxManifestSize)' app/artifact_manifest.go
    grep -q 'artifactauth.Verify(artifactPublicKey, data, sig)' app/artifact_manifest.go
    grep -q 'Remote asset removal cannot revoke' runbooks/rollback-a-bad-release.md ||
        grep -q 'local cache and offline bundle can remain usable' runbooks/rollback-a-bad-release.md
    grep -q 'SHA256SUMS.sig' runbooks/rollback-a-bad-release.md
    grep -q 'removes its private seed after use' runbooks/rollback-a-bad-release.md
    grep -q 'preparation occur before that stage' runbooks/rollback-a-bad-release.md
    ! grep -q 'installs nothing' runbooks/rollback-a-bad-release.md
    ! grep -q 'upload the matching regenerated' runbooks/rollback-a-bad-release.md
}

@test "manual hardware guide discloses actual preparation outside the state folder" {
    grep -q 'Resize-Partition -DriveLetter C' app/disk_windows.go
    grep -q 'New-Partition -DiskNumber' app/disk_windows.go
    grep -q 'disableFastStartup()' app/app.go
    grep -q 'setupESP(cfg)' app/app.go
    grep -q 'boot files on the ESP' docs/manual-testing.md
    grep -q 'may resize Windows' docs/manual-testing.md
    ! grep -q 'no repartitioning' <(tr '\n' ' ' < docs/manual-testing.md)
    ! grep -q 'Nothing before the reboot leaves more than' docs/manual-testing.md
}

@test "manual hardware guide separates requested return and cleanup from restoration" {
    grep -q 'uninstall cleanup incomplete' app/installer_windows.go
    grep -q 'reboot -ff' payload/deployer/deploy.sh
    grep -q 'a reboot request does not prove a Windows return' docs/manual-testing.md
    grep -q 'Uninstall tries cleanup; it can leave files or boot state behind' docs/manual-testing.md
    ! grep -q 'Uninstall puts everything back' docs/manual-testing.md
    ! grep -q 'after 30 seconds' docs/manual-testing.md
}

@test "manual hardware guide qualifies the legacy path instead of claiming VM-first or WinUI proof" {
    [ -f docs/adr/0004-restore-vm-first-product.md ]
    [ -f docs/winui-shell.md ]
    grep -q 'legacy Wails path for native installation' docs/manual-testing.md
    grep -q 'prove a Linux desktop inside Windows or the WinUI journey' docs/manual-testing.md
}
