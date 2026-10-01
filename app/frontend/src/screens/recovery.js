import { TryAgain, RepairBoot, Uninstall, GetRecoveryVerdict, InspectBoot, RestoreWindowsBoot } from '../../wailsjs/go/main/App';
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

  // Boot check (#290): what the boot configuration looks like right now,
  // observed, not inferred from the verdict. Actions that write to the boot
  // configuration stay disabled until this report says they are safe.
  const bootCard = el('div');
  bootCard.style.cssText = 'background:var(--bg-card);border:1px solid var(--border);border-radius:var(--radius);padding:16px;display:flex;flex-direction:column;gap:6px;margin-top:12px;font-size:12.5px';
  const bootTitle = el('div');
  bootTitle.style.cssText = 'font-weight:600;color:var(--text)';
  bootTitle.textContent = 'Checking the boot configuration…';
  bootCard.appendChild(bootTitle);
  const bootBody = el('div');
  bootBody.style.cssText = 'display:flex;flex-direction:column;gap:4px;color:var(--text-muted)';
  bootCard.appendChild(bootBody);
  screen.appendChild(bootCard);

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

  // 2. Keep Windows only: take wootc out of the boot order, keep the files.
  const restoreBtn = btn('Keep Windows only', 'btn btn-ghost', async () => {
    try {
      const after = await RestoreWindowsBoot();
      showBootReport(after);
      alert('Windows will start normally. Your setup files are kept, so you can try again later.');
    } catch (e) {
      alert('Windows boot was not restored: ' + e);
      refreshBootReport();
    }
  });
  restoreBtn.disabled = true;
  footer.appendChild(restoreBtn);

  // 3. Repair boot button
  const repairBtn = btn('Repair boot', 'btn btn-ghost', async () => {
    try {
      await RepairBoot();
      alert('Boot configuration repaired and checked. Your computer will restart to try again.');
    } catch (e) {
      alert('Repair boot hit a problem: ' + e);
      refreshBootReport();
    }
  });
  repairBtn.disabled = true;
  footer.appendChild(repairBtn);

  // 4. Try again button (primary)
  footer.appendChild(btn('Try again →', 'btn btn-primary', async () => {
    try {
      await TryAgain();
    } catch (e) {
      alert('Try again hit a problem: ' + e);
    }
  }));

  wrap.appendChild(footer);

  const stateText = {
    'windows-only': 'Windows starts normally. wootc is not in the boot order.',
    'one-shot-armed': 'The next restart (only) goes to the Linux installer.',
    'wootc-default': 'A wootc entry is ahead of Windows in the boot order.',
    'wootc-listed': 'Windows starts first; a wootc entry is still in the boot order.',
    'foreign-next': 'The next restart goes to an entry wootc does not own.',
    unknown: 'The boot configuration could not be read.',
  };

  function line(text) {
    const d = el('div');
    d.textContent = text;
    bootBody.appendChild(d);
  }

  function showBootReport(r) {
    r = r || {};
    bootTitle.textContent = stateText[r.bootState] || stateText.unknown;
    bootBody.textContent = '';
    (r.findings || []).forEach(line);
    (r.refusals || []).forEach((t) => line('Not offered: ' + t));
    if (r.bundlePath) line('Details saved to ' + r.bundlePath);
    restoreBtn.disabled = !r.canRestoreWindows;
    repairBtn.disabled = !r.canRepairBoot;
  }

  async function refreshBootReport() {
    try {
      showBootReport(await InspectBoot());
    } catch (e) {
      showBootReport({ bootState: 'unknown', refusals: ['boot check failed: ' + e] });
    }
  }

  refreshBootReport();
  return wrap;
}
