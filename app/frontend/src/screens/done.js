import { Reboot } from '../../wailsjs/go/main/App';
import { Quit } from '../../wailsjs/runtime/runtime';
import { state } from '../lib/state.js';
import { el, btn } from '../lib/ui.js';

// ── Screen 3: Done ────────────────────────────────────────────────────────────

export function renderDoneScreen() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');

  const hero = el('div', 'done-hero');
  hero.innerHTML = `
    <div class="done-icon">🎉</div>
    <div class="done-title">TunaOS is ready!</div>
    <div class="done-body">
      ${state.selected?.name || 'TunaOS'} ${state.selected?.desktopName || ''} has been configured.<br>
      Click <strong>Reboot Now</strong> to start the setup. The first boot takes 5–15 minutes
      while it downloads and installs TunaOS. After that, starting Linux is fast.
    </div>
    <div style="display:flex;gap:8px;align-items:flex-start;font-size:12px;color:var(--text-muted);margin-top:14px;background:var(--bg-card);border:1px solid var(--border);border-radius:6px;padding:9px 12px;text-align:left;max-width:460px">
      <span>🛡️</span><span>This is a one-time setup boot. If anything at all goes wrong,
      your PC simply starts Windows again as normal — Windows stays your default
      until Linux has proven it works. Your files aren't touched either way.</span>
    </div>
  `;
  screen.appendChild(hero);
  wrap.appendChild(screen);

  const footer = el('div', 'footer');
  footer.appendChild(btn('Reboot Later', 'btn btn-ghost', () => Quit()));
  footer.appendChild(btn('Reboot Now →', 'btn btn-primary', () => Reboot()));
  wrap.appendChild(footer);
  return wrap;
}
