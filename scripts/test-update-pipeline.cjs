'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { runStages: executeStages, finalSucceeded, assertSafeMainAdvance } = require('./update-pipeline.cjs');
const runStages = (state, operations) => executeStages({ tests: 'success', ...state }, operations);
const { ensureProduction, compareSite } = require('./verify-production.cjs');
const { makeMeta } = require('./dataset-meta.cjs');
const text = fs.readFileSync(require('node:path').join(__dirname, '../public/data/transactions.js'), 'utf8');
const sha = '1'.repeat(40), expected = makeMeta(text, sha);
const snapshot = () => ({ meta: { ...expected, provider: 'netlify', context: 'production', deploy_id: 'test-deploy' }, text });
function ops({ changed = false, deploy, collect } = {}) {
  return {
    api: collect || (async () => ({ new_transactions: changed ? 1 : 0, outcome: changed ? 'success-changed' : 'success-no-change' })),
    validation: async () => ({ transaction_count: expected.transaction_count }),
    git: async () => ({ commit_sha: sha, push: changed ? 'success' : 'not-needed' }),
    deployment: deploy || (async () => ensureProduction(expected, { read: async () => snapshot(), wait: async () => {}, log: () => {} })),
  };
}
test('A: new transactions + publication + served data => SUCCESS', async () => {
  const state = await runStages({ mode: 'refresh' }, ops({ changed: true }));
  assert.equal(state.success, true); assert.equal(state.api.new_transactions, 1); assert.equal(state.git.push, 'success');
});
test('B: zero new transactions still verifies production => SUCCESS', async () => {
  let reads = 0;
  const state = await runStages({ mode: 'auto' }, ops({ deploy: async () => ensureProduction(expected, { read: async () => { reads++; return snapshot(); }, log: () => {} }) }));
  assert.equal(state.success, true); assert.equal(state.git.push, 'not-needed'); assert.equal(reads, 1);
});
test('C/F: stale production recovers without another API call, including zero new records', async () => {
  for (const changed of [false, true]) {
    let calls = 0, recovery = 0;
    const state = await runStages({ mode: 'refresh' }, ops({ changed, collect: async () => { calls++; return { new_transactions: changed ? 1 : 0 }; },
      deploy: async () => ensureProduction(expected, {
        read: async () => recovery ? snapshot() : { meta: { ...snapshot().meta, commit_sha: '0'.repeat(40) } },
        trigger: async () => { recovery++; return 'fixture'; }, wait: async () => {}, attempts: 5, log: () => {},
      }) }));
    assert.equal(state.success, true); assert.equal(calls, 1); assert.equal(recovery, 1);
  }
});
test('E: failed API is not zero trades, never writes Git, still verifies production', async () => {
  let writes = 0, deployChecks = 0;
  const operations = ops({ collect: async () => { throw new Error('timeout after final retry'); } });
  operations.git = async () => { writes++; };
  operations.deployment = async () => { deployChecks++; return { status: 'success', site_status: 'success', actual_sha: sha }; };
  const state = await runStages({ mode: 'refresh' }, operations);
  assert.equal(state.success, false); assert.equal(writes, 0); assert.equal(deployChecks, 1);
  assert.equal(state.api.new_transactions, undefined);
});
test('F: exhausted deploy recovery fails after Git success without API re-collection', async () => {
  let calls = 0, recoveries = 0;
  const state = await runStages({ mode: 'refresh' }, ops({ changed: true,
    collect: async () => { calls++; return { new_transactions: 1 }; },
    deploy: async () => ensureProduction(expected, { read: async () => ({ meta: null }), trigger: async () => { recoveries++; }, wait: async () => {}, attempts: 14, log: () => {} }),
  }));
  assert.equal(state.success, false); assert.equal(state.git.status, 'success'); assert.equal(calls, 1); assert.equal(recoveries, 2);
});
test('G: Published/current metadata but stale served data is never SUCCESS', async () => {
  const stale = snapshot();
  stale.providerDeploy = { id: 'test-deploy', state: 'ready', commit_ref: sha };
  stale.text = text.replace('"price":', '"old_price":');
  assert.ok(compareSite(expected, stale).includes('served transactions.js hash'));
  const state = await runStages({ mode: 'auto' }, ops({ deploy: async () => ensureProduction(expected, { read: async () => stale, attempts: 1, log: () => {} }) }));
  assert.equal(state.success, false);
});
test('H: authentication failure cannot become success when production matches', async () => {
  const state = await runStages({ mode: 'refresh' }, ops({ collect: async () => { throw new Error('authentication HTTP 403'); } }));
  assert.equal(state.success, false); assert.equal(state.api.status, 'failed'); assert.equal(state.site.status, 'success');
});
test('Deployment-only recovery never invokes collection', async () => {
  let apiCalls = 0;
  const state = await runStages({ mode: 'deploy-only' }, ops({ collect: async () => { apiCalls++; } }));
  assert.equal(state.success, true); assert.equal(apiCalls, 0); assert.equal(state.api.status, 'skipped');
});
test('Final success needs deployment and live-file verification', () => {
  assert.equal(finalSucceeded({ api: { status: 'success' }, validation: { status: 'success' }, git: { status: 'success' }, deployment: { status: 'success' }, site: { status: 'failed' } }), false);
});

test('Skipped, cancelled, missing or failed regressions never produce final SUCCESS', () => {
  const state = { api: { status: 'success' }, validation: { status: 'success' }, git: { status: 'success' }, deployment: { status: 'success' }, site: { status: 'success' } };
  for (const tests of [undefined, 'failure', 'cancelled', 'skipped']) assert.equal(finalSucceeded({ ...state, tests }), false);
  assert.equal(finalSucceeded({ ...state, tests: 'success' }), true);
});
test('Concurrent data/code/report edits are rejected, unrelated UI changes can fast-forward', () => {
  for (const file of ['public/data/transactions.js', 'scripts/update-data-github.ps1', 'reports/molit-openapi-matching.md', 'config/additional-apartments.json']) {
    assert.throws(() => assertSafeMainAdvance([file]), /refuse stale overwrite/);
  }
  assert.doesNotThrow(() => assertSafeMainAdvance(['public/styles.css', 'public/app.js']));
});
test('Workflow always verifies production, not gated by data-changed', () => {
  const workflow = fs.readFileSync(require('node:path').join(__dirname, '../.github/workflows/daily-update.yml'), 'utf8');
  assert.match(workflow, /always\(\) && steps\.prepare\.outcome == 'success'/);
  assert.doesNotMatch(workflow, /verify\.outputs\.changed/);
  assert.match(workflow, /cancel-in-progress: false/);
  assert.match(workflow, /PIPELINE_MODE:.*inputs.mode \|\| 'refresh'/);
  assert.match(workflow, /default: refresh/);
});
