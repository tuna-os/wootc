import { StartInstall, CreateDataPartition, DefragDrive } from '../../wailsjs/go/main/App';
import { Quit } from '../../wailsjs/runtime/runtime';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { installVerb } from '../lib/branding.js';
import { el, btn, chip, warningBanner, inputField } from '../lib/ui.js';
import { renderProgress } from './progress.js';
import { tryInVM } from './vmpreview.js';

// ── Screen 1: Launchpad ───────────────────────────────────────────────────────

export function renderLaunchpad() {
  const screen = el('div', 'screen');

  // Header. The subtitle answers the first question a nervous Windows user
  // brings to this screen — "will this erase my stuff?" — before anything
  // else asks them to make a choice.
  const hdr = el('div');
  hdr.innerHTML = `
    <div class="screen-title">${installVerb()} TunaOS</div>
    <div class="screen-subtitle">${state.brand?.tagline || 'Try Linux alongside Windows — no repartitioning, nothing deleted, and fully undoable. Pick a look, set a password, and wootc does the rest.'}</div>
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
    // Recovery-key warning (#63): tell the user to record their key before
    // proceeding, regardless of whether we unlock C: or carve a separate
    // volume. This is honest disclosure — independent of #61.
    if (state.sysinfo?.bitLockerRecoveryKeyWarning) {
      screen.appendChild(warningBanner(
        '<b>⚠ Before you continue:</b> Make sure you have your BitLocker recovery key. ' +
        'Your PC uses BitLocker to protect drive C:. If the migration encounters trouble, ' +
        'you need that key to get back into Windows. You can find it at ' +
        '<b>Control Panel → BitLocker Drive Encryption → Back up recovery key</b>, ' +
        'or in your Microsoft account under Devices.'
      ));
    }
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
    card.__imgRef = img.imageRef;  // drive-mode E2E uses this to match
    card.onclick = () => { state.selected = img; applyImageDefaults(img); render(); };
    grid.appendChild(card);
  });
  screen.appendChild(grid);

  const customRef = state.policy?.customImageAllowed !== false ? inputField('Custom supported OCI image', 'text', state.config.customImageRef || '', v => {
    state.config.customImageRef = v.trim();
    if (/^ghcr\.io\/(tuna-os|ublue-os|projectbluefin)\/[a-z0-9][a-z0-9._/-]*(?::[A-Za-z0-9._-]+|@sha256:[a-f0-9]{64})$/.test(state.config.customImageRef)) {
      // Default a custom ref to the grub2/ostree path — the measured backend
      // of every supported family except dakota (docs/backend-contract.md),
      // and the only path that needs no bundled systemd-boot EFI. Guessing
      // systemd-boot here sent a bluefin:lts install into "systemd-boot is
      // not bundled" (run 20260723T1100); the deployer's own probe corrects
      // the backend at deploy time either way.
      state.selected = { id: 'custom', name: 'Custom image', imageRef: state.config.customImageRef, bootloader: 'auto', composeFs: false };
      applyImageDefaults(state.selected);
      render();
    }
    refreshInstallValidity();
  }, 'ghcr.io/ublue-os/image:tag') : null;
  if (customRef) screen.appendChild(customRef);

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

  // Identity. Both default from this Windows machine (#174), so in the normal
  // case there is nothing to type here and the row moves under Advanced —
  // leaving a password as the only thing the default form asks for.
  //
  // When either could NOT be derived the row stays on the main form. Install
  // validation requires a username, so hiding an empty one behind a collapsed
  // panel would disable the button and point at a field the user cannot see.
  const identityDerived = Boolean(state.config.username && state.config.hostname);
  const idRow = el('div', 'field-row');
  idRow.appendChild(inputField('Linux Username', 'text', state.config.username,
    v => { state.config.username = v; refreshInstallValidity(); },
    state.sysinfo?.suggestedUsername || 'user'));
  idRow.appendChild(inputField('Computer name', 'text', state.config.hostname,
    v => { state.config.hostname = v; refreshInstallValidity(); },
    state.sysinfo?.suggestedHostname || 'tunaos'));
  if (!identityDerived) fields.appendChild(idRow);

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

  // Auth-token migration is a separate, explicit opt-in from look/data
  // migration. The backend defaults every app to off and still refuses
  // Discord/Slack because those services prefer relinking.
  const movableSessions = state.sessionCandidates.filter(c => c.portable && c.recommend === 'copy');
  if (movableSessions.length) {
    const sessionBox = el('div');
    sessionBox.style.cssText = 'margin-top:8px;padding:8px;border:1.5px solid var(--border);border-radius:6px';
    sessionBox.innerHTML = `<div style="font-size:12px;font-weight:600">Signed-in app sessions</div><div style="font-size:11.5px;color:var(--text-muted);margin-top:2px">Optional: move these sessions while Windows is online. Off means you will sign in once on Linux.</div>`;
    movableSessions.forEach(candidate => {
      const row = el('label');
      row.style.cssText = 'display:flex;gap:8px;align-items:flex-start;cursor:pointer;font-size:12px;margin-top:7px';
      const checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      checkbox.checked = !!state.config.sessionConsent[candidate.app];
      checkbox.style.marginTop = '1px';
      checkbox.onchange = () => { state.config.sessionConsent[candidate.app] = checkbox.checked; };
      const copy = el('span');
      copy.innerHTML = `<b style="text-transform:capitalize">${candidate.app}</b><br><span style="color:var(--text-muted)">${candidate.note}</span>`;
      row.appendChild(checkbox);
      row.appendChild(copy);
      sessionBox.appendChild(row);
    });
    fields.appendChild(sessionBox);
  }

  const advanced = el('details');
  // Every control change re-renders the form; without persisting the open
  // state the panel snaps shut on each toggle — the user opens Advanced,
  // clicks a checkbox, and watches their panel vanish.
  if (state.advancedOpen) advanced.open = true;
  advanced.addEventListener('toggle', () => { state.advancedOpen = advanced.open; });
  advanced.style.cssText = 'margin-top:6px;border:1px solid var(--border);border-radius:6px;padding:7px 9px';
  advanced.innerHTML = `<summary style="cursor:pointer;font-size:12px;font-weight:600">Advanced</summary>`;

  // The identity row built above lands here when it was derived successfully;
  // otherwise it stayed on the main form where the user can actually see it.
  if (identityDerived) {
    const idNote = el('div');
    idNote.style.cssText = 'font-size:11.5px;color:var(--text-muted);margin-top:8px';
    idNote.textContent = 'Taken from this PC. Change these only if you want different ones on Linux.';
    advanced.appendChild(idNote);
    idRow.style.cssText = 'margin-top:6px';
    advanced.appendChild(idRow);
  }

  const bootChoice = el('label');
  bootChoice.style.cssText = 'display:flex;gap:8px;margin-top:8px;font-size:12px;align-items:flex-start';
  bootChoice.innerHTML = `<input type="checkbox" ${state.config.bootloader === 'systemd-boot' ? 'checked' : ''}><span>Force systemd-boot<br><span style="color:var(--text-muted)">Off (recommended): wootc detects the image's boot method automatically and uses the Secure-Boot-signed chain. On: boots the installer with a bundled systemd-boot EFI binary instead.</span></span>`;
  bootChoice.querySelector('input').onchange = e => { state.config.bootloader = e.target.checked ? 'systemd-boot' : 'auto'; render(); };
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
  footer.appendChild(btn('Cancel', 'btn btn-ghost', () => Quit()));
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

// ── Actions ───────────────────────────────────────────────────────────────────

// Gate the Install button on a valid form and show the reason why not.
function refreshInstallValidity() {
  const btn = document.getElementById('install-btn');
  const hint = document.getElementById('install-hint');
  if (!btn) return;
  const c = state.config;
  let reason = '';
  // Preflight safety gates (#63) come FIRST: these are conditions under which
  // starting at all risks the user's data or leaves the machine half-converted.
  // After the shrink there is no cheap undo, so they gate the button rather
  // than warning mid-run. Each names the single thing to fix.
  const si = state.sysinfo;
  if (si?.hibernated)
    reason = 'Windows is hibernated, so the drive holds unsaved changes. Shut down fully (Start ▸ Power ▸ Shut down while holding Shift) and start wootc again — migrating now could damage your files.';
  else if (si?.pendingReboot)
    reason = `Windows has an update waiting to finish (${si.pendingRebootReason || 'servicing'}). Restart the PC, let it complete, then run wootc again — an update finishing mid-migration can break startup.`;
  else if (si?.onBattery && si?.batteryKnown)
    reason = 'Plug in the power adapter first. Losing power partway through would leave the PC in a half-converted state.';
  else if (si && si.is64Bit === false)
    reason = 'This PC has a 32-bit version of Windows. wootc installs 64-bit Linux, which this PC cannot start.';
  else if (si && si.ramGB > 0 && si.ramGB < 3.5)
    reason = `This PC has ${si.ramGB.toFixed(1)} GB of memory. wootc needs at least 3.5 GB for the installed system to run properly.`;
  // Green-gate: block scenarios this channel has not proven (docs/RELEASING.md).
  else if (state.sysinfo?.bitLockerOn && state.policy && state.policy.bitlockerSupported === false)
    reason = `BitLocker encryption isn't supported in the ${state.policy.channel} yet — it's coming soon. For now, wootc needs drive encryption turned off.`;
  else if (!state.selected) reason = 'Choose a variant above.';
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

export function applyImageDefaults(image) {
  if (!image) return;
  // The deployer probes the image and detects its backend definitively
  // (bootupd-shipped signed grub → ostree/grub2; systemd-boot only →
  // composefs-native). The catalog's bootloader/composeFs fields are DISPLAY
  // metadata — forcing them into the install config sent bonito (ostree per
  // the deploy-time probe) down the composefs path, and pointed composefs
  // images at the unsigned systemd-boot deployer chain that Secure Boot
  // rejects. 'auto' keeps the E2E-proven signed chain booting the deployer
  // on every image, and deploy.sh stages the right Phase 2 — this is the
  // configuration that took dakota green (run 30710282014).
  state.config.bootloader = 'auto';
  state.config.composeFs = false;
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
      sessionConsent: state.config.sessionConsent,
    });
  } catch (e) {
    state.progress.error = String(e);
    renderProgress();
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

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
