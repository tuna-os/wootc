# Contributing to wootc

## Getting started

1. Fork and clone the repository.
2. Read `AGENTS.md` — it names the four project layers and points to key docs including `docs/agent-lessons.md`, which documents traps that each cost 60–90 minute VM runs.
3. Check `docs/status.md` for the current test matrix before assuming your change broke something.

## Building and testing

Run `just --list` to see all test targets.

Fast local tests — no containers:

```bash
just test
```

Slow tests in containers — needs `podman`:

```bash
just test-slow
```

Full E2E (Windows 11 → Linux → Windows 11) runs on remote hosts only. See `docs/RELEASING.md`.

## Before opening a PR

- Run `just test` locally on every change.
- Read `docs/agent-lessons.md` before touching the E2E harness, deployer, or runners.
- **Core rule**: Status from a proxy rather than an observable causes most bugs here. When adding a check, verify the test goes red when that observable does not occur.

## License

wootc is dual-licensed under GPL-2.0 and MIT (see `LICENSE-GPL-2.0` and
`LICENSE-MIT`).

## Getting help

Questions or stuck? Open an issue, or ask on
[Matrix #tunaos](https://matrix.to/#/%23tunaos:reilly.asia).
