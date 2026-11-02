# Native Windows shell: status and cutover

WinUI 3 remains the chosen Windows UI. Linux keeps GTK4/libadwaita.
Main now contains native setup packaging; that does not prove a native release
has shipped or passed its release gates. The latest non-prerelease inspected
on 2026-11-02 was `v0.1.0-alpha.1`, with the older Wails executables.
See [getting started](getting-started.md) for the download distinction.

## Source and evidence boundaries, 2026-11-02

| Phase | Actual state | Remaining work |
|---|---|---|
| A: engine protocol | Go stdio RPC, generated DTOs, authenticated native sessions and one-shot operation grants exist | Full native acceptance is separate from protocol/component tests |
| B: scaffold (#343) | Native projects, authenticated assessment RPC, startup UI tests, and five branded preview packages pass hosted component checks. Each installed package shows its palette and logo and refuses Windows builds before 17763. Windows policy refuses elevation for a standard user, and the shell keeps the branded assessment and the retry ([run 38776425860](https://github.com/tuna-os/wootc/actions/runs/38776425860)) | Interactive UAC consent on the secure desktop, proof on build 17763, and preview release assets (#608). The native E2E now installs the real preview installer in the guest ([run 38888315334](https://github.com/tuna-os/wootc/actions/runs/38888315334)) |
| C: experience (#344) | A read-only startup view, a configuration form, a route for an interrupted install, an install route that needs an engine grant and a confirmation, progress and done views fed by that install session, manage and recovery views whose uninstall and boot repair need their own engine grant in an install session, Linux window views whose VM actions each need an engine grant, UI Automation controls, a screen gallery, and an E2E drive mode (`WOOTC_E2E_DRIVE=1`) that operates these views exist. The GUI E2E can install the native shell in the guest and drive it (`WOOTC_E2E_GUI_FRONTEND=native`, see [Native shell E2E](#native-shell-e2e)). [Run 38857241312](https://github.com/tuna-os/wootc/actions/runs/38857241312) drove a full Windows, deployer, Linux and Windows cycle through it | Consumer screens, VM and migration flows, interactive UAC consent, accessibility, persistence, and the full journey. An unelevated shell with an elevated install engine, installed by the real preview installer, drove a full cycle ([run 38923119161](https://github.com/tuna-os/wootc/actions/runs/38923119161)) |
| D: release (#345) | Issue closed 2026-10-31; source builds branded Inno native setup as the primary artifact and retains one legacy artifact | A workflow/package definition is not a clean published native release; inspect retained build, install and removal evidence |
| E: removal (#346) | Wails remains in the source | Remove it only after a clean native release; closing D alone is not that proof |

This preview candidate retains [run 36328543336](https://github.com/tuna-os/wootc/actions/runs/36328543336).
It tested merge `68e6f452` from head `7aee354`.
The adapter passed 30 tests. Both tests for the UI passed at startup. No test skipped.
The [source and artifact record](experiments/evidence/2026-09-27-native-serving-readiness/hosted-7a/provenance.json) binds those checks.

The tests used the same elevated user. They do not prove interactive UAC or installation.

The UAC refusal test uses `ConsentPromptBehaviorUser=0` for a disposable standard user.
Windows then returns `ERROR_ACCESS_DISABLED_BY_POLICY`, not the `ERROR_CANCELLED` of a No click.
The shell shows both as a refusal. A No click on the secure desktop has no hosted test.
The older Wails assets remain the observed latest non-prerelease download;
main's native release packaging is a separate source fact.

The future preview and results follow the [migration extension plan](specs/migration-extensions.md). Those APIs do not exist in `serve` yet.
Phase 1 must run Linux inside Windows before native promotion.
Carry VM preparation, launch, stop, and resume through the shell.
The [VM-first correction](adr/0004-restore-vm-first-product.md) supersedes the earlier VM deferral.
The [enterprise proposal](specs/enterprise-migration.md) remains optional.

## Keep the engine contract stable

The Go engine owns install, storage, boot, recovery, and uninstall policy.
The shell owns presentation and the current person's choices.
Existing method names and DTO shapes remain stable unless a versioned change replaces them.
Generate C# DTOs from Go and retain protocol goldens.

Keep `wootc.exe install`, `status`, `uninstall`, `recover`, and stdio `serve`
for headless tools and tests. The native GUI uses the authenticated named-pipe
transport and session-scoped authorization described below, not an elevated
stdio child. Transport adapters must not duplicate install logic.

Source layout:

```text
shell/
  Wootc.Shell/                 WinUI application
    Engine/                   authenticated client, generated DTOs
    Branding/                 validated identity and XAML tokens
    ViewModels/               assessment, choices, progress, recovery
    Views/                    native controls and accessible labels
    Drive/                    E2E directives through view-model actions
  Wootc.Shell.Core/            testable state and protocol logic without WinUI
  Wootc.Shell.Tests/           unit/contract tests, including Linux CI
  Wootc.Shell.UiTests/         Windows UI Automation and screenshot evidence
```

## Build dependency and OS evidence

Current source pins **Windows App SDK 2.6.4** in
[`Wootc.Shell.csproj`](../shell/Wootc.Shell/Wootc.Shell.csproj) and
**.NET SDK 10.0.403** in [`global.json`](../shell/global.json), with roll-forward
disabled. Install that SDK to reproduce the build. The application still
targets `net8.0-windows10.0.19041.0`; SDK and target framework are different.
Older hosted runs on this page used earlier pins and do not certify the new
combination or the minimum OS.

The [SDK support contract](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/support)
includes backward compatibility to Windows 10 1809, build 17763.
That does not prove wootc works on that OS.
The `net8.0-windows10.0.19041.0` compile target and the minimum runtime
OS are separate settings. Review `TargetPlatformMinVersion` and
`SupportedOSPlatformVersion`, then test the actual native package on the
claimed minimum OS before the user guide adopts that floor.

The completed stdio cleanup and console fixes have tests in
`app/serve_shutdown_test.go` and `app/console_windows_test.go`.
These tests do not supply authentication between native peers or shell acceptance.

## Correct elevation and transport

The old proposal combined `runas` with redirected child stdin/stdout.
That launch model is invalid: `runas` uses ShellExecute, while .NET stream
redirection needs `UseShellExecute=false`.
See [Microsoft's process contract](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.processstartinfo.useshellexecute)
and [shell launch verbs](https://learn.microsoft.com/en-us/windows/win32/shell/launch).

The implemented native transport follows this contract:

1. Start the shell without elevation. Show local brand assets and read-only assessment.
2. Request UAC only for an operation that needs it. Launch the engine from its trusted absolute path with `runas`.
3. Retain the engine process handle. Do not redirect its standard streams through ShellExecute.
4. Use a named pipe with a unique local name with explicit ACLs, first-instance protection, and no remote clients.
5. Authenticate both peers against their expected process handles and tokens before any RPC.
6. Derive the source SID and session from the authenticated shell token.
7. Exchange protocol version, build identity, brand identity, and capabilities. Reject incompatible pairs before any mutation.
8. Send existing JSON-RPC messages over that pipe, with bounded message sizes and connection deadlines.

A random pipe name is not authentication.
Do not grant pipe access to all local users to accommodate alternate-admin UAC.
The authenticated source token, elevated token, and selected profile have distinct roles.
If impersonation fails, stop the request; never continue under the privileged token.
See Microsoft's [pipe security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights),
[client process identity](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeclientprocessid),
and [impersonation contract](https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-impersonatenamedpipeclient).

On UAC refusal, keep the branded assessment visible with an Allow button.
Do not place passwords, tokens, or unlock keys in process arguments or rendezvous files.
Reject a replaced engine, wrong-session peer, stale endpoint, or replayed handshake.
These checks need native Windows tests before the transport becomes a release path.

## Preserve the original person's identity

The native transport captures and revalidates the original user's token;
profile collection must use that authority rather than a path or username
supplied by a caller. The legacy installer now refuses when interactive
identity is unavailable or differs after elevation. `USERPROFILE` or
`WOOTC_*` hints are not an alternate-admin fallback.

Keep user-specific collection in the original unelevated session where possible.
Bind exports to the source SID, profile identity, session, plan, and consent.
Resolve Known Folders through the verified user token when necessary.
Use a separate privileged engine only for operations that need machine access.
See [Known Folder resolution](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shgetknownfolderpath)
and [DPAPI's user context](https://learn.microsoft.com/en-us/windows/win32/api/dpapi/nf-dpapi-cryptunprotectdata).

Tests must include a standard user who supplies a different administrator's credentials.
The data preview and exported data must still belong to the original person.
Never use the administrator's browser profile as an automatic fallback.

Decision, 2026-10-16: the first native release refuses an alternative administrator.
A standard user who types another administrator's credentials gets the refusal, not an install.
Support comes after that release, and only with the identity tests above.

## Disconnect, cancel, and recovery

EOF or a crash of the shell must request cancellation. It cannot mean immediate process exit.
The engine must wait for active work to reach a safe boundary and finish cleanup.
A BCD entry needs observed disarm or a persisted recovery result before exit.
A test of disconnect must start an armed operation to prove cleanup.

Keep RPC stdout separate from diagnostics. Logs go to stderr and the protected log directory.
Stdio mode must preserve its supplied handles. Do not attach a console over them.
Bound individual operations; a timeout must not kill a worker mid-mutation and report success.
A reconnect reads durable state and confirms the active run before another install starts.

## Consumer screens and migration

| Surface | Required behavior |
|---|---|
| Assessment | Hardware and space results, chosen distro, clear blocked reasons, help without UAC |
| Migration preview | What will move, what stays linked to Windows, what needs sign-in, space and consent |
| Preparation/install | Observed named stages, cancel behavior, honest errors and elapsed time |
| VM | Prepare the persistent image, open Linux inside Windows, stop/resume, and offer native promotion later |
| Ready | Next reboot, MOK instructions if applicable, Windows return path, migration still owed on Linux |
| Manage | Enter Linux, inspect outcomes, repair, uninstall with preservation choices |
| Recovery | Explain the last failed step and the safe next action from durable state |

The Linux GTK tools own first-login import, target verification, and sign-in guidance.
The Windows shell does not infer successful migration from a completed Linux install.
Expose details progressively; keep the default journey short for a casual user.

## Native distro identity

The same brand config must reach the shell, engine, setup package, and Apps entry.
UAC names the engine's publisher, so shell-only identity is insufficient.
Bundle local assets for the brand after validation for startup and UAC refusal.
Translate palette, typeface, logos, title, and support links into native resources.
CSS is not a native theme contract; document which custom layouts lack support.

The preview translates the palette and the existing `logo.svg` into native resources.
Contrast must pass WCAG limits, and high contrast keeps the system palette.
Each brand supplies its font as WOFF2. XAML cannot load that format, so the preview uses the system font.

Decision, 2026-10-16: the native shell uses the Windows system font for every brand.
No brand ships a font licence that allows redistribution in a desktop package.
A brand can add a native font later only as TTF or OTF with its licence file.
Gradients and radii from `theme.css` have no native equivalent.
Use the distro config from the adoption work, with versioned extensions.

Use standard Windows controls, light/dark themes, and a high-contrast fallback.
Mica and animation are optional. They cannot be prerequisites on older GPUs.
Test keyboard-only use, screen readers, large text, DPI changes, and reduced motion.
Target 1366×768 and low-memory machines as explicit test cohorts.

## Packaging and offline proof

Phase D's **source workflow** makes native shell setup the primary artifact:
each eligible brand builds `<Product>-Installer-Setup.exe` through the Inno
wrapper; the generic name is `wootc-Installer-Setup.exe`. It retains one
`wootc-legacy.exe` Wails download for the first native release. These names
describe packaging on main, not assets present in `v0.1.0-alpha.1`.

Keep the Go engine beside the shell and retain the standalone headless asset.
The native package embeds the public key for release verification. The package
workflow attaches `native-SHA256SUMS` beside the setup assets.
Package cleanup and Linux uninstall need separate, clearly named ownership.

The install does not depend on an external runtime after it arms.
Recovery tasks run the protected engine from the installed native bundle.
The Apps entry for the Linux install uses that bundle too. Shell removal does
not remove Linux data or silently change headless ownership.
The setup installer refuses an existing destination; an upgrade must remove
the prior native package first. Do not remove Linux data merely because a
user removes the shell.

Pin .NET, Windows App SDK, and build-tool versions before you change the package.
The self-contained settings for .NET and Windows App SDK are separate.

A guide from Microsoft describes support for single files in specific
configurations. Another guide still describes limitations. Do not make an
unconditional single-file promise.
Prove the chosen setup artifact on a clean offline VM with neither runtime
preinstalled.
See the [unpackaged guide](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app)
and [self-contained deployment](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps).

Derive the Windows minimum from the chosen SDK, .NET runtime, and project configuration.
Do not infer it only from the minimum for Windows App SDK.
Test Windows 10 and 11 before a change to the product requirements.

MSIX still needs a proven distribution path. Code signatures need one too.
The checked-in winget manifest targets Inno setup; package review/publication
is a separate prerequisite, not proof that `winget install` works today.
A native UI does not remove SmartScreen or code-signature requirements.

The production native engine's Secure Boot provenance derives from the exact
released shim bytes, signing key and matching source commit through
`shell/packaging/release-metadata.py`, not an empty/handwritten authority list.
The package Publisher uses `packaging/brand.py`'s effective identity (including
unapproved-brand distributor identity); installed-package checks retain
`publisher-observations.json`. Component fixtures and package assertions still
do not prove firmware trust or a fresh machine's Apps rendering.

The native plan displays the complete Windows-directory → editable Linux-user
mapping and warnings. Editing it discards an earlier grant and requires a new
check; final confirmation repeats the engine-granted mapping. Unsupported TPM
root encryption is no longer offered; the native default is `none`.
Hardware warnings remain visible during progress and on Done.

The dedicated `native-proof / native-shell GUI acceptance` E2E job records
actual UI Automation/CopyFromScreen observations before the confirmation
button, compares displayed boot evidence independently to Linux QGA and the
current Windows boot identity, and retains
`native-gui-soak-proof-<run>-<attempt>` and
`native-shell-build-<run>-<attempt>` artifacts. This is a source verification
path, **not** a newly passed native cycle, an RC qualification, or the start
or completion of a thirty-day soak.

## Screen gallery

The gallery is a separate build of the shell (`-p:NativeGallery=true`).
It uses recorded fixtures in `shell/Wootc.Shell.Gallery` in place of the engine, and it starts no engine process.
It cannot install, remove, repair, restart Windows, or run a VM.
A confirmed install in the gallery only replays the recorded `install:progress` stream.
The shipped preview never references the gallery project or its fixtures.

The `native-build` job drives the gallery with UI Automation through each screen.
The test reaches each screen and starts each action with the keyboard only.
Each control that gets focus must have an accessible name.
One screen is also shown with the Windows high-contrast setting on.
The screenshots and `gallery.json` are in the `winui-native-gallery` artifact, not in git.

## Native shell E2E

`run-e2e.sh --gui-install` with `WOOTC_E2E_GUI_FRONTEND=native` drives the native shell instead of the Wails app.
`e2e-hosted.yml` takes it as `gui_frontend: native`. `e2e-gui.yml` and `e2e-nightly.yml` offer it as a dispatch input.

1. A Windows job publishes the shell with the run's commit as `NativeBuildId` and the image's brand as `NativeBrandId`.
   It is the preview build. Each step refuses the gallery build (`-p:NativeGallery=true`).
2. The Linux E2E job builds `wootc-engine.exe` with the same build and brand identity.
   The engine also carries the public half of the run's manifest key. The harness signs the staged `SHA256SUMS.sig` with that key.
   `tests/e2e/native-package.py` then writes `native-package.json`, as `shell/packaging/write-manifest.ps1` does for the preview installer.
3. The Windows job compiles both Inno packages around that engine and manifest.
   The production `setup.iss` output is `<Product>-Installer-Setup.exe`.
   The `preview.iss` output remains the disposable GUI-package proof. It uses
   the pinned compiler through `shell/packaging/compile-preview.ps1`, the same
   script that `winui-preview.yml` uses. The two jobs run at the same time.
   They give the shell, engine, and both installers to each other as artifacts.
   Thus the seed of the manifest key stays in the Linux job
   (`.github/scripts/wait-run-artifact.sh`).
4. Before reboot, `setup-wootc.ps1` silently runs the production setup from
   the OEM payload. It stages the protected engine for recovery and status.
   The GUI path copies the preview installer separately. It compares the digest
   and runs the installer with `/VERYSILENT /SUPPRESSMSGBOXES`.
   It installs to `Program Files\wootc Native Preview\<brand>\bundle` with
   the Program Files ACLs that the shell and the engine need. The check needs
   the manifest file count, both binary digests, the Inno uninstall entry, and
   one uninstaller.
   `WOOTC_E2E_NATIVE_INSTALLER=robocopy` copies the preview package instead.
   The workflow selects this fallback if the runner cannot download the pinned
   compiler. We do not claim the production setup in that fallback. The run
   then shows a warning and names the method.
5. `WOOTC_E2E_DRIVE=1` and `WOOTC_PRELOAD=0` are set machine-wide, because the engine starts through `runas` and need not inherit the shell's environment.
   `ConsentPromptBehaviorAdmin=0` makes each engine elevation non-interactive: startup, then one install session per plan check.
6. The shell starts unelevated: from a `/RL LIMITED` task as the autologged administrator (`WOOTC_E2E_NATIVE_UNELEVATED=1`, the default; `0` restores `/RL HIGHEST`).
   A guest probe reads each token's integrity level and elevation.
   The ledger then needs `native-shell-unelevated` (shell at medium, 0x2000, not elevated, from the package).
   It also needs `native-engine-elevated` (the `--purpose install` engine at high, 0x3000, elevated, for the shell's own user, from the package).
   The single-instance check must find exactly one `Wootc.Shell.exe` from that package directory and no Wails app.
   A native run also needs a `native-shell` assertion, so the ledger never records a native green as a Wails one.

`ConsentPromptBehaviorAdmin=0` elevates an administrator without a prompt.
So this E2E does not prove interactive consent on the secure desktop, a No click, or a standard user who types an administrator's credentials.
The alternative-administrator flow stays refused (decision above).

[Run 38888315334](https://github.com/tuna-os/wootc/actions/runs/38888315334) ran the real installer for bluefin in the guest.
It passed the handoff, the compile, the silent install and every check in step 4.
Its unelevated launch then never started the shell.
The task read its launcher from `C:\wootc`, whose state ACL allows only SYSTEM and Administrators, and a limited token holds Administrators deny-only.
The unelevated launcher now lives in `C:\ProgramData\wootc-e2e-launch`, which Users can read and only SYSTEM and Administrators can change.

[Run 38902999307](https://github.com/tuna-os/wootc/actions/runs/38902999307) proved the unelevated split for bluefin.
The shell ran unelevated at medium integrity (0x2000).
The configuration engine and the install engine ran at high integrity (0x3000), elevated through `runas`, for the same user.
The plan check then refused the plan. The form kept the 40 GB default on a drive with 58 GB free, beside a 22 GB reserve.
The form now reads that reserve with `GetNativeInstallSpace` and lowers the disk size to fit, as the Wails launchpad does.

[Run 38923119161](https://github.com/tuna-os/wootc/actions/runs/38923119161) passed a full Windows, deployer, Linux and Windows cycle for bluefin with all three proofs.
The shell came from the real preview installer and started unelevated from a `/RL LIMITED` task.
The install engine ran elevated through `runas` for the same user.
[Run 38931058878](https://github.com/tuna-os/wootc/actions/runs/38931058878) passed the same cycle for bazzite, with the same three proofs.
MokManager enrolled the key, and the form chose a 35 GB disk on 59 GB free.
The form lowered the 40 GB default to 35 GB beside the 22 GB reserve on a drive with 58 GB free.

The plan check has a known time risk.
The shell waits 110 seconds for `PrepareNativeInstall`.
In that time the engine reads the system once and observes the storage twice, with a limit of 40 seconds for each observation.
The second observation also selects the state root again, and the grant contract needs it, so the check keeps both.
Run 38857241312 passed, but it did not record the margin.
If a slow disk causes a timeout, measure each part before you change a limit.

### Drive reports during the plan check

In runs 38923119161 and 38931058878 the harness read no drive report for about two minutes.
The silence started when the directive arrived and stopped at the progress screen (126 seconds for bluefin, 86 seconds for bazzite).
The state file did not exist in that time, so the shell wrote no report at all.
The engine and the window were not at fault:

- The tick that clicked Install waited for the whole plan check, which is a second elevation and then `PrepareNativeInstall`.
  The window starts no tick while one runs, so no tick reported until the install started.
- Before the click, the drive channel does not wait behind `GetNativeInstallSpace`.
  The configuration engine answers one request at a time, so the shell dropped the reports of those ticks.
  This read is limited to 20 seconds for the registry.

The drive loop now starts the click and does not wait for it.
Each tick reports the form while the check runs, and the next tick after the answer records the outcome.
During the check, `installBtnDisabled` is null: the engine has not accepted or refused the clicked plan yet.
The hint gives the check's elapsed time, and the harness writes each new hint to the log.
`report-install-checking.json` holds this report for the shell, the engine and the harness.

A person also waits for the plan check.
The window shows a busy bar and the elapsed time of the check, once each second.
The shell now reads and hashes its package on a worker thread, not on the window thread, before each engine connection.

### Hosted plan check

On the hosted runner, the UI test of the installed preview tries each image on each volume that the engine observes.
A plan needs space for the Linux disk (20 GB at least) and for the image's unpack area (22 GB at least) on one drive.
The engine offers only an NTFS basic-data partition on a GPT disk.
The hosted runner had 28 GB free on C: (run 38908347372), and no other volume gave a plan.
So the test cannot check a plan with the engine there.
It checks the form's space refusal against the drive's real free space, and it logs the observed volumes.

`test-installed-preview.ps1` also logs each fixed volume with its file system, partition style and free space.

Only the native VM E2E (`gui_frontend: native`) exercises the engine plan check.
The test does not change the free space or the reserve.
If a runner gives a volume that holds a plan, the test checks that plan with the engine automatically.

The job does not free space on C:.
In a trial, the job removed the toolchains that it does not use. That took about seven minutes, and C: then had 49 GB free.
That time is too much for each branded package job.
## Evidence before cutover

| Gate | Evidence |
|---|---|
| Transport | Native authenticated-peer tests; refusal of wrong SID/session/process; cancellation during mutation |
| Build | Windows CI builds and packages every eligible brand; generated DTOs remain current |
| UI parity | Real controls, screenshots, accessible names, keyboard flow, truthful blocked reasons |
| Drive contract | Existing `e2e-drive.json` directives operate view-models; image mismatch fails closed; an install directive must name its target volume (`storageId`: an engine storage id or a drive letter such as `C:`), and a missing, unknown or ambiguous target is refused as a drive error |
| Migration | Same plan/result fixtures on native Windows and GTK; partial results and retry stay visible |
| Deployment | Shell-driven Windows → deployer → Linux → Windows cycle, including offline and BitLocker cohorts |
| Recovery | Kill shell at safe test points; cancel; restart; inspect durable state; repair; uninstall |
| Consumer hardware | Low memory, slow disk, older GPU, high DPI, no development tools or WebView2 |
| Distribution | Own metadata/icons, clean-machine setup and removal, retained matching boot artifacts |

Carry engine evidence only for unchanged code and contracts.
Native UI, transport, identity, setup, and accessibility need new evidence.
Do not mark a matrix cell green from a Wails run after the shell cutover.
Track this rule with #357 and the [release ladder](milestones.md).
Retain the legacy build until a native release passes its gates, before phase E removes it.

## Current stdio protocol reference

### Purpose, launch and connection

`wootc.exe serve` is a headless adapter to the same Go engine used by the
installer. It is a child-process **stdin/stdout** protocol, not an HTTP server:
there is no TCP port, URL, REST endpoint, or listener option. It does not open
the GUI. `serve` defines no command-specific flags; additional arguments are
not a supported configuration API. Use a trusted matching engine build.

For a non-mutating protocol probe in PowerShell:

```powershell
$requests = @(
  '{"jsonrpc":"2.0","id":1,"method":"GetStatus"}'
  '{"jsonrpc":"2.0","id":2,"method":"Shutdown"}'
)
$requests | & .\wootc.exe serve 2> .\serve-stderr.log
```

Use the engine executable's actual path/name if your package calls it
`wootc-engine.exe`. The child must inherit or have explicitly redirected
stdin/stdout; drain stdout and stderr independently. Do not use `runas`
with redirected standard streams. The consumer native shell uses the
authenticated named-pipe launcher, identity handshake, and configuration or
install sessions instead. A random pipe name, a supplied username, or a
successful stdio probe does not authorize a native session.

**Safety:** stdio is a trusted automation interface, not an untrusted local
service. `StartInstall`, reboot, uninstall, defrag and VM actions can change the
machine. Elevation, protected state and all engine preconditions still apply.
Do not use mutating examples on a development workstation.

### Framing, responses and lifetime

- Write one UTF-8 JSON object per line, terminated by LF (CRLF is accepted).
  Blank lines are ignored. No JSON-RPC batches or `Content-Length` framing are
  supported. The current reader limit is 10 MiB per line; use small requests.
- Request envelope:
  `{"jsonrpc":"2.0","id":1,"method":"GetStatus","params":null}`.
  Method names are case-sensitive. Use a unique string or integer `id`.
  Omit `params` for parameterless methods. Native read methods reject any
  non-null params, even `{}`.
- Success: `{"jsonrpc":"2.0","id":1,"result":...}`.
  Void methods return `result:null`. Errors have `error` instead of `result`:
  `{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"..."}}`.
  `error.data` is optional; configuration errors can carry diagnostic data.
- This adapter responds with `id:null` when the request has no `id`; do not
  rely on JSON-RPC client-notification silence. Malformed JSON uses `id:null`.
  Unknown JSON object properties are not generally rejected by legacy calls;
  native plan and confirmation decoders are deliberately stricter.
- `-32700`: JSON decoding failed; `-32600`: missing/wrong `"2.0"` or empty
  method; `-32601`: unknown method or unavailable in this session;
  `-32602`: malformed params; `-32603`: engine failure, policy refusal, changed
  observations, or unavailable capability. Treat messages as display text,
  not stable machine-readable codes. An error is not a success receipt.
- Dispatch is sequential, but install and VM workers emit asynchronous events.
  Responses and events can be interleaved; route responses by `id` and events
  by `method`, never by line position.
- `StartInstall`/`PrepareVM` acceptance does not mean work finished. Read
  `GetStatus` or VM state and events. `CancelInstall` requests cancellation;
  `null` does not prove cleanup has completed.
- `Shutdown` responds with `null` and ends the loop; EOF also ends it. Closing
  the transport triggers VM shutdown and install cancellation/cleanup. The
  engine waits for safe cleanup; its 30-second install warning is **not** a
  deadline after which it kills the worker. Drain stderr until process exit.
  Exit 0 means the server loop ended normally, not that an install succeeded;
  a reader error returns exit 1.

### Session availability

The method list below is a union, not a promise that every transport accepts
every method:

| Session | Allowed surface |
|---|---|
| Legacy stdio `serve` | Legacy methods below; native configuration, grants, maintenance, `InspectBoot` and native VM methods are unavailable |
| Native assessment | `GetStatus`, `GetLastRun`, `GetRecoveryVerdict`, `GetInstallRecovery`; a configuration-capable session additionally permits `GetNativeConfiguration`, `GetNativeInstallSpace` and the three E2E drive methods |
| Native install-purpose | `GetStatus`, `CancelInstall`, `Shutdown`, grants/confirmations for install, maintenance and VM, plus `GetUninstallInfo`, `InspectBoot`, `GetNativeVMStatus`; `Reboot` only after this session's own successful completed install |

The trusted transport selects these capabilities. A JSON field cannot upgrade
an assessment session. E2E drive calls remain inert unless the **engine's**
environment enables `WOOTC_E2E_DRIVE=1`; this is a test facility, not a
consumer automation API.

### Methods

| Method | Params | Result |
|---|---|---|
| `GetSupportPolicy` | — | `SupportPolicy` |
| `GetSystemInfo` | — | `SystemInfo` |
| `GetBranding` | — | `Branding` |
| `GetReleaseNotice` | — | `ReleaseNotice` (optional newer release) |
| `GetImages` | — | `[]Image` |
| `GetInstallSteps` | — | `[]StepDefinition` |
| `GetNativeConfiguration` | — | `NativeConfigurationSnapshot` |
| `GetNativeInstallSpace` | image and drive of the last configuration read | `InstallSpace` (configuration session only; the space the image needs beside its disk) |
| `GetSessionCandidates` | — | `[]SessionCandidate` (detection/consent choices, no token material) |
| `StartInstall` | `InstallConfig` | `null` or error |
| `PrepareNativeInstall` | `InstallConfig` | `NativeInstallGrant` (install session only; one plan for each session) |
| `ConfirmNativeInstall` | intent confirmation | `null` or error (install session only; the first attempt uses the intent) |
| `CancelInstall` | — | `null` |
| `GetStatus` | — | `InstallStatus` |
| `DefragDrive` | — | `null` |
| `Reboot` | — | `null` |
| `ExistingInstallFound` | — | `bool` |
| `GetUninstallInfo` | — | `UninstallInfo` |
| `UninstallWith` | `UninstallOptions` | `null` |
| `InspectBoot` | — | `BootRepairReport` (install session only; saves an evidence bundle, changes no boot entry) |
| `PrepareNativeMaintenance` | `NativeMaintenancePlan` | `NativeMaintenanceGrant` (install session only; one plan for each session) |
| `ConfirmNativeMaintenance` | intent confirmation | `null` or error (install session only; the first attempt uses the intent) |
| `GetNativeVMStatus` | — | `NativeVMStatus` (install session only; no paths, process IDs or runtime hashes) |
| `PrepareNativeVMAction` | `NativeVMPlan` | `NativeVMGrant` (install session only; one pending VM action at a time) |
| `ConfirmNativeVMAction` | intent confirmation | `null` or error (install session only; the first attempt uses the intent) |
| `BootIntoLinux` | — | `null` |
| `GetLastRun` | — | `LifecycleState` |
| `GetRecoveryVerdict` | — | `RecoveryVerdict` |
| `GetInstallRecovery` | — | `InstallRecoverySummary` (class, safe actions and engine text; no evidence or step error) |
| `E2EDriveDirective` | — | `string` (empty unless the engine runs with `WOOTC_E2E_DRIVE=1`; native shell: configuration session only) |
| `E2EDriveReport` | `string` | `null` (written only when bound to the current directive; native shell: configuration session only) |
| `E2EDriveReady` | `string` | `null` (first-render marker, bound to no directive; native shell: configuration session only) |
| `GetVMCapability` | — | `VMCapability` (signed runtime and persistent disk availability) |
| `GetFreshVMCapability` | — | `VMCapability` (signed runtime and helper availability) |
| `GetVMState` | — | `VMState` (disk lifecycle, not desktop proof) |
| `TryInVMFresh` | image string | `null` or error; refuses preparation without account details |
| `InstallVMRuntime` | — | `null` or error; acquire this release's signed runtime, no replacement of an existing runtime |
| `PrepareVM` | `VMInstallConfig` | `null` or error; prepare the persistent account/disk, then launch |
| `BootInVM` | — | `null` or error; restart the verified stopped disk |
| `StopVM` | — | `null` or error; request guest shutdown, retain ownership until actual exit |
| `ForceStopVM` | — | `null` or error; forced stop requires recovery before reuse |
| `Shutdown` | — | `null`; stop the loop, then complete cleanup |

Notifications use `install:progress` and `vm:progress`.
The native shell uses the versioned VM contract (`NativeVMStatus`, `NativeVMPlan` and `NativeVMGrant`) in an install session.
Each VM action that changes state needs its own engine grant, and each grant is used once.
The legacy VM methods stay for the legacy app.

### Parameter schemas

Use JSON field names, not Go/C# property names. Integers must be JSON numbers,
booleans JSON booleans, and passwords strings. Never log request payloads.

| Type/call | JSON object fields and constraints |
|---|---|
| `InstallConfig` / `StartInstall` | `imageRef:string`, `diskSizeGB:integer`, `username:string`, `password:string`, `hostname:string`, `bootloader:string` (`auto`, `grub2`, `systemd-boot`), `composeFs:boolean`, `storageDrive:string` (letter without colon; legacy empty means C), `encryption:string` (`none`, `luks-passphrase`, or currently refused `tpm2-luks`), `luksPassphrase:string`, `windowsLook:boolean`; optional `sessionConsent:object<string,boolean>` is per-app opt-in, optional `profileAccounts:array<ProfileAccount>` is the reviewed complete mapping, optional `faultInject:string` is a test-only boundary |
| `PrepareNativeInstall` | Same install object **except** `sessionConsent` and `faultInject` are forbidden. Object only, at most 16 KiB; unknown/duplicate/null fields refused. Nonempty image, username, password and storage drive and positive disk size required. Admission further checks policy, image and physical storage observations |
| `ProfileAccount` | `{"windowsDir":"<observed raw profile directory>","linuxUser":"<reviewed account name>"}`; only Linux account names are editable, all discovered profiles must remain represented, and duplicates/invalid/reserved names refuse |
| `GetNativeInstallSpace` | `{"imageRef":"<observed ref>","storageDrive":"C"}`; must name one admitted image/drive from the last configuration read |
| `UninstallOptions` | `{"deleteRootDisk":false,"removePartition":false}`; destructive choices remain subject to engine ownership and safety checks |
| `NativeMaintenancePlan` | `action:string`: `uninstall`, `repair-boot`, `restore-windows-boot`, `try-again`, or `boot-linux`; `deleteRootDisk:boolean`, `removePartition:boolean` apply only to uninstall |
| `VMInstallConfig` / `PrepareVM` | `{"imageRef":"<ref>","username":"<Linux user>","password":"<secret>"}`; no implied encryption, Windows-look or session-migration options |
| `NativeVMPlan` | `action:string`: `install-runtime`, `prepare`, `boot`, `stop`, `force-stop`; only `prepare` includes `imageRef:string`, `username:string`, `password:string` |
| `TryInVMFresh`, `E2EDriveReport`, `E2EDriveReady` | String params; report/ready accept serialized report text, not an arbitrary JSON report object |

Legacy object parameters also accept `[object]`, using only the first element.
Legacy string params accept a string, `[string]`, or `{"state":"..."}` /
`{"report":"..."}`. New clients should send the direct object or string;
native plan/confirmation contracts do **not** accept positional arrays.

The native install grant returns `schemaVersion`, `session`, `brandId`,
`intentId`, admitted `imageRef`, `storageDrive`, `diskSizeGB`, `encryption`,
`bitLockerOn`, `bitLockerRecoveryKeyWarning`, `fastStartupOn`, and
`secureBootChainWarning`, `profileAccounts` and `profileWarnings`. Display the
engine's grant and mapping before confirmation; do not manufacture a grant
from the form. Confirmation is:

```json
{"jsonrpc":"2.0","id":12,"method":"ConfirmNativeInstall","params":{"kind":"confirm-install","protocolVersion":1,"session":"<grant.session>","brandId":"<grant.brandId>","intentId":"<grant.intentId>"}}
```

Maintenance/VM confirmations have those same binding fields plus the granted
`action`, using `kind:"confirm-maintenance"` / `"confirm-vm"` and their
respective method names. Session and intent IDs are engine-issued 32-character
lowercase hex. All confirmation fields are required, unknown/duplicate fields
are refused, and confirmations are limited to 4096 bytes. The first attempt
consumes its intent even if refused. Install/maintenance preparation is
one-shot per session, including a failed prepare; a changed plan needs a new
session. VM actions each need a fresh grant; a new VM prepare replaces an
unconfirmed grant. Engine observations and original-user identity are checked
again before mutation.

### Results, schemas and event payloads

The complete wire schema is the Go structs' **`json` tags**, with corresponding
`JsonPropertyName` attributes in the generated
[`Dto.cs`](../shell/Wootc.Shell/Engine/Dto.cs). `omitempty` fields may be absent;
do not interpret omission as proof of success. Go pointers can be `null`;
nil slices not explicitly normalized by a method can also be `null`.
`GetImages` and `GetSessionCandidates` explicitly normalize to `[]`.

This map covers every result and nested schema used by the methods above:

| Contract | Canonical definition / example |
|---|---|
| `SupportPolicy`, `SystemInfo`, `DataPartition`, `Branding`, `UninstallInfo`, `UninstallOptions` | [`app.go`](../app/app.go), [golden DTO JSON](../app/testdata/dto/) |
| `ReleaseNotice` (`version:string`, `url:string`; no notice has both strings empty) | [`release_notice.go`](../app/release_notice.go) |
| `Image`, `InstallConfig`, `InstallStatus`, `ProgressEvent`, `ProfileAccount` | [`install_contract.go`](../app/install_contract.go), [`profiles.go`](../app/profiles.go), [golden DTO JSON](../app/testdata/dto/) |
| `StepDefinition` (`id`, `owner`, `label`, all strings) | [`steps_gen.go`](../app/steps_gen.go); generated phase vocabulary, not prose matching |
| `SessionCandidate` (`app`, `kind`, `portable`, `recommend`, `note`, `consentRequired`) | [`session.go`](../app/session.go), [candidate example](../app/testdata/dto/session_candidate.json) |
| `NativeConfigurationSnapshot`, image/default/bundle/storage records | [`native_configuration.go`](../app/native_configuration.go), [configuration fixture](../tests/unit/fixtures/native-gallery/configuration.json) |
| `InstallSpace` (`imageRef`, `compressedBytes`, `sizeSource`, `scratchGiB`, `bundleGiB`, `reserveGiB`) | [`install_space.go`](../app/install_space.go); reserve is space **beside** the Linux disk |
| `NativeInstallGrant` | [`native_install_session.go`](../app/native_install_session.go) |
| `NativeMaintenancePlan`, `NativeMaintenanceGrant` | [`native_maintenance.go`](../app/native_maintenance.go), [maintenance exchanges](../tests/unit/fixtures/native-maintenance/responses.ndjson) |
| `BootRepairReport` | [`boot_repair.go`](../app/boot_repair.go); observation includes saved evidence, not repair success |
| `NativeVMCapability`, `NativeVMStatus`, `NativeVMPlan`, `NativeVMGrant` | [`native_vm.go`](../app/native_vm.go), [VM exchanges](../tests/unit/fixtures/native-vm/responses.ndjson) |
| `LifecycleState` | [`state.go`](../app/state.go), [lifecycle example](../app/testdata/dto/lifecycle_state.json) |
| `RecoveryVerdict` | [`recovery.go`](../app/recovery.go) |
| `InstallRecoverySummary`, `InstallRecoveryActions` | [`status_install_recovery.go`](../app/status_install_recovery.go); native response is a safe summary, not raw journal evidence |
| `VMInstallConfig` | [`vm_account.go`](../app/vm_account.go) |
| `VMCapability` | [`vm_windows.go`](../app/vm_windows.go), [non-Windows definition](../app/vm_other.go) |
| `VMState`, `VMEvent` | [`vm_lifecycle.go`](../app/vm_lifecycle.go), [`app.go`](../app/app.go), [event example](../app/testdata/dto/vm_event.json) |

An illustrative status exchange (values vary with the engine's observation):

```json
{"jsonrpc":"2.0","id":1,"method":"GetStatus"}
{"jsonrpc":"2.0","id":1,"result":{"running":false,"done":false,"existing":false}}
```

Notifications omit `id`. Install progress carries `ProgressEvent`:

```json
{"jsonrpc":"2.0","method":"install:progress","params":{"phaseId":"image-pull","step":"Downloading Linux","message":"Downloading Linux…","percent":50,"done":false}}
```

`phaseId` and `error` may be absent. The example is a shape illustration, not
an observed run. `vm:progress` carries `VMEvent` (`stage:string`,
`percent:number`, `message:string`). A progress
percentage, helper exit or running QEMU process does not establish login,
desktop readiness or successful migration. Read the durable lifecycle and
independent evidence before reporting completion.

### Contributor testing patterns

- Protocol behavior and JSON goldens: from `app`, run `go test ./...`.
  `serve_test.go`, `serve_assessment_test.go`, `serve_shutdown_test.go` and
  native session tests exercise decoding, routing, refusal, and cleanup.
  Add behavioral requests/responses, not source-text assertions.
- After an intentional Go DTO change, run `go generate ./...` from `app` and
  review generated DTO changes. Use `go test . -run TestDTOGoldens -update`
  only when deliberately updating the golden contract; a new golden is not
  runtime evidence.
- Cross-platform shell logic: `dotnet test shell/Wootc.Shell.Tests/Wootc.Shell.Tests.csproj`
  and `dotnet test shell/Wootc.Shell.NativeTests/Wootc.Shell.NativeTests.csproj`.
  Recorded exchanges and the gallery are suitable for screen/blocked-state
  development, but do not prove Windows transport, elevation or installation.
- On an isolated Windows fixture, use the real installed matching engine and
  native shell, then run the native E2E lane described above. Include malformed
  and replayed grants, cancel/EOF during an armed operation, and restart/recovery.
  Observe cleanup and Windows return; a successful `Shutdown` response alone
  proves neither. Interactive UAC, minimum OS, offline setup, accessibility,
  consumer hardware and RC screenshots retain their own acceptance gates.
