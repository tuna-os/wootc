# app/ — the wootc install engine

Go engine behind the native WinUI shell (`shell/`). The graphical installer is
the shell; this module is the engine it drives.

- `wootc install|status|uninstall` run the pipeline headless (`headless.go`).
- `--native-serve` is the authenticated JSON-RPC transport the shell uses
  (`serve.go`).
- Build the branded Windows executable with `packaging/build-windows.py`.
- Tests: `cd app && go test ./...`.

The Wails app, its web frontend and the Playwright GUI tests were removed in
#346; see [docs/winui-shell.md](../docs/winui-shell.md).
