import '../src/style.css';
import { GetImages, GetSystemInfo, ExistingInstallFound, GetMode, GetSessionCandidates, GetBranding, GetUninstallInfo, GetVMCapability, GetFreshVMCapability, GetSupportPolicy, GetLastRun, GetRecoveryVerdict } from '../wailsjs/go/main/App';
import { EventsOn } from '../wailsjs/runtime/runtime';
import { startE2EDrive } from './lib/e2e.js';
import { state } from './lib/state.js';
import { setRenderer } from './lib/render.js';
import { applyBranding } from './lib/branding.js';
import { renderTitleBar } from './lib/titlebar.js';
import { renderLaunchpad, applyImageDefaults } from './screens/launchpad.js';
import { INSTALL_STEPS, renderProgressScreen, renderProgress } from './screens/progress.js';
import { renderVMPreviewScreen } from './screens/vmpreview.js';
import { renderDoneScreen } from './screens/done.js';
import { renderControlPanel } from './screens/control.js';
import { renderMigrateScreen, renderMigrateRows, refreshCategories } from './screens/migrate.js';
import { renderRecoveryScreen } from './screens/recovery.js';

// ── Init ──────────────────────────────────────────────────────────────────────

async function init() {
  try { applyBranding(await GetBranding()); } catch { applyBranding({ name: 'TunaOS', productName: 'wootc', tagline: '', logoEmoji: '🐠', version: '0.1.0', installVerb: 'Install' }); }
  // Listen for progress events from Go backend
  EventsOn('install:progress', (e) => {
    state.progress.step = e.step;
    state.progress.message = e.message;
    state.progress.percent = e.percent;
    if (e.error) state.progress.error = e.error;
    if (e.done) { state.screen = 'done'; render(); return; }
    if (e.step && !state.progress.completedSteps.includes(e.step)) {
      // Mark previous step as done when a new one starts
      const idx = INSTALL_STEPS.indexOf(e.step);
      if (idx > 0) {
        for (let i = 0; i < idx; i++) {
          if (!state.progress.completedSteps.includes(INSTALL_STEPS[i]))
            state.progress.completedSteps.push(INSTALL_STEPS[i]);
        }
      }
    }
    if (state.screen === 'progress') renderProgress();
  });

  // Try-in-VM builder progress (§6.1). Drives the preview screen while the
  // headless builder pulls the image and installs it onto preview.raw.
  EventsOn('vm:progress', (e) => {
    state.vmProgress = { stage: e.stage, percent: e.percent || 0, message: e.message || '' };
    if (e.stage === 'ready') state.vmReady = true;
    if (e.stage === 'error') state.vmError = e.message;
    if (state.screen === 'vmpreview') render();
  });

  // Conversion progress events from the migration dashboard backend.
  EventsOn('migrate:progress', (p) => {
    if (p.error) {
      delete state.converting[p.category];
      alert(`Something went wrong moving ${p.category}: ${p.error}\nYour files are safe — nothing was deleted.`);
      refreshCategories();
      return;
    }
    state.converting[p.category] = p.percent;
    if (p.done) {
      delete state.converting[p.category];
      refreshCategories();
      return;
    }
    if (state.screen === 'migrate') renderMigrateRows();
  });

  state.mode = await GetMode().catch(() => 'installer');

  if (state.mode === 'migration') {
    await refreshCategories();
    state.screen = 'migrate';
    render();
    return;
  }

  const [images, sysinfo, existing, policy, sessionCandidates, lastRun, recoveryVerdict] = await Promise.all([
    GetImages(),
    GetSystemInfo(),
    ExistingInstallFound(),
    GetSupportPolicy().catch(() => ({ channel: 'alpha', experimentalImages: false, bitlockerSupported: false, customImageAllowed: false })),
    // A missing binding throws synchronously, which would escape a plain
    // .catch() on the call and blank the whole launchpad; session candidates
    // are optional, so absorb that too.
    Promise.resolve().then(GetSessionCandidates).catch(() => []),
    // Honesty on relaunch: a failed attempt must greet the user as a failed
    // attempt, not as "an existing installation was found".
    Promise.resolve().then(GetLastRun).catch(() => null),
    // Recovery guard verdict (§2)
    Promise.resolve().then(GetRecoveryVerdict).catch(() => null),
  ]);
  state.lastRun = lastRun && lastRun.state ? lastRun : null;
  state.recoveryVerdict = recoveryVerdict && recoveryVerdict.verdict && recoveryVerdict.verdict !== 'none' && recoveryVerdict.verdict !== 'healthy' && recoveryVerdict.verdict !== 'deployed' ? recoveryVerdict : null;

  state.policy = policy;
  state.images = images || [];
  state.sysinfo = sysinfo;
  state.sessionCandidates = sessionCandidates || [];
  // A brand can name its pre-selected card; otherwise the first offered
  // image is the default, as before.
  state.selected = (state.brand?.defaultImage
    && state.images.find(i => i.id === state.brand.defaultImage))
    || state.images[0] || null;
  applyImageDefaults(state.selected);

  // Default the Linux identity from this Windows machine so the launchpad
  // only has to ask for a password (#174). Both are sanitised Go-side and
  // come back "" when nothing usable survives, in which case the field stays
  // empty for the user rather than showing a wrong guess.
  // (This replaced a hardcoded 'james' placeholder that shipped as the
  // username default for every user.)
  if (sysinfo.suggestedUsername) state.config.username = sysinfo.suggestedUsername;

  if (sysinfo.suggestedHostname) state.config.hostname = sysinfo.suggestedHostname;

  // Default the disk to half of C:'s free space, 40–200 GB in 5 GB steps —
  // a size the user never has to think about. root.disk is sparse (space is
  // consumed only as Linux fills it), so generosity costs nothing up front;
  // the launchpad still clamps to what C: can actually hold, and the slider
  // lives under Advanced for anyone who wants a different number.
  if (sysinfo.freeDiskGB > 0) {
    const half = Math.floor(sysinfo.freeDiskGB / 2 / 5) * 5;
    state.config.diskSizeGB = Math.min(200, Math.max(40, half));
  }

  if (existing) {
    try { state.uninstallInfo = await GetUninstallInfo(); } catch { state.uninstallInfo = {}; }
    try { state.vmCapability = await GetVMCapability(); } catch { state.vmCapability = null; }
  }
  try { state.freshVmCapability = await GetFreshVMCapability(); } catch { state.freshVmCapability = null; }
  
  if (state.recoveryVerdict) {
    state.screen = 'recovery';
  } else {
    state.screen = existing ? 'control' : 'launchpad';
  }
  render();
}

// ── Router ────────────────────────────────────────────────────────────────────

function render() {
  const app = document.getElementById('app');
  app.innerHTML = '';
  app.appendChild(renderTitleBar());

  const content = document.createElement('div');
  content.id = 'screen-content';
  content.style.flex = '1';
  content.style.display = 'flex';
  content.style.flexDirection = 'column';
  content.style.overflow = 'hidden';

  switch (state.screen) {
    case 'launchpad': content.appendChild(renderLaunchpad()); break;
    case 'progress':  content.appendChild(renderProgressScreen()); break;
    case 'done':      content.appendChild(renderDoneScreen()); break;
    case 'control':   content.appendChild(renderControlPanel()); break;
    case 'migrate':   content.appendChild(renderMigrateScreen()); break;
    case 'vmpreview': content.appendChild(renderVMPreviewScreen()); break;
    case 'recovery':  content.appendChild(renderRecoveryScreen()); break;
    default:          content.innerHTML = '<div style="padding:40px;color:#666">Loading…</div>';
  }

  app.appendChild(content);
}

// ── Boot ──────────────────────────────────────────────────────────────────────

// Screens repaint through lib/render.js rather than importing this module back;
// hand it the router before anything can ask for one.
setRenderer(render);

init().catch(console.error);
startE2EDrive(state);
