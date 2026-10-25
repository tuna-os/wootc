import { verifyInstalledBootUI } from './installed-boot-ui-proof.js';
import { E2EDriveDirective, E2EDriveReady, E2EDriveReport, Reboot } from '../../wailsjs/go/main/App';

// Wails' WebView cannot expose CDP, so GUI E2E drives the real form through
// the same Go-to-JS bridge and DOM event handlers used by the application.
// Accepts several acceptable labels for one field. User-facing copy is
// deliberately churny (#176 is an ongoing pass to plainer English), and
// driveInstall() bails silently when a lookup misses — so a pure wording
// change could disable the whole GUI E2E without failing anything loudly.
// Listing the aliases keeps a rename from becoming a silent test outage.
function fieldByLabel(...labels) {
  for (const field of document.querySelectorAll('.field')) {
    const fieldLabel = field.querySelector('label');
    if (fieldLabel && labels.includes(fieldLabel.textContent)) return field.querySelector('input');
  }
  return null;
}

function driveInstall(directive, state) {
  if (window.__e2eInstallRequested || state.screen !== 'launchpad') return;

  const imageInput = fieldByLabel('Custom supported OCI image');
  const username = fieldByLabel('Linux Username');
  const hostname = fieldByLabel('Computer name', 'Hostname');
  const passwords = document.querySelectorAll('input[type=password]');
  const encryption = directive.encryption || 'none';
  const encryptionRadio = document.querySelector(`input[name=encryption][value=${encryption}]`);

  if (encryptionRadio && !encryptionRadio.checked) {
    encryptionRadio.checked = true;
    if (encryptionRadio.onchange) encryptionRadio.onchange();
  }

  if (!imageInput && directive.image) {
    for (const card of document.querySelectorAll('.image-card')) {
      if (card.__imgRef === directive.image) {
        card.click();
        break;
      }
    }
  }

  if (!username || !hostname || passwords.length < 2) return;
  const fields = [
    [username, directive.username],
    [hostname, directive.hostname],
    [passwords[0], directive.password],
    [passwords[1], directive.password],
  ];
  if (imageInput) fields.unshift([imageInput, directive.image]);
  for (const [input, value] of fields) {
    input.value = value;
    if (input.oninput) input.oninput();
  }

  // INTEGRITY GATE: install ONLY the image the directive named. When the
  // requested image has no catalog card (e.g. status-gated out of GetImages)
  // and no custom-ref field is available, the selection silently stays the
  // DEFAULT — and clicking Install here would run a full green E2E against
  // the wrong distribution while the harness records the requested one
  // (run 32581422435 "bazzite" installed bluefin-lts exactly this way).
  // Refuse, and let reportState carry the mismatch so the harness fails
  // loudly instead of the run lying quietly.
  if (directive.image && state.selected?.imageRef !== directive.image) return;

  const installButton = document.getElementById('install-btn');
  if (installButton && !installButton.disabled) {
    // Do not replay a click whose handler may have partially run. A thrown
    // click also cannot become a successful drive observation on the next poll.
    window.__e2eInstallRequested = true;
    installButton.click();
    window.__e2eInstallDriven = true;
  }
}

async function drivePrepareVM(directive, state) {
  if (window.__e2ePrepareVMRequested || state.screen !== 'launchpad') return;
  await reportState(state, directive);

  // Selecting a catalog card or applying a custom image re-renders the
  // launchpad. Do that first, then look up fresh input elements so the
  // remaining values are written into the controls the user can see.
  if (directive.image) {
    const currentRef = state.selected?.imageRef || '';
    const card = [...document.querySelectorAll('.image-card')]
      .find((candidate) => candidate.__imgRef === directive.image);
    const imageInput = fieldByLabel('Custom supported OCI image');
    if (card && currentRef !== directive.image) {
      card.click();
    } else if (!card && imageInput && currentRef !== directive.image) {
      imageInput.value = directive.image;
      if (imageInput.oninput) imageInput.oninput();
    }
  }

  if (directive.image && state.selected?.imageRef === directive.image) {
    await reportState(state, directive);
  }

  const username = fieldByLabel('Linux Username');
  const passwords = document.querySelectorAll('input[type=password]');
  if (!username || passwords.length < 2) return;

  username.value = directive.username || '';
  if (username.oninput) username.oninput();
  for (const password of passwords) {
    password.value = directive.password || '';
    if (password.oninput) password.oninput();
  }

  if (directive.image && state.selected?.imageRef !== directive.image) return;
  await reportState(state, directive);
  const button = document.getElementById('vm-prepare-btn');
  if (!button || button.disabled) return;

  window.__e2ePrepareVMRequested = true;
  button.click();
  window.__e2ePrepareVMDriven = true;
}

async function reportState(state, directive) {
  // The harness reads imageMismatch to fail FAST when the directive's image
  // cannot be selected (see the integrity gate in driveInstall) — the
  // alternative is a silent install of the default image.
  const wantRef = window.__e2eWantImage || '';
  const report = {
    schemaVersion: 1,
    runId: directive.runId,
    directiveId: directive.directiveId,
    action: directive.action,
    screen: state.screen,
    installDriven: !!window.__e2eInstallDriven,
    installBtnDisabled: (document.getElementById('install-btn') || {}).disabled ?? null,
    hint: (document.getElementById('install-hint') || {}).textContent || '',
    progressStep: state.progress?.step || '',
    error: state.progress?.error || null,
    selectedRef: state.selected?.imageRef || '',
    imageMismatch: !!(wantRef && state.screen === 'launchpad' &&
      !window.__e2eInstallDriven && state.selected?.imageRef !== wantRef),
  };
  // The installed-boot proof is the one report that carries a rendered
  // receipt; every other action keeps the exact base schema.
  if (directive.action === 'verify-installed-boot') {
    report.installedBootVerification = window.__e2eInstalledBootVerification || null;
  }
  if (directive.action === 'prepare-vm') Object.assign(report, {
    vmPrepareDriven: !!window.__e2ePrepareVMDriven,
    freshVmAvailable: !!state.freshVmCapability?.available,
    freshVmReason: state.freshVmCapability?.reason || '',
    vmPrepareButtonVisible: !!document.getElementById('vm-prepare-btn'),
    vmPrepareButtonDisabled: document.getElementById('vm-prepare-btn')?.disabled ?? null,
    vmRuntimeButtonVisible: [...document.querySelectorAll('button')]
      .some((button) => button.textContent.includes('Set up Linux in a window')),
    vmImageMismatch: !!(window.__e2eWantVMImage && state.screen === 'launchpad' &&
      !window.__e2ePrepareVMDriven && state.selected?.imageRef !== window.__e2eWantVMImage),
    vmReady: !!state.vmReady,
    vmProgressStage: state.vmProgress?.stage || '',
  });
  await E2EDriveReport(JSON.stringify(report));
}

export function startE2EDrive(state) {
  async function driveLoop() {
    // A missing binding throws SYNCHRONOUSLY (a non-E2E build has nothing
    // to drive, so stop). A rejected promise is a TRANSIENT backend failure
    // and must not stop the loop the same way: returning here killed all
    // polling permanently on one bad read, leaving a live app that never
    // reports again. Same split as main.js session candidates.
    let call;
    try {
      call = E2EDriveDirective();
    } catch {
      return; // Optional binding is absent outside E2E builds.
    }
    let raw = '';
    try {
      raw = await call;
    } catch {
      // Transient failure: fall through to the readiness signal and retry
      // on the next poll.
    }
    // A UTF-8 BOM prefix is not JSON whitespace: JSON.parse throws on it.
    // The harness wrote the install directive with a BOM through run
    // 36420437461, so every poll died here and no report was ever written.
    // The writer is fixed and Go strips it too; this keeps any BOM'd
    // producer from silently disabling the loop again.
    raw = (raw || '').replace(/^\uFEFF/, '');

    try {
      if (!raw) {
        // No directive yet: the harness is still waiting for first render,
        // and a bound report is impossible without a directive to bind to.
        // Signal readiness on its own channel so launch is observable before
        // any directive exists. Diagnostic only; never breaks the app.
        try {
          await E2EDriveReady(JSON.stringify({ schemaVersion: 1, screen: state.screen || '' }));
        } catch {
          // Readiness is best-effort; the next poll retries.
        }
      }
      if (raw) {
        const directive = JSON.parse(raw);
        if (directive.schemaVersion !== 1 || typeof directive.runId !== 'string' ||
            !directive.runId || !/^[0-9a-f]{32}$/.test(directive.directiveId) ||
            !['install', 'reboot', 'prepare-vm', 'verify-installed-boot'].includes(directive.action)) throw new Error('Invalid drive identity');
        if (window.__e2eRunId && window.__e2eRunId !== directive.runId) throw new Error('Changed drive run');
        window.__e2eRunId = directive.runId;
        if (directive.action === 'install') {
          if (window.__e2eInstallDirectiveId && window.__e2eInstallDirectiveId !== directive.directiveId) {
            throw new Error('Changed install directive');
          }
          window.__e2eInstallDirectiveId = directive.directiveId;
        }
        if (directive.action === 'verify-installed-boot') {
          window.__e2eInstalledBootVerification = verifyInstalledBootUI(directive);
        }
        if (directive.action === 'install') {
          window.__e2eWantImage = directive.image || '';
          driveInstall(directive, state);
        }
        if (directive.action === 'prepare-vm') {
          if (window.__e2ePrepareVMDirectiveId && window.__e2ePrepareVMDirectiveId !== directive.directiveId) {
            throw new Error('Changed VM preparation directive');
          }
          window.__e2ePrepareVMDirectiveId = directive.directiveId;
          window.__e2eWantVMImage = directive.image || '';
          await drivePrepareVM(directive, state);
        }
        if (directive.action === 'reboot' && state.screen === 'done' && window.__e2eInstallDriven &&
            window.__e2eInstallDirectiveId === directive.directiveId && !window.__e2eRebootDriven) {
          window.__e2eRebootDriven = true;
          Reboot();
        }
        await reportState(state, directive);
      }
    } catch {
      // Drive mode is diagnostic and must never break the application.
    }
    setTimeout(driveLoop, 2000);
  }

  driveLoop();
}
