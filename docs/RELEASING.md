# Releasing wootc — the green-gated ladder

wootc writes Linux onto a stranger's only computer. The release rule follows
directly from the North Star (*a nervous Windows user must not lose data*):
**the app only ever offers scenarios the E2E matrix has actually proven
green.** Everything else is hidden until it is proven. Features unlock as the
matrix greens; the channel graduates when whole tiers are green.

## The single source of truth

The [build/test matrix](../README.md#buildtest-matrix) is authoritative. A
combination is *green* only when the hosted E2E (`e2e-matrix.yml` /
`e2e-gui.yml`) has passed it end-to-end — Windows seed → deploy → Phase-2
bridge → Phase-3 native disk → seeded file on the native disk.

Two places consume that status, and they must agree:

- **`app/data/images.json`** — each image carries `"status": "green" |
  "experimental"`. Only `green` images are offered in alpha.
- **`app/app.go` `GetSupportPolicy()`** — per-channel gate for the *scenario*
  axes (BitLocker/FDE, custom OCI refs, encryption). The frontend reads it to
  gate the UI; `StartInstall` enforces it as the authoritative backstop.

When a matrix cell goes green, flip its `status` (and/or the relevant policy
flag) in the same PR that records the green run — never ahead of it.

## Channels

The active channel comes from `$WOOTC_CHANNEL`, else `C:\wootc\channel.txt`,
else the built-in default (`alpha`).

| Channel | Bar to enter | Offers |
|---|---|---|
| **alpha** | one image green end-to-end (incl. GUI-driven) | green images only; encryption off; no BitLocker; no custom refs |
| **beta** | the **full matrix** green | all images; custom refs; still gates any axis whose issue is open |
| **stable** | full matrix green + a soak period with no data-safety regressions | everything |

Alpha deliberately refuses more than it allows. A blocked user with intact
Windows is a good outcome; a walked-into-red user with a broken boot is not.

## Alpha (now)

- **Image:** `ghcr.io/projectbluefin/bluefin:lts` — the one combination green
  end-to-end, including a full GUI-driven run.
- **Encryption:** off only. `tpm2-luks` (Phase-2 regen, [#33](https://github.com/tuna-os/wootc/issues/33))
  and BitLocker FDE ([#34](https://github.com/tuna-os/wootc/issues/34)) are
  gated off; the app detects BitLocker and tells the user plainly that it is
  coming soon rather than proceeding into a known failure.
- **Root filesystem:** ext4 (sealed default). btrfs is blocked
  ([#35](https://github.com/tuna-os/wootc/issues/35)).
- **No custom OCI refs** — only the offered, tested image.

## The unlock path to beta

Each of these flips a gate the moment its matrix row is green:

- [ ] yellowfin / bonito / marlin / flounder full three-phase → `status: green`
- [ ] composefs-native (dakota) Phase-2/3
- [ ] Windows 10 + Home/Enterprise/LTSC editions
- [ ] BitLocker FDE path (#34) → `BitLockerSupported: true`
- [ ] tpm2-luks root (#33) → offer encryption
- [ ] btrfs sealed Phase-2 (#35) → offer btrfs
- [ ] custom OCI refs (once the deploy path is family-agnostic green) → `CustomImageAllowed: true`

When the **whole matrix** is green, the default channel becomes `beta`
(catalog all-green, custom refs on), and the axis gates open as their issues
close.

## Cutting a release

Releases are **E2E-gated** — tagging publishes nothing until a real Windows VM
has migrated to Linux and back on a hosted runner (`release.yml` → the gate
calls the same reusable E2E the nightly proves, on the alpha image, GUI-driven).

```
git tag v0.1.0-alpha.1 && git push origin v0.1.0-alpha.1
# → tests → E2E gate (real Windows VM, bluefin:lts, GUI-driven) → build + publish
```

The published artifact is `wootc.exe` (Wails, Go + web UI; no runtime deps).
`skip_e2e` exists for emergencies and documents itself in the release notes.

## User instructions (shipped in the release notes / INSTALL.md)

1. Download `wootc.exe`. It is not code-signed yet (alpha) — SmartScreen will
   warn; *More info → Run anyway*.
2. Requirements the app checks for you: Windows 10/11 64-bit, UEFI + Secure
   Boot, TPM 2.0, **BitLocker off** (alpha), ~40 GB free.
3. Run it, pick Bluefin, set a username + password, click Install. Nothing on
   your PC changes until you click **Reboot Now** — and even then Windows and
   all your files stay put; Linux lives in a file beside them.
4. First boot shows a calm "Setting up your new Linux system" screen for
   5–15 minutes. When it finishes you're in Linux. To go back to Windows,
   reboot and pick Windows — or uninstall wootc from inside it (deletes a
   folder and a boot entry).

Uninstalling is always: delete `C:\wootc` and remove the "wootc" boot entry —
the app's Control Panel does both.
