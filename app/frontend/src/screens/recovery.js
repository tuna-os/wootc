import { TryAgain, RepairBoot, Uninstall, GetRecoveryVerdict } from '../../wailsjs/go/main/App';
import { Quit } from '../../wailsjs/runtime/runtime';
import { state } from '../lib/state.js';
import { distroName } from '../lib/branding.js';
import { el, btn, warningBanner } from '../lib/ui.js';

// ── Screen: Recovery Guard Prompt (§2, Borrowed from Libertix) ───────────────

export function renderRecoveryScreen() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');

  const v = state.recoveryVerdict || {};
  const titleText = v.title || `Could not finish setting up ${distroName()} this time`;
  const msgText = v.message || 'Windows restarted before the installation could complete.';

  screen.innerHTML = `
    <div class="screen-title" style="color:var(--text)">${titleText}</div>
    <div class="screen-subtitle">${msgText}</div>
  `;

  // Calm reassurance banner: "Your Windows and all of your files are safe and untouched."
  const safeBanner = el('div');
  safeBanner.style.cssText = 'background:rgba(16, 185, 129, 0.12);border:1px solid rgba(16, 185, 129, 0.35);border-radius:8px;padding:12px 16px;display:flex;gap:12px;align-items:flex-start;margin-top:12px';
  safeBanner.innerHTML = `
    <span style="font-size:20px;line-height:1">🛡️</span>
    <div style="font-size:13px;line-height:1.4;color:var(--text)">
      <strong>Your Windows and all of your files are safe and untouched.</strong><br>
      <span style="color:var(--text-muted);font-size:12px">Windows remains your default system. No personal files or existing operating systems were changed.</span>
    </div>
  `;
  screen.appendChild(safeBanner);

  // Diagnostic detail card
  const card = el('div');
  card.style.cssText = 'background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:16px;display:flex;flex-direction:column;gap:10px;margin-top:12px';
  
  let detailsHtml = '';
  if (v.details) {
    detailsHtml += `<div style="font-size:12.5px;color:var(--text)">${v.details}</div>`;
  }
  if (v.phase) {
    detailsHtml += `<div style="font-size:11.5px;color:var(--text-muted)">Stage: <code>${v.phase}</code></div>`;
  }
  if (v.logTail && v.logTail.length > 0) {
    const logSnippet = v.logTail.slice(-10).join('\n');
    detailsHtml += `
      <details style="font-size:11.5px;color:var(--text-muted);margin-top:6px;cursor:pointer">
        <summary style="font-weight:600">View recent log details</summary>
        <pre style="background:var(--bg);padding:8px;border-radius:4px;overflow-x:auto;max-height:120px;font-size:10.5px;margin-top:6px">${logSnippet}</pre>
      </details>
    `;
  }
  card.innerHTML = detailsHtml || `<div style="font-size:12.5px;color:var(--text-muted)">Choose an option below to proceed.</div>`;
  screen.appendChild(card);

  wrap.appendChild(screen);

  // Action buttons
  const footer = el('div', 'footer');
  footer.style.cssText = 'display:flex;gap:10px;justify-content:flex-end;padding:16px 24px;border-top:1px solid var(--border);background:var(--bg-card)';

  // 1. Remove button
  footer.appendChild(btn(`Remove ${distroName()}`, 'btn btn-danger', async () => {
    if (!confirm(`Remove ${distroName()} files and restore the boot configuration?`)) return;
    try {
      await Uninstall();
      alert(`${distroName()} has been removed. Windows is unchanged.`);
      Quit();
    } catch (e) {
      alert('Removal encountered an error: ' + e);
    }
  }));

  // 2. Repair boot button
  footer.appendChild(btn('Repair boot', 'btn btn-ghost', async () => {
    try {
      await RepairBoot();
      alert('Boot configuration repaired. Your computer will restart to try again.');
    } catch (e) {
      alert('Repair boot hit a problem: ' + e);
    }
  }));

  // 3. Try again button (primary)
  footer.appendChild(btn('Try again →', 'btn btn-primary', async () => {
    try {
      await TryAgain();
    } catch (e) {
      alert('Try again hit a problem: ' + e);
    }
  }));

  wrap.appendChild(footer);
  return wrap;
}
