# Branding — ship a re-skinned migrator

wootc is themeable so partners and enterprises can ship a branded
migrator without forking the code. Two override files, both read at
runtime from `C:\wootc\`:

## `brand.json` — look and copy

Drop a `brand.json` next to the installer (or push it via MDM to
`C:\wootc\brand.json`). Any field you omit falls back to the wootc
default; you only specify what you want to change.

```json
{
  "name": "Acme Switch",
  "tagline": "Move to Acme Linux in minutes.",
  "logoEmoji": "🅰️",
  "version": "2.0",
  "accent": "#e6007a",
  "accentText": "#ffffff",
  "background": "#0d0b14",
  "card": "#181320",
  "text": "#f0e8f5",
  "installVerb": "Migrate"
}
```

| Field | Effect |
|---|---|
| `name` | Title bar, window title |
| `tagline` | Launchpad subtitle, window title |
| `logoEmoji` | Title-bar logo |
| `version` | Title-bar version tag |
| `accent` / `accentText` | Primary buttons, selection, slider, focus ring (and its text color) |
| `background` / `card` / `text` | Core palette (applied as CSS variables) |
| `installVerb` | CTA + heading verb ("Install" → "Migrate", "Switch", …) |

The palette is applied as CSS custom properties at startup, so a single
accent change re-skins every button, chip, and highlight consistently.
See the branded screenshot in [gui-walkthrough.md](gui-walkthrough.md).

## `images.json` — the variant catalog

Replace the built-in TunaOS catalog with your own images. Same schema as
the built-in list:

```json
[
  {
    "id": "acme-desktop",
    "name": "Acme Desktop",
    "emoji": "🅰️",
    "base": "Acme Linux 3",
    "desktop": "gnome",
    "desktopName": "GNOME",
    "imageRef": "registry.acme.example/acme-desktop:latest",
    "description": "Acme's supported desktop image."
  }
]
```

`imageRef` is passed opaquely to the deployer — it is never inspected by
the installer, so any OCI reference your provisioner understands works.

## Locked-down single-image onramp

A common case: a distro or product wants to offer *their* Linux as a
one-click escape hatch from Windows — no variant picker, no choice, just
"Leave Windows for FooOS." Ship an `images.json` with exactly one entry
and the installer collapses to that single image:

```json
[
  {
    "id": "fooos",
    "name": "FooOS",
    "emoji": "🦊",
    "base": "FooOS 12",
    "desktop": "gnome",
    "desktopName": "",
    "imageRef": "registry.foo.example/fooos:stable",
    "description": "The whole of FooOS, installed from Windows."
  }
]
```

With one image the variant grid still renders that single card
pre-selected, so the user goes straight to credentials → Install. Pair it
with a `brand.json` whose `installVerb` is "Switch" or "Install FooOS" and
`tagline` names the destination, and the app reads end-to-end as a
first-party FooOS onramp rather than a generic tool.

Recommended locked-down bundle for a single-project onramp:

| File | Purpose |
|---|---|
| `images.json` (1 entry) | pins the destination image; hides the choice |
| `brand.json` | first-party name, logo, accent, "Switch to FooOS" verb |
| MDM/installer placement | push both to `C:\wootc\` before first launch |

Because `imageRef` is opaque and the boot chain is provisioner-agnostic
(see [architecture-boundary.md](architecture-boundary.md) and
[non-bootc-adoption.md](non-bootc-adoption.md)), a project shipping a
non-bootc image can use the exact same locked-down onramp — only the
provisioner stage differs.

## What is NOT themeable (on purpose)

The honesty rules are not configurable: the "nothing is deleted from
Windows" reassurance, the per-app truthful session outcomes, and the
BitLocker/data-safety warnings are part of the product's trust contract,
not the skin. A branded migrator can look like anything; it cannot lie
about what happens to the user's data.

## Testing a brand

Add a scenario to `tests/gui/gui.spec.js` with your `brand` object (see
the branding test) — it renders your skin headlessly and screenshots it
in ~1 second, no Windows needed.
