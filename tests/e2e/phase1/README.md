# Phase-1 E2E — installer verification without a deploy

Tests **Phase 1 only**: everything `wootc.exe` does on Windows up to the
armed reboot. No deployer boot, no image pull — the whole test runs in
~2 minutes against an already-booted E2E Windows VM (the `--keep` state of
`run-e2e.sh`, or any dockur container with QGA up).

Designed to run on **dilli** so kanpur (main) and himachal (VHDX) stay
undisturbed.

## What it exercises

1. Cross-compiles the real product (`wails` frontend build + `GOOS=windows
   go build -tags desktop,production`) — the binary users run, not a
   parallel script.
2. Pre-stages deployer artifacts into `C:\wootc\install\` via the Samba
   share (`downloadDeployer` skips files that already exist, so the
   GitHub download becomes a no-op — no network dependency).
3. Runs `wootc.exe install -image ... -username ... -password ...`
   (headless mode) over QGA.
4. Asserts the resulting system state (`assert-phase1.ps1`):
   - `state.json` = `armed`
   - `root.vhdx` exists and `Mount-DiskImage`/`Dismount-DiskImage` works
   - `vault.json` has a `$6$` hash and no plaintext password
   - ESP carries the signed chain: `EFI\fedora\{shimx64,grubx64}.efi` +
     deployer grub.cfg, `EFI\wootc\{deployer-vmlinuz,initramfs}`
   - BCD: "wootc" firmware entry with path `\EFI\fedora\shimx64.efi`,
     armed in the one-shot `bootsequence` (and NOT in `displayorder`)
   - `wootc.exe status` reports `armed`

Assertions marked `[pending-port]` cover the ESP staging that is still
being ported from `setup-wootc.ps1` into the Go `bootchain` (roadmap
item 2 in docs/gui-phase1-architecture.md) — they are expected to fail
until that lands, and they define its acceptance criteria.

## Driving the actual GUI (UI automation)

Wails on Windows renders in WebView2, which honors
`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222`.
That exposes the Chrome DevTools Protocol, so Playwright can drive the
real installer UI:

```powershell
# In the guest (via QGA):
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9222"
Start-Process C:\wootc\wootc.exe
```

```js
// On the host, with the port forwarded (compose.yml debug ports —
// see the configurable mapping added in 3731990):
const browser = await chromium.connectOverCDP('http://localhost:9222');
const page = browser.contexts()[0].pages()[0];
await page.click('.variant-card >> text=Yellowfin');
await page.fill('#username', 'test');
// ...
```

Pipeline logic is already covered headlessly; CDP runs are for the
frontend wiring (screen transitions, progress events, error rendering).
Keep them few and cheap.

## Usage

```bash
# On the E2E host with a running wootc-e2e-windows container:
./run-phase1.sh                # build + stage + install + assert
./run-phase1.sh --skip-build   # reuse existing wootc.exe artifact
```
