// Run the production request function with deliberately reordered responses.
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const source = readFileSync(new URL('../plugins/kindle-preview/preview.js', import.meta.url), 'utf8');
const start = source.indexOf('let metricsSequence = 0;');
const end = source.indexOf('\nasync function rerender(', start);
assert.ok(start >= 0 && end > start);
const calls = [];
const label = { textContent: '' };
const state = {
  device: { id: 'kpw5' }, reader: { level: 8, margin: 'narrow', spacing: 'medium', font: 'song' },
  draft: {}, metrics: null,
};
const context = vm.createContext({
  S: state, $: () => label,
  api: (name, params) => new Promise((resolve, reject) => calls.push({ name, params, resolve, reject })),
});
vm.runInContext(source.slice(start, end), context);
const refresh = () => vm.runInContext('refreshMetrics()', context);

const old = refresh();
state.reader.level = 9;
const current = refresh();
assert.equal(calls[0].params.level, 8);
assert.equal(calls[1].params.level, 9);
calls[1].resolve({ rootPx: 24 });
assert.equal(await current, true);
calls[0].resolve({ rootPx: 20 });
assert.equal(await old, false);
assert.equal(state.metrics.rootPx, 24);
assert.equal(label.textContent, 9);

const staleFailure = refresh();
state.reader.level = 10;
const latest = refresh();
calls[3].resolve({ rootPx: 28 });
assert.equal(await latest, true);
calls[2].reject(new Error('stale response'));
assert.equal(await staleFailure, false);
assert.equal(state.metrics.rootPx, 28);
assert.equal(label.textContent, 10);

const failure = refresh();
const checked = assert.rejects(failure, /current response/);
calls[4].reject(new Error('current response'));
await checked;
assert.equal(state.metrics.rootPx, 28);
console.log('PASS: stale success and failure are discarded; current failure remains visible to caller.');
