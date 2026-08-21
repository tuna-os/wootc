import { CancelInstall } from '../../wailsjs/go/main/App';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { el, btn } from '../lib/ui.js';

// ── Screen 2: Progress ────────────────────────────────────────────────────────

// The canonical ordered step list. The Go backend emits these exact strings on
// install:progress, so main.js's event wiring imports it to mark earlier steps
// complete, and the step list below renders it.
export const INSTALL_STEPS = [
  'Checking your PC',
  'Preparing Windows',
  'Setting things up',
  'Finding your files',
  'Making room for Linux',
  'Downloading Linux',
  'Preparing the startup menu',
  'Getting Linux prepared',
  'Making Linux bootable on your machine',
  'Saving your settings',
  'Collecting your look',
  'Finishing up',
];

export function renderProgressScreen() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');
  screen.id = 'progress-screen';
  screen.appendChild(renderProgressInner());
  wrap.appendChild(screen);

  const footer = el('div', 'footer');
  const cancelBtn = btn('Cancel', 'btn btn-ghost btn-danger', async () => {
    await CancelInstall();
    state.screen = 'launchpad';
    render();
  });
  footer.appendChild(cancelBtn);
  wrap.appendChild(footer);
  return wrap;
}

function renderProgressInner() {
  const frag = document.createDocumentFragment();
  const hdr = el('div');
  hdr.innerHTML = `<div class="screen-title">Installing TunaOS</div>
    <div class="screen-subtitle">${state.selected?.name || ''} ${state.selected?.desktopName || ''} — ${state.selected?.base || ''}</div>`;
  frag.appendChild(hdr);

  const pw = el('div', 'progress-wrap');

  const stepLabel = el('div', 'progress-step');
  stepLabel.textContent = state.progress.step || 'Starting…';

  const msgLabel = el('div', 'progress-msg');
  msgLabel.textContent = state.progress.message || '';

  const track = el('div', 'progress-bar-track');
  const fill = el('div', 'progress-bar-fill');
  fill.style.width = `${state.progress.percent}%`;
  track.appendChild(fill);

  // Step list
  const stepList = el('div', 'progress-steps-list');
  INSTALL_STEPS.forEach(s => {
    const item = el('div', 'step-item');
    const done = state.progress.completedSteps.includes(s);
    const active = state.progress.step === s;
    const hasErr = state.progress.error && active;
    if (done) item.classList.add('done');
    else if (active && !hasErr) item.classList.add('active');
    else if (hasErr) item.classList.add('error');
    item.innerHTML = `<span class="step-dot"></span>${s}`;
    stepList.appendChild(item);
  });

  if (state.progress.error) {
    const errDiv = el('div');
    errDiv.style.cssText = 'color:var(--danger);font-size:12.5px;background:rgba(248,113,113,0.08);border:1px solid rgba(248,113,113,0.25);border-radius:6px;padding:10px 14px;margin-top:8px';
    errDiv.textContent = '✖ ' + state.progress.error;
    pw.appendChild(errDiv);
    // The moment of maximum fear. Everything wootc does before the reboot
    // lives in one folder plus a boot entry — say so, truthfully.
    const errCalm = el('div');
    errCalm.style.cssText = 'font-size:12px;color:var(--text-muted);margin-top:6px';
    errCalm.textContent = 'Your files and Windows are unharmed — nothing outside the wootc folder was changed. You can safely close this and try again.';
    pw.appendChild(errCalm);
  }

  pw.appendChild(stepLabel);
  pw.appendChild(msgLabel);
  pw.appendChild(track);
  pw.appendChild(stepList);

  // Standing reassurance while the user watches the bar: the truthful safety
  // model (SPEC: nothing permanent until Linux is proven working), in one
  // line, visible the whole time.
  const calm = el('div');
  calm.style.cssText = 'display:flex;gap:8px;align-items:flex-start;font-size:12px;color:var(--text-muted);margin-top:12px;background:var(--bg-card);border:1px solid var(--border);border-radius:6px;padding:9px 12px';
  calm.innerHTML = `<span>🛡️</span><span>Your files and Windows stay untouched. Everything here goes into one folder — until Linux is proven working, nothing permanent changes, and you can undo this at any time.</span>`;
  pw.appendChild(calm);
  frag.appendChild(pw);
  return frag;
}

export function renderProgress() {
  const screen = document.getElementById('progress-screen');
  if (!screen) return;
  screen.innerHTML = '';
  screen.appendChild(renderProgressInner());
}
