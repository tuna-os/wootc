import { CancelInstall } from '../../wailsjs/go/main/App';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { distroName, productName } from '../lib/branding.js';
import { el, btn } from '../lib/ui.js';

// ── Screen 2: Progress ────────────────────────────────────────────────────────

// The canonical ordered step list. The Go backend emits these exact strings on
// install:progress, so main.js's event wiring imports it to mark earlier steps
// complete, and the step list below renders it.
// The step list the user watches. It must be EXACTLY the pipeline's step
// names from app.go, in order: a step whose name does not match never lights
// up, and stays grey for the whole install — which reads as a step that did
// not happen. payload/steps.tsv is the catalogue and app/steps_test.go fails
// when these drift (#334).
export const INSTALL_STEPS = [
  'Checking your PC',
  'Preparing Windows',
  'Setting things up',
  'Finding your files',
  'Making room for Linux',
  'Downloading Linux',
  'Downloading your Linux system',
  'Preparing the startup menu',
  'Getting Linux prepared',
  'Making Linux bootable on your machine',
  'Saving your settings',
  'Saving your BitLocker recovery key',
  'Looking at your installed apps',
  'Checking your signed-in apps',
  'Looking for your cloud drives',
  'Collecting your look and Wi-Fi',
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
  hdr.innerHTML = `<div class="screen-title">Installing ${distroName()}</div>
    <div class="screen-subtitle">${state.selected?.name || ''} ${state.selected?.desktopName || ''} — ${state.selected?.base || ''}</div>`;
  frag.appendChild(hdr);

  const pw = el('div', 'progress-wrap');

  const stepLabel = el('div', 'progress-step');
  stepLabel.textContent = state.progress.step || 'Starting…';

  const msgLabel = el('div', 'progress-msg');
  msgLabel.textContent = state.progress.message || '';

  // Disclosure, not surprise: the BitLocker key step stores a copy on disk,
  // and the audit found that never said anywhere on screen.
  const bitlockerNote = /BitLocker/i.test(state.progress.step || '')
    ? `A copy of your recovery key is stored at C:\\wootc\\install so Linux can reach your files. Uninstalling ${productName()} removes it.`
    : '';

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

  // From "Making Linux bootable on your machine" onward, "nothing changed"
  // stops being true: a one-time startup entry exists. The audit caught the
  // old copy lying at exactly the moment of maximum fear — a failure at 85%
  // read "nothing outside the wootc folder was changed" while the machine
  // was armed. Say what is actually true at each point. (On failure or
  // cancel past that step, the backend removes the entry again.)
  const bcdStep = 'Making Linux bootable on your machine';
  const pastArm = state.progress.completedSteps.includes(bcdStep) ||
    (state.progress.step === bcdStep && !state.progress.error);

  if (state.progress.error) {
    const errDiv = el('div');
    errDiv.style.cssText = 'color:var(--danger);font-size:12.5px;background:rgba(248,113,113,0.08);border:1px solid rgba(248,113,113,0.25);border-radius:6px;padding:10px 14px;margin-top:8px';
    errDiv.textContent = '✖ ' + state.progress.error;
    pw.appendChild(errDiv);
    // The moment of maximum fear. Everything wootc does before the reboot
    // lives in one folder plus a boot entry — say so, truthfully.
    const errCalm = el('div');
    errCalm.style.cssText = 'font-size:12px;color:var(--text-muted);margin-top:6px';
    errCalm.textContent = pastArm
      ? 'Your files and Windows are unharmed — everything lives in the wootc folder, and the one-time startup entry has been removed again. You can safely close this and try again.'
      : 'Your files and Windows are unharmed — nothing outside the wootc folder was changed. You can safely close this and try again.';
    pw.appendChild(errCalm);
  }

  pw.appendChild(stepLabel);
  pw.appendChild(msgLabel);
  if (bitlockerNote) {
    const bn = el('div');
    bn.style.cssText = 'font-size:11.5px;color:var(--text-muted);margin-top:4px';
    bn.textContent = bitlockerNote;
    pw.appendChild(bn);
  }
  pw.appendChild(track);
  pw.appendChild(stepList);

  // Standing reassurance while the user watches the bar: the truthful safety
  // model (SPEC: nothing permanent until Linux is proven working), in one
  // line, visible the whole time — and updated the moment it would
  // otherwise become a lie.
  const calm = el('div');
  calm.style.cssText = 'display:flex;gap:8px;align-items:flex-start;font-size:12px;color:var(--text-muted);margin-top:12px;background:var(--bg-card);border:1px solid var(--border);border-radius:6px;padding:9px 12px';
  calm.innerHTML = pastArm
    ? `<span>🛡️</span><span>Your files and Windows stay untouched. ${productName()} has added a one-time startup entry for the setup boot — everything else lives in one folder, Windows stays your default, and you can undo this at any time.</span>`
    : `<span>🛡️</span><span>Your files and Windows stay untouched. Everything here goes into one folder — until Linux is proven working, nothing permanent changes, and you can undo this at any time.</span>`;
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
