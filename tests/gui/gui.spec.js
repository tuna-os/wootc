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
  await page.locator('input[placeholder="james"]').fill('alice');
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
  await page.locator('input[placeholder="james"]').fill('alice');
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter2');
  await page.locator('#install-btn').click();
  await expect(page.locator('.progress-bar-fill')).toBeVisible();
  // Wait until a mid-run step is active.
  await expect(page.locator('.progress-steps-list')).toContainText('Setting up ESP');
  await page.waitForTimeout(900);
  await shot(page, '03-progress');
});

test('installer — done screen', async ({ page }) => {
  const steps = [...INSTALL_STEPS, { step: 'done', message: 'Installation complete.', percent: 100, done: true }];
  await boot(page, { mode: 'installer', images: IMAGES, sysinfo: SYSINFO, installSteps: steps, stepDelay: 10 });
  await page.locator('input[placeholder="james"]').fill('alice');
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
    vm: { available: true, diskPath: 'C:\\wootc\\disks\\root.vhdx' } });
  await expect(page.getByText('Try Linux in a window')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Boot in VM' })).toBeEnabled();
  await shot(page, '09-vm-mode');
});

test('installer — BitLocker offers unencrypted-partition path (no forced decrypt)', async ({ page }) => {
  const sysinfo = { ...SYSINFO, bitLockerOn: true, bitLockerState: 'on',
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
