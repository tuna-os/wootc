# Verification ladder — phase by phase

The road to MVP is climbed one rung at a time; a rung is only "done" when
its E2E harness proves it repeatably, and each rung builds on the one
below. (North Star: README.md. Boundary rules: docs/architecture-boundary.md.)

## Rung 1 — Phase 1 alone: installer produces a boot-ready disk

**Claim:** on a virgin Windows machine, wootc (GUI or headless) ends with
the system armed: root.vhdx exists and is Windows-attachable, the signed
chain + deployer pair are on the ESP, the BCD one-shot is set, vault.json
holds only a hash, `state.json` = `armed`.

**Harness:** `tests/e2e/phase1/run-phase1.sh` (~2 min against a kept VM,
no deployer boot). Runs the real `wootc.exe` over QGA.

**Status (2026-07-17):** the headless install pipeline runs green
end-to-end on a virgin Windows VM (dilli). First real run caught and
fixed a genuine product bug (sha512-crypt salt magic prefix). Full
assertion sweep is the remaining checkbox.

## Rung 2 — Phase 1 → Phase 2: armed system boots into Linux

**Claim:** rebooting the rung-1 system runs the deployer unattended
(pull → fisherman → verification → ESP sync), and the following boot
reaches the installed system's login on native Phase-2 boot.
`state.json` walks armed → deploying → deployed, then `healthy` written
by the installed system.

**Harness:** extends the phase-1 run with the reboot + serial-console
monitoring from `run-e2e.sh`; asserts the `healthy` state and an SSH/QGA
sign of life from Linux.

**Blocked on:** the Phase-2 track's current work (silent early-boot
panic on main; qemu-nbd switch-root survival on the VHDX branch). Rung 2
inherits whichever root-disk format wins there.

## Rung 3 — Phase 1 → 2 → 3: migration works where the user lives

**Claim:** on the Phase-2 system, the User Data Bridge is live
(Windows folders visible in $HOME, Steam library registered, browser
import available) and the migration dashboard performs a reversible
category conversion; Windows still boots afterwards.

**Harness:** QGA/SSH-driven checks inside the Phase-2 system — bind
mounts present for the vault-created user, `wootc-convert-dir` round-trip
on a seeded folder, dashboard backend (`GetMigrationCategories`) sane;
then reboot back to Windows and assert it comes up clean.

**Status:** components implemented (bridge scripts, dashboard, polkit);
untested beyond builds until rung 2 stands.

## Working agreement

- Fix at the lowest rung that reproduces a failure; never debug rung 3
  symptoms while rung 2 is red.
- Every rung's harness must run on any of the E2E hosts (kanpur,
  himachal, dilli) — host-specific setup goes in a bootstrap recipe, not
  in engineers' heads.
- A rung's harness is part of its definition of done: no green harness,
  no claimed rung.
