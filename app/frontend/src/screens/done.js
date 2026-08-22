import { Reboot } from '../../wailsjs/go/main/App';
import { Quit } from '../../wailsjs/runtime/runtime';
import { state } from '../lib/state.js';
import { distroName } from '../lib/branding.js';
import { el, btn } from '../lib/ui.js';

// The celebration mark: a branded build celebrates with its own logo; the
// generic build keeps the confetti (emoji only where it IS the branding).
function doneMark() {
  const b = state.brand || {};
  if (b.logoDataUri) return `<img class="done-icon" src="${b.logoDataUri}" alt="">`;
  return '🎉';
}

// ── Screen 3: Done ────────────────────────────────────────────────────────────

export function renderDoneScreen() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');

  const hero = el('div', 'done-hero');
  hero.innerHTML = `
    <div class="done-icon">${doneMark()}</div>
    <div class="done-title">${distroName()} is ready!</div>
    <div class="done-body">
      ${state.selected?.name || distroName()} ${state.selected?.desktopName || ''} has been configured.<br>
      Click <strong>Reboot Now</strong> to start the setup. The first boot takes 5–15 minutes
      while it downloads and installs ${distroName()}. After that, starting Linux is fast.
    </div>
    <div style="display:flex;gap:8px;align-items:flex-start;font-size:12px;color:var(--text-muted);margin-top:14px;background:var(--bg-card);border:1px solid var(--border);border-radius:6px;padding:9px 12px;text-align:left;max-width:460px">
      <span>🛡️</span><span>This is a one-time setup boot. If anything at all goes wrong,
      your PC simply starts Windows again as normal — Windows stays your default
      until Linux has proven it works. Your files aren't touched either way.</span>
    </div>
    ${state.selected?.mokEnroll ? `
    <div style="display:flex;gap:8px;align-items:flex-start;font-size:12px;color:var(--text-muted);margin-top:8px;background:var(--bg-card);border:1px solid var(--border);border-radius:6px;padding:9px 12px;text-align:left;max-width:460px">
      <span>🔑</span><span><strong>One extra one-time step for ${state.selected?.name || 'this system'}:</strong>
      after setup, a blue "MOK management" screen appears once. That's your PC asking
      permission to trust ${state.selected?.name || 'the'} drivers — choose
      <strong>Enroll MOK</strong> → <strong>Continue</strong> → <strong>Yes</strong>, and type the password
      <strong>${state.selected.mokEnroll}</strong>. Totally normal, and it never appears again.</span>
    </div>` : ''}
  `;
  screen.appendChild(hero);
  wrap.appendChild(screen);

  // "Reboot Now" runs a forced restart on a short timer — open documents in
  // other apps do not get a save prompt. The audit flagged that nothing
  // warned about it; one quiet line above the buttons does.
  const saveNote = el('div');
  saveNote.style.cssText = 'font-size:11.5px;color:var(--text-muted);text-align:center;margin-top:10px';
  saveNote.textContent = 'Save any open work first — the restart closes other apps without asking.';
  screen.appendChild(saveNote);

  const footer = el('div', 'footer');
  footer.appendChild(btn('Reboot Later', 'btn btn-ghost', () => Quit()));
  footer.appendChild(btn('Reboot Now →', 'btn btn-primary', () => Reboot()));
  wrap.appendChild(footer);
  return wrap;
}
