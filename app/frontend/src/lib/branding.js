import { state } from './state.js';

// ── Partner/enterprise branding ───────────────────────────────────────────────

// Apply partner/enterprise branding as CSS variables + document title.
export function applyBranding(b) {
  state.brand = b;
  const r = document.documentElement.style;
  if (b.accent)     { r.setProperty('--accent', b.accent); r.setProperty('--border-focus', b.accent); }
  if (b.accentText)   r.setProperty('--accent-text', b.accentText);
  if (b.background)   r.setProperty('--bg', b.background);
  if (b.card)         r.setProperty('--bg-card', b.card);
  if (b.text)         r.setProperty('--text', b.text);
  document.title = `${b.name} — ${b.tagline}`;
}

export function installVerb() {
  return state.brand?.installVerb || 'Install';
}
