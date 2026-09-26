import { PrepareVM, StopVM, ForceStopVM, BootInVM, GetUninstallInfo, GetVMState, GetVMCapability } from '../../wailsjs/go/main/App';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { distroName } from '../lib/branding.js';
import { el, btn } from '../lib/ui.js';

// ── Try in VM (§6.1) ──────────────────────────────────────────────────────────

export async function tryInVM() {
  if (!state.selected) return;
  if (!state.config.password || state.config.password !== state.config.passwordConfirm) { alert('Set and confirm your Linux password first.'); return; }
  state.screen = 'vmpreview';
  state.vmProgress = { stage: 'pulling', percent: 0, message: 'Preparing the builder…' };
  state.vmReady = false;
  state.vmError = null;
  render();
  try {
    await PrepareVM({ imageRef: state.selected.imageRef, username: state.config.username, password: state.config.password });
    state.config.password = ''; state.config.passwordConfirm = '';
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
      <h2>Linux is starting</h2>
      <div style="color:var(--text-muted);max-width:440px">${state.selected?.name || distroName()} is starting in its own window. Sign in with your Linux username and password when the login screen appears. Your work stays on this disk. To close Linux safely, use Shut down Linux below. Native boot is not available yet.</div>`;
    const row = el('div'); row.style.cssText = 'display:flex;gap:10px;margin-top:8px';
    row.appendChild(btn('Shut down Linux', 'btn btn-primary', async () => {
      try { await StopVM(); state.vmState = { phase: 'stopped' }; state.vmReady = false; render(); }
      catch (e) { alert(String(e)); }
    }));
    row.appendChild(btn('Force stop…', 'btn btn-danger', async () => {
      if (!confirm('Force stop Linux? Unsaved work may be lost. The disk will require recovery before restarting.')) return;
      try { await ForceStopVM(); } catch (e) { alert(String(e)); }
    }));
    row.appendChild(btn('Manage Linux', 'btn btn-ghost', async () => {
      state.uninstallInfo = await GetUninstallInfo(); state.vmState = await GetVMState(); state.vmCapability = await GetVMCapability();
      state.screen = 'control'; render();
    }));
    screen.appendChild(row);
  } else if (state.vmState?.phase === 'stopped') {
    const title = el('h2'); title.textContent = 'Linux is shut down. Your work is saved on the same disk.'; screen.appendChild(title);
    screen.appendChild(btn('Start Linux again', 'btn btn-primary', async () => {
      try { await BootInVM(); state.vmReady = true; render(); } catch (e) { alert(String(e)); }
    }));
  } else {
    const pct = Math.round(p.percent || 0);
    screen.innerHTML = `<div style="font-size:40px">🔨</div>
      <h2>Preparing your Linux system…</h2>
      <div style="color:var(--text-muted);max-width:440px">${p.message || 'Working…'}</div>
      <div style="width:60%;max-width:360px;height:8px;background:var(--border);border-radius:4px;overflow:hidden;margin-top:8px">
        <div style="width:Preparation is in progress.;height:100%;background:var(--accent);transition:width .3s"></div>
      </div>
      <div style="font-size:12px;color:var(--text-muted)">Preparation is in progress.</div>`;
  }
  wrap.appendChild(screen);
  return wrap;
}
