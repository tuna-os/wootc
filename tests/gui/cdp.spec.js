// cdp.spec.js — Windows conformance: drive the REAL wootc.exe (WebView2)
// over the Chrome DevTools Protocol. Unlike gui.spec.js (mocked backend on
// Linux), this exercises the genuine Go↔JS bindings and WebView2 render,
// closing the gap the mock cannot cover: binding marshalling and the real
// window chrome.
//
// Prereqs (set by the CI job / run-cdp.sh):
//   - wootc.exe launched with
//       WOOTC_UI_PREVIEW=1  (stubs destructive pipeline steps)
//       WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9222
//   - WOOTC_CDP_URL pointing at the (optionally forwarded) debug endpoint.
//
// Run: WOOTC_CDP_URL=http://127.0.0.1:9222 npx playwright test cdp.spec.js

import { test, expect, chromium } from '@playwright/test';

const CDP = process.env.WOOTC_CDP_URL || 'http://127.0.0.1:9222';

let browser, page;

test.beforeAll(async () => {
  browser = await chromium.connectOverCDP(CDP);
  const ctx = browser.contexts()[0];
  page = ctx.pages()[0] || (await ctx.waitForEvent('page'));
  await page.waitForLoadState('domcontentloaded');
});

test.afterAll(async () => { await browser?.close(); });

test('real bindings — launchpad renders from GetImages/GetSystemInfo/GetBranding', async () => {
  // The catalog and branding came across the real Go↔JS bridge.
  await expect(page.locator('.image-card').first()).toBeVisible({ timeout: 15000 });
  await expect(page.locator('.titlebar-name')).not.toBeEmpty();
  // System-info chips prove GetSystemInfo marshalled a real struct.
  await expect(page.locator('.sysinfo')).toBeVisible();
});

test('real bindings — validation + scripted install run', async () => {
  await page.locator('.image-card').first().click();
  await page.locator('input[placeholder="james"]').fill('tester');
  const pw = page.locator('input[type=password]');
  await pw.nth(0).fill('hunter2');
  await pw.nth(1).fill('hunter2');
  await expect(page.locator('#install-btn')).toBeEnabled();
  await page.locator('#install-btn').click();
  // Preview mode scripts progress → done through the real event bridge.
  await expect(page.locator('.done-title')).toContainText('ready', { timeout: 20000 });
});
