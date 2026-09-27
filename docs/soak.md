# Native GUI soak ledger

The soak has **not started**. We claim no 30-day streak.

The [ledger workflow](../.github/workflows/soak-ledger.yml) updates
[the live ledger](https://github.com/tuna-os/wootc/blob/soak-ledger/soak.md)
after GUI runs and each day. Its separate branch retains each try and the SHA
of the collector. It does not change main. The first update imports 90 days;
later updates keep every stored row. A release tag supplies no proof by itself.

A maintainer must record a start date in [the config](../tools/soak/config.json)
after phase D (#345), M4.1–M4.6 (#229–#234), the listed dependencies, and every RC prerequisite in
#212 pass. The check excludes the soak checkbox in #212. A date before dependency
closure fails. Closure must precede the start at UTC midnight. The config has no start date now. Wails releases and old VM passes
cannot supply a native streak.

Only GUI runs that finish on the schedule from this repository's main history
can count. The collector keeps each red even after a green retry. A red needs
a diagnosis issue whose body links the run. The check covers all stored reds,
including those outside the import window. Record that issue under `diagnoses`
with the key `runId:runAttempt`. An unexplained red invalidates the streak.

Missing UTC days and ineligible runs reset it. A change to the shell or transport
code resets it. The current UTC day does not count until it ends.

## Native proof contract

Wails cannot qualify. A future native runner must supply a job named
`native-shell GUI acceptance`. These steps must pass:

- `Verify native process identity`
- `Assert native UIA journeys`
- `Capture native framebuffer`

It must upload both artifacts in the same run and try. The ledger does not
supply that runner.

- `native-shell-build-<runId>-<attempt>`: the tested `Wootc.Shell.exe` at the archive root.
- `native-gui-soak-proof-<runId>-<attempt>`: the native receipt, raw UIA captures,
  PNG framebuffers, and an independent Linux boot observation at the archive root.

The collector checks the IDs and digests of artifacts from GitHub. It checks
the source SHA and try number. The hash of the native process must match the
bytes of the packaged executable. The receipt must name WinUI 3 and Windows
UI Automation. The collector rejects browser receipts.

Each required control must be visible and enabled. Its observed value must
match the required value. A screenshot alone fails. The Linux summary must match
a separate observation from Linux in that try. Its capture time must fall inside
the try and before the UI summary. The record must match the live Linux boot ID. Missing or stale evidence fails.
Ambiguous or incorrect evidence also fails.

[The verifier](../tools/soak/ledger.py) defines the receipt fields and control IDs.
It hashes sorted `(path, Git blob SHA)` arrays as compact JSON with SHA-256.
`shell/` supplies the shell identity. `app/` and `tests/e2e/qga.py` supply
the conservative transport identity. The collector compares them with the GitHub tree at the tested commit.

The ledger records the source SHA, executable hash, IDs of artifacts, and hashes
of archives. Artifact expiry cannot remove a retained observation. The native
producer and real VM proof remain necessary before any row can qualify.
This ledger schedules no VM run and starts no soak.
