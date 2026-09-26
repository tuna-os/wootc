import { TryInVMFresh } from '../../wailsjs/go/main/App';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { distroName } from '../lib/branding.js';
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
      <h2>Your VM window has opened</h2>
      <div style="color:var(--text-muted);max-width:440px">${state.selected?.name || distroName()} has started in its own window. Check that Linux reaches its desktop. Native boot is not available from this preview yet; keep the disk to preserve your work.</div>`;
    const row = el('div'); row.style.cssText = 'display:flex;gap:10px;margin-top:8px';
    row.appendChild(btn('Not now', 'btn btn-ghost', () => { state.screen = 'launchpad'; render(); }));
    screen.appendChild(row);
  } else {
    const pct = Math.round(p.percent || 0);
    screen.innerHTML = `<div style="font-size:40px">🔨</div>
      <h2>Building your preview…</h2>
      <div style="color:var(--text-muted);max-width:440px">${p.message || 'Working…'}</div>
      <div style="width:60%;max-width:360px;height:8px;background:var(--border);border-radius:4px;overflow:hidden;margin-top:8px">
        <div style="width:${pct}%;height:100%;background:var(--accent);transition:width .3s"></div>
      </div>
      <div style="font-size:12px;color:var(--text-muted)">${pct}%</div>`;
  }
  wrap.appendChild(screen);
  return wrap;
}
