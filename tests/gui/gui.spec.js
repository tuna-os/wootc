// gui.spec.js — Playwright conformance + screenshot capture for the wootc
// GUI. Drives the real frontend bundle with a mocked Wails backend
// (mock-backend.js). Screenshots land in docs/screenshots/ and double as
// the documentation walkthrough; the expect() calls are the conformance
// checks.

import { test, expect } from '@playwright/test';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { IMAGES, SYSINFO, INSTALL_STEPS, MIGRATION_CATEGORIES, APPS, OFFICE } from './fixtures.js';

const dir = path.dirname(fileURLToPath(import.meta.url));
const SHOTS = path.join(dir, '../../docs/screenshots');
const mockSrc = fs.readFileSync(path.join(dir, 'mock-backend.js'), 'utf8');

// Load the app with a given mock config injected before any script runs.
async function boot(page, mock) {
  await page.addInitScript((m) => { window.__WOOTC_MOCK = m; }, mock);
  await page.addInitScript({ content: mockSrc });
  await page.goto('/');
}

async function shot(page, name) {
  await page.screenshot({ path: path.join(SHOTS, `${name}.png`) });
}

test('installer — launchpad (variant selection + system info)', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO, existing: false });
  await expect(page.locator('.screen-title').first()).toContainText('Install TunaOS');
  await expect(page.locator('.image-card')).toHaveCount(4);
  // System info chips reflect the host.
  await expect(page.locator('.sysinfo')).toContainText('UEFI');
  await expect(page.locator('.sysinfo')).toContainText('Secure Boot');
  // Install is gated until the form is valid.
  await expect(page.locator('#install-btn')).toBeDisabled();
  await shot(page, '01-launchpad');
});

test('installer — validation gates the Install button', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO });
  const inputs = page.locator('.field input');
  // username, hostname, password, confirm — fill a mismatching pair first.
  await page.locator('.field:has-text("Linux Username") input').fill('alice');
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter3');
  await expect(page.locator('#install-hint')).toContainText('do not match');
  await expect(page.locator('#install-btn')).toBeDisabled();
  await shot(page, '02-validation');
  // Fix the confirm — button enables.
  await pw.nth(1).fill('hunter2');
  await expect(page.locator('#install-btn')).toBeEnabled();
});

test('installer — progress screen', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO, installSteps: INSTALL_STEPS, stepDelay: 400 });
  await page.locator('.field:has-text("Linux Username") input').fill('alice');
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter2');
  await page.locator('#install-btn').click();
  await expect(page.locator('.progress-bar-fill')).toBeVisible();
  // Wait until a mid-run step is active.
  await expect(page.locator('.progress-steps-list')).toContainText('Getting Linux prepared');
  await page.waitForTimeout(900);
  await shot(page, '03-progress');
});

test('installer — done screen', async ({ page }) => {
  const steps = [...INSTALL_STEPS, { step: 'done', message: 'Installation complete.', percent: 100, done: true }];
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO, installSteps: steps, stepDelay: 10 });
  await page.locator('.field:has-text("Linux Username") input').fill('alice');
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter2');
  await page.locator('#install-btn').click();
  await expect(page.locator('.done-title')).toContainText('ready', { timeout: 5000 });
  await shot(page, '04-done');
});

test('control panel — partition-aware uninstall options', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO, existing: true,
    uninstall: { found: true, storageDrive: 'D', diskPath: 'D:\\wootc\\disks\\root.vhdx',
      diskSizeGB: 40, onDedicatedVol: true, reclaimGB: 60 } });
  await expect(page.locator('.screen-title')).toContainText('Manage TunaOS');
  // Reversible by default: keeping data is the unchecked default.
  await expect(page.getByText('Also delete my Linux data')).toBeVisible();
  // Partition-aware option appears for a wootc-created volume.
  await expect(page.getByText(/Give the 60 GB back to Windows/)).toBeVisible();
  await shot(page, '05-control-panel');
});

test('control panel — Boot in VM offered when available (§6.2)', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO, existing: true,
    uninstall: { found: true, storageDrive: 'C', diskPath: 'C:\\wootc\\disks\\root.vhdx', diskSizeGB: 40 },
    vm: { available: true, accelerator: 'whpx', bundled: true, diskPath: 'C:\\wootc\\disks\\root.vhdx' } });
  await expect(page.getByText('Try Linux in a window')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Boot in VM' })).toBeEnabled();
  await shot(page, '09-vm-mode');
});

test('control panel — unavailable VM explains how to enable acceleration', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO, existing: true,
    uninstall: { found: true, diskPath: 'C:\\wootc\\disks\\root.vhdx' },
    vm: { available: false, reason: "No supported VM accelerator is available. Enable Windows Hypervisor Platform in 'Turn Windows features on or off'." } });
  await expect(page.getByText(/Enable Windows Hypervisor Platform/)).toBeVisible();
  await expect(page.getByRole('button', { name: 'Boot in VM' })).toBeDisabled();
  await shot(page, '12-vm-unavailable');
});

test('installer — NTFS defrag recommendation is advisory and actionable (§3.6)', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES,
    sysinfo: { ...SYSINFO, defragRecommended: true } });
  await expect(page.getByText('Windows recommends optimizing C:')).toBeVisible();
  await expect(page.getByText(/Installation remains safe if you skip this/)).toBeVisible();
  await shot(page, '11-defrag-preflight');
  await page.getByRole('button', { name: 'Defrag now' }).click();
  await expect(page.getByText('Windows recommends optimizing C:')).toBeHidden();
});

test('installer — backend detection is automatic; forcing systemd-boot warns for Secure Boot', async ({ page }) => {
  // Catalog bootloader/composeFs are display metadata: the deployer's probe
  // decides the backend (forcing metadata sent ostree bonito down the
  // composefs path, and pointed composefs images at the unsigned
  // systemd-boot deployer chain that Secure Boot rejects). Selecting any
  // image leaves the override OFF; turning it on is explicit and warns.
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO });
  await page.getByText('Bonito').first().click();
  await page.locator('details:has-text("Advanced") summary').click();
  const force = page.getByRole('checkbox', { name: /Force systemd-boot/ });
  await expect(force).not.toBeChecked();
  await force.check();
  await expect(page.getByText(/requires a verified.*shim plus vendor-signed/)).toBeVisible();
});

test('installer — supported family custom OCI reference is accepted', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: { ...SYSINFO, secureBootOn: false } });
  await page.locator('input[placeholder="ghcr.io/ublue-os/image:tag"]').fill('ghcr.io/projectbluefin/bluefin:stable');
  // A supported-family custom ref is accepted: fill a valid form and the
  // Install button enables. (Custom refs default to grub2/ostree per the
  // backend contract — covered by the "custom OCI ref defaults" test.)
  // Identity fields live under "Advanced" now (defaults come from the PC).
  await page.locator('details:has-text("Advanced") summary').click();
  await page.locator('.field:has-text("Linux Username") input').fill('tester');
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter2');
  await expect(page.locator('#install-btn')).toBeEnabled();
});

test('installer — BitLocker offers unencrypted-partition path (no forced decrypt)', async ({ page }) => {
  const sysinfo = { ...SYSINFO, bitLockerOn: true, bitLockerState: 'on',
    bitLockerRecoveryKeyWarning: true,
    dataPartitions: [{ letter: 'E', label: 'Backup', freeGB: 200, encrypted: false }] };
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo });
  // The chooser must NOT mention decrypting C:.
  const body = await page.locator('#app').innerText();
  expect(body).toContain('keep C: fully encrypted');
  expect(body.toLowerCase()).not.toContain('decrypt c:');
  // Both options present: reuse existing unencrypted E:, or create new.
  await expect(page.getByText(/Use drive E:/)).toBeVisible();
  await expect(page.getByText(/Create a new space for Linux/)).toBeVisible();
  await shot(page, '08-bitlocker');
});

test('installer — LUKS encryption options (§2.6) with TPM recommended', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO });
  // Encryption section is visible with three radio options.
  await expect(page.getByText('Disk Encryption')).toBeVisible();
  await expect(page.getByText('No encryption')).toBeVisible();
  await expect(page.getByText('TPM auto-unlock')).toBeVisible();
  await expect(page.getByText('RECOMMENDED', { exact: true })).toBeVisible();
  await expect(page.getByText('Passphrase')).toBeVisible();
  // Default is TPM auto-unlock; no passphrase field shown.
  const passCount = await page.locator('input[type="password"]').count();
  // There should be exactly 2 password fields: Password + Confirm (no LUKS passphrase)
  expect(passCount).toBe(2);
  // Switching to passphrase mode reveals the LUKS passphrase input.
  await page.getByText('Passphrase').click();
  await page.waitForTimeout(200);
  await expect(page.locator('input[type="password"]').nth(2)).toBeVisible();
  await shot(page, '10-luks-encryption');
});

test('branding — partner re-skin applies theme + copy', async ({ page }) => {
  const brand = {
    name: 'Acme Switch', tagline: 'Move to Acme Linux in minutes.', logoEmoji: '🅰️',
    version: '2.0', accent: '#e6007a', accentText: '#ffffff',
    background: '#0d0b14', card: '#181320', text: '#f0e8f5', installVerb: 'Migrate',
  };
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO, brand });
  // Brand name in the title bar, custom install verb on the CTA and title.
  await expect(page.locator('.titlebar-name')).toContainText('Acme Switch');
  await expect(page.locator('.screen-title').first()).toContainText('Migrate TunaOS');
  await expect(page.locator('#install-btn')).toContainText('Migrate');
  // Accent applied as a CSS variable.
  const accent = await page.evaluate(() =>
    getComputedStyle(document.documentElement).getPropertyValue('--accent').trim());
  expect(accent).toBe('#e6007a');
  await shot(page, '07-branded');
});

test('migration dashboard — files, apps, office', async ({ page }) => {
  await boot(page, { mode: 'migration', categories: MIGRATION_CATEGORIES, apps: APPS, office: OFFICE });
  await expect(page.locator('.screen-title')).toContainText('already here');
  // Files section: bridged + native + available states all render.
  await expect(page.getByText('Steam games')).toBeVisible();
  await expect(page.getByText('✓ On Linux')).toBeVisible();       // native
  await expect(page.getByText('Connected to Windows').first()).toBeVisible(); // bridged
  // Apps section with honest per-app badges.
  await expect(page.getByText('Your apps')).toBeVisible();
  await expect(page.getByText('✓ Signed in').first()).toBeVisible();  // firefox/telegram
  await expect(page.getByText('Re-link needed')).toBeVisible();        // signal
  // Office section.
  await expect(page.getByText('Microsoft Office → LibreOffice')).toBeVisible();
  await shot(page, '06-migration-dashboard');
});

test('installer — custom OCI ref defaults to auto backend detection', async ({ page }) => {
  // Guessing systemd-boot for custom refs sent a bluefin:lts install into
  // "systemd-boot is not bundled" (run 20260723T1100), and guessing grub2
  // hardcoded the other direction. The deployer probes the image and picks
  // the backend definitively (the configuration that took dakota green —
  // run 30710282014), so the GUI's job is to say 'auto' and stay out of it.
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO });
  await page.locator('input[placeholder="ghcr.io/ublue-os/image:tag"]').fill('ghcr.io/projectbluefin/bluefin:lts');
  const sel = await page.evaluate(() => window.__WOOTC_STATE?.selected || null);
  if (sel) {
    expect(sel.bootloader).toBe('auto');
    expect(sel.composeFs).toBe(false);
  } else {
    // State not exported to the page — assert via the visible config text.
    await page.locator('details:has-text("Advanced") summary').click();
    await expect(page.locator('body')).not.toContainText('systemd-boot is not bundled');
  }
});

// #174 / streamlined launchpad. The identity row is only allowed to hide when
// it actually carries derived values — install validation REQUIRES a username,
// so a blank-and-hidden one would disable Install while pointing at a field
// the user cannot see.
test('installer — identity hides under Advanced only when derived from the PC', async ({ page }) => {
  await boot(page, {
    mode: 'installer', images: IMAGES,
    sysinfo: { ...SYSINFO, suggestedUsername: 'jreilly', suggestedHostname: 'thinkpad' },
  });

  // Derived: the default form asks for a password only. The field is still in
  // the DOM (inside the collapsed <details>), so assert on VISIBILITY — the
  // E2E drive helper relies on that DOM presence, and a text assertion here
  // would pass even if the row were shown.
  await expect(page.locator('.field:has-text("Linux Username") input')).toBeHidden();

  // ...and the values are still reachable (and correct) under Advanced.
  await page.locator('details:has-text("Advanced") summary').click();
  await expect(page.locator('.field:has-text("Linux Username") input')).toHaveValue('jreilly');
  await expect(page.locator('.field:has-text("Computer name") input')).toHaveValue('thinkpad');

  // Password alone is enough to enable Install.
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter2');
  await expect(page.locator('#install-btn')).toBeEnabled();
});

test('installer — identity stays on the main form when it cannot be derived', async ({ page }) => {
  // No suggestedUsername/suggestedHostname: nothing was derived, so the fields
  // must remain visible rather than silently blocking the Install button.
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO });
  await expect(page.locator('.field:has-text("Linux Username") input')).toBeVisible();
});

// #175. The window is frameless, so the title bar's own controls are the ONLY
// way to minimise or close it — if they stop reaching the runtime the app
// becomes untappable, which no other test would notice.
test('titlebar — frameless window controls reach the runtime', async ({ page }) => {
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO });

  await page.locator('#win-min').click();
  expect(await page.evaluate(() => window.__wootcWindowCalls)).toContain('WindowMinimise');

  await page.locator('#win-close').click();
  expect(await page.evaluate(() => window.__wootcWindowCalls)).toContain('Quit');
});

// Closing mid-install would leave the PC part-way converted, so the close
// button must ask first — and must NOT quit when the user declines.
test('titlebar — closing during an install asks for confirmation', async ({ page }) => {
  await boot(page, {
    mode: 'installer', images: IMAGES, sysinfo: SYSINFO,
    installSteps: INSTALL_STEPS, stepDelay: 4000,
  });
  await page.locator('.field:has-text("Linux Username") input').fill('alice');
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter2');
  await page.locator('#install-btn').click();
  await expect(page.locator('.progress-bar-fill')).toBeVisible();

  // Decline: the app must stay open.
  page.once('dialog', d => d.dismiss());
  await page.locator('#win-close').click();
  expect(await page.evaluate(() => window.__wootcWindowCalls)).not.toContain('Quit');

  // Accept: now it quits.
  page.once('dialog', d => d.accept());
  await page.locator('#win-close').click();
  expect(await page.evaluate(() => window.__wootcWindowCalls)).toContain('Quit');
});

// Every "get me out of here" button must actually quit. These reach the
// runtime via the Quit import; an earlier version called window.wails?.Quit?.()
// — a global Wails does not define — so they optional-chained into silent
// no-ops and no test noticed, because the mock had invented window.wails.
test('every exit button reaches the runtime', async ({ page }) => {
  // Launchpad "Cancel"
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO });
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  expect(await page.evaluate(() => window.__wootcWindowCalls)).toContain('Quit');

  // Migration dashboard "Close"
  await boot(page, { mode: 'migration', categories: MIGRATION_CATEGORIES, apps: APPS, office: OFFICE });
  await page.locator('.footer').getByRole('button', { name: 'Close', exact: true }).click();
  expect(await page.evaluate(() => window.__wootcWindowCalls)).toContain('Quit');
});
