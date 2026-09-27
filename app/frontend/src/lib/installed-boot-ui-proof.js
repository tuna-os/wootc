// This observes the rendered control panel. Expected facts never populate UI.
function visibleText(node) {
  if (!node?.isConnected || !node.getClientRects().length) return null;
  const view = node.ownerDocument.defaultView;
  const rect = node.getBoundingClientRect();
  if (rect.width <= 0 || rect.height <= 0 || rect.bottom <= 0 || rect.top >= view.innerHeight || rect.right <= 0 || rect.left >= view.innerWidth) return null;
  for (let parent = node; parent; parent = parent.parentElement) {
    const css = view.getComputedStyle(parent);
    if (css.display === 'none' || css.visibility !== 'visible' || Number(css.opacity) === 0) return null;
  }
  return node.innerText;
}

export function verifyInstalledBootUI(directive, root = document) {
  const expected = directive.expected || {};
  const panel = root.querySelector('[data-wootc-screen="control"]');
  const summary = panel?.querySelector('.boot-evidence-summary');
  const observed = {
    heading: visibleText(panel?.querySelector('.boot-evidence-heading')),
    kernel: visibleText(summary?.querySelector('[data-boot-evidence="kernel"]')),
    sourceImageRef: visibleText(summary?.querySelector('[data-boot-evidence="source-image"]')),
    boundFolders: visibleText(summary?.querySelector('[data-boot-evidence="bound-folders"]')),
    matchedUsers: visibleText(summary?.querySelector('[data-boot-evidence="matched-users"]')),
    summary: visibleText(summary),
  };
  const errors = [];
  if (!directive.runId || !directive.nonce) errors.push('Missing current-run receipt identity');
  if (!expected.kernel || !expected.sourceImageRef || !Number.isInteger(expected.boundFolders) ||
      !Number.isInteger(expected.matchedUsers) || expected.boundFolders < 0 || expected.matchedUsers < 0) {
    errors.push('Incomplete independently observed first-boot facts');
  }
  if (!observed.heading?.endsWith(' boot verified')) errors.push('Verified boot heading is not rendered');
  for (const field of ['kernel', 'sourceImageRef', 'boundFolders', 'matchedUsers']) {
    if (observed[field] === null || observed[field] !== String(expected[field])) {
      errors.push(`Rendered ${field} differs from this boot`);
    }
  }
  const wantedSummary = `Linux ${expected.kernel} · ${expected.sourceImageRef} · ` +
    `${expected.boundFolders} folders connected for ${expected.matchedUsers} users`;
  if (observed.summary !== wantedSummary) errors.push('Rendered first-boot summary differs from this boot');
  return { action: 'verify-installed-boot', runId: directive.runId, nonce: directive.nonce,
    observed, passed: errors.length === 0, errors };
}
