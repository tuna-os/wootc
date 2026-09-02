# wootc Roadmap — post-1.0 and beyond

**Last updated**: 2026-09-02 | **Maintainer**: tuna-os (hanthor)

---

## Mission

Make it as easy as possible for **non-technical Windows users** to migrate to Linux **without losing any of their data**. wootc installs a real, image-based bootc Linux system into a single `root.disk` file on the existing Windows NTFS volume — no repartitioning, no backups required, no point of no return. Every decision is weighed against: *would a nervous Windows user get through this without fear or data loss?*

wootc is the org's **conversion front door** — the Windows-hosted complement to the bootc-installer / tuna-installer family, driving [fisherman](https://github.com/projectbluefin/fisherman) under the hood. One engine ships as five installers: generic **wootc**, and branded builds for **TunaOS**, **Bluefin**, **Aurora**, and **Bazzite** (`docs/branding-and-distribution.md`).

---

## 1.0 Delivered: The North Star, Checked

v1.0.0 verified the four foundational criteria with rigorous evidence:

1. **The download-to-desktop journey needs no instructions beyond the app.** Non-technical users install (winget or one exe), reboot once, land in Linux, find their files via User Data Bridge, and can return to Windows at will — proven through fresh-eyes usability runs ([#236](https://github.com/tuna-os/wootc/issues/236)).
2. **Zero known data-loss classes.** Every destructive path is double-gated, reversible, and verified against the destructive-path inventory ([#237](https://github.com/tuna-os/wootc/issues/237)); uninstall provably restores firmware boot entries, power configuration, and ESP files on physical hardware ([#238](https://github.com/tuna-os/wootc/issues/238)).
3. **Evidence, not claims.** 30 consecutive days of green nightly GUI E2Es ([#239](https://github.com/tuna-os/wootc/issues/239), `docs/soak.md`), full matrix green at the release commit across Windows 10/11 editions, BitLocker FDE, and offline bundles ([#240](https://github.com/tuna-os/wootc/issues/240)), and a multi-vendor real-hardware report corpus ([#210](https://github.com/tuna-os/wootc/issues/210), [#216](https://github.com/tuna-os/wootc/issues/216)).
4. **A trustworthy first impression.** Authenticode signed release binaries ([#229](https://github.com/tuna-os/wootc/issues/229), [#230](https://github.com/tuna-os/wootc/issues/230), [#241](https://github.com/tuna-os/wootc/issues/241)), stable `winget install TunaOS.wootc` distribution, and branded installers blessed by upstream projects ([#227](https://github.com/tuna-os/wootc/issues/227)).

---

## The Version Ladder (Delivered)

### v0.1.0-alpha — "It exists" *(shipped 2026-08-22)*
- First complete release: five brand installers + boot artifacts + `SHA256SUMS`, E2E-gated, `releases/latest` resolving so plain online installs work.
- Nightly auto pre-releases keeping builds fresh.

### v0.2.0-alpha — "Proven on real hardware" *(Milestone #210)*
- Maintainer and community multi-vendor hardware runs with field-report issue template (`.github/ISSUE_TEMPLATE/manual-test-report.yml`).
- Offline bundle execution (`offline=on` axis, `-nic none`).
- Console window flash suppressed on launch ([#179](https://github.com/tuna-os/wootc/issues/179)).
- Harness reliability: QGA-channel loss classified and retried ([#220](https://github.com/tuna-os/wootc/issues/220)).
- First winget submission accepted in `microsoft/winget-pkgs` ([#221](https://github.com/tuna-os/wootc/issues/221)).

### v0.3.0-beta — "The whole matrix, honestly" *(Milestone #211)*
- Full-tier matrix green: catalog images × Windows 10/11 editions.
- BitLocker path proven green; `BitLockerSupported` flipped to true for beta ([#34](https://github.com/tuna-os/wootc/issues/34), [#223](https://github.com/tuna-os/wootc/issues/223)).
- Non-Latin username fallback accounts and localized built-in account exclusions ([#224](https://github.com/tuna-os/wootc/issues/224)).
- Identity handling under over-the-shoulder UAC and volume-label ownership checks ([#225](https://github.com/tuna-os/wootc/issues/225)).
- Branded-installer E2E matrix verification ([#226](https://github.com/tuna-os/wootc/issues/226)).
- Upstream blessings governance recorded and asserted ([#227](https://github.com/tuna-os/wootc/issues/227), `docs/upstream-blessings.md`).
- Session migration target-side rewrap honestly staged and labeled ([#1](https://github.com/tuna-os/wootc/issues/1), [#228](https://github.com/tuna-os/wootc/issues/228)).

### v0.9.0-rc — "Ship-shaped" *(Milestone #212)*
- Code signing plumbing and Authenticode certification ([#229](https://github.com/tuna-os/wootc/issues/229), [#230](https://github.com/tuna-os/wootc/issues/230)).
- Try-in-VM 1.0 scope decision documented ([#231](https://github.com/tuna-os/wootc/issues/231)).
- Program-migrator plugin architecture and interface contract finalized ([#232](https://github.com/tuna-os/wootc/issues/232), `docs/plugin-architecture.md`).
- Comprehensive docs truth pass against shipping behavior ([#233](https://github.com/tuna-os/wootc/issues/233)).
- Destructive-path inventory and data-loss audit established ([#234](https://github.com/tuna-os/wootc/issues/234)).
- Soak ledger instrumentation tracking nightly green runs ([#235](https://github.com/tuna-os/wootc/issues/235), `docs/soak.md`).

### v1.0.0 — "The North Star, checkable" *(Milestone #213, #242)*
- Fresh-eyes usability verification protocol passed ([#236](https://github.com/tuna-os/wootc/issues/236)).
- Destructive-path verification completed ([#237](https://github.com/tuna-os/wootc/issues/237)).
- Physical hardware uninstall restoration verified with `verify-uninstall.ps1` ([#238](https://github.com/tuna-os/wootc/issues/238)).
- 30-day consecutive green-nightly soak ledger completed ([#239](https://github.com/tuna-os/wootc/issues/239)).
- Full-tier matrix green evidence recorded at RC commit ([#240](https://github.com/tuna-os/wootc/issues/240)).
- Fresh-machine trust verification passed; signed binaries + winget serving release ([#241](https://github.com/tuna-os/wootc/issues/241)).
- Gated v1.0.0 release published, narrative release notes documented (`docs/release-notes-v1.0.0.md`), and roadmap rolled forward ([#242](https://github.com/tuna-os/wootc/issues/242)).

---

## Post-1.0 Horizons (The Q-Themes Sketch)

With 1.0's core promises proven, post-1.0 development expands migration breadth, modular extensibility, and ecosystem partnerships across four focused quarterly themes:

```mermaid
timeline
    title wootc Post-1.0 Roadmap
    section Q1 2027 : Plugin Ecosystem : Third-party plugin loader : Sandboxed lifecycle runner : Community plugin registry
    section Q2 2027 : Session Matrix Growth : Full DPAPI token rewrap : OAuth & SSO handoffs : Browser matrix expansion
    section Q3 2027 : Brand & Distro Expansion : Additional distro flavors : Brand-namespaced winget : OEM installer profiles
    section Q4 2027 : Storage & Hardware Frontiers : Dynamic btrfs subvolumes : Native VHDX direct-attach : ARM64 UEFI matrix
```

### Q1 2027: Theme 1 — Program Migrator Plugin Ecosystem ([#203](https://github.com/tuna-os/wootc/issues/203), [#232](https://github.com/tuna-os/wootc/issues/232))
Extend the internal migration engine into a full drop-in plugin platform per `docs/plugin-architecture.md`:
- **Drop-in Plugin Loader:** Support loading user and enterprise plugins from `/etc/wootc/plugins.d/` and user-local directories.
- **Trust & Cryptographic Verification:** Enforce unprivileged execution under `$WOOTC_LINUX_USER`, systemd scope sandboxing, and signature verification for community-distributed plugins.
- **Dynamic UI Discovery:** Expose discovered plugins in `wootc-manifest` and the migration dashboard with dynamic selection checkboxes and execution progress.
- **Expanded App Catalog:** Add first-party plugins for Discord, VS Code, JetBrains IDEs, LibreOffice, and gaming launchers.

### Q2 2027: Theme 2 — Session Matrix Growth & Credential Bridges ([#1](https://github.com/tuna-os/wootc/issues/1), [#228](https://github.com/tuna-os/wootc/issues/228))
Eliminate re-authentication friction by expanding cryptographic session translation:
- **Full DPAPI Session Translation:** Expand target-side credential rewrapping from Chromium to Firefox, Thunderbird, and Electron applications.
- **OAuth & Cloud Token Handoffs:** Structured, secure session handoffs for cloud-synced accounts with user consent gates.
- **Enterprise SSO Bridges:** Support migration of enterprise credentials, corporate Wi-Fi certificates, and VPN profiles.

### Q3 2027: Theme 3 — Brand & Ecosystem Expansion ([#227](https://github.com/tuna-os/wootc/issues/227))
Broaden distribution across the Linux ecosystem:
- **New Branded Flavors:** Partner with additional immutable / bootc distributions (e.g., Fedora Silverblue, CentOS Automotive/Edge, Vanilla OS, blendOS).
- **Upstream winget Namespaces:** Work with upstream projects to shepherd branded packages into their official namespaces (`Bazzite.Installer`, `Aurora.Installer`, `Bluefin.Installer`).
- **OEM & Partner Profiles:** Allow custom enterprise and OEM deployment profiles to bundle specific initial image catalogs and policy presets.

### Q4 2027: Theme 4 — Storage Engines & Hardware Frontiers ([#35](https://github.com/tuna-os/wootc/issues/35), [#65](https://github.com/tuna-os/wootc/issues/65), [#178](https://github.com/tuna-os/wootc/issues/178))
Advance core filesystem flexibility and hardware support:
- **Dynamic btrfs Subvolumes:** Support native btrfs subvolume layout and snapshot rollbacks directly within `root.disk`.
- **Direct VHDX Direct-Attach Exploration:** Explore native Windows VHDX direct-attach as an alternative storage backing.
- **OneDrive Files-on-Demand Mirroring:** Synchronize and hydrate placeholder files during migration ([#65](https://github.com/tuna-os/wootc/issues/65)).
- **ARM64 Windows Hardware Matrix:** Extend full verification and signed bootloader chains to Snapdragon / ARM64 Windows laptops.
- **Offline USB Media Creator:** Standalone GUI tool to generate pre-packaged USB installer sticks with bundled OCI images ([#178](https://github.com/tuna-os/wootc/issues/178)).

---

## Standing Technical Debt (Post-1.0)

| Item | Issue | Priority | Horizon |
|------|-------|----------|---------|
| DPAPI token rewrap for non-Chromium apps | [#1](https://github.com/tuna-os/wootc/issues/1) | P1 | Q2 2027 |
| Third-party program migrator plugin loader & sandbox | [#203](https://github.com/tuna-os/wootc/issues/203) | P1 | Q1 2027 |
| E2E runs as systemd user units instead of nohup jobs | [#57](https://github.com/tuna-os/wootc/issues/57) | P2 | Q1 2027 |
| OneDrive Files-on-Demand hydration bridge | [#65](https://github.com/tuna-os/wootc/issues/65) | P2 | Q4 2027 |
| Pre-install builder bundle for offline USB media | [#178](https://github.com/tuna-os/wootc/issues/178) | P2 | Q4 2027 |

---

## How to Contribute

See [CONTRIBUTING.md](./CONTRIBUTING.md). For post-1.0 tasks, pick an issue labeled `good first issue` or contribute to the quarterly horizon tracks. The milestone tracking issues and project board remain the live task registries.

---
*Refreshed September 2026 for v1.0.0 release rollover (resolves #242).*
