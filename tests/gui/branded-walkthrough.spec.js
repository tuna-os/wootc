// branded-walkthrough.spec.js — automated screenshot walkthroughs for every
// brand build (docs/branding-and-distribution.md §2). Each brand's REAL
// embedded assets are read from app/branding/<id>/ — brand.json, logo.svg,
// font.woff2, theme.css — and assembled into the exact GetBranding payload a
// `-X main.brandID=<id>` binary serves (same layering as branding_embed.go +
// mergeBranding: defaults ← brand.json ← asset data URIs). The four journey
// screens are then driven through the real frontend bundle and land in
// docs/screenshots/brands/<id>/, where docs/branded-walkthroughs.md shows
// them. The expect() calls double as conformance checks: a branded build
// must wear its own name, mark and look on every screen.

import { test, expect } from '@playwright/test';
import { INSTALLER_STEP_DEFINITIONS } from './step-catalogue-gen.js';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import { SYSINFO, INSTALL_STEPS } from './fixtures.js';

const dir = path.dirname(fileURLToPath(import.meta.url));
const BRANDS_DIR = path.join(dir, '../../app/branding');
const SHOTS = path.join(dir, '../../docs/screenshots/brands');
const mockSrc = fs.readFileSync(path.join(dir, 'mock-backend.js'), 'utf8');
const catalog = JSON.parse(fs.readFileSync(path.join(dir, '../../app/data/images.json'), 'utf8'));

// Mirrors defaultBranding() in app/app.go.
const DEFAULTS = {
  name: 'TunaOS', tagline: 'Bring Windows to Linux — keep everything.',
  logoEmoji: '🐠', version: '0.1.0',
  accent: '#5b6ee1', accentText: '#ffffff',
  background: '#0a0a0f', card: '#13131e', text: '#e8e8f0',
  installVerb: 'Install', productName: 'wootc', exeName: 'wootc',
};

// Mirrors embeddedBranding() + mergeBranding(): non-empty brand.json fields
// overlay the defaults; the asset files become data URIs.
function loadBrand(id) {
  const bdir = path.join(BRANDS_DIR, id);
  const json = JSON.parse(fs.readFileSync(path.join(bdir, 'brand.json'), 'utf8'));
  const brand = { ...DEFAULTS };
  for (const [k, v] of Object.entries(json)) {
    if (v !== '' && v !== undefined && v !== null && !(Array.isArray(v) && v.length === 0)) brand[k] = v;
  }
  const asset = (file, mime) => {
    const p = path.join(bdir, file);
    return fs.existsSync(p) ? `data:${mime};base64,${fs.readFileSync(p).toString('base64')}` : undefined;
  };
  const logo = asset('logo.svg', 'image/svg+xml');
  const font = asset('font.woff2', 'font/woff2');
  if (logo) brand.logoDataUri = logo;
  if (font) brand.fontDataUri = font;
  const theme = path.join(bdir, 'theme.css');
  if (fs.existsSync(theme)) brand.themeCss = fs.readFileSync(theme, 'utf8');
  return brand;
}

// Mirrors GetImages: a brand catalog restricts + orders; the generic build
// offers the green (alpha-proven) set.
function brandImages(brand) {
  if (brand.catalog?.length) {
    const byId = Object.fromEntries(catalog.map(i => [i.id, i]));
    return brand.catalog.map(id => byId[id]).filter(Boolean);
  }
  return catalog.filter(i => i.status === 'green');
}

async function boot(page, mock) {
  await page.addInitScript((m) => { window.__WOOTC_MOCK = m; },
    { ...mock, stepCatalogue: mock.stepCatalogue ?? INSTALLER_STEP_DEFINITIONS });
  await page.addInitScript({ content: mockSrc });
  await page.goto('/');
}

const shot = (page, id, name) =>
  page.screenshot({ path: path.join(SHOTS, id, `${name}.png`) });

// The project name may appear only inside the on-disk contract — Windows
// paths such as C:\wootc\disks\root.disk, which the deployer shares and
// docs/branding-and-distribution.md §2 keeps. Everything else a person reads
// in a branded build must be the brand's own words.
const WINDOWS_PATH = /[A-Za-z]:\\[^\s,;)]*/g;
function readableText(text) {
  return text.replace(WINDOWS_PATH, '');
}
async function expectNoProjectName(page, where) {
  const text = readableText(await page.locator('body').innerText());
  expect(text, `${where} shows the project name`).not.toMatch(/wootc/i);
}

async function fillForm(page) {
  await page.locator('.field:has-text("Linux Username") input').fill('alice');
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter2');
}

for (const id of fs.readdirSync(BRANDS_DIR).filter(f =>
  fs.existsSync(path.join(BRANDS_DIR, f, 'brand.json')))) {
  const brand = loadBrand(id);
  const images = brandImages(brand);
  const branded = !!brand.logoDataUri; // real-asset brands vs emoji (generic/TunaOS)

  test.describe(`walkthrough: ${id}`, () => {
    test('launchpad wears the brand', async ({ page }) => {
      await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand });
      await expect(page.locator('.screen-title').first())
        .toContainText(`${brand.installVerb} ${brand.name}`);
      await expect(page.locator('.titlebar-name')).toContainText(brand.productName);
      if (branded) {
        await expect(page.locator('img.titlebar-logo')).toBeVisible();
        await expect(page.locator('img.image-emoji').first()).toBeVisible();
        // The deep theme won: the ground is the brand's, not the default.
        const bg = await page.evaluate(() =>
          getComputedStyle(document.documentElement).getPropertyValue('--bg').trim());
        expect(bg.toLowerCase()).toBe(brand.background.toLowerCase());
      }
      if (brand.hideCustomImage) {
        await expect(page.getByPlaceholder('ghcr.io/ublue-os/image:tag')).toHaveCount(0);
      }
      // A branded build never shows the project name anywhere a user reads —
      // the requirement the whole branding system exists for. This caught a
      // real leak: the bluefin-lts catalog card called itself "the
      // fully-tested wootc image".
      if (branded) {
        expect(await page.locator('body').innerText()).not.toMatch(/wootc/i);
      }
      // The brand's default card is pre-selected.
      if (brand.defaultImage) {
        const def = images.find(i => i.id === brand.defaultImage);
        await expect(page.locator('.image-card.selected')).toContainText(def.name);
      }
      await shot(page, id, '01-launchpad');
    });

    test('progress speaks the brand', async ({ page }) => {
      await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand,
        installSteps: INSTALL_STEPS, stepDelay: 400 });
      await fillForm(page);
      await page.locator('#install-btn').click();
      await expect(page.locator('.screen-title').first())
        .toContainText(`Installing ${brand.name}`);
      await expect(page.locator('.progress-steps-list')).toContainText('Getting Linux prepared');
      await page.waitForTimeout(900);
      if (branded) await expectNoProjectName(page, 'progress');
      await shot(page, id, '02-progress');
    });

    test('done celebrates the brand', async ({ page }) => {
      const steps = [...INSTALL_STEPS,
        { step: 'done', message: 'Installation complete.', percent: 100, done: true }];
      await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand,
        installSteps: steps, stepDelay: 10 });
      await fillForm(page);
      await page.locator('#install-btn').click();
      await expect(page.locator('.done-title'))
        .toContainText(`${brand.name} setup is ready`, { timeout: 5000 });
      await expect(page.getByText('Save any open work first', { exact: false })).toBeInViewport();
      await expect(page.getByRole('button', { name: 'Reboot Now →' })).toBeInViewport();
      await expect(page.locator('.done-hero')).toContainText('Linux has not finished installing yet');
      await expect(page.locator('.done-hero')).not.toContainText('5–15 minutes');
      // An image that needs the distribution's MOK key (mokEnroll, #248)
      // shows the one-time MokManager step and its password before the
      // reboot, never after it.
      const def = images.find(i => i.id === (brand.defaultImage || images[0]?.id));
      if (def?.mokEnroll) {
        await expect(page.locator('body')).toContainText(`Driver trust for ${def.name}`);
        await expect(page.locator('body')).toContainText('Enroll MOK');
        await expect(page.locator('body')).toContainText(def.mokEnroll);
      }
      if (branded) await expectNoProjectName(page, 'done');
      await shot(page, id, '03-done');
    });

    test('manage offers the branded way back in (and out)', async ({ page }) => {
      await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand, existing: true,
        uninstall: { found: true, deployed: true, storageDrive: 'C',
          diskPath: 'C:\\wootc\\disks\\root.disk', diskSizeGB: 40 } });
      await expect(page.locator('.screen-title')).toContainText(`Manage ${brand.name}`);
      await expect(page.getByRole('button', { name: `Restart into ${brand.name} →` })).toBeVisible();
      await expect(page.getByRole('button', { name: `Uninstall ${brand.name}` })).toBeVisible();
      if (branded) await expectNoProjectName(page, 'manage');
      await shot(page, id, '04-manage');
    });

    if (!branded) return;

    test('uninstall dialogs speak the brand', async ({ page }) => {
      await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand, existing: true,
        uninstall: { found: true, deployed: true, storageDrive: 'C',
          diskPath: 'C:\\wootc\\disks\\root.disk', diskSizeGB: 40 } });
      const said = [];
      page.on('dialog', async (d) => { said.push(d.message()); await d.accept(); });
      await page.getByRole('button', { name: `Uninstall ${brand.name}` }).click();
      await expect.poll(() => said.length).toBeGreaterThanOrEqual(2);
      expect(said[0]).toContain(`Remove ${brand.name}?`);
      expect(said[1]).toContain(`${brand.name} has been removed`);
      for (const m of said) expect(readableText(m)).not.toMatch(/wootc/i);
    });

    test('an interrupted install speaks the brand', async ({ page }) => {
      await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand, installRecovery: {
        class: 'resumable', cause: 'interrupted', imageRef: images[0].imageRef,
        lastCompletedStep: 'Downloading Linux', stoppedAtStep: 'Downloading your Linux system',
        title: 'Setup stopped unexpectedly',
        message: `${brand.productName} closed or the computer lost power before setup finished.`,
        actions: { resumeInstall: true, retryDeploy: false, repairBoot: false, remove: true },
        recommended: 'resume', keepsVerifiedBlobs: 1, keepsVerifiedBytes: 1024 ** 3,
        evidence: ['journal.json: outcome "running", process 4242 no longer running'] } });
      const screen = page.locator('#interrupted-screen');
      await expect(screen).toContainText(`How it ended: ${brand.productName} closed`);
      await expect(screen).toContainText(`What ${brand.productName} found`);
      await expectNoProjectName(page, 'interrupted');
    });

    for (const [bootState, words] of [
      ['windows-only', `${brand.productName} is not in the boot order`],
      ['wootc-default', `A startup entry from ${brand.productName}`],
      ['foreign-next', `an entry ${brand.productName} does not own`],
    ]) {
      test(`recovery (${bootState}) speaks the brand`, async ({ page }) => {
        await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand,
          recoveryVerdict: { verdict: 'failed', title: 'Setup stopped', message: 'Setup could not finish this time.',
            untouched: true, canTryAgain: true, canRemove: true, canRepairBoot: true },
          bootReport: { bootState, ownership: 'certain', canRestoreWindows: false, canRepairBoot: true } });
        await expect(page.locator('body')).toContainText(words);
        await expectNoProjectName(page, `recovery ${bootState}`);
      });
    }

    test('a failed last run speaks the brand', async ({ page }) => {
      await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand,
        lastRun: { state: 'failed', phase: 'Making room for Linux', error: 'disk full' } });
      await expect(page.locator('body')).toContainText("didn't finish");
      await expectNoProjectName(page, 'failed last run');
    });

    // brand.json's background/text/card are set inline and win anyway; the
    // tokens below come only from theme.css. If the theme stopped covering
    // them (or became conditional on the colour scheme), a light-mode
    // Windows would get style.css's light palette under the brand's ground.
    test('a light-mode Windows still gets the brand look', async ({ page }) => {
      const read = () => page.evaluate(() => {
        const cs = getComputedStyle(document.documentElement);
        const names = ['--bg', '--bg-card', '--bg-input', '--bg-hover', '--border', '--text', '--text-muted', '--text-dim', '--accent'];
        return Object.fromEntries(names.map(n => [n, cs.getPropertyValue(n).trim().toLowerCase()]));
      });
      await page.emulateMedia({ colorScheme: 'dark' });
      await boot(page, { mode: 'installer', images, sysinfo: SYSINFO, brand });
      await expect(page.locator('.titlebar-name')).toContainText(brand.productName);
      const dark = await read();
      await page.emulateMedia({ colorScheme: 'light' });
      expect(await page.evaluate(() => matchMedia('(prefers-color-scheme: light)').matches)).toBe(true);
      const light = await read();
      expect(light, 'light-mode tokens differ from the brand look').toEqual(dark);
      expect(light['--bg']).toBe(brand.background.toLowerCase());
      await shot(page, id, '05-light-mode');
    });
  });
}

test('a downstream brand opens its own support site', async ({ page }) => {
  const brand = { ...loadBrand('wootc'), name: 'Acme Linux', productName: 'Acme Setup', supportURL: 'https://example.com/support' };
  await boot(page, { mode: 'installer', images: catalog.filter(i => i.status === 'green'), sysinfo: SYSINFO, brand });
  await expect(page.locator('.titlebar-name')).toHaveText('Acme Setup');
  await page.getByRole('button', { name: 'Get help', exact: true }).click();
  await expect.poll(() => page.evaluate(() => window.__wootcWindowCalls)).toContainEqual(['BrowserOpenURL', brand.supportURL]);
});
