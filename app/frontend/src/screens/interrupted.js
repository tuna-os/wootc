import { PrepareResume, TryAgain, RepairBoot, Uninstall } from '../../wailsjs/go/main/App';
import { Quit } from '../../wailsjs/runtime/runtime';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { distroName } from '../lib/branding.js';
import { fmtSize } from '../lib/format.js';
import { el, btn } from '../lib/ui.js';
import { installStepLabel } from './progress.js';
import { applyImageDefaults } from './launchpad.js';

// ── Screen: interrupted install (#287) ───────────────────────────────────────
// Shown on relaunch when GetInstallRecovery classifies the last attempt as
// resumable, failed, or needing repair. It names how the attempt ended and the
// last step that finished, lists the evidence, and offers only the actions the
// backend allowed. Every string from the backend goes through textContent.

export const INTERRUPTED_CLASSES = ['resumable', 'failed', 'needs-repair'];

function textDiv(text, css) {
  const d = el('div');
  d.textContent = text;
  if (css) d.style.cssText = css;
  return d;
}

function causeLine(r) {
  switch (r.cause) {
    case 'cancelled': return 'How it ended: you cancelled it.';
    case 'interrupted': return 'How it ended: wootc closed or the computer lost power.';
    case 'step-failed': return 'How it ended: a step failed.';
    case 'never-booted': return 'How it ended: the computer did not start the installer.';
    case 'deployer-interrupted': return 'How it ended: the installer stopped before it finished.';
    case 'deployer-failed': return 'How it ended: the installer reported an error.';
    default: return 'How it ended: unknown.';
  }
}

export function renderInterruptedScreen() {
  const r = state.installRecovery || {};
  const a = r.actions || {};
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');
  screen.id = 'interrupted-screen';

  screen.appendChild(Object.assign(textDiv(r.title || `${distroName()} setup did not finish`), { className: 'screen-title' }));
  screen.appendChild(Object.assign(textDiv(r.message || ''), { className: 'screen-subtitle' }));

  const card = el('div');
  card.style.cssText = 'background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:16px;display:flex;flex-direction:column;gap:8px;margin-top:12px;font-size:12.5px';
  card.appendChild(textDiv(causeLine(r)));
  card.appendChild(textDiv(`Last finished step: ${r.lastCompletedStep ? installStepLabel(r.lastCompletedStep) : 'none'}`));
  if (r.stoppedAtStep) card.appendChild(textDiv(`Stopped during: ${installStepLabel(r.stoppedAtStep)}`));
  if (r.error) card.appendChild(textDiv(`Error: ${r.error}`, 'color:var(--text-muted)'));
  if (a.resumeInstall && r.keepsVerifiedBlobs > 0) {
    card.appendChild(textDiv(`Kept: ${fmtSize(r.keepsVerifiedBytes || 0)} of checked download. Setup continues from there.`));
  }
  if (a.resumeInstall && r.discardsRootDisk) {
    card.appendChild(textDiv('The empty Linux disk file from the stopped attempt is deleted first. It holds no data.', 'color:var(--text-muted)'));
  }
  if (Array.isArray(r.evidence) && r.evidence.length) {
    const det = el('details');
    det.style.cssText = 'color:var(--text-muted);font-size:11.5px';
    const sum = el('summary');
    sum.textContent = 'What wootc found';
    det.appendChild(sum);
    const ul = el('ul');
    ul.className = 'interrupted-evidence';
    r.evidence.forEach(line => { const li = el('li'); li.textContent = line; ul.appendChild(li); });
    det.appendChild(ul);
    card.appendChild(det);
  }
  screen.appendChild(card);
  wrap.appendChild(screen);

  const footer = el('div', 'footer');
  footer.style.cssText = 'display:flex;gap:10px;justify-content:flex-end;padding:16px 24px;border-top:1px solid var(--border);background:var(--bg-card)';
  const primary = (key) => r.recommended === key ? 'btn btn-primary' : 'btn btn-ghost';

  if (a.remove) {
    footer.appendChild(btn(`Remove ${distroName()}`, r.recommended === 'remove' ? 'btn btn-danger' : 'btn btn-ghost', async () => {
      if (!confirm(`Remove the unfinished ${distroName()} installation and restore the startup settings?`)) return;
      try {
        await Uninstall();
        alert(`The unfinished installation was removed. Windows is unchanged.`);
        Quit();
      } catch (e) {
        alert('Removal hit a problem: ' + e);
      }
    }));
  }
  if (a.repairBoot) {
    footer.appendChild(btn('Repair boot', primary('repair-boot'), async () => {
      try {
        await RepairBoot();
      } catch (e) {
        alert('Repair boot hit a problem: ' + e);
      }
    }));
  }
  if (a.retryDeploy) {
    footer.appendChild(btn('Try again →', primary('retry-deploy'), async () => {
      try {
        await TryAgain();
      } catch (e) {
        alert('Try again hit a problem: ' + e);
      }
    }));
  }
  if (a.resumeInstall) {
    footer.appendChild(btn('Continue setup →', primary('resume'), async () => {
      try {
        await PrepareResume();
      } catch (e) {
        alert('Continue hit a problem: ' + e);
        return;
      }
      // Passwords are never recorded, so the launchpad asks for them again.
      const img = (state.images || []).find(i => i.imageRef === r.imageRef);
      if (img) { state.selected = img; applyImageDefaults(img); }
      state.installRecovery = null;
      state.lastRun = null;
      state.screen = 'launchpad';
      render();
    }));
  }
  wrap.appendChild(footer);
  return wrap;
}
