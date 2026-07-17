import '../src/style.css';
import { GetImages, GetSystemInfo, StartInstall, CancelInstall, GetStatus, Reboot, ExistingInstallFound, GetMode, GetMigrationCategories, ConvertCategory, ImportBrowserData } from '../wailsjs/go/main/App';
import { EventsOn } from '../wailsjs/runtime/runtime';

// ── State ─────────────────────────────────────────────────────────────────────

const state = {
  screen: 'loading',   // loading | launchpad | progress | done | control | migrate
  mode: 'installer',   // installer (Windows) | migration (installed Linux)
  images: [],
  sysinfo: null,
  categories: [],      // migration dashboard rows
  converting: {},      // category id → percent while a conversion runs
  selected: null,      // selected Image
  config: {
    diskSizeGB: 40,
    username: '',
    password: '',
    hostname: 'tunaos',
    bootloader: 'grub2',
  },
  progress: {
    step: '',
    message: '',
    percent: 0,
    completedSteps: [],
    error: null,
  },
};

const INSTALL_STEPS = [
  'Checking system',
  'Disabling Fast Startup',
  'Creating directories',
  'Creating root.vhdx',
  'Downloading deployer',
  'Writing GRUB config',
  'Setting up ESP',
  'Configuring BCD',
  'Writing vault.json',
  'Finalizing',
];

// ── Init ──────────────────────────────────────────────────────────────────────

async function init() {
  // Listen for progress events from Go backend
  EventsOn('install:progress', (e) => {
    state.progress.step = e.step;
    state.progress.message = e.message;
    state.progress.percent = e.percent;
    if (e.error) state.progress.error = e.error;
    if (e.done) { state.screen = 'done'; render(); return; }
    if (e.step && !state.progress.completedSteps.includes(e.step)) {
      // Mark previous step as done when a new one starts
      const idx = INSTALL_STEPS.indexOf(e.step);
      if (idx > 0) {
        for (let i = 0; i < idx; i++) {
          if (!state.progress.completedSteps.includes(INSTALL_STEPS[i]))
            state.progress.completedSteps.push(INSTALL_STEPS[i]);
        }
      }
    }
    if (state.screen === 'progress') renderProgress();
  });

  // Conversion progress events from the migration dashboard backend.
  EventsOn('migrate:progress', (p) => {
    if (p.error) {
      delete state.converting[p.category];
      alert(`Something went wrong moving ${p.category}: ${p.error}\nYour files are safe — nothing was deleted.`);
      refreshCategories();
      return;
    }
    state.converting[p.category] = p.percent;
    if (p.done) {
      delete state.converting[p.category];
      refreshCategories();
      return;
    }
    if (state.screen === 'migrate') renderMigrateRows();
  });

  state.mode = await GetMode().catch(() => 'installer');

  if (state.mode === 'migration') {
    await refreshCategories();
    state.screen = 'migrate';
    render();
    return;
  }

  const [images, sysinfo, existing] = await Promise.all([
    GetImages(),
    GetSystemInfo(),
    ExistingInstallFound(),
  ]);

  state.images = images || [];
  state.sysinfo = sysinfo;
  state.selected = state.images[0] || null;

  // Pre-fill username from OS if available
  try {
    const u = (sysinfo.osVersion || '').toLowerCase();
    if (!u.includes('dev')) state.config.username = 'james'; // placeholder
  } catch {}

  state.screen = existing ? 'control' : 'launchpad';
  render();
}

async function refreshCategories() {
  try {
    state.categories = (await GetMigrationCategories()) || [];
  } catch (e) {
    console.error(e);
    state.categories = [];
  }
  if (state.screen === 'migrate') render();
}

// ── Router ────────────────────────────────────────────────────────────────────

function render() {
  const app = document.getElementById('app');
  app.innerHTML = '';
  app.appendChild(renderTitleBar());

  const content = document.createElement('div');
  content.id = 'screen-content';
  content.style.flex = '1';
  content.style.display = 'flex';
  content.style.flexDirection = 'column';
  content.style.overflow = 'hidden';

  switch (state.screen) {
    case 'launchpad': content.appendChild(renderLaunchpad()); break;
    case 'progress':  content.appendChild(renderProgressScreen()); break;
    case 'done':      content.appendChild(renderDoneScreen()); break;
    case 'control':   content.appendChild(renderControlPanel()); break;
    case 'migrate':   content.appendChild(renderMigrateScreen()); break;
    default:          content.innerHTML = '<div style="padding:40px;color:#666">Loading…</div>';
  }

  app.appendChild(content);
}

// ── Title bar ─────────────────────────────────────────────────────────────────

function renderTitleBar() {
  const bar = el('div', 'titlebar');
  bar.innerHTML = `
    <span class="titlebar-logo">🐠</span>
    <span class="titlebar-name">wootc</span>
    <span class="titlebar-version">0.1.0</span>
    <span class="titlebar-step">${stepLabel()}</span>
  `;
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

// ── Screen 1: Launchpad ───────────────────────────────────────────────────────

function renderLaunchpad() {
  const screen = el('div', 'screen');

  // Header
  const hdr = el('div');
  hdr.innerHTML = `
    <div class="screen-title">Install TunaOS</div>
    <div class="screen-subtitle">Choose a variant, set your disk size and credentials, then click Install.</div>
  `;
  screen.appendChild(hdr);

  // System info chips
  if (state.sysinfo) {
    const si = el('div', 'sysinfo');
    si.appendChild(chip(`💾 ${Math.round(state.sysinfo.freeDiskGB)} GB free`, false));
    si.appendChild(chip(state.sysinfo.isUefi ? '⚡ UEFI' : '🔌 BIOS', false));
    if (state.sysinfo.secureBootOn)  si.appendChild(chip('🔒 Secure Boot', false));
    if (state.sysinfo.bitLockerOn)   si.appendChild(chip('⚠ BitLocker On', true));
    if (state.sysinfo.fastStartupOn) si.appendChild(chip('⚠ Fast Startup', true));
    screen.appendChild(si);
  }

  // BitLocker warning
  if (state.sysinfo?.bitLockerOn) {
    screen.appendChild(warningBanner(
      'BitLocker is enabled on C:. wootc will create a separate partition for Linux, or you can choose an existing unencrypted drive.'
    ));
  }

  // Image grid
  const gridLabel = el('div');
  gridLabel.innerHTML = `<div class="screen-title" style="font-size:13px;font-weight:600;color:var(--text-dim);text-transform:uppercase;letter-spacing:0.6px">Choose a variant</div>`;
  screen.appendChild(gridLabel);

  const grid = el('div', 'image-grid');
  state.images.forEach(img => {
    const card = el('div', 'image-card' + (state.selected?.id === img.id ? ' selected' : ''));
    card.innerHTML = `
      <div class="image-card-header">
        <span class="image-emoji">${img.emoji}</span>
        <span>${img.name}</span>
        <span class="image-desktop">${img.desktopName}</span>
      </div>
      <div class="image-base">${img.base}</div>
      <div class="image-desc">${img.description}</div>
    `;
    card.onclick = () => { state.selected = img; render(); };
    grid.appendChild(card);
  });
  screen.appendChild(grid);

  // Config fields
  const fields = el('div', 'fields');

  // Disk size slider
  const diskField = el('div', 'field');
  diskField.innerHTML = `<label>Virtual Disk Size</label>`;
  const sliderRow = el('div', 'slider-row');
  const slider = document.createElement('input');
  slider.type = 'range'; slider.min = '20'; slider.max = '500'; slider.step = '5';
  slider.value = String(state.config.diskSizeGB);
  const sliderVal = el('span', 'slider-val');
  sliderVal.textContent = `${state.config.diskSizeGB} GB`;
  slider.oninput = () => {
    state.config.diskSizeGB = Number(slider.value);
    sliderVal.textContent = `${state.config.diskSizeGB} GB`;
  };
  const freeNote = el('div');
  freeNote.style.cssText = 'font-size:11.5px;color:var(--text-muted);margin-top:3px';
  freeNote.textContent = state.sysinfo ? `Available: ${Math.round(state.sysinfo.freeDiskGB)} GB on C:` : '';
  sliderRow.appendChild(slider);
  sliderRow.appendChild(sliderVal);
  diskField.appendChild(sliderRow);
  diskField.appendChild(freeNote);
  fields.appendChild(diskField);

  // Username + hostname
  const row1 = el('div', 'field-row');
  row1.appendChild(inputField('Linux Username', 'text', state.config.username, v => state.config.username = v, 'james'));
  row1.appendChild(inputField('Hostname', 'text', state.config.hostname, v => state.config.hostname = v, 'tunaos'));
  fields.appendChild(row1);

  // Password
  const row2 = el('div', 'field-row');
  row2.appendChild(inputField('Password', 'password', state.config.password, v => state.config.password = v, ''));
  row2.appendChild(inputField('Confirm Password', 'password', '', () => {}, ''));
  fields.appendChild(row2);

  screen.appendChild(fields);

  // Footer
  const footer = el('div', 'footer');
  const installBtn = btn('Install →', 'btn btn-primary', () => startInstall());
  installBtn.disabled = !state.selected;
  footer.appendChild(btn('Cancel', 'btn btn-ghost', () => window.wails?.Quit?.()));
  footer.appendChild(installBtn);

  const wrap = el('div');
  wrap.style.display = 'flex';
  wrap.style.flexDirection = 'column';
  wrap.style.flex = '1';
  wrap.style.overflow = 'hidden';
  wrap.appendChild(screen);
  wrap.appendChild(footer);
  return wrap;
}

// ── Screen 2: Progress ────────────────────────────────────────────────────────

function renderProgressScreen() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');
  screen.id = 'progress-screen';
  screen.appendChild(renderProgressInner());
  wrap.appendChild(screen);

  const footer = el('div', 'footer');
  const cancelBtn = btn('Cancel', 'btn btn-ghost btn-danger', async () => {
    await CancelInstall();
    state.screen = 'launchpad';
    render();
  });
  footer.appendChild(cancelBtn);
  wrap.appendChild(footer);
  return wrap;
}

function renderProgressInner() {
  const frag = document.createDocumentFragment();
  const hdr = el('div');
  hdr.innerHTML = `<div class="screen-title">Installing TunaOS</div>
    <div class="screen-subtitle">${state.selected?.name || ''} ${state.selected?.desktopName || ''} — ${state.selected?.base || ''}</div>`;
  frag.appendChild(hdr);

  const pw = el('div', 'progress-wrap');

  const stepLabel = el('div', 'progress-step');
  stepLabel.textContent = state.progress.step || 'Starting…';

  const msgLabel = el('div', 'progress-msg');
  msgLabel.textContent = state.progress.message || '';

  const track = el('div', 'progress-bar-track');
  const fill = el('div', 'progress-bar-fill');
  fill.style.width = `${state.progress.percent}%`;
  track.appendChild(fill);

  // Step list
  const stepList = el('div', 'progress-steps-list');
  INSTALL_STEPS.forEach(s => {
    const item = el('div', 'step-item');
    const done = state.progress.completedSteps.includes(s);
    const active = state.progress.step === s;
    const hasErr = state.progress.error && active;
    if (done) item.classList.add('done');
    else if (active && !hasErr) item.classList.add('active');
    else if (hasErr) item.classList.add('error');
    item.innerHTML = `<span class="step-dot"></span>${s}`;
    stepList.appendChild(item);
  });

  if (state.progress.error) {
    const errDiv = el('div');
    errDiv.style.cssText = 'color:var(--danger);font-size:12.5px;background:rgba(248,113,113,0.08);border:1px solid rgba(248,113,113,0.25);border-radius:6px;padding:10px 14px;margin-top:8px';
    errDiv.textContent = '✖ ' + state.progress.error;
    pw.appendChild(errDiv);
  }

  pw.appendChild(stepLabel);
  pw.appendChild(msgLabel);
  pw.appendChild(track);
  pw.appendChild(stepList);
  frag.appendChild(pw);
  return frag;
}

function renderProgress() {
  const screen = document.getElementById('progress-screen');
  if (!screen) return;
  screen.innerHTML = '';
  screen.appendChild(renderProgressInner());
}

// ── Screen 3: Done ────────────────────────────────────────────────────────────

function renderDoneScreen() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');

  const hero = el('div', 'done-hero');
  hero.innerHTML = `
    <div class="done-icon">🎉</div>
    <div class="done-title">TunaOS is ready!</div>
    <div class="done-body">
      ${state.selected?.name || 'TunaOS'} ${state.selected?.desktopName || ''} has been configured.<br>
      Click <strong>Reboot Now</strong> to start the deployer. The first boot takes 5–15 minutes
      while it downloads and installs TunaOS. Subsequent boots are instant.
    </div>
  `;
  screen.appendChild(hero);
  wrap.appendChild(screen);

  const footer = el('div', 'footer');
  footer.appendChild(btn('Reboot Later', 'btn btn-ghost', () => window.wails?.Quit?.()));
  footer.appendChild(btn('Reboot Now →', 'btn btn-primary', () => Reboot()));
  wrap.appendChild(footer);
  return wrap;
}

// ── Screen 4: Control Panel ───────────────────────────────────────────────────

function renderControlPanel() {
  const wrap = el('div');
  wrap.style.cssText = 'display:flex;flex-direction:column;flex:1;overflow:hidden';
  const screen = el('div', 'screen');
  screen.innerHTML = `
    <div class="screen-title">Manage TunaOS</div>
    <div class="screen-subtitle">An existing TunaOS installation was found on this PC.</div>
  `;

  const card = el('div');
  card.style.cssText = 'background:var(--bg-card);border:1.5px solid var(--border);border-radius:var(--radius);padding:20px;display:flex;flex-direction:column;gap:12px;margin-top:8px';
  card.innerHTML = `
    <div style="font-weight:600;font-size:14px">C:\\wootc\\disks\\root.vhdx</div>
    <div style="font-size:12.5px;color:var(--text-muted)">Your TunaOS installation lives in this file. Deleting it will remove Linux but leave Windows intact.</div>
  `;
  screen.appendChild(card);

  wrap.appendChild(screen);

  const footer = el('div', 'footer');
  footer.appendChild(btn('Reinstall', 'btn btn-ghost', () => { state.screen = 'launchpad'; render(); }));
  footer.appendChild(btn('Uninstall TunaOS', 'btn btn-danger', () => confirmUninstall()));
  footer.appendChild(btn('Close', 'btn btn-primary', () => window.wails?.Quit?.()));
  wrap.appendChild(footer);
  return wrap;
}

// ── Screen 5: Migration dashboard (installed Linux system) ───────────────────

const CATEGORY_ICONS = {
  Documents: '📄', Pictures: '🖼️', Downloads: '📥',
  Music: '🎵', Videos: '🎬', Desktop: '🖥️',
  steam: '🎮', browser: '🌐',
};

function renderMigrateScreen() {
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

  const list = el('div');
  list.id = 'migrate-rows';
  list.style.cssText = 'display:flex;flex-direction:column;gap:8px;margin-top:10px;overflow-y:auto';
  list.appendChild(renderMigrateRowsInner());
  screen.appendChild(list);

  wrap.appendChild(screen);

  const footer = el('div', 'footer');
  footer.appendChild(btn('Refresh', 'btn btn-ghost', () => refreshCategories()));
  footer.appendChild(btn('Close', 'btn btn-primary', () => window.wails?.Quit?.()));
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

function renderMigrateRows() {
  const list = document.getElementById('migrate-rows');
  if (!list) return;
  list.innerHTML = '';
  list.appendChild(renderMigrateRowsInner());
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

function fmtSize(bytes) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(0)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

function confirmUninstall() {
  if (confirm('Remove the TunaOS boot entry? (root.vhdx will NOT be deleted — remove it manually from C:\\wootc\\disks\\)')) {
    import('../wailsjs/go/main/App').then(({ Uninstall }) => Uninstall());
  }
}

// ── Actions ───────────────────────────────────────────────────────────────────

async function startInstall() {
  if (!state.selected) return;
  state.screen = 'progress';
  state.progress = { step: '', message: '', percent: 0, completedSteps: [], error: null };
  render();

  try {
    await StartInstall({
      imageRef:   state.selected.imageRef,
      diskSizeGB: state.config.diskSizeGB,
      username:   state.config.username,
      password:   state.config.password,
      hostname:   state.config.hostname,
      bootloader: state.config.bootloader,
    });
  } catch (e) {
    state.progress.error = String(e);
    renderProgress();
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function el(tag, className = '') {
  const e = document.createElement(tag);
  if (className) e.className = className;
  return e;
}

function btn(label, className, onClick) {
  const b = el('button', className);
  b.textContent = label;
  b.onclick = onClick;
  return b;
}

function chip(label, isWarn) {
  const c = el('div', 'chip' + (isWarn ? ' warn' : ' ok'));
  c.textContent = label;
  return c;
}

function warningBanner(text) {
  const d = el('div', 'warning-banner');
  d.innerHTML = `<svg width="14" height="14" viewBox="0 0 16 16" fill="currentColor"><path d="M8 1a7 7 0 1 0 0 14A7 7 0 0 0 8 1zm.75 10.5h-1.5v-1.5h1.5v1.5zm0-3h-1.5V4.5h1.5V8.5z"/></svg><span>${text}</span>`;
  return d;
}

function inputField(label, type, value, onChange, placeholder) {
  const f = el('div', 'field');
  const lbl = el('label');
  lbl.textContent = label;
  const inp = document.createElement('input');
  inp.type = type;
  inp.value = value;
  inp.placeholder = placeholder;
  inp.oninput = () => onChange(inp.value);
  f.appendChild(lbl);
  f.appendChild(inp);
  return f;
}

// ── Boot ──────────────────────────────────────────────────────────────────────

init().catch(console.error);
