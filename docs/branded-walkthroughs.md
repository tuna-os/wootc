# Branded installer walkthroughs

Automated screenshot walkthroughs for every brand build
(docs/branding-and-distribution.md). These are **generated, not curated**:
`tests/gui/branded-walkthrough.spec.js` assembles each brand's real embedded
assets from `app/branding/<brand>/` — the same brand.json, logo, typeface
and theme a `-X main.brandID=<brand>` binary compiles in — drives the real
frontend bundle through the four journey screens, and asserts on every one
that the build wears its own name, mark and look (and, for branded builds,
never the word "wootc"). Re-running the Playwright suite refreshes every
image below.

**Live video walkthroughs** — every distribution that has passed a full
GUI-driven E2E gets its own timelapse (a real Windows VM installing that
image through the real GUI, migrating data, and returning to Windows) in
the gallery at **https://tuna-os.github.io/wootc/e2e/** ; the most recent
green run of any image is always at
[/e2e/latest/](https://tuna-os.github.io/wootc/e2e/latest/). Cuts publish
automatically on green (`e2e-gui.yml`), one directory per distribution.

The journey per brand: **launchpad** (the brand's catalog, its default
pre-selected) → **progress** (the reassurance screen in the brand's look) →
**done** (celebrating with the brand's own mark) → **manage** (the branded
way back in — "Restart into …" — and the way out).

## Bazzite — "The next generation of Linux gaming"

| | |
|---|---|
| ![Bazzite launchpad](screenshots/brands/bazzite/01-launchpad.png) | ![Bazzite progress](screenshots/brands/bazzite/02-progress.png) |
| ![Bazzite done](screenshots/brands/bazzite/03-done.png) | ![Bazzite manage](screenshots/brands/bazzite/04-manage.png) |

## Bluefin — "The next generation Linux workstation"

| | |
|---|---|
| ![Bluefin launchpad](screenshots/brands/bluefin/01-launchpad.png) | ![Bluefin progress](screenshots/brands/bluefin/02-progress.png) |
| ![Bluefin done](screenshots/brands/bluefin/03-done.png) | ![Bluefin manage](screenshots/brands/bluefin/04-manage.png) |

## Aurora — "Simply delightful"

| | |
|---|---|
| ![Aurora launchpad](screenshots/brands/aurora/01-launchpad.png) | ![Aurora progress](screenshots/brands/aurora/02-progress.png) |
| ![Aurora done](screenshots/brands/aurora/03-done.png) | ![Aurora manage](screenshots/brands/aurora/04-manage.png) |

## TunaOS

| | |
|---|---|
| ![TunaOS launchpad](screenshots/brands/tunaos/01-launchpad.png) | ![TunaOS progress](screenshots/brands/tunaos/02-progress.png) |
| ![TunaOS done](screenshots/brands/tunaos/03-done.png) | ![TunaOS manage](screenshots/brands/tunaos/04-manage.png) |

## wootc (generic)

The un-branded engine, as shipped today — also covered by the main
[GUI walkthrough](gui-walkthrough.md).

| | |
|---|---|
| ![wootc launchpad](screenshots/brands/wootc/01-launchpad.png) | ![wootc progress](screenshots/brands/wootc/02-progress.png) |
| ![wootc done](screenshots/brands/wootc/03-done.png) | ![wootc manage](screenshots/brands/wootc/04-manage.png) |
