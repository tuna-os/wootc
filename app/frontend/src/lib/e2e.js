import { E2EDriveDirective, E2EDriveReport, Reboot } from '../../wailsjs/go/main/App';

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
  if (window.__e2eInstallDriven || state.screen !== 'launchpad') return;

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

  const installButton = document.getElementById('install-btn');
  if (installButton && !installButton.disabled) {
    window.__e2eInstallDriven = true;
    installButton.click();
  }
}

async function reportState(state) {
  await E2EDriveReport(JSON.stringify({
    screen: state.screen,
    installDriven: !!window.__e2eInstallDriven,
    installBtnDisabled: (document.getElementById('install-btn') || {}).disabled ?? null,
    hint: (document.getElementById('install-hint') || {}).textContent || '',
    progressStep: state.progress?.step || '',
    error: state.progress?.error || null,
  }));
}

export function startE2EDrive(state) {
  async function driveLoop() {
    let raw = '';
    try {
      raw = await E2EDriveDirective();
    } catch {
      return; // Optional binding is absent outside E2E builds.
    }

    try {
      if (raw) {
        const directive = JSON.parse(raw);
        if (directive.action === 'install') driveInstall(directive, state);
        if (directive.action === 'reboot' && state.screen === 'done' && !window.__e2eRebootDriven) {
          window.__e2eRebootDriven = true;
          Reboot();
        }
      }
      await reportState(state);
    } catch {
      // Drive mode is diagnostic and must never break the application.
    }
    setTimeout(driveLoop, 2000);
  }

  driveLoop();
}
