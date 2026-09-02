# The WinUI 3 shell — replacing Wails on Windows

**Decision (maintainer, 2026-09-02, #304):** the Windows installer becomes a
native **WinUI 3** application. Wails and the embedded web frontend are
retired on Windows. The Linux side stays GTK4/libadwaita (already native).

This document is the architecture and the cut-over plan. It is written
against the code on `main` as of `c666581`, and it deliberately keeps every
contract the harness and the deployer already depend on.

## What stays, what goes

| Piece | Today | After |
|---|---|---|
| Install engine (Phase 1 pipeline, BCD, ESP, vault, sessions, uninstall, recovery) | Go, `app/`, in-process behind Wails bindings | Go, `app/`, unchanged logic, exposed by `wootc.exe serve` |
| Windows UI | Wails v2 + 2,300 lines of vanilla JS/CSS in `app/frontend/` | WinUI 3 (C#, .NET 8, Windows App SDK) in `shell/` |
| Headless CLI (`install`, `status`, `uninstall`, `recover`) | `wootc.exe <cmd>` | unchanged |
| E2E drive mode (`C:\wootc\e2e-drive.json` → `e2e-drive-state.json`) | directives executed as DOM events in `lib/e2e.js` | same files, same directives, executed against the shell's view-models |
| Branding (`app/branding/<brand>/brand.json`, `theme.css`) | CSS variables set from `GetBranding()` | XAML resources set from the same `GetBranding()` payload; `theme.css` retired |
| Linux migration dashboard | `wootc-dashboard` Wails/webkit build in `ci.yml` (built, never shipped) | removed with Wails; `payload/migration/*-gui` (GTK4/Adw) remain the Linux UI |
| GUI tests | Playwright over a dev-server build of the frontend | view-model unit tests (xUnit) + a UI Automation smoke on `windows-latest` |
| WebView2 runtime dependency | required (download on Windows 10) | gone |

## Architecture

```
Bluefin-Installer.exe  (WinUI 3 shell, runs as the logged-in user, NOT elevated)
   │  spawns, with the UAC prompt, one child:
   ▼
wootc.exe serve        (Go engine, requireAdministrator manifest, no window)
   │  JSON-RPC 2.0, newline-delimited, over the child's stdin/stdout
   │  requests:  the 14 methods that were Wails bindings
   │  notifications: install:progress, vm:progress
   ▼
C:\wootc\…             state.json, install\, disks\  (unchanged)
```

Three properties fall out of this split and are the reason for it:

1. **The engine never changes shape.** `StartInstall`, `GetSystemInfo`,
   `GetBranding`, `GetUninstallInfo`, `UninstallWith`, `BootIntoLinux`,
   `GetLastRun`, `E2EDriveDirective`/`E2EDriveReport` and the rest keep their
   names and JSON DTOs. This is exactly what #297 asks for ("thin Wails
   adapter; preserve exported method names and DTO shapes") — `serve` is that
   adapter, minus Wails.
2. **Identity is explicit.** The shell runs as the human; the engine runs
   elevated. The shell passes the interactive user's name and profile into
   `StartInstall` instead of the engine guessing it from an elevated token
   (the over-the-shoulder UAC problem of #225/#317 disappears structurally).
3. **One shell binary, branded at runtime.** The shell skins itself from
   `GetBranding()` (accent, background, card, text, font, product name,
   tagline, catalog). Per-brand builds differ only in exe name, icon and
   VERSIONINFO, which the release matrix already varies.

### The `serve` protocol

`wootc.exe serve` reads JSON-RPC 2.0 requests from stdin and writes responses
and notifications to stdout, one JSON object per line. Nothing else ever
writes to stdout in this mode; logs go to stderr and `C:\wootc\logs\`.

| Method | Params | Result |
|---|---|---|
| `GetSupportPolicy` | — | `SupportPolicy` |
| `GetSystemInfo` | — | `SystemInfo` |
| `GetBranding` | — | `Branding` |
| `GetImages` | — | `[]Image` |
| `GetSessionCandidates` | — | as today |
| `StartInstall` | `InstallConfig` | `null` or error |
| `CancelInstall` | — | `null` |
| `GetStatus` | — | `InstallStatus` |
| `DefragDrive` | — | `null` |
| `Reboot` | — | `null` |
| `ExistingInstallFound` | — | `bool` |
| `GetUninstallInfo` | — | `UninstallInfo` |
| `UninstallWith` | `UninstallOptions` | `null` |
| `BootIntoLinux` | — | `null` |
| `GetLastRun` | — | `LifecycleState` |
| `E2EDriveDirective` | — | `string` |
| `E2EDriveReport` | `string` | `null` |
| `Shutdown` | — | `null` (engine exits 0) |

Notifications: `{"method":"install:progress","params":ProgressEvent}` and
`{"method":"vm:progress","params":…}` — the same payloads `runtime.EventsEmit`
sends today. The engine exits when stdin closes, so a crashed shell cannot
leave an elevated engine alive; an install already past "Making Linux
bootable" finishes its step and disarms exactly as `CancelInstall` does.

The protocol is documented by a Go test that round-trips every method
through a pipe and pins the DTO JSON against golden files, so a field rename
in `app.go` fails the test before it breaks the shell.

### Shell layout

```
shell/
  Wootc.Shell/                 WinUI 3 app (net8.0-windows10.0.19041, WindowsAppSDK)
    App.xaml(.cs)              startup: spawn engine, GetBranding, apply theme, route
    Engine/EngineClient.cs     process + JSON-RPC client, typed DTOs (generated)
    Engine/Dto.cs              generated from app/*.go json tags (go:generate)
    ViewModels/                Launchpad, Progress, Done, Control, Recovery
    Views/                     one XAML page per view-model
    Branding/BrandTheme.cs     Branding → ResourceDictionary (accent, backdrop, font)
    Drive/E2EDrive.cs          e2e-drive.json directives → view-model actions → report
  Wootc.Shell.Tests/           xUnit: view-model state machine, drive directives, DTO goldens
  Wootc.Shell.UiTest/          FlaUI smoke: launch, land on Launchpad, Install disabled/enabled reasons
```

Screens map one-to-one from `app/frontend/src/screens/`: `launchpad`,
`progress`, `done`, `control`, plus `recovery` from #331. `vmpreview` is not
carried over: #318 cuts pre-install Try-in-VM from 1.0. `migrate` is Linux-only
and leaves with Wails.

Design language: Fluent, Mica backdrop, system light/dark, the brand accent
as the app accent, the brand font when installed with a Segoe UI Variable
fallback. The frameless custom title bar of the Wails app (#175) becomes the
standard WinUI title bar with `ExtendsContentIntoTitleBar`.

### Elevation

The shell manifest does **not** request administrator. On first engine call
the shell starts `wootc.exe serve` with the `runas` verb; Windows shows one
UAC prompt naming the engine's publisher. Every later call rides the same
child. If the user declines, the shell shows the launchpad read-only with the
reason ("wootc needs permission to change startup settings") and an
**Allow** button that retries — the same honesty the battery and BitLocker
gates already practice.

### E2E and GUI tests

- `run-e2e.sh --gui-install` keeps working unchanged: the harness writes
  `e2e-drive.json`; the shell's `E2EDrive` polls `E2EDriveDirective` every
  2 s (as `lib/e2e.js` does), applies `install` to the Launchpad view-model
  (image card, username, hostname, passwords, encryption), enforces the same
  image-integrity gate (`imageMismatch`), clicks Install, and on the Done
  screen honours `reboot`. It reports through `E2EDriveReport` with the same
  state JSON the harness parses today.
- `tests/gui/gui.spec.js` (Playwright against the web frontend) is replaced
  by `Wootc.Shell.Tests` (view-model logic, runs on Linux under `dotnet test`
  with the WinUI project excluded) and `Wootc.Shell.UiTest` (FlaUI on
  `windows-latest`: launch, screenshot each screen, assert the Install
  button's disabled reason text). The GUI screenshot gallery job renders from
  the UiTest screenshots.
- The CDP-based recipe in `tests/e2e/phase1/README.md` is deleted; it never
  worked with stock Wails and has no WinUI equivalent.

### Packaging and delivery

WinUI 3 cannot be published as a single-file exe. Two delivery forms, in
order:

1. **Now (unsigned, alpha):** `dotnet publish` self-contained, unpackaged
   (`WindowsPackageType=None`, `WindowsAppSDKSelfContained=true`), wrapped by
   **Inno Setup** into one `Bluefin-Installer-Setup.exe` per brand. No runtime
   to download, installs to `%LOCALAPPDATA%\Programs\<Brand>`, adds the
   Add/Remove entry the engine registers today. SmartScreen warns, exactly as
   it does for the unsigned Wails exe.
2. **When signed (#229/#230):** the same publish output as **MSIX** per brand,
   winget `InstallerType: msix` replacing `portable` in
   `packaging/winget/*.yaml.in`. MSIX cannot be installed unsigned, so signing
   is a hard prerequisite for this form, not for the shell itself.

The engine exe ships inside the shell's folder; the release keeps publishing
`wootc.exe` on its own for the headless and harness paths.

### Build and CI

- `windows-latest` job: `dotnet restore/build/test` for `shell/`, `dotnet
  publish` per brand from `packaging/brands.sh` (#319) with
  `-p:AssemblyName=<exeName> -p:ApplicationIcon=… -p:Version=…`, Inno Setup via
  the `innosetup` Chocolatey package, artifacts uploaded beside the Go
  artifacts. Go engine build unchanged.
- `ci.yml` drops `wootc-dashboard` (Linux Wails) and the Wails Windows build
  once the shell is the release artifact; until then both build.
- Windows App SDK floor: Windows 10 1809 (10.0.17763). `docs/user-guide.md`
  requirements line gains it; every supported machine already meets it.

## Cut-over plan

| Phase | Deliverable | Depends on |
|---|---|---|
| A | `wootc.exe serve` + protocol golden tests + DTO generator; Wails untouched | #297 seams (done as part of it) |
| B | `shell/` scaffold, CI build on windows-latest, brand matrix, Inno packaging; ships as a **preview** asset next to the Wails exe | A |
| C | Screens complete; drive mode; UiTest gallery; one green `--gui-install` E2E with the shell | B, #331 for the Recovery screen |
| D | Release artifacts switch to the shell; Wails exe kept one release as `wootc-legacy.exe` | C |
| E | Delete Wails, `app/frontend/`, `wailsjs/`, `migration_linux.go`, dashboard build, Playwright GUI tests; `docs/` truth pass | D + one clean release |

Each phase is one PR series; nothing in A–C changes what a user downloads.

## What this does not fix, said plainly

- **Signing.** SmartScreen and the UAC publisher line are the same problem
  before and after; #229 is the fix. WinUI does not help or hurt it.
- **The Linux side on KDE.** Bazzite and Aurora users still see GTK windows
  for the migration tools. A Breeze-aware theme is the cheap step; Kirigami
  twins are a separate decision.
- **Windows 10 without WebView2** was the one concrete usability cost of
  Wails; it is gone. Windows 10 below 1809 was never supported.
