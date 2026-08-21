import { TryInVMFresh, InstallPreviewForReal } from '../../wailsjs/go/main/App';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { el, btn } from '../lib/ui.js';

// ── Try in VM (§6.1) ──────────────────────────────────────────────────────────

export async function tryInVM() {
  if (!state.selected) return;
  state.screen = 'vmpreview';
  state.vmProgress = { stage: 'pulling', percent: 0, message: 'Preparing the builder…' };
  state.vmReady = false;
  state.vmError = null;
  render();
  try {
    await TryInVMFresh(state.selected.imageRef);
  } catch (e) {
    state.vmError = String(e);
    render();
  }
}

async function installPreviewForReal() {
  try {
    await InstallPreviewForReal({
      imageRef:   state.selected.imageRef,
      diskSizeGB: state.config.diskSizeGB,
      username:   state.config.username,
      password:   state.config.password,
      hostname:   state.config.hostname,
      bootloader: state.config.bootloader,
      composeFs:  state.config.composeFs,
      encryption: state.config.encryption,
      luksPassphrase: state.config.luksPassphrase,
      windowsLook: state.config.windowsLook,
      sessionConsent: state.config.sessionConsent,
    });
    state.screen = 'done';
    render();
  } catch (e) {
    alert('Could not finalize the install: ' + e);
  }
}

export function renderVMPreviewScreen() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');
  screen.style.cssText = 'padding:32px;display:flex;flex-direction:column;gap:16px;align-items:center;justify-content:center;text-align:center;flex:1';

  const p = state.vmProgress || { stage: '', percent: 0, message: '' };
  if (state.vmError) {
    screen.innerHTML = `<div style="font-size:40px">😕</div>
      <h2>Couldn't start the preview</h2>
      <div style="color:var(--text-muted);max-width:420px">${state.vmError}</div>`;
    const back = btn('Back', 'btn btn-ghost', () => { state.screen = 'launchpad'; render(); });
    screen.appendChild(back);
  } else if (state.vmReady) {
    screen.innerHTML = `<div style="font-size:40px">🖥️</div>
      <h2>Your preview is running</h2>
      <div style="color:var(--text-muted);max-width:440px">${state.selected?.name || 'TunaOS'} is booting in its own window — try it out. If you like it, install it for real using the same disk (no re-download, no re-deploy).</div>`;
    const row = el('div'); row.style.cssText = 'display:flex;gap:10px;margin-top:8px';
    row.appendChild(btn('Not now', 'btn btn-ghost', () => { state.screen = 'launchpad'; render(); }));
    row.appendChild(btn('Install for Real →', 'btn btn-primary', () => installPreviewForReal()));
    screen.appendChild(row);
  } else {
    const pct = Math.round(p.percent || 0);
    screen.innerHTML = `<div style="font-size:40px">🔨</div>
      <h2>Building your preview…</h2>
      <div style="color:var(--text-muted);max-width:440px">${p.message || 'Working…'}</div>
      <div style="width:60%;max-width:360px;height:8px;background:var(--border);border-radius:4px;overflow:hidden;margin-top:8px">
        <div style="width:${pct}%;height:100%;background:var(--primary);transition:width .3s"></div>
      </div>
      <div style="font-size:12px;color:var(--text-muted)">${pct}%</div>`;
  }
  wrap.appendChild(screen);
  return wrap;
}
