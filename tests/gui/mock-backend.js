// mock-backend.js — a fake Wails runtime injected before the app boots, so
// Playwright can drive the real frontend bundle on Linux without WebView2
// or the Go backend. Each scenario sets window.__WOOTC_MOCK before load.
//
// The frontend calls window.go.main.App.<Method>() and
// window.runtime.EventsOn/EventsEmit — we implement exactly those.

window.__wootcInstallEmitters = [];

function makeApp(mock) {
  const P = (v) => Promise.resolve(v);
  return {
    GetBranding: () => P(mock.brand || { name: 'wootc', tagline: 'Bring Windows to Linux — keep everything.', logoEmoji: '🐠', version: '0.1.0', accent: '#5b6ee1', accentText: '#ffffff', background: '#0a0a0f', card: '#13131e', text: '#e8e8f0', installVerb: 'Install' }),
    GetMode: () => P(mock.mode || 'installer'),
    GetImages: () => P(mock.images || []),
    GetSystemInfo: () => P(mock.sysinfo || {}),
    ExistingInstallFound: () => P(!!mock.existing),
    GetStatus: () => P(mock.status || { running: false, done: false, existing: false }),
    StartInstall: (cfg) => {
      // Drive the progress screen through a scripted sequence, fast.
      const steps = mock.installSteps || [];
      let i = 0;
      const tick = () => {
        if (i >= steps.length) return;
        const s = steps[i++];
        window.__wootcInstallEmitters.forEach((cb) => cb(s));
        if (!s.done && !s.error) setTimeout(tick, mock.stepDelay ?? 40);
      };
      setTimeout(tick, 20);
      return P();
    },
    CancelInstall: () => P(),
    Reboot: () => P(),
    Uninstall: () => P(),
    GetMigrationCategories: () => P(mock.categories || []),
    GetAppMigrations: () => P(mock.apps || []),
    GetOfficeMigration: () => P(mock.office || { present: false }),
    ConvertCategory: () => P(),
    ImportBrowserData: () => P('ok'),
    CreateDataPartition: () => P({ letter: 'D', label: 'wootc-data', freeGB: 60, encrypted: false }),
    GetUninstallInfo: () => P(mock.uninstall || { found: false }),
    UninstallWith: () => P(),
    GetVMCapability: () => P(mock.vm || { available: false, reason: '' }),
    BootInVM: () => P(),
    DefragDrive: () => { if (mock.defragError) return Promise.reject(mock.defragError); return P(); },
  };
}

const mock = window.__WOOTC_MOCK || {};
window.go = { main: { App: makeApp(mock) } };
// The bundled wailsjs EventsOn delegates to EventsOnMultiple, which the
// real runtime provides — mock the full surface the bundle touches.
window.runtime = {
  EventsOnMultiple: (name, cb) => {
    if (name === 'install:progress') window.__wootcInstallEmitters.push(cb);
    return () => {};
  },
  EventsOn: (name, cb) => window.runtime.EventsOnMultiple(name, cb, -1),
  EventsOnce: (name, cb) => window.runtime.EventsOnMultiple(name, cb, 1),
  EventsOff: () => {},
  EventsEmit: () => {},
  LogPrint: () => {}, LogInfo: () => {}, LogError: () => {},
  WindowMinimise: () => {}, WindowHide: () => {}, Quit: () => {},
  Environment: () => Promise.resolve({ buildType: 'test' }),
};
window.wails = { Quit: () => {} };
