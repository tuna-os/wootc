// ── State ─────────────────────────────────────────────────────────────────────
//
// The one mutable object every screen reads and writes. Screens import it and
// mutate it in place, exactly as they did when this all lived in main.js, then
// ask for a repaint through lib/render.js — so there is still a single source
// of truth and a single way to get it on screen.

export const state = {
  screen: 'loading',   // loading | launchpad | progress | done | control | migrate
  mode: 'installer',   // installer (Windows) | migration (installed Linux)
  images: [],
  sysinfo: null,
  brand: null,         // partner/enterprise branding (themeable)
  categories: [],      // migration dashboard rows
  apps: [],            // detected app migrations
  sessionCandidates: [], // Windows-online DPAPI findings; never tokens
  office: null,        // MS Office → LibreOffice summary
  migrationProfile: null,
  look: null,
  converting: {},      // category id → percent while a conversion runs
  selected: null,      // selected Image
  config: {
    diskSizeGB: 40,
    username: '',
    password: '',
    hostname: 'tunaos',
    // 'auto' is the backend contract: the deployer probes the image and
    // picks the chain. 'systemd-boot' is the only explicit override the UI
    // offers (Advanced → Force systemd-boot).
    bootloader: 'auto',
    encryption: 'tpm2-luks',
    luksPassphrase: '',
    // ON by default: everything safe to migrate comes along (wallpaper,
    // accent, keyboard layout, pins, shortcuts) — Advanced holds the
    // opt-out for anyone who wants the image maker's stock desktop.
    windowsLook: true,
    sessionConsent: {},
  },
  progress: {
    step: '',
    message: '',
    percent: 0,
    completedSteps: [],
    error: null,
  },
};
