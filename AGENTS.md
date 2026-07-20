# wootc — Agent Guidance

## SOFA Usage

When beginning meaningful work in this project, create or confirm a SOFA
API session and check SOFA attention if available. The API key is stored
in `~/.sofa/credentials.json` (gitignored, chmod 600).

Before spending meaningful time on uncertain technical work, search SOFA
for existing questions, TILs, Blueprints, Playbooks, or replies that
could apply. Prefer higher-trust results when several posts fit, but
inspect the content before relying on it.

When SOFA content helps, vote at read time if you can judge usefulness.
After you actually apply guidance from a post, verify the post with the
observed outcome.

Before ending meaningful coding, debugging, configuration, or research
work, decide whether the session produced reusable knowledge. If it did,
contribute with the smallest matching SOFA primitive: vote, verification,
reply, TIL, question, Blueprint, or Playbook.

Do not publish public SOFA content without following the agent role,
publication policy, moderation, and human-approval requirements.

## Start here

- **`docs/agent-lessons.md`** — traps that have each cost a 60–90 minute VM run.
  Read before touching the E2E harness, the deployer, or the runners.
- **`docs/phase2-debug-plan.md`** — live hypotheses for the Phase-2 boot, kept
  strictly separated into what is *established* vs merely *claimed*.

The single most useful heuristic in this codebase: **status derived from a proxy
rather than an observable is the dominant bug class here.** When adding a check,
ask what it would print if the thing it asserts never happened — then break the
code and confirm the test goes red.

## Project layers

The codebase has four distinct layers. Delegate to the matching agent when
working in a specific layer.

| Layer | Agent | Key files |
|-------|-------|-----------|
| Windows OEM | `wootc.wootc-windows-oem` | `autounattend.xml`, `setup-wootc.ps1`, `install.bat` |
| QGA control plane | `wootc.wootc-qga-control` | `qga.py`, QGA socket wiring in `compose.yml` |
| Deployer initramfs | `wootc.wootc-deployer` | `module-setup.sh`, `deploy.sh`, `deploy-hook.sh` |
| E2E test runner | `wootc.wootc-e2e-runner` | `run-e2e.sh`, Kanpur infrastructure |

All four agents have the `wootc-e2e` skill loaded, which covers shared
knowledge: PowerShell safety rules, QGA primitives, Kanpur quirks, and the
debug cycle.

## Project status

### QGA control plane — Live (commit 377a2ff)

The E2E control plane has been migrated from WinRM to QEMU Guest Agent.
The QGA client (`tests/e2e/qga.py`, 131-line stdlib Python) talks
JSON-lines over a virtio-serial Unix socket at `/run/shm/qga.sock`.

QGA provides:
- `guest-ping` for readiness (no credentials needed)
- `guest-exec` for running PowerShell as SYSTEM
- `guest-file-read` for reading OEM logs
- Reboot detection via guest-ping down/up cycle

See `HANDOFF.md` for the full design rationale.

### E2E Testing — autounattend.xml v3 Fixed (commit 0779d8d)
The critical fix: autounattend.xml was missing a `DiskConfiguration` block.
Without it, Windows Setup waits forever at "Where do you want to install
Windows?" — disk never grows past 1.2MB. v3 adds explicit UEFI GPT
partitioning (EFI 100MB + MSR 16MB + Primary), removes EnableLUA=false
(breaks Windows 11 boot), and merges WinRM setup into consolidated
FirstLogonCommands.

### BCD Chainload — Proven Working
`bcdedit /copy {bootmgr}` (not `/create /application firmware`) is the
correct approach. `/application firmware` is not a valid bcdedit type on
Windows 11. Fixed in `setup-wootc.ps1` and `app/installer_windows.go`.

### wubildr.efi — Built and Tested
Custom GRUB core image (1.3MB) with embedded bootstrap config, ntfs +
loopback modules. Built via `grub2-mkimage` inside the deployer container.
Stock Fedora grubx64.efi drops to rescue shell — wubildr.efi fixes this.

### Secure Boot chainload — shim + signed grub (not yet green)

`wubildr.efi` is **unsigned**, so Secure Boot rejects it with `Access Denied`
on the serial console. The fix is a Microsoft-signed intermediate bootloader:

**UEFI → shimx64.efi → grubx64.efi → grub.cfg → deployer**

| Component | Signer | Source |
|-----------|--------|--------|
| `shimx64.efi` | Microsoft | Fedora `shim-x64` package |
| `grubx64.efi` | Fedora (in-shim MOK) | Fedora `grub2-efi-x64` package |
| `grub.cfg` | N/A (on ESP) | same logic as `wubildr.cfg` |
| `ntfs.mod`, `loopback.mod` | N/A (loaded by grub from ESP) | Fedora `grub2-efi-x64-modules` |

**Critical:** Fedora's signed `grubx64.efi` does NOT embed ntfs+loopback
modules. Place them as separate `.mod` files on the ESP and `insmod ntfs`
`insmod loopback` in `grub.cfg` BEFORE any search/loopback commands.

### E2E boot chain progress
Each row is a separate reboot from one step to the next:

| Step | Status | Evidence |
|------|--------|----------|
| OEM setup complete | ✅ | root.disk created, BCD configured, Fast Startup disabled |
| Boot via wubildr.efi | ❌ | `Access Denied` — unsigned binary, Secure Boot blocks it |
| Boot via shimx64.efi | ✅ | `BdsDxe: starting Boot0005...shimx64.efi` — no Access Denied |
| GRUB loads grub.cfg | ✅ | `GRUB version 2.12` visible on serial console |
| GRUB loads ntfs.mod | ❌ | `error: no such device:` — modules not on ESP |
| GRUB finds root.disk | ❌ | Blocked by missing modules |
| Deployer boots | ❌ | Not yet reached |
| fisherman runs | ❌ | Not yet reached |
| Linux installed + Windows returns | ❌ | Not yet reached |

### Serial logging

The `compose.yml` overrides Dockur's default `SERIAL=mon:stdio` with
`SERIAL=file:/storage/deployer-serial.log` so the deployer's console output
is written to a persistent file on the mounted `/storage` volume. This file
**survives container teardown** and single-handedly made the Secure Boot
rejection visible.

### Snapshot before Phase 2

Always copy `storage/data.qcow2` before the first deployer boot. If the
deployer fails or corrupts the disk, restore from the snapshot and retry
without reinstalling Windows:

```bash
cp storage/data.qcow2 storage/data.qcow2.snap
# ... attempt deployer boot, fails ...
cp storage/data.qcow2.snap storage/data.qcow2
# restart VM --skip-install
```

### PowerShell safety rules — Established (commit 09060c4)

Three rules that have burned multiple E2E cycles. Always validate
before committing changes to `setup-wootc.ps1` or any Windows script.

**R1: No trailing backslash in double-quoted strings.** PowerShell sees
`\"` as an escaped quote and the string never terminates. The runner has a
pre-flight check: `grep -n '\\\\"$' setup-wootc.ps1`.

**R2: Use variable expansion — no `-f` or `+` concatenation inside parenthesized expressions.**
Both `-f` format strings and `+` concatenation inside `(...)` trigger parser
confusion with closing parentheses. Use plain variable expansion:
`Write-Host "  root.disk: $diskPath ($DiskSizeGB GB)"`

**R3: Single-quote here-strings for GRUB config.** GRUB config contains
`$prefix`, `$root`, `{` etc. Use `@'...'@` not `@"..."@`.

**R4: CRLF line endings + UTF-8 BOM for Windows PowerShell 5.1.**
PowerShell 5.1's `Get-Content -Raw` and internal script parser corrupt
UTF-8 files with LF-only line endings. The E2E runner automatically
converts `setup-wootc.ps1` before staging it in the OEM payload.
Always use `printf '\xEF\xBB\xBF' > file.ps1; sed 's/$/\r/' file.ps1 >> file.ps1.crlf`
when writing PowerShell scripts intended for Windows 10/11 VMs.

### Kanpur quirks

The E2E host (kanpur) is Bluefin (Fedora Silverblue, immutable). These
quirks are documented in the `wootc-e2e` skill and the e2e-runner agent:

- `podman-compose` is at `~/.local/bin/podman-compose`, not on default PATH
- Podman creates root-owned files in `tests/e2e/` — `chown -R` before re-running
- Stale `rootlessport` processes hold port 3389 across runs — kill them
- Container name is always `wootc-e2e-windows`

### Phase 2 target (not yet green)

1. Fresh Windows 11 install under KVM + TPM 2.0 + Secure Boot.
2. Windows creates `root.disk`, copies the deployer, installs `wubildr.efi`,
   and configures the one-shot BCD entry.
3. The deployer boots and completes Linux installation.
4. Windows returns after that one-shot deployer boot.
5. The test explicitly schedules the installed Phase 2 Linux root, observes a
   successful Linux boot, then observes a successful Windows return.

### Key artifacts
- `CONTEXT.md` — Domain glossary (Phases 1-3, root.disk, User Data Bridge)
- `HANDOFF.md` — QGA migration design rationale and decision record
- `docs/adr/0001-phase1-first-architecture.md` — Phase 1 VM-first architecture
- `tests/e2e/wootc-files/wubildr.efi` — Custom GRUB image (1.3MB)
- `tests/e2e/qga.py` — QGA JSON-lines client (stdlib only)
- `AGENTS.md` — This file

### Running E2E

**Read `docs/agent-lessons.md` first.** It records the traps that have each cost
at least one 60–90 minute run — liveness signals that lie, timeouts that are not
wall-clock, vacuous tests on a noexec /tmp, and the runner operations that have
killed live runs.

Prefer a **GitHub hosted runner** over the laptops:

```bash
gh workflow run e2e-nightly.yml --ref <branch> \
  -f image=ghcr.io/tuna-os/yellowfin:gnome -f win_version=11 -f bitlocker=off
```

ubuntu-latest exposes `/dev/kvm`, and `e2e-hosted.yml` handles disk reclaim and
storage placement. The three laptop runners have each failed in a different
host-specific way (see the table at the end of `docs/agent-lessons.md`).

On a laptop runner, launch as a **systemd user unit** — not `nohup`. Lingering
must be enabled or systemd kills the run when your ssh session closes:

```bash
loginctl enable-linger james          # once per host
ssh <host> 'cd /var/home/james/wootc
  systemd-run --user --unit=wootc-e2e --collect \
    --setenv=XDG_RUNTIME_DIR=/run/user/$(id -u) \
    --setenv=HOME=/var/home/james \
    -p StandardOutput=append:/tmp/wootc-e2e-run.log \
    -p StandardError=append:/tmp/wootc-e2e-run.log \
    -p WorkingDirectory=/var/home/james/wootc \
    ./tests/e2e/run-e2e.sh ghcr.io/tuna-os/yellowfin:gnome'
```

`XDG_RUNTIME_DIR` and `HOME` are required, or rootless podman resolves *root*
storage paths and fails with `permission denied` on `/run/containers/storage`.

**Checking on a run** — do not trust `pgrep` (it matches your own ssh command)
or `systemctl is-active` (meaningless if launched via nohup). Use:

```bash
ssh <host> '
  # is it writing?
  echo "age=$(( $(date +%s) - $(stat -c %Y /tmp/wootc-e2e-run.log) ))s"
  # is the guest working? silence + high CPU = fine, silence + idle = wedged
  podman exec wootc-e2e-windows sh -c "ps -eo pcpu,args | grep [q]emu-system"
  # read only the CURRENT run (logs are appended across runs)
  L=$(grep -an "Run ID" /tmp/wootc-e2e-run.log | tail -1 | cut -d: -f1)
  tail -n +$L /tmp/wootc-e2e-run.log | tail -5'
```

Decisive markers to grep for, in order of the run:
`closure staged and verified` → `deployer active` → `deployer rebooted` →
`attach-loop hook entered` → either an `EXIT: <reason>` line or
`post-attach by-uuid`.

**Never** `podman system prune -af` on a host with a live run. It has killed
three runs at once and deleted the locally-built
`wootc-e2e-windows-ssh:latest`, after which compose tries to pull from a
registry literally named `localhost`. Rebuild with
`bash tests/e2e/build-ssh-image.sh`.

For delegated work, use the `wootc.wootc-e2e-runner` agent.
