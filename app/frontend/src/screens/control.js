import { BootInVM, UninstallWith } from '../../wailsjs/go/main/App';
import { Quit } from '../../wailsjs/runtime/runtime';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { el, btn } from '../lib/ui.js';

// ── Screen 4: Control Panel ───────────────────────────────────────────────────

export function renderControlPanel() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');
  screen.innerHTML = `
    <div class="screen-title">Manage TunaOS</div>
    <div class="screen-subtitle">An existing TunaOS installation was found on this PC.</div>
  `;

  const u = state.uninstallInfo || {};
  const path = u.diskPath || 'C:\\wootc\\disks\\root.vhdx';
  const sizeStr = u.diskSizeGB ? ` (${Math.round(u.diskSizeGB)} GB)` : '';
  const card = el('div');
  card.style.cssText = 'background:var(--bg-card);border:1.5px solid var(--border);border-radius:var(--radius);padding:20px;display:flex;flex-direction:column;gap:12px;margin-top:8px';
  card.innerHTML = `
    <div style="font-weight:600;font-size:14px">${path}${sizeStr}</div>
    <div style="font-size:12.5px;color:var(--text-muted)">Your TunaOS installation lives here. Removing it leaves Windows completely intact.</div>
  `;
  screen.appendChild(card);

  // Uninstall options (§5) — checkboxes drive UninstallWith.
  state.uninstallOpts = state.uninstallOpts || { deleteRootDisk: false, removePartition: false };
  const opts = el('div');
  opts.style.cssText = 'display:flex;flex-direction:column;gap:8px;margin-top:6px';
  const checkbox = (id, label, sub, danger) => {
    const row = el('label');
    row.style.cssText = 'display:flex;gap:10px;align-items:flex-start;cursor:pointer;font-size:12.5px';
    row.innerHTML = `<input type="checkbox" ${state.uninstallOpts[id] ? 'checked' : ''} style="margin-top:2px">
      <span><b style="${danger ? 'color:var(--danger)' : ''}">${label}</b><br><span style="color:var(--text-muted)">${sub}</span></span>`;
    row.querySelector('input').onchange = (e) => { state.uninstallOpts[id] = e.target.checked; };
    return row;
  };
  opts.appendChild(checkbox('deleteRootDisk', 'Also delete my Linux data',
    'Removes root.disk. Your Linux files are permanently deleted. Leave unchecked to keep them for later.', true));
  if (u.onDedicatedVol && u.reclaimGB) {
    opts.appendChild(checkbox('removePartition', `Give the ${Math.round(u.reclaimGB)} GB back to Windows`,
      `Removes the wootc-data drive (${u.storageDrive}:) and extends C: into the freed space.`, false));
  }
  screen.appendChild(opts);

  wrap.appendChild(screen);

  // Boot-in-VM (§6.2): view Linux without rebooting, when the VM viewer is
  // present and WHPX is on.
  const vm = state.vmCapability;
  if (vm) {
    const vmCard = el('div');
    vmCard.style.cssText = 'background:var(--bg-card);border:1.5px solid var(--border);border-radius:8px;padding:14px 16px;margin-top:10px;display:flex;align-items:center;gap:12px';
    vmCard.innerHTML = `<span style="font-size:20px">🖥️</span>
      <div style="flex:1;min-width:0">
        <div style="font-weight:600;font-size:13px">Try Linux in a window</div>
        <div style="font-size:11.5px;color:var(--text-muted)">${vm.available
          ? `Boot your installed TunaOS in a window using ${String(vm.accelerator || 'hardware acceleration').toUpperCase()}. Changes persist — it's the same system.`
          : vm.reason}</div>
      </div>`;
    const vmBtn = btn('Boot in VM', 'btn btn-ghost', async () => {
      try { await BootInVM(); } catch (e) { alert('Could not start the VM: ' + e); }
    });
    vmBtn.style.flexShrink = '0';
    vmBtn.disabled = !vm.available;
    vmCard.appendChild(vmBtn);
    screen.appendChild(vmCard);
  }

  const footer = el('div', 'footer');
  footer.appendChild(btn('Reinstall', 'btn btn-ghost', () => { state.screen = 'launchpad'; render(); }));
  footer.appendChild(btn('Uninstall TunaOS', 'btn btn-danger', () => confirmUninstall()));
  footer.appendChild(btn('Close', 'btn btn-primary', () => Quit()));
  wrap.appendChild(footer);
  return wrap;
}

async function confirmUninstall() {
  const o = state.uninstallOpts || {};
  let msg = 'Remove TunaOS?\n\nThis removes the boot entry, the ESP files, and the deployer files.';
  if (o.deleteRootDisk) msg += '\n\n⚠ Your Linux data (root.disk) will be permanently deleted.';
  else msg += '\n\nYour Linux data (root.disk) will be kept.';
  if (o.removePartition) msg += '\n⚠ The wootc-data drive will be removed and its space returned to C:.';
  if (!confirm(msg)) return;
  try {
    await UninstallWith({ deleteRootDisk: !!o.deleteRootDisk, removePartition: !!o.removePartition });
    alert('TunaOS has been removed. Windows is unchanged.');
    Quit();
  } catch (e) {
    alert('Uninstall hit a problem: ' + e);
  }
}
