// ── Repaint indirection ───────────────────────────────────────────────────────
//
// main.js owns the screen table, so it owns render(). Screens only ever need to
// *trigger* a repaint, and importing main.js from a screen would close an import
// cycle (main → screen → main). So main.js registers its router here at boot and
// screens call this render() instead. Same synchronous call, one-way imports.

let renderer = () => {};

export function setRenderer(fn) {
  renderer = fn;
}

export function render() {
  renderer();
}
