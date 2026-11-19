# Coming from WSL: move your workflow, not your whole distribution

WSL runs Linux inside Windows. wootc's native path installs a separate Linux
system beside Windows; it does not turn your WSL installation into a bootable
system. Your Windows account, WSL account and new Linux account are different.
With Windows, you can compare your work and return to the original tools.
This does not guarantee protection against data loss.

Read the [current status](status.md), [download guide and trust prompts](getting-started.md)
and [user guide](user-guide.md) before you choose a build.
A release tag does not prove readiness for VM-first use, a particular image
or your hardware. The complete VM-first experience has its own acceptance gate.

## 1. Inventory and back up in Windows

1. Run `wsl --list --verbose` in PowerShell. Record the distributions you use
   privately; do not paste account details into a public report.
2. In each WSL distribution, save open work. Commit projects or back them up
   independently. Record required runtimes, packages, databases and services.
   Projects under `/home` live inside WSL, not in Windows Documents.
3. Stop database/services cleanly, exit applications and run `wsl --shutdown`
   from PowerShell. Do this before you export or install.
   Do not treat a copy of a live `ext4.vhdx` as an application-consistent backup.
4. Export **each** needed distribution to independent backup storage. For
   example, if `wsl --list --verbose` lists `Ubuntu` and `E:` is your backup:

   ```powershell
   wsl --export Ubuntu E:\Backups\Ubuntu-before-wootc.tar
   ```

   Use your actual distribution name and an existing backup destination. A
   WSL export can contain passwords, keys and work data: encrypt/protect it,
   and never attach it to an issue. Follow
   [Microsoft's WSL export/import guidance](https://learn.microsoft.com/en-us/windows/wsl/basic-commands#export-a-distribution)
   to verify restoration on a separate test instance. An export is not proof
   of recovery until you have checked its contents and restore procedure.
5. Back up Windows files separately, including cloud data downloaded for
   offline use. Keep recovery media for Windows accessible without this PC.
   Also keep any BitLocker key you need accessible without this PC.
   Do not decrypt or bypass organizational policy to satisfy the installer.

Keep these backups and WSL installed throughout the trial. Do **not** run
`wsl --unregister`: it deletes the registered distribution's data.

## 2. Install through the supported journey

Follow the selected build's [user guide](user-guide.md).
If you volunteer, also follow the [manual test protocol](manual-testing.md).
Use an admitted image and storage plan. Keep Windows as your recovery path.
Do not remove Windows or reclaim its partition during a first migration.
Review the proposed disk and boot changes; do not assume every plan only creates a file.

On first Linux login, inspect **Bring Over From Windows** and the WSL category
when available. Availability in code or a dashboard is not proof that the
selected image and hardware have passed migration acceptance.

## 3. Understand what the WSL helper actually does

The implementation is
[`wootc-wsl-bridge`](../payload/migration/wootc-wsl-bridge):

| Source | Behavior and limit |
| --- | --- |
| WSL1 files under the Windows profile | Searches legacy `lxss/rootfs` and Store `Packages/*/LocalState/rootfs` locations. |
| WSL2 `ext4.vhdx` | Searches Store `Packages/*/LocalState` and `wsl/*` under the Windows profile; needs `qemu-nbd`, an available NBD device and readable Windows storage. Attaches the source read-only. Imported/custom-location distros may not be found. |
| Multiple distros or Linux homes | Uses the first discovered rootfs and first home directory (or `/root`); it is **not** a distro/account picker. If this is not your intended source, leave the WSL category off and restore selected files manually from your backup. |
| Shell/editor config | Copies an allowlist including `.bashrc`, `.zshrc`, `.gitconfig`, `.vimrc`, `.tmux.conf` and selected other dotfiles; skips destination files already present. It does not merge them. |
| SSH | Copies public keys, `config` and `known_hosts` if absent at the destination; does not copy SSH private keys or GPG private-key stores. |
| Packages | Maps a subset of installed Debian/Ubuntu `dpkg` packages to a proposed `~/.config/wootc/Brewfile`. This is neither the complete package set nor a version lock; other package managers are not reconstructed. |
| Projects, databases, containers, services and credentials | No complete WSL filesystem, application state, account or service import. Move these deliberately from verified backups using the application's own procedure. |

**Review configuration for secrets before you select migration.** An allowlisted
`.gitconfig`, `.curlrc`, `.zshenv` or SSH config can itself contain a token,
private host name or command. An allowlist is not a secret scanner. Also review
commands in shell startup files before you open the destination shell.
The exclusion of private-key files does not make every copied configuration non-sensitive.

## 4. Rebuild and verify the development environment

1. Compare copied dotfiles with your backup and review import results for each
   item. A preserved collision or partial result is not a completed migration.
   Deliberately merge files that the helper skipped. Adapt WSL paths such as
   `/mnt/c`, `wsl.exe` calls and Windows executables.

   Keep native edits and back up the destination config before you edit it.
   Do not replace a destination symlink or delete an existing file to force the importer to run.
2. Inspect `~/.config/wootc/Brewfile` before you install anything. Preserve any
   native edits. Manually merge a proposal that conflicts with native content.
   Do not assume silent regeneration or that a retry refreshed the file.
   Where Homebrew is available and the reviewed tools are appropriate, run as
   your normal user:

   ```sh
   brew bundle --file="$HOME/.config/wootc/Brewfile"
   ```

   This optional step will download software; it does not automatically restore
   the full toolchain. Use your distribution's supported tools for other packages.
3. Restore a non-sensitive project to a new Linux directory. Compare important
   files with the backup, and run its normal build/tests. Re-establish language
   runtimes, databases and containers with their supported migration methods.
4. Sign into services again or enroll new keys through your organization's
   approved procedure. Do not copy credential stores to avoid sign-in.
5. Verify the contents of files, editor settings, network access and a work task.
   A populated dashboard or generated Brewfile alone is not success.
6. Reboot to the Windows desktop, confirm the original WSL environment still
   works, and re-enter Linux using the documented management path. For an alpha
   cohort run, complete uninstall and the restoration checklist too.

## If it does not work

A missing WSL category, wrong source, empty folder, unexpected prompt or broken
return to Windows is a problem to report. Do not force-mount disks or delete
the original. Stop and submit a sanitized
[field report](https://github.com/tuna-os/wootc/issues/new?template=manual-test-report.yml).
Include the build, WSL1/WSL2, checkpoint and whether you needed help.

Never attach an export, `.vhdx`, recovery key, raw home directory or configuration
with credentials. See [recovery and uninstall](user-guide.md#10-problems-and-recovery).

Real user stories and public videos need an actual completed journey and the
participant's separate consent for publication. This guide is a procedure, not
a claim of a successful case study for a WSL graduation.
