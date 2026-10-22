# winget packaging

`*.yaml.in` are templates for the [winget-pkgs](https://github.com/microsoft/winget-pkgs)
manifests of the generic native setup installer, published as
**`TunaOS.wootc`** (`InstallerType: inno`). The setup package installs the
WinUI shell and its protected Go engine; it does not put a portable
`wootc.exe` on PATH.

`.github/workflows/winget-publish.yml` renders them for every **full** release.
It skips pre-releases. It fills `{{VERSION}}` and `{{TAG}}` from the release
tag, then waits for the native package workflow. Next, it uses the release's
`wootc-Installer-Setup.exe` asset and computes `{{SHA256}}` from the published
bytes. Finally, [wingetcreate](https://github.com/microsoft/winget-create)
submits a PR to winget-pkgs.

Requirements, both one-time:

- **`WINGET_TOKEN` repository secret** — a classic PAT with `public_repo`
  scope, used by wingetcreate to fork winget-pkgs and open the PR. Without
  it the workflow prints what it *would* submit and exits green.
- The **first** submission creates the package (same rendered manifests);
  Microsoft's moderation review of a new package can take a few days.
  Updates after that are routine.

## Branded installers

Branded installers (Bazzite-Installer, Aurora-Installer, …) are deliberately
NOT auto-submitted: their winget identities belong to their projects
(`Bazzite.Installer` sits in Bazzite's namespace, not ours), so each needs
that project's sign-off first (#227).

The sign-off is recorded per brand in `app/branding/<brand>/blessing.json` —
`winget.identifier`, `winget.namespaceOwner`, and `winget.identifierAgreed`.
Nothing branded is submitted anywhere until that last flag is true, and
`tests/unit/brand-blessings.bats` asserts no branded identifier appears in
`winget-publish.yml` at all.

`brand/*.yaml.in` are the templates for those packages, and
`render-brand.sh` fills them from the brand's own `brand.json` and
`blessing.json`:

```sh
packaging/winget/render-brand.sh bazzite            # placeholders, shape only
packaging/winget/render-brand.sh bazzite 0.2.0 <url> <sha256>
```

They render to stdout and are never submitted — the point is to have the
real thing to *offer* a project when asking, rather than describing a
package they cannot see. A rendered set carries the namespace owner and the
blessing status in its header, and its description says
`PERMISSION NOT YET GRANTED` until `identifierAgreed` is true, so a draft
pasted into somebody's issue tracker cannot imply a yes nobody gave.

The ask itself is in [docs/upstream-blessings.md](../../docs/upstream-blessings.md).
