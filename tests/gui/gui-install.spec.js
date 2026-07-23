// gui-install.spec.js — the GUI-DRIVEN full run's Phase-1 leg: drive the
// REAL wootc.exe over CDP through a REAL install (no WOOTC_UI_PREVIEW).
// Selects the case's image via the custom-OCI field, fills the account
// form, clicks Install, waits for the live pipeline to reach the done
// screen, and finally clicks "Reboot Now →" — which boots the deployer.
// Everything after that reboot is verified by run-e2e.sh's normal flow.
//
// Env:
//   WOOTC_CDP_URL       CDP endpoint (forwarded guest 9222)
//   WOOTC_GUI_IMAGE     ghcr.io/... image ref to install
//   WOOTC_GUI_USERNAME  Linux account to create (default wootc)
//   WOOTC_GUI_PASSWORD  its password            (default wootc-e2e-pass)
//   WOOTC_GUI_HOSTNAME  hostname                (default wootc-test)

import { test, expect, chromium } from '@playwright/test';

const CDP = process.env.WOOTC_CDP_URL || 'http://127.0.0.1:9222';
const IMAGE = process.env.WOOTC_GUI_IMAGE || 'ghcr.io/tuna-os/yellowfin:gnome';
const USERNAME = process.env.WOOTC_GUI_USERNAME || 'wootc';
const PASSWORD = process.env.WOOTC_GUI_PASSWORD || 'wootc-e2e-pass';
const HOSTNAME = process.env.WOOTC_GUI_HOSTNAME || 'wootc-test';

// A real Phase-1 pipeline creates root.vhdx and stages the ESP — minutes,
// not seconds. Budget generously; run-e2e.sh bounds the whole leg anyway.
test.setTimeout(30 * 60 * 1000);

let browser, page;

test.beforeAll(async () => {
  browser = await chromium.connectOverCDP(CDP);
  const ctx = browser.contexts()[0];
  page = ctx.pages()[0] || (await ctx.waitForEvent('page'));
  await page.waitForLoadState('domcontentloaded');
});

test.afterAll(async () => { await browser?.close(); });

test('GUI-driven install: form → real pipeline → done → reboot', async () => {
  // Launchpad up with the real catalog over the Go bridge.
  await expect(page.locator('.image-card').first()).toBeVisible({ timeout: 20000 });

  // Pick the case's exact image via the custom-OCI field (works for every
  // supported family, not only the curated cards).
  await page.locator('.field:has-text("Custom supported OCI image") input').fill(IMAGE);

  await page.locator('.field:has-text("Linux Username") input').fill(USERNAME);
  await page.locator('.field:has-text("Hostname") input').fill(HOSTNAME);
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill(PASSWORD);
  await pw.nth(1).fill(PASSWORD);

  const install = page.locator('#install-btn');
  await expect(install).toBeEnabled();
  await install.click();

  // The REAL pipeline runs now (download no-ops on pre-staged artifacts,
  // root.vhdx creation, ESP staging, BCD arm). Fail fast on a surfaced
  // pipeline error instead of waiting out the full budget.
  const done = page.locator('.done-title');
  const errBox = page.locator('.progress-error, .error');
  await Promise.race([
    done.waitFor({ state: 'visible', timeout: 25 * 60 * 1000 }),
    errBox.waitFor({ state: 'visible', timeout: 25 * 60 * 1000 })
      .then(async () => {
        throw new Error(`install pipeline surfaced an error: ${await errBox.first().innerText()}`);
      }),
  ]);
  await expect(done).toContainText('ready');

  // The machine is armed. Hand control to the deployer exactly the way a
  // user would. The click severs CDP (Windows goes down) — that is success.
  await page.locator('button:has-text("Reboot Now")').click().catch(() => {});
});
