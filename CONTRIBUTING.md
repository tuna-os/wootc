# Contributing to wootc

<!-- hive-contribute-plea: donated-compute appeal, keep in sync across repos -->
## Contribute compute — no code needed

**[Donate time with your AI CLI](https://hub.tunaos.org/#contribute).**

Your machine runs one task at a time using your signed-in AI coding CLI.
The relay alternates between eligible **School** (OS) and **Reef** (apps)
hives after each task. If one hive has no work, the other can continue.

The guide covers prerequisites, verified `just` setup, credentials, provider
costs, and how to stop with Ctrl+C. Your subscription quota or API charges apply.
Never post account credentials or API keys in issues or pull requests.

## Getting started

1. Fork the repository and clone your fork.
2. Read `AGENTS.md` first. It names the four project layers: Windows OEM,
   QGA control plane, deployer initramfs, and E2E test runner. It also names
   the docs to read before you change each layer. One of these docs is
   `docs/agent-lessons.md`. It records traps that each cost a 60–90 minute VM run.
3. Check the build/test matrix in `docs/status.md` for known-good and
   known-red cells. Do this before you blame a symptom on your change.

## Prerequisites

Clone with submodules, or initialize them after you clone:

```bash
git submodule update --init --recursive
```

The fast tier runs in Bash without a container or VM. Install all four lanes
below; the runner skips a lane when its executable is missing.

| Tool | Installation and version source | Fast-tier lane |
|---|---|---|
| [just](https://just.systems/man/en/packages.html) | Follow the package instructions for your platform, or use `cargo install --locked just` with Rust installed. The repository does not pin a just version. | Recipe launcher; optional when invoking `bash tests/run.sh fast` directly |
| [Bats](https://bats-core.readthedocs.io/en/stable/installation.html) | Debian/Ubuntu: `sudo apt-get install bats`; Fedora: `sudo dnf install bats`; macOS: `brew install bats-core`. No Bats minimum is pinned. | `bats tests/unit/*.bats` |
| [Python 3](https://www.python.org/downloads/) | Debian/Ubuntu: `sudo apt-get install python3`; Fedora: `sudo dnf install python3`; macOS: `brew install python`. Use Python **3.11 or later** for the package consumer controls, as required by `ci-tests.yml`; there is no single repository-wide Python pin. | Each `tests/unit/test_*.py`, directly, without pytest |
| [Go](https://go.dev/doc/install) | Use the official installer/archive or your platform package manager. `app/go.mod` declares **1.26.0**; the fast CI job selects **1.27**. Use that CI toolchain to match CI, and honor each submodule's own `go.mod`. | `go test ./...` in `app`, `fisherman/tui`, and `fisherman/fisherman` |
| [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) | Follow the Linux, macOS, or Windows instructions and make **`pwsh`** available in Bash's `PATH`. Windows PowerShell's `powershell.exe` is not the runner's executable. No PowerShell version is pinned for this tier. | `tests/lint-ps1.ps1` and each `tests/unit/test-*.ps1` |

The fixtures also use standard Unix tools such as `rsync`, `jq`, QEMU's
common/GUI utilities and `binutils`; individual suites may need additional
tools. For Debian/Ubuntu, this set is useful:

```bash
sudo apt-get update
sudo apt-get install bats python3 rsync jq qemu-system-common qemu-system-gui binutils
```

Install Go, PowerShell and `just` through the linked instructions; this command
does not install them. macOS can run suitable portable lanes, but some fixtures
use utilities from Linux. On Windows, use a Linux development environment
(for example WSL) for the Bash fast tier; Windows-specific engine and WinUI
tests still need Windows. Native shell development has separate .NET and
Windows SDK requirements in [the shell guide](docs/winui-shell.md).

### Containers and Linux/KVM E2E are separate

- Install [Podman](https://podman.io/docs/installation) for `just test-slow`.
  On macOS/Windows, follow its `podman machine init` / `podman machine start`
  setup. A Podman machine does not prove host support for privileged integration
  tests on Linux or nested Windows/KVM E2E.
- For a Linux VM host, install QEMU utilities (`sudo apt-get install qemu-utils`
  on Debian/Ubuntu, `sudo dnf install qemu-img` on Fedora). Confirm with
  `qemu-img --version`. See [QEMU downloads](https://www.qemu.org/download/).
- `/dev/kvm` is a **Linux kernel capability**, not a downloadable tool. Enable
  CPU virtualization in firmware, then check:

  ```bash
  test -c /dev/kvm && test -r /dev/kvm && test -w /dev/kvm
  ```

  If the device is absent, load the appropriate module (`sudo modprobe kvm_intel`
  or `sudo modprobe kvm_amd`). If you cannot access it, follow your distribution's
  KVM group policy (commonly `sudo usermod -aG kvm "$USER"`, then log out and
  back in). A VM host also needs nested virtualization exposed by its provider.
  See [KVM setup](https://www.linux-kvm.org/page/RunningKVM).
- macOS and Windows do not expose Linux `/dev/kvm` directly. Full hosted E2E
  uses the project's dedicated remote hosts and credentials; these
  packages do not grant access. Read [agent lessons](docs/agent-lessons.md)
  and [E2E architecture](docs/e2e-architecture.md) before you use that lane.

There are no repository-pinned Podman or QEMU minimum versions.
Record the versions you used and their evidence.
Do not invent compatibility guarantees.

## Building and testing

`just --list` shows all targets. The prerequisites above distinguish the local
fast tier from container and VM work.

The fast, no-container red-green loop for day-to-day changes:

```bash
just test          # or: tests/run.sh fast
```

This runs the Bats, Python, PowerShell and Go lanes listed above. **A `PASSED`
summary with `!! ... skipping ...` warnings does not prove every suite ran.**
Retain the lane headers and skip warnings when reporting results. Windows-tagged
Go (`app/*_windows.go`) only runs on Windows; a Linux fast-tier pass does not
prove the Windows engine or the WinUI interface.

Containerized integration tests (User Data Bridge, WSL, go-native gates) run
in a privileged Fedora container and need `podman`:

```bash
just test-slow      # or: tests/run.sh slow
```

Full hosted E2E (Windows 11 → wootc deployer → native Linux → Windows 11)
runs on dedicated remote hosts. You cannot reproduce it on your own machine.
`docs/RELEASING.md` tells how matrix cells go green.

### What CI runs on a pull request

CI runners are shared by all tuna-os repositories, so a PR runs only the
jobs that its change can affect:

- Lint and the fast tier run on every PR.
- The other jobs in `ci.yml` and `ci-tests.yml` run only when the PR changes
  their inputs. `.github/scripts/ci-scope.sh` holds the path map. A change to
  that script, to those two workflows, or to `.github/actions/` runs all jobs.
- `winui-preview.yml` packages one brand per PR. The brand changes with the
  run number. The PR also packages each brand whose `app/branding/<brand>/`
  it changes. Set the `WINUI_PREVIEW_BRANDS_PER_PR` repository variable to
  package more brands.

A push to `main` uses the same path map on the pushed commits, so each
commit that changes a job's inputs still gets its own run of that job (#363).
A manual dispatch and a nightly schedule run all jobs. `winui-preview.yml`
also packages all brands each night.

## Before opening a PR

- Run `just test` (fast tier) locally — it's fast enough to run on every
  change.
- Before you change the E2E harness, the deployer, or the runners, read
  `docs/agent-lessons.md`. Those traps are easy to hit again.
- **Status that comes from a proxy and not from an observable** is the most
  frequent bug class in this codebase. When you add a check, ask what it
  prints if the asserted thing never occurred. Then break the code and make
  sure that the test goes red.

## License

wootc is dual-licensed under GPL-2.0 and MIT (see `LICENSE-GPL-2.0` and
`LICENSE-MIT`).

## Getting help

Questions or stuck? Open an issue, or ask on
[Matrix #tunaos](https://matrix.to/#/%23tunaos:reilly.asia).

Use the [documentation index](docs/README.md) to find role-specific references.
For deployment evaluation rather than source development, start with the
[IT-admin quick start](docs/it-admin-quick-start.md).
