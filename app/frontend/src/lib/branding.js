import { state } from './state.js';

// ── Partner/enterprise branding ───────────────────────────────────────────────

// Apply branding: CSS variables + document title, and — for a brand build
// carrying real assets — the brand's typeface (@font-face from an embedded
// data URI, never a network fetch) and its deep theme stylesheet, injected
// AFTER style.css so its token and component overrides win.
export function applyBranding(b) {
  state.brand = b;
  const r = document.documentElement.style;
  if (b.accent)     { r.setProperty('--accent', b.accent); r.setProperty('--border-focus', b.accent); }
  if (b.accentText)   r.setProperty('--accent-text', b.accentText);
  if (b.background)   r.setProperty('--bg', b.background);
  if (b.card)         r.setProperty('--bg-card', b.card);
  if (b.text)         r.setProperty('--text', b.text);

  const inject = (id, css) => {
    let s = document.getElementById(id);
    if (!css) { if (s) s.remove(); return; }
    if (!s) { s = document.createElement('style'); s.id = id; document.head.appendChild(s); }
    s.textContent = css;
  };
  inject('brand-font', b.fontDataUri && b.fontFamily
    ? `@font-face{font-family:'${b.fontFamily}';src:url(${b.fontDataUri}) format('woff2');font-weight:100 900;font-display:swap}` +
      `html,body{font-family:'${b.fontFamily}','Inter',system-ui,sans-serif}`
    : '');
  inject('brand-theme', b.themeCss || '');

  document.title = `${b.productName || b.name} — ${b.tagline}`;
}

// The brand's mark as an <img> (real asset), or the emoji as a fallback —
// emojis survive only where they ARE the branding (the generic TunaOS build).
const escapeHTML = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function brandMark(cls = '') {
  const b = state.brand || {};
  if (b.logoDataUri) return `<img class="${escapeHTML(cls)}" src="${escapeHTML(b.logoDataUri)}" alt="${escapeHTML(b.name || '')} logo">`;
  return `<span class="${escapeHTML(cls)}">${escapeHTML(b.logoEmoji || '🐠')}</span>`;
}

export function installVerb() {
  return state.brand?.installVerb || 'Install';
}

// The distribution being installed ("TunaOS", "Bazzite") — what the result
// is called on every screen.
export function distroName() {
  return state.brand?.name || 'TunaOS';
}

// The installer's own name. "wootc" in the generic build; branded builds
// never show that word (docs/branding-and-distribution.md).
export function productName() {
  return state.brand?.productName || 'wootc';
}
