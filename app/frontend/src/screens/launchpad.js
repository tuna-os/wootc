import { StartInstall, CreateDataPartition, DefragDrive } from '../../wailsjs/go/main/App';
import { Quit } from '../../wailsjs/runtime/runtime';
import { state } from '../lib/state.js';
import { render } from '../lib/render.js';
import { installVerb, distroName, productName } from '../lib/branding.js';
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
    <div class="screen-title">${installVerb()} ${distroName()}</div>
    <div class="screen-subtitle">${state.brand?.tagline || `Try Linux alongside Windows — no repartitioning, nothing deleted, and fully undoable. Pick a look, set a password, and ${productName()} does the rest.`}</div>
  `;
  screen.appendChild(hdr);

  // Honesty on relaunch: if the last attempt failed, say so — the old
  // behavior greeted a failed install with silence (or, when root.disk
  // existed, with "an existing installation was found").
  if (state.lastRun?.state === 'failed') {
    screen.appendChild(warningBanner(
      `<b>Your last install attempt didn't finish</b> (stopped at "${state.lastRun.phase || 'an early step'}"). ` +
      'Nothing outside the wootc folder was changed and no Linux boot is armed. ' +
      'You can simply try again below.'
    ));
  }

  // System info chips
  if (state.sysinfo) {
    const si = el('div', 'sysinfo');
    si.appendChild(chip(`💾 ${Math.round(state.sysinfo.freeDiskGB)} GB free`, false));
    si.appendChild(chip(state.sysinfo.isUefi ? '⚡ UEFI' : '🔌 BIOS', false));
    if (state.sysinfo.secureBootOn)  si.appendChild(chip('🔒 Secure Boot', false));
    if (state.sysinfo.bitLockerOn)   si.appendChild(chip('⚠ BitLocker On', true));
    if (state.sysinfo.fastStartupOn) {
      // A bare "⚠ Fast Startup" named a thing the user has never heard of
      // and explained nothing. Say what happens about it.
      const fs = chip('⚠ Fast Startup on', true);
      fs.title = 'Windows Fast Startup keeps the disk half-asleep between boots, which would ' +
        `corrupt files shared with Linux. ${productName()} turns it off during setup — startup may look ` +
        'slightly different afterwards, and everything else is unaffected.';
      si.appendChild(fs);
    }
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
    // A branded build shows its real mark on its own catalog cards; emoji
    // remain only where they are the actual branding (generic TunaOS build).
    const art = state.brand?.logoDataUri
      ? `<img class="image-emoji" src="${state.brand.logoDataUri}" alt="">`
      : `<span class="image-emoji">${img.emoji}</span>`;
    card.innerHTML = `
      <div class="image-card-header">
        ${art}
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

  // A branded installer installs its own distribution — the custom-ref field
  // is hidden outright (hideCustomImage), on top of the channel gate. It is a
  // power-user control, so it lives under Advanced with the other overrides.
  const customRef = (state.policy?.customImageAllowed !== false && !state.brand?.hideCustomImage) ? inputField('Custom supported OCI image', 'text', state.config.customImageRef || '', v => {
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

  // Config fields.
  //
  // The default form asks for as little as a Mac's first-run setup would: a
  // password, nothing else. Everything else has a solid default — identity
  // mirrored from this PC, disk sized from free space, TPM-backed encryption,
  // Windows look and Wi-Fi brought along — and every default is inspectable
  // and changeable under Advanced. A control only earns a place on the main
  // form when it is a question we genuinely cannot answer for the user
  // (BitLocker placement, a missing identity).
  const fields = el('div', 'fields');

  // Disk size slider. The slider must not offer sizes C: cannot hold: the
  // audit found a user with 30 GB free could drag to 500 GB and learn about
  // it from a raw allocation error mid-install. Cap the range at what fits
  // (leaving DISK_HEADROOM_GB for Windows itself), and gate the button too.
  const diskField = el('div', 'field');
  diskField.innerHTML = `<label>Virtual Disk Size</label>`;
  const sliderRow = el('div', 'slider-row');
  const slider = document.createElement('input');
  const maxFit = maxDiskSizeGB();
  slider.type = 'range'; slider.min = '20'; slider.max = String(Math.max(20, Math.min(500, maxFit))); slider.step = '5';
  if (state.config.diskSizeGB > maxFit && maxFit >= 20) {
    state.config.diskSizeGB = Math.floor(maxFit / 5) * 5;
  }
  slider.value = String(state.config.diskSizeGB);
  const sliderVal = el('span', 'slider-val');
  sliderVal.textContent = `${state.config.diskSizeGB} GB`;
  slider.oninput = () => {
    state.config.diskSizeGB = Number(slider.value);
    sliderVal.textContent = `${state.config.diskSizeGB} GB`;
    refreshInstallValidity();
  };
  const freeNote = el('div');
  freeNote.style.cssText = 'font-size:11.5px;color:var(--text-muted);margin-top:3px';
  freeNote.textContent = state.sysinfo ? `Available: ${Math.round(state.sysinfo.freeDiskGB)} GB on C:` : '';
  sliderRow.appendChild(slider);
  sliderRow.appendChild(sliderVal);
  diskField.appendChild(sliderRow);
  diskField.appendChild(freeNote);

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

  // Password — in the normal derived-identity case, the ONLY thing the
  // default form asks the user to type.
  const row2 = el('div', 'field-row');
  row2.appendChild(inputField('Password', 'password', state.config.password, v => { state.config.password = v; refreshInstallValidity(); }, ''));
  row2.appendChild(inputField('Confirm Password', 'password', state.config.passwordConfirm || '', v => { state.config.passwordConfirm = v; refreshInstallValidity(); }, ''));
  fields.appendChild(row2);

  // Say what the defaults will do rather than asking about each one — trust
  // is built by naming the plan, not by a wall of controls.
  const plan = el('div');
  plan.id = 'plan-note';
  plan.style.cssText = 'font-size:11.5px;color:var(--text-muted);margin-top:2px';
  fields.appendChild(plan);

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
      <span><b>${title}${recommended ? ' <span style="color:var(--accent);font-size:10px;font-weight:500">RECOMMENDED</span>' : ''}</b><br><span style="color:var(--text-muted)">${sub}</span></span>`;
    row.querySelector('input').onchange = () => { state.config.encryption = value; refreshInstallValidity(); render(); };
    // Visual highlight for selected option
    if (checked) row.style.borderColor = 'var(--accent)';
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

  // Windows-Style Mode (SPEC §4.4) — ON by default: everything safe to bring
  // along comes along (wallpaper, accent, keyboard layout, taskbar pins,
  // desktop shortcuts), the same way a Mac migration would. Advanced holds
  // the opt-out for anyone who wants the image maker's stock desktop.
  const lookRow = el('label');
  lookRow.style.cssText = 'display:flex;gap:8px;align-items:flex-start;cursor:pointer;font-size:12px;padding:8px;margin-top:8px;border:1.5px solid var(--border);border-radius:6px';
  lookRow.innerHTML = `<input type="checkbox" ${state.config.windowsLook ? 'checked' : ''} style="margin-top:1px">
    <span><b>Make it feel like Windows</b><br><span style="color:var(--text-muted)">Bring your wallpaper, accent color, keyboard layout, taskbar pins and desktop shortcuts over. Off keeps the desktop's own look.</span></span>`;
  lookRow.querySelector('input').onchange = (e) => { state.config.windowsLook = e.target.checked; };
  if (state.config.windowsLook) lookRow.style.borderColor = 'var(--accent)';

  // Auth-token migration is a separate, explicit opt-in from look/data
  // migration. The backend defaults every app to off and still refuses
  // Discord/Slack because those services prefer relinking.
  let sessionBox = null;
  const movableSessions = state.sessionCandidates.filter(c => c.portable && c.recommend === 'copy');
  if (movableSessions.length) {
    sessionBox = el('div');
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

  // The solid-default controls: sized, chosen, and switched on for the user,
  // adjustable here without ever being questions on the main form.
  diskField.style.marginTop = '8px';
  advanced.appendChild(diskField);
  encSection.style.marginTop = '10px';
  advanced.appendChild(encSection);
  advanced.appendChild(lookRow);
  if (sessionBox) advanced.appendChild(sessionBox);
  if (customRef) {
    customRef.style.marginTop = '8px';
    advanced.appendChild(customRef);
  }

  const bootChoice = el('label');
  bootChoice.style.cssText = 'display:flex;gap:8px;margin-top:8px;font-size:12px;align-items:flex-start';
  bootChoice.innerHTML = `<input type="checkbox" ${state.config.bootloader === 'systemd-boot' ? 'checked' : ''}><span>Force systemd-boot<br><span style="color:var(--text-muted)">Off (recommended): ${productName()} detects the image's boot method automatically and uses the Secure-Boot-signed chain. On: boots the installer with a bundled systemd-boot EFI binary instead.</span></span>`;
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

// Windows needs working room on C: after the disk file lands; below this the
// OS itself degrades (updates fail, hibernation file has no home). The same
// number gates the slider range and the install button.
const DISK_HEADROOM_GB = 15;

// The largest root disk C: can actually hold, honoring the headroom. The
// BitLocker carve path sizes from the same user choice, so one cap serves
// both. Unknown free space (no sysinfo yet) imposes no cap.
function maxDiskSizeGB() {
  const free = state.sysinfo?.freeDiskGB;
  if (!free || free <= 0) return 500;
  return Math.floor(free - DISK_HEADROOM_GB);
}

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
    reason = `Windows is hibernated, so the drive holds unsaved changes. Shut down fully (Start ▸ Power ▸ Shut down while holding Shift) and start ${productName()} again — migrating now could damage your files.`;
  else if (si?.pendingReboot)
    reason = `Windows has an update waiting to finish (${si.pendingRebootReason || 'servicing'}). Restart the PC, let it complete, then run ${productName()} again — an update finishing mid-migration can break startup.`;
  else if (si?.onBattery && si?.batteryKnown)
    reason = 'Plug in the power adapter first. Losing power partway through would leave the PC in a half-converted state.';
  else if (si && si.is64Bit === false)
    reason = `This PC has a 32-bit version of Windows. ${productName()} installs 64-bit Linux, which this PC cannot start.`;
  else if (si && si.ramGB > 0 && si.ramGB < 3.5)
    reason = `This PC has ${si.ramGB.toFixed(1)} GB of memory. ${distroName()} needs at least 3.5 GB to run properly.`;
  // Green-gate: block scenarios this channel has not proven (docs/RELEASING.md).
  else if (state.sysinfo?.bitLockerOn && state.policy && state.policy.bitlockerSupported === false)
    reason = `BitLocker encryption isn't supported in the ${state.policy.channel} yet — it's coming soon. For now, ${productName()} needs drive encryption turned off.`;
  else if (state.sysinfo && state.sysinfo.freeDiskGB > 0 && maxDiskSizeGB() < 20)
    reason = `C: has only ${Math.round(state.sysinfo.freeDiskGB)} GB free — not enough for Linux (20 GB) plus the ${DISK_HEADROOM_GB} GB Windows needs to keep working. Free up some space first.`;
  else if (state.sysinfo && state.sysinfo.freeDiskGB > 0 && c.diskSizeGB > maxDiskSizeGB())
    reason = `C: has ${Math.round(state.sysinfo.freeDiskGB)} GB free, and Windows needs about ${DISK_HEADROOM_GB} GB of that to keep working. Choose ${maxDiskSizeGB()} GB or less — or free up space first.`;
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
  refreshPlanNote();
}

// The main form asks one question and states the plan for everything it did
// not ask. Every input handler funnels through refreshInstallValidity, so the
// promise text tracks Advanced adjustments (disk size, hostname, look) live.
function refreshPlanNote() {
  const note = document.getElementById('plan-note');
  if (!note) return;
  const c = state.config;
  const disk = state.sysinfo?.bitLockerOn
    ? `${c.diskSizeGB} GB set aside for Linux`
    : `${c.diskSizeGB} GB for Linux (space is only used as you fill it)`;
  const named = c.hostname ? `this PC keeps its name (“${c.hostname}”)` : 'a computer name is set for you';
  const brings = c.windowsLook
    ? 'your files, Wi-Fi and the Windows look come along'
    : 'your files and Wi-Fi come along';
  note.textContent = `Everything else is taken care of: ${disk}, ${named}, and ${brings}. Adjust under Advanced.`;
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
      // windowsLook was silently dropped here for as long as the checkbox
      // existed — the backend's collect step gated on a field that never
      // arrived, so no real GUI install ever brought the look (or, worse,
      // Wi-Fi) along. The field must travel with the config it belongs to.
      windowsLook:    state.config.windowsLook,
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
