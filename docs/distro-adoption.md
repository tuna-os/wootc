# Make the installer your own

A distro can use its own name, artwork, catalog, and support links.
The core engine stays shared. Home users still get the same simple journey.
A brand does not prove that an image can boot. The status matrix remains the gate.

## Create a brand

Fork the repository. Run this command with your own names and URLs:

```sh
python3 packaging/brand.py init \
  --id acme --name 'Acme Linux' --publisher 'Acme Project' \
  --website https://example.com --support https://example.com/support \
  --winget-id Acme.Installer --image-ref registry.example.com/acme:stable \
  --self-owned --logo ./acme-logo.svg --icon ./acme.ico
python3 packaging/brand.py validate --brand acme
```

Use `--self-owned` only for a mark and package namespace you own.
Without it, the record stays `pending`; the tool does not invent permission.
The tool updates the ownership table. It refuses to overwrite a brand.

| File | Purpose |
|---|---|
| `app/branding/acme/brand.json` | Names, publisher, palette, links, default image, catalog policy |
| `app/branding/acme/images.json` | Optional catalog for this brand; replaces the shared catalog for this build |
| `app/branding/acme/logo.svg` | Embedded logo for the UI |
| `app/branding/acme/icon.ico` | Windows executable icon; optional if the SVG can supply it |
| `app/branding/acme/font.woff2` | Optional embedded font; set `fontFamily` |
| `app/branding/acme/theme.css` | Optional CSS for the whole UI |
| `app/branding/acme/blessing.json` | Mark and package ownership decision |
| `app/branding/ownership.json` | Self-owned brands and winget namespaces for this checkout |
| `packaging/brand.schema.json` | Editor schema; the CLI also checks catalogs and ownership |

The new image starts as `experimental`. Use the beta channel in a test VM.
Do not set it to `green` until the full chain passes with retained evidence.
A brand can use existing image IDs instead of a private catalog.
An invalid catalog causes an error. It does not select another distro.

## Identity fields

| Field | Surface |
|---|---|
| `name` | Distro name, boot-menu label, Apps entry |
| `productName` | Installer window and title bar |
| `exeName` | Release filename stem; unique across brands |
| `publisher` | Windows company metadata and Apps publisher |
| `fileDescription` | Windows Details description; defaults to product name |
| `copyright` | Windows legal-copyright metadata; keep accurate license notices |
| `websiteURL` | Apps information link |
| `supportURL` | Help button and Apps support link |
| `tagline`, `installVerb` | User-facing copy |
| `accent`, `accentText`, `background`, `card`, `text` | Color tokens; use readable contrast |
| `catalog`, `defaultImage` | Image choice and default |
| `hideCustomImage`, `preloadImage` | Restrict image choice; fetch payload before the reboot |

Links must use HTTPS. Fonts and artwork stay inside the binary.
The UI no longer fetches a generic font from Google at startup.
Use `theme.css` for layout and other visual changes.
Keep keyboard focus, large text, and screen-reader labels intact.

## Build and prove it

```sh
(cd app/frontend && npm ci && npm run build)
python3 packaging/build-windows.py --brand acme \
  --artifact-repository acme/installer --version v1.2.3 --output dist/Acme-Installer.exe
```

The helper creates per-brand Windows resources in a temporary copy.
It keeps administrator elevation and the GUI subsystem.
The release version sets the executable metadata and boot-artifact pin.
Publish the matching boot artifacts at that release before distribution.
The repository defaults to `GITHUB_REPOSITORY` in CI, or `tuna-os/wootc` locally.
The artifact origin stays inside the binary; a brand file cannot change it.

| Check | Required proof |
|---|---|
| Config | `python3 packaging/brand.py validate` |
| Names | Title, screens, Apps entry, Details tab, and boot menu match the distro |
| Artwork | UI mark and Windows icon match; inspect small icons and high-DPI displays |
| Links | Help reaches the distro's support site |
| Offline | Fonts, logos, and staged payload need no live CDN |
| Safety | The default channel still hides unproved images |
| Platform | Full Windows-to-Linux-to-Windows run; real hardware for each supported cohort |
| Distribution | Own signature, asset signatures, license notices, and an approved package namespace |

The same JSON fields flow through the current UI and the generated WinUI DTO.
WinUI still needs its own visual and E2E proof before release cutover.

Internal paths such as `C:\wootc` remain stable for recovery and interoperability.
License attribution also remains. A brand does not add support for an arbitrary
non-bootc installer; that needs the [provisioner contract](architecture-boundary.md).
The optional [enterprise proposal](specs/enterprise-migration.md) does not add
fleet controls to the consumer screen.
