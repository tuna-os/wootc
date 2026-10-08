# Contributing to wootc

## Getting started

1. Fork the repository and clone your fork.
2. Read `AGENTS.md` first — it names the four project layers (Windows OEM,
   QGA control plane, deployer initramfs, E2E test runner) and the docs to
   read before touching each one, plus `docs/agent-lessons.md`, which
   documents traps that have each cost a 60–90 minute VM run.
3. Check the build/test matrix in `docs/status.md` for current known-good vs.
   known-red status before assuming a symptom is your change's fault.

## Prerequisites

You need several tools. Which tools depend on which tests you run. Install them on your platform:

### All platforms

- **`just`** — task runner (required for all builds)
  - Linux/macOS: `curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash` or use your package manager
  - macOS: `brew install just`
  - Windows: `choco install just` or `scoop install just`

- **Python 3.9+** — used by tests and the justfile
  - Linux: usually pre-installed; `apt install python3` or equivalent
  - macOS: `brew install python3`
  - Windows: [python.org](https://www.python.org/downloads/) or `winget install Python.Python.3.12`

### For container tests and E2E tests (`just test-slow`)

- **`podman`** — container runtime (Linux, macOS, Windows)
  - Linux: `apt install podman` (Debian/Ubuntu) or equivalent
  - macOS: `brew install podman`
  - Windows: `choco install podman-cli` or [Podman Desktop](https://podman-desktop.io/)

- **`qemu-img`** — QEMU tools (Linux and macOS)
  - Linux: `apt install qemu-utils` (Debian/Ubuntu) or `dnf install qemu-img` (Fedora)
  - macOS: `brew install qemu`
  - Windows: typically included with QEMU; install via `choco install qemu` or Podman Desktop

- **KVM kernel module** (Linux only)
  - Check: `ls /dev/kvm` (should exist)
  - Enable: `sudo modprobe kvm` (then add `kvm` to `/etc/modules` to keep it enabled)
  - Verify: `kvm-ok` (install `cpu-checker` if not found)
  - Note: KVM needs hardware virtualization. This is VT-x on Intel or AMD-V on AMD. Check your BIOS.

### For GUI E2E tests

Use the same tools as above. The GUI tests also need a running Podman daemon and about 50 GB of disk space for full runs.

## Building and testing

`just --list` shows all targets (requires `just`; the E2E targets also need
`podman`, `qemu-img`, and `/dev/kvm`).

The fast, no-container red-green loop for day-to-day changes:

```bash
just test          # or: tests/run.sh fast
```

This runs the bats unit suites (payload gates/transforms) plus `go test` for
the cross-platform Go packages. Windows-tagged Go (`app/*_windows.go`) only
builds on Windows by design, so this tier covers the platform-independent
code.

Containerized integration tests (User Data Bridge, WSL, go-native gates) run
in a privileged Fedora container and need `podman`:

```bash
just test-slow      # or: tests/run.sh slow
```

Full hosted E2E (Windows 11 → wootc deployer → native Linux → Windows 11)
runs on dedicated remote hosts and isn't something a contributor's local
environment can reproduce — see `docs/RELEASING.md` for how matrix cells go
green.

## Before opening a PR

- Run `just test` (fast tier) locally — it's fast enough to run on every
  change.
- If you're touching the E2E harness, the deployer, or the runners, read
  `docs/agent-lessons.md` first; it exists because those traps are easy to
  re-hit.
- The heuristic that matters most in this codebase: **status derived from a
  proxy rather than an observable is the dominant bug class here.** When
  adding a check, ask what it would print if the thing it asserts never
  happened, then break the code and confirm the test goes red.

## License

wootc is dual-licensed under GPL-2.0 and MIT (see `LICENSE-GPL-2.0` and
`LICENSE-MIT`).

## Getting help

Questions or stuck? Open an issue, or ask on
[Matrix #tunaos](https://matrix.to/#/%23tunaos:reilly.asia).
