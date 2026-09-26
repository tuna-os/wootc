# Native Windows shell: status and cutover

WinUI 3 remains the chosen Windows UI. Linux keeps GTK4/libadwaita.
The existing consumer installer stays the default until native proof passes.
This revision corrects the transport and identity assumptions in the earlier design.

## Current source, 2026-09-26

| Phase | Actual state | Remaining work |
|---|---|---|
| A: engine protocol | Go `wootc.exe serve`, protocol tests, DTO generator exist | Safe disconnect barrier and preservation of transport handles need correction |
| B: scaffold (#343) | `shell/` contains generated `Engine/Dto.cs` only | Native projects, authenticated transport, brand resources, CI, preview package |
| C: experience (#344) | No native views or UI tests | Consumer screens, migration preview, E2E drive mode, accessibility, full-cycle proof |
| D: release (#345) | Not started | Native default only after C; retain a legacy artifact for one release |
| E: removal (#346) | Not started | Remove Wails/web frontend only after a clean native release and docs audit |

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
Do not remove Linux data merely because a user removes the preview shell.

Pin .NET, Windows App SDK, and build-tool versions before the package experiment.
The self-contained settings for .NET and Windows App SDK are separate.
One Microsoft guide describes single-file support for specific configurations.
Another guide still describes limitations. Do not make an unconditional single-file promise.
Prove the chosen artifact on a clean offline VM with neither runtime preinstalled.
See the [unpackaged guide](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/unpackage-winui-app)
and [self-contained deployment](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/self-contained-deploy/deploy-self-contained-apps).

Derive the Windows minimum from the chosen SDK, .NET runtime, and project configuration.
Do not infer it only from the minimum for Windows App SDK.
Test Windows 10 and 11 before a change to the product requirements.
MSIX, signatures, and winget changes need their own proven distribution path.
A native UI does not remove SmartScreen or code-signature requirements.

## Evidence before cutover

| Gate | Evidence |
|---|---|
| Transport | Native authenticated-peer tests; refusal of wrong SID/session/process; cancellation during mutation |
| Build | Windows CI builds and packages every eligible brand; generated DTOs remain current |
| UI parity | Real controls, screenshots, accessible names, keyboard flow, truthful blocked reasons |
| Drive contract | Existing `e2e-drive.json` directives operate view-models; image mismatch fails closed |
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
