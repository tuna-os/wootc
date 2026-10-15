# Contributing to wootc

## Getting started

1. Fork the repository and clone your fork.
2. Read `AGENTS.md` first. It names the four project layers: Windows OEM,
   QGA control plane, deployer initramfs, and E2E test runner. It also names
   the docs to read before you change each layer. One of these docs is
   `docs/agent-lessons.md`. It records traps that each cost a 60–90 minute VM run.
3. Check the build/test matrix in `docs/status.md` for known-good and
   known-red cells. Do this before you blame a symptom on your change.

## Building and testing

`just --list` shows all targets (needs `just`; the E2E targets also need
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
runs on dedicated remote hosts. You cannot reproduce it on your own machine.
`docs/RELEASING.md` tells how matrix cells go green.

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
