import { Quit, WindowMinimise } from '../../wailsjs/runtime/runtime';
import { state } from './state.js';
import { el } from './ui.js';

// ── Title bar ─────────────────────────────────────────────────────────────────

export function renderTitleBar() {
  const b = state.brand || { logoEmoji: '🐠', name: 'wootc', version: '0.1.0' };
  const bar = el('div', 'titlebar');
  bar.innerHTML = `
    <span class="titlebar-logo">${b.logoEmoji || '🐠'}</span>
    <span class="titlebar-name">${b.name || 'wootc'}</span>
    <span class="titlebar-version">${b.version || ''}</span>
    <span class="titlebar-step">${stepLabel()}</span>
    <div class="titlebar-controls">
      <button class="titlebar-btn" id="win-min" title="Minimise" aria-label="Minimise">
        <svg width="10" height="10" viewBox="0 0 10 10"><rect x="0" y="4.5" width="10" height="1" fill="currentColor"/></svg>
      </button>
      <button class="titlebar-btn titlebar-btn-close" id="win-close" title="Close" aria-label="Close">
        <svg width="10" height="10" viewBox="0 0 10 10"><path d="M0 0 L10 10 M10 0 L0 10" stroke="currentColor" stroke-width="1.2"/></svg>
      </button>
    </div>
  `;
  // The window is frameless (#175), so these are the ONLY way to minimise or
  // close it — wire them before returning, not lazily on some later render.
  bar.querySelector('#win-min').onclick = () => WindowMinimise();
  bar.querySelector('#win-close').onclick = () => {
    // A running install is mid-way through repartitioning; quitting silently
    // would leave the machine half-converted with no explanation.
    if (state.screen === 'progress' && !state.progress.error) {
      const ok = confirm(
        'Installation is still running.\n\n' +
        'Closing now leaves the PC part-way through the migration. ' +
        'Your Windows and files are safe, but the install will not finish.\n\n' +
        'Close anyway?');
      if (!ok) return;
    }
    Quit();
  };
  return bar;
}

function stepLabel() {
  const labels = {
    launchpad: 'Step 1 of 3 — Configure',
    progress:  'Step 2 of 3 — Installing',
    done:      'Step 3 of 3 — Done',
    control:   'Manage Installation',
    migrate:   'Your Windows Data',
  };
  return labels[state.screen] || '';
}
