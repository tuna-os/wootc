# Brand configurations

One directory per brand build (docs/branding-and-distribution.md). The binary
embeds every directory; `-ldflags "-X main.brandID=<dir>"` picks which one the
build wears (default `wootc`).

Per-directory files — only `brand.json` is required:

| File | Becomes | Notes |
|---|---|---|
| `brand.json` | `Branding` overlay | identity, palette, catalog, distribution flags |
| `logo.svg` | `LogoDataURI` | the real mark; replaces the emoji everywhere one renders |
| `font.woff2` | `FontDataURI` | the brand's typeface, embedded — never fetched at run time |
| `theme.css` | `ThemeCSS` | deep restyle injected after `style.css` (tokens, buttons, radii) |

## Upstream blessings

A branded build wears somebody else's mark. `<brand>/blessing.json` records
what that project has actually said about it — the mark, the name, the
tagline, and distributing an exe under their brand — plus who owns the
winget namespace the identifier would sit in. The ask itself, and the
manifests to offer with it, are in
[docs/upstream-blessings.md](../../docs/upstream-blessings.md).

| Brand | Mark owner | Status | Mark | Name | Tagline | Branded exe | winget identifier |
|---|---|---|---|---|---|---|---|
| `wootc` | TunaOS — this project | blessed | yes | yes | yes | yes | `TunaOS.wootc` |
| `tunaos` | TunaOS — this project | blessed | yes | yes | yes | yes | `TunaOS.Installer` |
| `bluefin` | Universal Blue — ublue-os/bluefin | pending | pending | pending | pending | pending | `Bluefin.Installer` |
| `bazzite` | Universal Blue — ublue-os/bazzite | pending | pending | pending | pending | pending | `Bazzite.Installer` |
| `aurora` | Universal Blue — ublue-os/aurora | pending | pending | pending | pending | pending | `Aurora.Installer` |

The two `TunaOS.*` identifiers are ours (`TunaOS.wootc` is published;
`TunaOS.Installer` is reserved, not submitted). The other three sit in
Universal Blue's namespace, not ours.

**Nothing here has been asked yet.** Every `pending` means exactly that: no
request has been filed, so no answer has been given, and the record says so
rather than implying a conversation that did not happen. `ask.filed` is
`false` on all three.

**The status is not decoration.** `packaging/brands.sh` reads it and the
release matrix follows:

- **blessed** — build and ship it.
- **pending** — still built (shipping predates the ask), but the release log
  names it as unblessed. Set `WOOTC_REQUIRE_BLESSING=1` to drop pending
  brands too.
- **declined** — the exe drops from the release matrix. Not ours to ship.

A brand directory with **no** `blessing.json` is a hard build error, not a
default yes: a new brand cannot reach a release without someone writing down
who was asked. `app/blessing_test.go` holds the rest of the line — the status
must agree with its own four answers, a mark this project does not own cannot
be `blessed` without a link to the yes, and every cell of this table is
compared against the JSON.

## Asset provenance

Real assets, taken from each project's own published branding:

- **bazzite/**: logo `bazzite_b.svg` and the cobalt→violet gradient
  (`#0047ab → #8a2be2`) from [ublue-os/bazzite.gg]; typeface DM Sans
  (site body font; SIL OFL, via Google Fonts).
- **bluefin/**: logo tile (`#3550ec → #252b4b`) from
  [projectbluefin/website] `public/img/logo.svg`; typeface Inter (site
  display font, `--wc-font-display`; SIL OFL).
- **aurora/**: `aurora-logo.svg` and the aurora gradient
  (`#2eb9df → #9e00ff`) from getaurora.dev; typeface Geist (site body
  font; SIL OFL).
- **tunaos/**, **wootc/**: emoji marks — that IS the TunaOS branding today;
  swap in a real `logo.svg` when one exists.

[ublue-os/bazzite.gg]: https://github.com/ublue-os/bazzite.gg
[projectbluefin/website]: https://github.com/projectbluefin/website

See [Make the installer your own](../../docs/distro-adoption.md) for the distro
setup tool, identity fields, private catalogs, Windows assets, and proof steps.
