import '../src/style.css';
import { GetImages, GetSystemInfo, StartInstall, CancelInstall, GetStatus, Reboot, ExistingInstallFound, GetMode, GetMigrationCategories, ConvertCategory, ImportBrowserData, GetAppMigrations, GetOfficeMigration, GetBranding, CreateDataPartition, GetUninstallInfo, UninstallWith, GetVMCapability, BootInVM, DefragDrive, GetFreshVMCapability, TryInVMFresh, InstallPreviewForReal, E2EDriveDirective, E2EDriveReport } from '../wailsjs/go/main/App';
import { EventsOn } from '../wailsjs/runtime/runtime';

// ── State ─────────────────────────────────────────────────────────────────────

const state = {
  screen: 'loading',   // loading | launchpad | progress | done | control | migrate
  mode: 'installer',   // installer (Windows) | migration (installed Linux)
  images: [],
  sysinfo: null,
  brand: null,         // partner/enterprise branding (themeable)
  categories: [],      // migration dashboard rows
  apps: [],            // detected app migrations
  office: null,        // MS Office → LibreOffice summary
  converting: {},      // category id → percent while a conversion runs
  selected: null,      // selected Image
  config: {
    diskSizeGB: 40,
    username: '',
    password: '',
    hostname: 'tunaos',
    bootloader: 'grub2',
    encryption: 'tpm2-luks',
    luksPassphrase: '',
    windowsLook: false,
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
  'Collecting your look',
  'Finalizing',
];

// ── Init ──────────────────────────────────────────────────────────────────────

// Apply partner/enterprise branding as CSS variables + document title.
function applyBranding(b) {
  state.brand = b;
  const r = document.documentElement.style;
  if (b.accent)     { r.setProperty('--accent', b.accent); r.setProperty('--border-focus', b.accent); }
  if (b.accentText)   r.setProperty('--accent-text', b.accentText);
  if (b.background)   r.setProperty('--bg', b.background);
  if (b.card)         r.setProperty('--bg-card', b.card);
  if (b.text)         r.setProperty('--text', b.text);
  document.title = `${b.name} — ${b.tagline}`;
}

async function init() {
  try { applyBranding(await GetBranding()); } catch { applyBranding({ name: 'wootc', tagline: '', logoEmoji: '🐠', version: '0.1.0', installVerb: 'Install' }); }
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

  // Try-in-VM builder progress (§6.1). Drives the preview screen while the
  // headless builder pulls the image and installs it onto preview.raw.
  EventsOn('vm:progress', (e) => {
    state.vmProgress = { stage: e.stage, percent: e.percent || 0, message: e.message || '' };
    if (e.stage === 'ready') state.vmReady = true;
    if (e.stage === 'error') state.vmError = e.message;
    if (state.screen === 'vmpreview') render();
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
  applyImageDefaults(state.selected);

  // Pre-fill username from OS if available
  try {
    const u = (sysinfo.osVersion || '').toLowerCase();
    if (!u.includes('dev')) state.config.username = 'james'; // placeholder
  } catch {}

  if (existing) {
    try { state.uninstallInfo = await GetUninstallInfo(); } catch { state.uninstallInfo = {}; }
    try { state.vmCapability = await GetVMCapability(); } catch { state.vmCapability = null; }
  }
  try { state.freshVmCapability = await GetFreshVMCapability(); } catch { state.freshVmCapability = null; }
  state.screen = existing ? 'control' : 'launchpad';
  render();
}

async function refreshCategories() {
  try {
    const [cats, apps, office] = await Promise.all([
      GetMigrationCategories(),
      GetAppMigrations().catch(() => []),
      GetOfficeMigration().catch(() => null),
    ]);
    state.categories = cats || [];
    state.apps = apps || [];
    state.office = office && office.present ? office : null;
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
    case 'vmpreview': content.appendChild(renderVMPreviewScreen()); break;
    default:          content.innerHTML = '<div style="padding:40px;color:#666">Loading…</div>';
  }

  app.appendChild(content);
}

// ── Title bar ─────────────────────────────────────────────────────────────────

function renderTitleBar() {
  const b = state.brand || { logoEmoji: '🐠', name: 'wootc', version: '0.1.0' };
  const bar = el('div', 'titlebar');
  bar.innerHTML = `
    <span class="titlebar-logo">${b.logoEmoji || '🐠'}</span>
    <span class="titlebar-name">${b.name || 'wootc'}</span>
    <span class="titlebar-version">${b.version || ''}</span>
    <span class="titlebar-step">${stepLabel()}</span>
  `;
  return bar;
}

function installVerb() {
  return state.brand?.installVerb || 'Install';
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
    <div class="screen-title">${installVerb()} TunaOS</div>
    <div class="screen-subtitle">${state.brand?.tagline || 'Choose a variant, set your disk size and credentials, then click Install.'}</div>
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

  // BitLocker: never force decryption — offer an unencrypted home for Linux.
  if (state.sysinfo?.bitLockerOn) {
    screen.appendChild(renderBitlockerChooser());
  }

  if (state.sysinfo?.defragRecommended) {
    const warning = el('div');
    warning.style.cssText = 'background:rgba(245,158,11,.10);border:1px solid rgba(245,158,11,.35);border-radius:8px;padding:11px 13px;display:flex;gap:12px;align-items:center';
    warning.innerHTML = `<div style="flex:1"><b style="font-size:12.5px">Windows recommends optimizing C:</b><br><span style="font-size:11.5px;color:var(--text-muted)">A fragmented NTFS volume can make the Linux virtual disk slower. Installation remains safe if you skip this.</span></div>`;
    const optimize = btn('Defrag now', 'btn btn-ghost', async () => {
      optimize.disabled = true;
      optimize.textContent = 'Optimizing…';
      try {
        await DefragDrive();
        state.sysinfo.defragRecommended = false;
        render();
      } catch (e) {
        optimize.disabled = false;
        optimize.textContent = 'Defrag now';
        alert('Windows could not optimize C:: ' + e);
      }
    });
    warning.appendChild(optimize);
    screen.appendChild(warning);
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
    card.onclick = () => { state.selected = img; applyImageDefaults(img); render(); };
    grid.appendChild(card);
  });
  screen.appendChild(grid);

  const customRef = inputField('Custom supported OCI image', 'text', state.config.customImageRef || '', v => {
    state.config.customImageRef = v.trim();
    if (/^ghcr\.io\/(tuna-os|ublue-os|projectbluefin)\/[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$/.test(state.config.customImageRef)) {
      state.selected = { id: 'custom', name: 'Custom image', imageRef: state.config.customImageRef, bootloader: 'systemd-boot', composeFs: true };
      applyImageDefaults(state.selected);
      render();
    }
    refreshInstallValidity();
  }, 'ghcr.io/ublue-os/image:tag');
  screen.appendChild(customRef);

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
  row2.appendChild(inputField('Password', 'password', state.config.password, v => { state.config.password = v; refreshInstallValidity(); }, ''));
  row2.appendChild(inputField('Confirm Password', 'password', state.config.passwordConfirm || '', v => { state.config.passwordConfirm = v; refreshInstallValidity(); }, ''));
  fields.appendChild(row2);

  // Disk encryption (SPEC §2.6)
  const encSection = el('div');
  encSection.style.cssText = 'margin-top:6px';
  const encLabel = el('div');
  encLabel.style.cssText = 'font-size:11.5px;font-weight:600;color:var(--text-muted);margin-bottom:6px;text-transform:uppercase;letter-spacing:0.5px';
  encLabel.textContent = 'Disk Encryption';
  encSection.appendChild(encLabel);
  const encOpts = el('div');
  encOpts.style.cssText = 'display:flex;flex-direction:column;gap:4px';
  const encRadio = (value, title, sub, recommended) => {
    const row = el('label');
    row.style.cssText = 'display:flex;gap:8px;align-items:flex-start;cursor:pointer;font-size:12px;padding:6px 8px;border:1.5px solid var(--border);border-radius:6px';
    const checked = state.config.encryption === value;
    row.innerHTML = `<input type="radio" name="encryption" value="${value}" ${checked ? 'checked' : ''} style="margin-top:1px">
      <span><b>${title}${recommended ? ' <span style="color:var(--primary);font-size:10px;font-weight:500">RECOMMENDED</span>' : ''}</b><br><span style="color:var(--text-muted)">${sub}</span></span>`;
    row.querySelector('input').onchange = () => { state.config.encryption = value; refreshInstallValidity(); render(); };
    // Visual highlight for selected option
    if (checked) row.style.borderColor = 'var(--primary)';
    return row;
  };
  encOpts.appendChild(encRadio('none', 'No encryption', 'Fastest. Anyone with physical access to the PC can read the Linux disk.', false));
  encOpts.appendChild(encRadio('tpm2-luks', 'TPM auto-unlock', 'LUKS encryption that unlocks automatically via the TPM chip. No prompt at boot.', true));
  encOpts.appendChild(encRadio('luks-passphrase', 'Passphrase', 'LUKS encryption that asks for your Linux password every boot.', false));
  encSection.appendChild(encOpts);

  // Passphrase input (only when passphrase mode)
  if (state.config.encryption === 'luks-passphrase') {
    const ppRow = el('div', 'field-row');
    ppRow.style.marginTop = '8px';
    ppRow.appendChild(inputField('LUKS Passphrase', 'password', state.config.luksPassphrase, v => { state.config.luksPassphrase = v; refreshInstallValidity(); }, ''));
    encSection.appendChild(ppRow);
  }
  fields.appendChild(encSection);

  // Windows-Style Mode (SPEC §4.4) — opt-in. Default off so we honor the
  // image maker's desktop defaults; ticking it brings the user's Windows
  // wallpaper, accent, keyboard layout, taskbar pins and desktop shortcuts
  // over on first login.
  const lookRow = el('label');
  lookRow.style.cssText = 'display:flex;gap:8px;align-items:flex-start;cursor:pointer;font-size:12px;padding:8px;margin-top:8px;border:1.5px solid var(--border);border-radius:6px';
  lookRow.innerHTML = `<input type="checkbox" ${state.config.windowsLook ? 'checked' : ''} style="margin-top:1px">
    <span><b>Make it feel like Windows</b><br><span style="color:var(--text-muted)">Bring your wallpaper, accent color, keyboard layout, taskbar pins and desktop shortcuts over. Off keeps the desktop's own look.</span></span>`;
  lookRow.querySelector('input').onchange = (e) => { state.config.windowsLook = e.target.checked; };
  if (state.config.windowsLook) lookRow.style.borderColor = 'var(--primary)';
  fields.appendChild(lookRow);

  const advanced = el('details');
  advanced.style.cssText = 'margin-top:6px;border:1px solid var(--border);border-radius:6px;padding:7px 9px';
  advanced.innerHTML = `<summary style="cursor:pointer;font-size:12px;font-weight:600">Advanced boot options</summary>`;
  const bootChoice = el('label');
  bootChoice.style.cssText = 'display:flex;gap:8px;margin-top:8px;font-size:12px;align-items:flex-start';
  bootChoice.innerHTML = `<input type="checkbox" ${state.config.bootloader === 'systemd-boot' ? 'checked' : ''}><span>Use systemd-boot<br><span style="color:var(--text-muted)">Required by composefs images. Uses a bundled EFI binary and ESP-synced kernel entries.</span></span>`;
  bootChoice.querySelector('input').onchange = e => { state.config.bootloader = e.target.checked ? 'systemd-boot' : 'grub2'; render(); };
  advanced.appendChild(bootChoice);
  if (state.config.bootloader === 'systemd-boot') {
    const sb = el('div');
    sb.style.cssText = 'font-size:11.5px;color:var(--warning);margin-top:7px';
    sb.textContent = state.sysinfo?.secureBootKnown === false
      ? 'Secure Boot status is unknown. Installation requires a verified Microsoft-trusted shim plus vendor-signed systemd-boot chain.'
      : state.sysinfo?.secureBootOn
        ? 'Secure Boot is enabled. systemd-boot requires a verified shim plus vendor-signed loader chain; otherwise choose GRUB2.'
        : 'Secure Boot is off. The bundled unsigned systemd-boot path is supported.';
    advanced.appendChild(sb);
  }
  fields.appendChild(advanced);

  const hint = el('div');
  hint.id = 'install-hint';
  hint.style.cssText = 'font-size:11.5px;color:var(--text-muted);min-height:15px;margin-top:2px';
  fields.appendChild(hint);

  screen.appendChild(fields);

  // Footer
  const footer = el('div', 'footer');
  const installBtn = btn(`${installVerb()} →`, 'btn btn-primary', () => startInstall());
  installBtn.id = 'install-btn';
  footer.appendChild(btn('Cancel', 'btn btn-ghost', () => window.wails?.Quit?.()));
  // Try-in-VM (§6.1): only when a fresh-build VM is possible on this host.
  if (state.freshVmCapability?.available && state.selected) {
    footer.appendChild(btn('Try in VM', 'btn btn-ghost', () => tryInVM()));
  }
  footer.appendChild(installBtn);
  // Defer validity to after mount so the hint element exists.
  setTimeout(refreshInstallValidity, 0);

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

// ── Try in VM (§6.1) ──────────────────────────────────────────────────────────

async function tryInVM() {
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

async function installPreviewForReal() {
  try {
    await InstallPreviewForReal({
      imageRef:   state.selected.imageRef,
      diskSizeGB: state.config.diskSizeGB,
      username:   state.config.username,
      password:   state.config.password,
      hostname:   state.config.hostname,
      bootloader: state.config.bootloader,
      composeFs:  state.config.composeFs,
      encryption: state.config.encryption,
      luksPassphrase: state.config.luksPassphrase,
      windowsLook: state.config.windowsLook,
    });
    state.screen = 'done';
    render();
  } catch (e) {
    alert('Could not finalize the install: ' + e);
  }
}

function renderVMPreviewScreen() {
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
      <h2>Your preview is running</h2>
      <div style="color:var(--text-muted);max-width:440px">${state.selected?.name || 'TunaOS'} is booting in its own window — try it out. If you like it, install it for real using the same disk (no re-download, no re-deploy).</div>`;
    const row = el('div'); row.style.cssText = 'display:flex;gap:10px;margin-top:8px';
    row.appendChild(btn('Not now', 'btn btn-ghost', () => { state.screen = 'launchpad'; render(); }));
    row.appendChild(btn('Install for Real →', 'btn btn-primary', () => installPreviewForReal()));
    screen.appendChild(row);
  } else {
    const pct = Math.round(p.percent || 0);
    screen.innerHTML = `<div style="font-size:40px">🔨</div>
      <h2>Building your preview…</h2>
      <div style="color:var(--text-muted);max-width:440px">${p.message || 'Working…'}</div>
      <div style="width:60%;max-width:360px;height:8px;background:var(--border);border-radius:4px;overflow:hidden;margin-top:8px">
        <div style="width:${pct}%;height:100%;background:var(--primary);transition:width .3s"></div>
      </div>
      <div style="font-size:12px;color:var(--text-muted)">${pct}%</div>`;
  }
  wrap.appendChild(screen);
  return wrap;
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
    scroll.appendChild(appsSection);
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
  none:     { label: 'Re-link needed', cls: '' },
};

function renderAppRow(a) {
  const row = el('div');
  row.style.cssText = 'display:flex;align-items:center;gap:12px;background:var(--bg-card);border:1.5px solid var(--border);border-radius:8px;padding:10px 16px';
  const badge = SESSION_BADGE[a.session] || SESSION_BADGE.signin;
  row.innerHTML = `
    <span style="font-size:18px">${APP_ICONS[a.app] || '📦'}</span>
    <div style="flex:1;min-width:0">
      <div style="font-weight:600;font-size:13px;text-transform:capitalize">${a.app}</div>
      <div style="font-size:11.5px;color:var(--text-muted);margin-top:1px">${a.note || ''}</div>
    </div>
    <span class="chip ${badge.cls}" style="flex-shrink:0">${badge.label}</span>
  `;
  return row;
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
    window.wails?.Quit?.();
  } catch (e) {
    alert('Uninstall hit a problem: ' + e);
  }
}

// ── Actions ───────────────────────────────────────────────────────────────────

// Gate the Install button on a valid form and show the reason why not.
function refreshInstallValidity() {
  const btn = document.getElementById('install-btn');
  const hint = document.getElementById('install-hint');
  if (!btn) return;
  const c = state.config;
  let reason = '';
  if (!state.selected) reason = 'Choose a variant above.';
  else if (!c.username.trim()) reason = 'Enter a Linux username.';
  else if (!/^[a-z_][a-z0-9_-]*$/.test(c.username)) reason = 'Username must be lowercase letters, digits, - or _.';
  else if (!c.password) reason = 'Set a password.';
  else if (c.password !== (c.passwordConfirm || '')) reason = 'Passwords do not match.';
  else if (c.encryption === 'luks-passphrase' && !c.luksPassphrase) reason = 'Set a LUKS passphrase, or switch to TPM or no encryption.';
  else if (!state.selected?.imageRef || !/^ghcr\.io\/(tuna-os|ublue-os|projectbluefin)\//.test(state.selected.imageRef)) reason = 'Choose a supported TunaOS, Universal Blue, or Bluefin image.';
  btn.disabled = reason !== '';
  if (hint) {
    hint.textContent = reason;
    hint.style.color = reason ? 'var(--danger)' : 'var(--text-muted)';
  }
}

function applyImageDefaults(image) {
  if (!image) return;
  state.config.bootloader = image.bootloader || (image.family === 'el10' ? 'grub2' : 'systemd-boot');
  state.config.composeFs = image.composeFs !== undefined ? !!image.composeFs : state.config.bootloader === 'systemd-boot';
}

async function startInstall() {
  if (!state.selected) return;
  state.screen = 'progress';
  state.progress = { step: '', message: '', percent: 0, completedSteps: [], error: null };
  render();

  try {
    // BitLocker: resolve where Linux will live before the pipeline runs.
    let storageDrive = '';
    if (state.sysinfo?.bitLockerOn) {
      const mode = state.config.bitlockerMode || 'create';
      if (mode.startsWith('use:')) {
        storageDrive = mode.slice(4);
      } else {
        state.progress.step = 'Creating space for Linux';
        state.progress.message = 'Making an unencrypted partition (C: stays encrypted)…';
        renderProgress();
        const part = await CreateDataPartition(state.config.diskSizeGB + 5);
        storageDrive = part.letter;
      }
    }

    await StartInstall({
      imageRef:   state.selected.imageRef,
      diskSizeGB: state.config.diskSizeGB,
      username:   state.config.username,
      password:   state.config.password,
      hostname:   state.config.hostname,
      bootloader: state.config.bootloader,
      composeFs:  state.config.composeFs,
      storageDrive,
      encryption:     state.config.encryption,
      luksPassphrase: state.config.luksPassphrase,
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

// BitLocker chooser: keep C: encrypted, put Linux on an unencrypted
// volume — either an existing one or a new partition carved from C:.
function renderBitlockerChooser() {
  const wrap = el('div');
  wrap.appendChild(warningBanner(
    "Your C: drive is encrypted with BitLocker. Linux needs an unencrypted place to live — " +
    "we'll keep C: fully encrypted and set up a separate space just for Linux. Nothing on C: is decrypted."
  ));

  const box = el('div');
  box.style.cssText = 'background:var(--bg-card);border:1.5px solid var(--border);border-radius:8px;padding:12px 14px;margin-top:8px;display:flex;flex-direction:column;gap:8px';

  const existing = (state.sysinfo.dataPartitions || []).filter(p => !p.encrypted && p.freeGB >= state.config.diskSizeGB);
  const opt = (id, title, sub, checked) => {
    const row = el('label');
    row.style.cssText = 'display:flex;gap:10px;align-items:flex-start;cursor:pointer;font-size:12.5px';
    row.innerHTML = `<input type="radio" name="blmode" value="${id}" ${checked ? 'checked' : ''} style="margin-top:2px">
      <span><b>${title}</b><br><span style="color:var(--text-muted)">${sub}</span></span>`;
    row.querySelector('input').onchange = () => { state.config.bitlockerMode = id; refreshInstallValidity(); };
    return row;
  };

  // Default to creating a partition (always available); existing volumes first if present.
  if (existing.length) {
    existing.forEach(p => {
      box.appendChild(opt('use:' + p.letter,
        `Use drive ${p.letter}: ${p.label ? '(' + p.label + ')' : ''}`,
        `${Math.round(p.freeGB)} GB free, unencrypted — Linux will live here.`,
        state.config.bitlockerMode === 'use:' + p.letter));
    });
  }
  box.appendChild(opt('create',
    'Create a new space for Linux (recommended)',
    `Shrinks C: by ${state.config.diskSizeGB} GB and makes a new unencrypted drive just for Linux. C: stays BitLocker-protected.`,
    !state.config.bitlockerMode || state.config.bitlockerMode === 'create' || !existing.length));

  wrap.appendChild(box);
  if (!state.config.bitlockerMode) state.config.bitlockerMode = existing.length ? 'use:' + existing[0].letter : 'create';
  return wrap;
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

// ── E2E drive mode ────────────────────────────────────────────────────────────
// Wails' WebView cannot expose CDP (both loaders drop the env var once the
// framework passes its own browser args), so the GUI E2E drives the REAL form
// through this loop instead: a directive arrives over the same Go<->JS bridge
// every user click crosses, is executed as DOM events against the live
// widgets (same handlers, same validation), and state is reported back.
// E2EDriveDirective returns "" unless the app runs with WOOTC_E2E_DRIVE=1.
function e2eFill(sel, value) {
  const inp = document.querySelector(sel);
  if (!inp) return false;
  inp.value = value;
  inp.dispatchEvent(new Event('input'));
  if (inp.oninput) inp.oninput();
  return true;
}

function e2eFieldByLabel(label) {
  for (const f of document.querySelectorAll('.field')) {
    const l = f.querySelector('label');
    if (l && l.textContent === label) return f.querySelector('input');
  }
  return null;
}

async function e2eDriveLoop() {
  let raw = '';
  try { raw = await E2EDriveDirective(); } catch { return; }  // binding absent: stop
  try {
    if (raw) {
      const d = JSON.parse(raw);
      if (d.action === 'install' && !window.__e2eInstallDriven && state.screen === 'launchpad') {
        const img = e2eFieldByLabel('Custom supported OCI image');
        const user = e2eFieldByLabel('Linux Username');
        const host = e2eFieldByLabel('Hostname');
        const pws = document.querySelectorAll('input[type=password]');
        if (img && user && host && pws.length >= 2) {
          [[img, d.image], [user, d.username], [host, d.hostname],
           [pws[0], d.password], [pws[1], d.password]].forEach(([inp, v]) => {
            inp.value = v;
            if (inp.oninput) inp.oninput();
          });
          const btn = document.getElementById('install-btn');
          if (btn && !btn.disabled) {
            window.__e2eInstallDriven = true;
            btn.click();
          }
        }
      }
      if (d.action === 'reboot' && state.screen === 'done' && !window.__e2eRebootDriven) {
        window.__e2eRebootDriven = true;
        Reboot();
      }
    }
    await E2EDriveReport(JSON.stringify({
      screen: state.screen,
      installDriven: !!window.__e2eInstallDriven,
      installBtnDisabled: (document.getElementById('install-btn') || {}).disabled ?? null,
      hint: (document.getElementById('install-hint') || {}).textContent || '',
      progressStep: state.progress?.step || '',
      error: state.progress?.error || null,
    }));
  } catch (e) { /* drive mode must never break the app */ }
  setTimeout(e2eDriveLoop, 2000);
}

init().catch(console.error);
e2eDriveLoop();
