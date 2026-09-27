// Actual frontend drive module with disposable DOM/binding spies. No browser,
// Windows guest, real install or reboot acceptance follows from these controls.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8').replace(/^import .*;\n/, '').replace('export function startE2EDrive', 'function startE2EDrive');
const image = 'ghcr.io/tuna-os/yellowfin:gnome';
const identity = {schemaVersion: 1, runId: 'current', directiveId: '1234567890abcdef1234567890abcdef'};
let directive = {...identity, action: 'install', image, username: 'wootc', hostname: 'test', password: 'public-test'};
const reports = [];
let scheduled, clicks = 0, reboots = 0, events = 0;
const button = {disabled: false, click() { clicks++; }};
const input = () => ({value: '', oninput() { events++; }});
const fields = ['Custom supported OCI image', 'Linux Username', 'Computer name'].map(label => {
  const value = input(); return {querySelector(selector) { return selector === 'label' ? {textContent: label} : value; }};
});
const passwords = [input(), input()];
const context = {
 window: {},
 document: {
  querySelectorAll(selector) { return selector === '.field' ? fields : selector === 'input[type=password]' ? passwords : []; },
  querySelector() { return null; },
  getElementById(id) { return id === 'install-btn' ? button : null; },
 },
 E2EDriveDirective: async () => JSON.stringify(directive),
 E2EDriveReport: async raw => reports.push(JSON.parse(raw)),
 Reboot: () => { reboots++; },
 setTimeout(callback) { scheduled = callback; },
};
vm.runInNewContext(source, context);
const state = {screen: 'launchpad', selected: {imageRef: image}, progress: {step: 'armed'}};
async function settle() { await new Promise(resolve => setImmediate(resolve)); }
(async () => {
 context.startE2EDrive(state); await settle();
 assert.equal(clicks, 1); assert.equal(events, 5);
 assert.equal(reports.length, 1);
 for (const [key, value] of Object.entries(identity)) assert.equal(reports[0][key], value);
 assert.equal(reports[0].action, 'install'); assert.equal(reports[0].installDriven, true);
 state.screen = 'done'; scheduled(); await settle();
 assert.equal(reports.at(-1).screen, 'done');
 const count = reports.length;
 directive = {...directive, runId: 'stale'}; scheduled(); await settle();
 assert.equal(reports.length, count); assert.equal(clicks, 1); assert.equal(reboots, 0);
 directive = {...directive, runId: 'current', directiveId: '0'.repeat(32)}; scheduled(); await settle();
 assert.equal(reports.length, count); assert.equal(clicks, 1);
 directive = {...identity, action: 'reboot'}; scheduled(); await settle();
 assert.equal(reboots, 1); assert.equal(reports.at(-1).action, 'reboot');
 scheduled(); await settle(); assert.equal(reboots, 1);
 console.log(JSON.stringify({controls: 6, scope: 'actual frontend module with DOM and bridge spies', installReceipt: reports[1]}));
})().catch(error => { console.error(error); process.exitCode = 1; });
