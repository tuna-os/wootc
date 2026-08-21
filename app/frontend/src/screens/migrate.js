import {
  GetMigrationCategories, GetAppMigrations, GetOfficeMigration, GetMigrationProfile,
  GetLookMigration, SetMigrationProfile, SetSessionConsent, ReinstallApps,
  ConvertCategory, ImportBrowserData,
} from '../../wailsjs/go/main/App';
import { Quit } from '../../wailsjs/runtime/runtime';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { fmtSize } from '../lib/format.js';
import { el, btn, chip } from '../lib/ui.js';

// ── Screen 5: Migration dashboard (installed Linux system) ───────────────────

// A missing Wails binding makes its generated wrapper throw synchronously, so
// a plain `.catch()` on the call never runs and one absent optional method
// would blank the whole dashboard. Degrade that section instead.
async function optional(call, fallback) {
  try {
    return (await call()) ?? fallback;
  } catch (e) {
    console.error(e);
    return fallback;
  }
}

export async function refreshCategories() {
  try {
    const [cats, apps, office, profile, look] = await Promise.all([
      optional(GetMigrationCategories, []),
      optional(GetAppMigrations, []),
      optional(GetOfficeMigration, null),
      optional(GetMigrationProfile, null),
      optional(GetLookMigration, null),
    ]);
    state.categories = cats || [];
    state.apps = apps || [];
    state.office = office && office.present ? office : null;
    state.migrationProfile = profile;
    state.look = look;
  } catch (e) {
    console.error(e);
    state.categories = [];
  }
  if (state.screen === 'migrate') render();
}

const CATEGORY_ICONS = {
  Documents: '📄', Pictures: '🖼️', Downloads: '📥',
  Music: '🎵', Videos: '🎬', Desktop: '🖥️',
  steam: '🎮', browser: '🌐',
};

export function renderMigrateScreen() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');

  const hdr = el('div');
  hdr.innerHTML = `
    <div class="screen-title">Your Windows files are already here</div>
    <div class="screen-subtitle">
      Everything below is available right now, straight from Windows — no copying needed.
      When you're ready, move things over to Linux at your own pace.
    </div>
  `;
  screen.appendChild(hdr);

  const reassure = el('div', 'warning-banner');
  reassure.style.cssText = 'background:rgba(74,222,128,0.07);border-color:rgba(74,222,128,0.3);color:var(--text-dim)';
  reassure.innerHTML = `<span>🛡️</span><span>Moving something to Linux never deletes it from Windows. Until you choose to remove Windows entirely, your files exist safely in both places.</span>`;
  screen.appendChild(reassure);

  const scroll = el('div');
  scroll.style.cssText = 'overflow-y:auto;display:flex;flex-direction:column;gap:16px;margin-top:10px';

  const filesSection = el('div');
  filesSection.appendChild(sectionLabel('Your files & games'));
  const list = el('div');
  list.id = 'migrate-rows';
  list.style.cssText = 'display:flex;flex-direction:column;gap:8px';
  list.appendChild(renderMigrateRowsInner());
  filesSection.appendChild(list);
  scroll.appendChild(filesSection);

  if (state.apps.length) {
    const appsSection = el('div');
    appsSection.appendChild(sectionLabel('Your apps'));
    const al = el('div');
    al.style.cssText = 'display:flex;flex-direction:column;gap:8px';
    state.apps.forEach(a => al.appendChild(renderAppRow(a)));
    appsSection.appendChild(al);
    const reinstall = btn('Reinstall detected apps', 'btn btn-ghost', async () => {
      reinstall.disabled = true;
      reinstall.textContent = 'Installing…';
      try {
        await ReinstallApps();
        alert('The detected Flatpak apps were installed. App data and credentials were not copied.');
      } catch (e) {
        alert('Could not reinstall detected apps: ' + e);
      } finally {
        reinstall.disabled = false;
        reinstall.textContent = 'Reinstall detected apps';
      }
    });
    reinstall.style.cssText = 'font-size:12px;margin-top:8px';
    appsSection.appendChild(reinstall);
    scroll.appendChild(appsSection);
  }

  if (state.migrationProfile) {
    const profile = el('div');
    profile.appendChild(sectionLabel('Windows profile mapping'));
    const card = el('div');
    card.style.cssText = 'background:var(--bg-card);border:1.5px solid var(--border);border-radius:8px;padding:12px 16px;display:flex;align-items:center;gap:10px';
    const copy = el('div');
    copy.style.flex = '1';
    copy.innerHTML = `<div style="font-size:12.5px;font-weight:600">Linux <code>${state.migrationProfile.linuxUser || 'unknown'}</code> → Windows <code>${state.migrationProfile.windowsProfile || 'not mapped'}</code></div><div style="font-size:11.5px;color:var(--text-muted);margin-top:3px">${state.migrationProfile.note || ''}</div>`;
    card.appendChild(copy);
    const choose = btn('Choose', 'btn btn-ghost', async () => {
      const value = prompt('Windows profile folder name:', state.migrationProfile.windowsProfile || '');
      if (!value) return;
      try { await SetMigrationProfile(value.trim()); await refreshCategories(); }
      catch (e) { alert('Could not map that Windows profile: ' + e); }
    });
    choose.style.fontSize = '12px';
    card.appendChild(choose);
    profile.appendChild(card);
    scroll.appendChild(profile);
  }

  if (state.look) {
    const look = el('div');
    look.appendChild(sectionLabel('Windows look'));
    const card = el('div');
    card.style.cssText = 'background:var(--bg-card);border:1.5px solid var(--border);border-radius:8px;padding:12px 16px';
    const status = state.look.applied ? '✓ Applied to this Linux user' : state.look.available ? 'Ready to apply on first login' : 'Not collected';
    card.innerHTML = `<div style="font-size:12.5px;font-weight:600">${status}</div><div style="font-size:11.5px;color:var(--text-muted);margin-top:3px">${state.look.note || ''}</div>`;
    if (state.look.items?.length) {
      const items = el('div');
      items.style.cssText = 'display:flex;gap:6px;flex-wrap:wrap;margin-top:8px';
      state.look.items.forEach(item => items.appendChild(chip(item, false)));
      card.appendChild(items);
    }
    look.appendChild(card);
    scroll.appendChild(look);
  }

  if (state.office) {
    const off = el('div');
    off.appendChild(sectionLabel('Microsoft Office → LibreOffice'));
    const card = el('div');
    card.style.cssText = 'background:var(--bg-card);border:1.5px solid var(--border);border-radius:8px;padding:12px 16px';
    const moved = (state.office.migrated || []).map(m => ({
      'custom-dictionary': 'custom dictionary', templates: 'templates', fonts: 'fonts',
      autocorrect: 'AutoCorrect list', 'office-format-defaults': 'save-as-Office default',
    }[m] || m));
    card.innerHTML = `<div style="font-size:12.5px;color:var(--text-dim)">${state.office.note || ''}</div>` +
      (moved.length ? `<div style="margin-top:8px;display:flex;gap:6px;flex-wrap:wrap">${moved.map(m => `<span class="chip ok">✓ ${m}</span>`).join('')}</div>` : '');
    off.appendChild(card);
    scroll.appendChild(off);
  }

  screen.appendChild(scroll);
  wrap.appendChild(screen);

  const footer = el('div', 'footer');
  footer.appendChild(btn('Refresh', 'btn btn-ghost', () => refreshCategories()));
  footer.appendChild(btn('Close', 'btn btn-primary', () => Quit()));
  wrap.appendChild(footer);
  return wrap;
}

function renderMigrateRowsInner() {
  const frag = document.createDocumentFragment();
  if (!state.categories.length) {
    const empty = el('div');
    empty.style.cssText = 'padding:30px;text-align:center;color:var(--text-muted);font-size:13px';
    empty.textContent = 'Looking for your Windows data…';
    frag.appendChild(empty);
    return frag;
  }
  state.categories.forEach(c => {
    const row = el('div');
    row.style.cssText = 'display:flex;align-items:center;gap:12px;background:var(--bg-card);border:1.5px solid var(--border);border-radius:8px;padding:12px 16px';

    const icon = el('span');
    icon.style.fontSize = '20px';
    icon.textContent = CATEGORY_ICONS[c.id] || '📁';
    row.appendChild(icon);

    const mid = el('div');
    mid.style.cssText = 'flex:1;min-width:0';
    const size = c.sizeBytes >= 0 ? ` · ${fmtSize(c.sizeBytes)}` : '';
    mid.innerHTML = `
      <div style="font-weight:600;font-size:13.5px">${c.label}<span style="font-weight:400;color:var(--text-muted)">${size}</span></div>
      <div style="font-size:12px;color:var(--text-muted);margin-top:2px">${c.description}</div>
    `;
    row.appendChild(mid);

    row.appendChild(migrateAction(c));
    frag.appendChild(row);
  });
  return frag;
}

export function renderMigrateRows() {
  const list = document.getElementById('migrate-rows');
  if (!list) return;
  list.innerHTML = '';
  list.appendChild(renderMigrateRowsInner());
}

function sectionLabel(text) {
  const l = el('div');
  l.style.cssText = 'font-size:11px;font-weight:600;color:var(--text-dim);text-transform:uppercase;letter-spacing:0.6px;margin-bottom:6px';
  l.textContent = text;
  return l;
}

const APP_ICONS = {
  firefox: '🦊', chrome: '🌐', edge: '🌐', vscode: '💻', discord: '💬',
  spotify: '🎧', slack: '💬', steam: '🎮', obs: '🎥', telegram: '✈️',
  signal: '🔒', whatsapp: '💬', thunderbird: '📧', zoom: '🎦',
};

// The honest outcome badge, driven by the backend's session verdict.
const SESSION_BADGE = {
  portable: { label: '✓ Signed in', cls: 'ok' },
  signin:   { label: 'Sign in once', cls: '' },
  relink:   { label: 'Re-link needed (2 steps)', cls: '' },
  none:     { label: 'Re-link needed', cls: '' },
};

function renderAppRow(a) {
  const row = el('div');
  row.style.cssText = 'display:flex;align-items:center;gap:12px;background:var(--bg-card);border:1.5px solid var(--border);border-radius:8px;padding:10px 16px';
  const badge = SESSION_BADGE[a.session] || SESSION_BADGE.signin;
  
  const left = el('div');
  left.style.cssText = 'display:flex;align-items:center;gap:12px;flex:1;min-width:0';
  left.innerHTML = `
    <span style="font-size:18px">${APP_ICONS[a.app] || '📦'}</span>
    <div style="flex:1;min-width:0">
      <div style="font-weight:600;font-size:13px;text-transform:capitalize">${a.app}</div>
      <div style="font-size:11.5px;color:var(--text-muted);margin-top:1px">${a.note || ''}</div>
    </div>
  `;
  row.appendChild(left);

  if (a.consentAvailable) {
    const consent = el('label');
    consent.style.cssText = 'display:flex;align-items:center;gap:5px;font-size:11px;color:var(--text-muted);flex-shrink:0';
    const checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = !!a.consent;
    checkbox.title = 'Allow session token copy when the Windows-online exporter supports this app';
    checkbox.onchange = async () => {
      checkbox.disabled = true;
      try { await SetSessionConsent(a.app, checkbox.checked); a.consent = checkbox.checked; }
      catch (e) { checkbox.checked = !checkbox.checked; alert('Could not save session consent: ' + e); }
      finally { checkbox.disabled = false; }
    };
    consent.appendChild(checkbox);
    consent.appendChild(document.createTextNode('Allow session copy'));
    row.appendChild(consent);
  }

  if (a.session === 'relink') {
    const relinkBtn = btn('Re-link Guide', 'btn btn-ghost', () => openRelinkModal(a));
    relinkBtn.style.fontSize = '12px';
    relinkBtn.style.flexShrink = '0';
    row.appendChild(relinkBtn);
  }

  const chipSpan = el('span', `chip ${badge.cls}`);
  chipSpan.style.flexShrink = '0';
  chipSpan.textContent = badge.label;
  row.appendChild(chipSpan);
  return row;
}

function openRelinkModal(a) {
  const modal = el('div');
  modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;z-index:1000;padding:20px';
  const content = el('div');
  content.style.cssText = 'background:var(--bg-card);border:1.5px solid var(--border);border-radius:12px;padding:20px;max-width:480px;width:100%;box-shadow:0 10px 25px rgba(0,0,0,0.5)';
  
  let title = 'Re-link Phone App';
  let stepsHtml = '';

  if (a.app === 'signal') {
    title = 'Signal: Phone Re-link Steps';
    stepsHtml = `
      <ol style="margin:12px 0;padding-left:20px;font-size:13px;color:var(--text-dim);display:flex;flex-direction:column;gap:8px">
        <li>Open Signal on your phone.</li>
        <li>Go to <strong>Settings → Linked Devices</strong>.</li>
        <li>Tap <strong>Link New Device</strong> and scan the QR code displayed in Signal Desktop.</li>
      </ol>
      <div style="font-size:12px;color:var(--text-muted);margin-bottom:16px">Note: Message history stays on your phone by design.</div>
    `;
  } else if (a.app === 'whatsapp') {
    title = 'WhatsApp: Web Re-link Steps';
    stepsHtml = `
      <ol style="margin:12px 0;padding-left:20px;font-size:13px;color:var(--text-dim);display:flex;flex-direction:column;gap:8px">
        <li>Open <strong>web.whatsapp.com</strong> in your browser.</li>
        <li>Open WhatsApp on your phone and go to <strong>Settings → Linked Devices</strong>.</li>
        <li>Tap <strong>Link a Device</strong> and scan the QR code on screen.</li>
      </ol>
    `;
  } else if (a.app === 'telegram') {
    title = 'Telegram: Re-link / Fallback Steps';
    stepsHtml = `
      <ol style="margin:12px 0;padding-left:20px;font-size:13px;color:var(--text-dim);display:flex;flex-direction:column;gap:8px">
        <li>Open Telegram Desktop on Linux.</li>
        <li>Scan the displayed QR code using Telegram on your phone (<strong>Settings → Devices → Link Desktop Device</strong>).</li>
        <li>Alternatively, enter your phone number to receive a login code.</li>
      </ol>
    `;
  } else {
    stepsHtml = `<div style="font-size:13px;color:var(--text-dim);margin:12px 0">${a.note || 'Follow phone app settings to link device.'}</div>`;
  }

  content.innerHTML = `
    <div style="font-weight:600;font-size:16px;margin-bottom:8px">${title}</div>
    ${stepsHtml}
  `;

  const footer = el('div');
  footer.style.cssText = 'display:flex;justify-content:flex-end;margin-top:16px';
  const closeBtn = btn('Done', 'btn btn-primary', () => document.body.removeChild(modal));
  footer.appendChild(closeBtn);
  content.appendChild(footer);
  modal.appendChild(content);
  document.body.appendChild(modal);
}

function migrateAction(c) {
  const holder = el('div');
  holder.style.cssText = 'display:flex;align-items:center;gap:8px;flex-shrink:0';

  if (c.id in state.converting) {
    const pct = Math.round(state.converting[c.id] || 0);
    const track = el('div');
    track.style.cssText = 'width:110px;height:6px;background:var(--border);border-radius:3px;overflow:hidden';
    const fill = el('div');
    fill.style.cssText = `width:${pct}%;height:100%;background:var(--accent, #4ade80);transition:width .3s`;
    track.appendChild(fill);
    const lbl = el('span');
    lbl.style.cssText = 'font-size:11.5px;color:var(--text-muted);min-width:34px';
    lbl.textContent = `${pct}%`;
    holder.appendChild(track);
    holder.appendChild(lbl);
    return holder;
  }

  switch (c.state) {
    case 'bridged': {
      holder.appendChild(chip('Connected to Windows', false));
      const b = btn('Move to Linux', 'btn btn-ghost', () => confirmConvert(c));
      b.style.fontSize = '12px';
      holder.appendChild(b);
      break;
    }
    case 'native':
      holder.appendChild(chip('✓ On Linux', false));
      break;
    case 'available': {
      if (c.id === 'browser') {
        const b = btn('Import', 'btn btn-ghost', () => runBrowserImport());
        b.style.fontSize = '12px';
        holder.appendChild(b);
      } else {
        holder.appendChild(chip('Found on Windows', false));
      }
      break;
    }
    default:
      holder.appendChild(chip('Not found', false));
  }
  return holder;
}

function confirmConvert(c) {
  const size = c.sizeBytes >= 0 ? ` (${fmtSize(c.sizeBytes)})` : '';
  if (!confirm(
    `Move ${c.label}${size} to Linux?\n\n` +
    `Your files will be copied to fast Linux storage. The Windows copy stays exactly where it is — nothing is deleted.`
  )) return;
  state.converting[c.id] = 0;
  renderMigrateRows();
  ConvertCategory(c.id).catch(e => {
    delete state.converting[c.id];
    alert(`Something went wrong: ${e}\nYour files are safe — nothing was deleted.`);
    refreshCategories();
  });
}

async function runBrowserImport() {
  try {
    await ImportBrowserData();
    await refreshCategories();
  } catch (e) {
    alert(`Browser import hit a snag: ${e}\nNothing was changed on the Windows side.`);
  }
}
