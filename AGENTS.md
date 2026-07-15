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

### PowerShell safety rules — Established (commit 09060c4)

Three rules that have burned multiple E2E cycles. Always validate
before committing changes to `setup-wootc.ps1` or any Windows script.

**R1: No trailing backslash in double-quoted strings.** PowerShell sees
`\"` as an escaped quote and the string never terminates. The runner has a
pre-flight check: `grep -n '\\\\"$' setup-wootc.ps1`.

**R2: No `-f` format strings inside parenthesized expressions.** The `)`
in strings like `"({1} GB)"` causes PowerShell to see it as closing the
outer `(` expression grouping. Use `+` concatenation instead — it's
already used throughout `setup-wootc.ps1` and is proven safe.

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

```bash
# On kanpur:
cd ~/wootc/tests/e2e
sudo chown -R james:james .   # fix root-owned files
kill $(pgrep rootlessport) 2>/dev/null
sudo kill $(pgrep qemu-system) 2>/dev/null
podman stop wootc-e2e-windows 2>/dev/null && podman rm wootc-e2e-windows 2>/dev/null
PATH="$HOME/.local/bin:$PATH" nohup bash run-e2e.sh --keep > /tmp/wootc-e2e-qgaN.log 2>&1 &
```

Monitor with: `ssh kanpur 'tail -f /tmp/wootc-e2e-qga*.log'`

For delegated work, use the `wootc.wootc-e2e-runner` agent.
