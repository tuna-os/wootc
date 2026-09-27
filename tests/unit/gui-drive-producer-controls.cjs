// Actual frontend drive module with disposable DOM/binding spies. No browser,
// Windows guest, real install or reboot acceptance follows from these controls.
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const source = fs.readFileSync(process.argv[2], 'utf8').replace(/^import .*;\n/, '').replace('export function startE2EDrive', 'function startE2EDrive');
const image = 'ghcr.io/tuna-os/yellowfin:gnome';
const identity = {schemaVersion: 1, runId: 'current', directiveId: '1234567890abcdef1234567890abcdef'};
let directive = {...identity, action: 'install', image, username: 'wootc', hostname: 'test', password: 'public-test'};
const installFields = ['schemaVersion', 'runId', 'directiveId', 'action', 'screen', 'installDriven', 'installBtnDisabled', 'hint', 'progressStep', 'error', 'selectedRef', 'imageMismatch'];
const vmFields = ['vmPrepareDriven', 'freshVmAvailable', 'freshVmReason', 'vmPrepareButtonVisible', 'vmPrepareButtonDisabled', 'vmRuntimeButtonVisible', 'vmImageMismatch', 'vmReady', 'vmProgressStage'];
const fieldsEqual = (receipt, expected) => assert.deepEqual(Object.keys(receipt).sort(), [...expected].sort());
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
 fieldsEqual(reports.at(-1), installFields);
 const installReceipt = reports.at(-1);
 const count = reports.length;
 directive = {...directive, runId: 'stale'}; scheduled(); await settle();
 assert.equal(reports.length, count); assert.equal(clicks, 1); assert.equal(reboots, 0);
 directive = {...directive, runId: 'current', directiveId: '0'.repeat(32)}; scheduled(); await settle();
 assert.equal(reports.length, count); assert.equal(clicks, 1);
 directive = {...identity, action: 'reboot'}; scheduled(); await settle();
 assert.equal(reboots, 1); assert.equal(reports.at(-1).action, 'reboot');
 scheduled(); await settle(); assert.equal(reboots, 1);
 const rebootReceipt = reports.at(-1);
 fieldsEqual(rebootReceipt, installFields);
 await context.reportState(state, {...identity, action: 'prepare-vm'});
 const prepareReceipt = reports.at(-1);
 fieldsEqual(prepareReceipt, [...installFields, ...vmFields]);
 // A click that throws never reports installDriven and is not replayed.
 const failedReports = []; let failedScheduled, failedClicks = 0;
 const failedContext = {...context, window: {},
  document: {...context.document, getElementById(id) {
    return id === 'install-btn' ? {disabled: false, click() { failedClicks++; throw Error('public click failure'); }} : null;
  }},
  E2EDriveDirective: async () => JSON.stringify({...identity, action: 'install', image, username: 'wootc', hostname: 'test', password: 'public-test'}),
  E2EDriveReport: async raw => failedReports.push(JSON.parse(raw)),
  setTimeout(callback) { failedScheduled = callback; },
 };
 vm.runInNewContext(source, failedContext);
 const failedState = {screen: 'launchpad', selected: {imageRef: image}, progress: {step: 'armed'}};
 failedContext.startE2EDrive(failedState); await settle();
 assert.equal(failedClicks, 1); assert.equal(failedReports.length, 0);
 failedState.screen = 'done'; failedScheduled(); await settle();
 assert.equal(failedClicks, 1); assert.equal(failedReports.length, 1);
 assert.equal(failedReports[0].installDriven, false);
 // An unselectable requested image must never click the default selection.
 const mismatchReports = []; let mismatchClicks = 0;
 const mismatchContext = {...context, window: {},
  document: {...context.document, getElementById(id) {
    return id === 'install-btn' ? {disabled: false, click() { mismatchClicks++; }} : null;
  }},
  E2EDriveDirective: async () => JSON.stringify({...identity, action: 'install', image, username: 'wootc', hostname: 'test', password: 'public-test'}),
  E2EDriveReport: async raw => mismatchReports.push(JSON.parse(raw)),
 };
 vm.runInNewContext(source, mismatchContext);
 mismatchContext.startE2EDrive({screen: 'launchpad', selected: {imageRef: 'unrequested-default'}}); await settle();
 assert.equal(mismatchClicks, 0); assert.equal(mismatchReports.length, 1);
 assert.equal(mismatchReports[0].installDriven, false);
 assert.equal(mismatchReports[0].imageMismatch, true);
 console.log(JSON.stringify({controls: 8, mismatchReceipt: mismatchReports[0], thrownClickReceipt: failedReports[0], scope: 'actual frontend module with DOM and bridge spies', installReceipt, rebootReceipt, prepareReceipt, receiptActionControls: 3}));
})().catch(error => { console.error(error); process.exitCode = 1; });
