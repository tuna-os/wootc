import { defineConfig } from '@playwright/test';
import path from 'path';
import { fileURLToPath } from 'url';

const dir = path.dirname(fileURLToPath(import.meta.url));

// Serve the built frontend bundle statically; scenarios inject the mock
// Wails backend before the app script runs (see gui.spec.js).
export default defineConfig({
  testDir: dir,
  outputDir: path.join(dir, '.results'),
  timeout: 30000,
  fullyParallel: false,
  reporter: [['list']],
  // cdp.spec.js drives a real wootc.exe over CDP (Windows E2E only); it runs
  // only when WOOTC_CDP_URL is set. The mock suite runs everywhere.
  testIgnore: process.env.WOOTC_CDP_URL ? [] : ['cdp.spec.js'],
  use: {
    // wootc's window is a fixed 820×620; match it so screenshots are honest.
    viewport: { width: 820, height: 620 },
    baseURL: 'http://127.0.0.1:5599',
  },
  webServer: {
    command: `npx --yes http-server "${path.join(dir, '../../app/frontend/dist')}" -p 5599 -s -c-1`,
    url: 'http://127.0.0.1:5599',
    reuseExistingServer: true,
    timeout: 30000,
  },
});
