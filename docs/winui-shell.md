# Native Windows shell: status and cutover

WinUI 3 remains the chosen Windows UI. Linux keeps GTK4/libadwaita.
The existing consumer installer stays the default until native proof passes.
This revision corrects the transport and identity assumptions in the earlier design.

## Current source, 2026-09-27

| Phase | Actual state | Remaining work |
|---|---|---|
| A: engine protocol | Go stdio RPC and DTO generator exist; legacy disconnect and console controls pass | Native operation authorization and the full consumer journey remain open |
| B: scaffold (#343) | Native projects, authenticated assessment RPC, startup UI tests, and five branded preview packages pass hosted component checks. Each installed package shows its palette and logo and refuses Windows builds before 17763. Windows policy refuses elevation for a standard user, and the shell keeps the branded assessment and the retry ([run 38776425860](https://github.com/tuna-os/wootc/actions/runs/38776425860)) | Interactive UAC consent on the secure desktop, proof on build 17763, and preview release assets (#608). The native E2E now installs the real preview installer in the guest ([run 38888315334](https://github.com/tuna-os/wootc/actions/runs/38888315334)) |
| C: experience (#344) | A read-only startup view, a configuration form, a route for an interrupted install, an install route that needs an engine grant and a confirmation, progress and done views fed by that install session, manage and recovery views whose uninstall and boot repair need their own engine grant in an install session, Linux window views whose VM actions each need an engine grant, UI Automation controls, a screen gallery, and an E2E drive mode (`WOOTC_E2E_DRIVE=1`) that operates these views exist. The GUI E2E can install the native shell in the guest and drive it (`WOOTC_E2E_GUI_FRONTEND=native`, see [Native shell E2E](#native-shell-e2e)). [Run 38857241312](https://github.com/tuna-os/wootc/actions/runs/38857241312) drove a full Windows, deployer, Linux and Windows cycle through it | Consumer screens, VM and migration flows, interactive UAC consent, accessibility, persistence, and the full journey. An unelevated shell with an elevated install engine, installed by the real preview installer, drove a full cycle ([run 38923119161](https://github.com/tuna-os/wootc/actions/runs/38923119161)) |
| D: release (#345) | Not started | Native default only after C; retain a legacy artifact for one release |
| E: removal (#346) | Not started | Remove Wails/web frontend only after a clean native release and docs audit |

This preview candidate retains [run 36328543336](https://github.com/tuna-os/wootc/actions/runs/36328543336).
It tested merge `68e6f452` from head `7aee354`.
The adapter passed 30 tests. Both tests for the UI passed at startup. No test skipped.
The [source and artifact record](experiments/evidence/2026-09-27-native-serving-readiness/hosted-7a/provenance.json) binds those checks.

The tests used the same elevated user. They do not prove interactive UAC or installation.

The UAC refusal test uses `ConsentPromptBehaviorUser=0` for a disposable standard user.
Windows then returns `ERROR_ACCESS_DISABLED_BY_POLICY`, not the `ERROR_CANCELLED` of a No click.
The shell shows both as a refusal. A No click on the secure desktop has no hosted test.
The current Wails installer and release assets remain the default.

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
for headless tools and tests. The native GUI needs a separate transport adapter.
A transport adapter must not add a second implementation of install logic.

Proposed layout:

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
  Wootc.Shell.UiTest/          Windows UI Automation and screenshot evidence
```

## Build dependency and OS evidence

On 2026-09-27, Microsoft identifies **2.5.1** as the stable version of
Windows App SDK. The [download page](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads)
and [package page](https://www.nuget.org/packages/Microsoft.WindowsAppSDK/2.5.1)
show that version. The preview pins that package and .NET SDK 8.0.425.
The hosted run above restored, built, and tested that combination.
It does not prove the minimum OS in the manifest.

The [SDK support contract](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/support)
includes backward compatibility to Windows 10 1809, build 17763.
That does not prove wootc works on that OS.
The requested `net8.0-windows10.0.19041` compile target and the minimum runtime
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

Proposed native transport:

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

The old design claimed a fix for alternate-admin UAC through explicit profile fields.
The current `InstallConfig` has no verified source-user contract.
Several collectors still read `HKCU` or `USERPROFILE` in the elevated process.
A supplied path or username is not proof of ownership.

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

Publish the shell as a preview beside the current installer first.
An Inno Setup wrapper can provide one download for an unpackaged self-contained bundle.
Keep the Go engine beside the shell and retain the standalone headless asset.
Package cleanup and Linux uninstall need separate, clearly named ownership.

The install does not depend on the preview package after it arms.
The recovery tasks run a copy of the engine in `install\wootc.exe` under the install directory.
The Apps entry for the Linux install runs that copy too, so removal of the preview does not break that entry.
The preview installer refuses an existing destination, so an upgrade also removes the preview first.
Do not remove Linux data merely because a user removes the preview shell.

Pin .NET, Windows App SDK, and build-tool versions before the package experiment.
The self-contained settings for .NET and Windows App SDK are separate.

A guide from Microsoft describes support for single files in specific configurations.
Another guide still describes limitations. Do not make an unconditional single-file promise.
Prove the chosen artifact on a clean offline VM with neither runtime preinstalled.
See the [unpackaged guide](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app)
and [self-contained deployment](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps).

Derive the Windows minimum from the chosen SDK, .NET runtime, and project configuration.
Do not infer it only from the minimum for Windows App SDK.
Test Windows 10 and 11 before a change to the product requirements.
MSIX, signatures, and winget changes need their own proven distribution path.
A native UI does not remove SmartScreen or code-signature requirements.

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
3. The Windows job compiles the real preview installer (`preview.iss`) for the brand around that engine and manifest.
   It uses the pinned Inno compiler through `shell/packaging/compile-preview.ps1`, the same script `winui-preview.yml` uses.
   The two jobs run at the same time. They give the shell, the engine and the installer to each other as run artifacts.
   Thus the seed of the manifest key stays in the Linux job (`.github/scripts/wait-run-artifact.sh`).
4. In the guest, the harness copies the installer, compares its digest, and runs it with `/VERYSILENT /SUPPRESSMSGBOXES`.
   It installs to `Program Files\wootc Native Preview\<brand>\bundle` with the Program Files ACLs that the shell and the engine need.
   The check needs the manifest file count, both binary digests, the Inno uninstall entry, and one uninstaller.
   `WOOTC_E2E_NATIVE_INSTALLER=robocopy` copies the package instead.
   The workflow selects it only when the runner cannot download the pinned compiler.
   The run then shows a warning and names the method.
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
| `GetSessionCandidates` | — | as today |
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
| `GetVMCapability` | — | `VMCapability` | Signed runtime and persistent disk availability. |
| `GetFreshVMCapability` | — | `VMCapability` | Signed runtime and helper availability. |
| `GetVMState` | — | `VMState` | Durable disk lifecycle; desktop readiness requires independent evidence. |
| `TryInVMFresh` | image string | — | Legacy call refuses preparation without account details. |
| `InstallVMRuntime` | — | — | Acquire the signed runtime for this release; no native fallback or existing-runtime replacement. |
| `PrepareVM` | `VMInstallConfig` | — | Prepare a persistent system with its Linux account, then launch its VM. |
| `BootInVM` | — | — | Restart the same verified, stopped VM disk. |
| `StopVM` | — | — | Request guest shutdown; preserve ownership until actual exit. |
| `ForceStopVM` | — | — | Explicit forced stop; disk requires recovery before reuse. |
| `Shutdown` | — | `null` (engine exits 0) |

Notifications use `install:progress` and `vm:progress`.
The native shell uses the versioned VM contract (`NativeVMStatus`, `NativeVMPlan` and `NativeVMGrant`) in an install session.
Each VM action that changes state needs its own engine grant, and each grant is used once.
The legacy VM methods stay for the legacy app.
