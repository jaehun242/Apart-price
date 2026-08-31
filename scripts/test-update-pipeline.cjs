'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  runStages: executeStages, finalSucceeded, assertSafeMainAdvance,
  assertCurrentSource, resolveMode, pagesDeploymentResult,
} = require('./update-pipeline.cjs');
const runStages = (state, operations) => executeStages({ tests: 'success', ...state }, operations);
const sha = '1'.repeat(40), later = '2'.repeat(40);
const pagesEnv = {
  PAGES_DEPLOY_OUTCOME: 'success', PAGES_URL: 'https://example.github.io/apart/',
  PAGES_BASE_URL: 'https://example.github.io/apart', PAGES_ARTIFACT_ID: '123',
  GITHUB_SHA: later,
};
function ops({ changed = false, collect, validate, deployOutcome = 'success' } = {}) {
  return {
    api: collect || (async () => ({ new_transactions: changed ? 1 : 0, outcome: changed ? 'success-changed' : 'success-no-change' })),
    validation: validate || (async () => ({ transaction_count: 100 })),
    git: async () => ({ commit_sha: sha, push: changed ? 'success' : 'not-needed' }),
    pages_source: async () => ({ commit_sha: sha }),
    pages_guard: async () => ({ commit_sha: sha }),
    deployment: async state => pagesDeploymentResult(state, { ...pagesEnv, PAGES_DEPLOY_OUTCOME: deployOutcome }),
  };
}
test('Changed data commits and deploys inside the same execution', async () => {
  const state = await runStages({ mode: 'refresh' }, ops({ changed: true }));
  assert.equal(state.success, true);
  assert.equal(state.git.push, 'success');
  assert.equal(state.deployment.commit_sha, sha);
  // The data commit can be newer than the workflow trigger; artifact identity uses HEAD.
  assert.equal(state.deployment.workflow_commit_sha, later);
});
test('Zero changes skip a data commit but still deploy Pages', async () => {
  const state = await runStages({ mode: 'refresh' }, ops());
  assert.equal(state.success, true);
  assert.equal(state.api.new_transactions, 0);
  assert.equal(state.git.push, 'not-needed');
  assert.equal(state.deployment.status, 'success');
});
test('Failed collection is not zero trades and cannot save or deploy', async () => {
  let writes = 0, publishes = 0;
  const operations = ops({ collect: async () => { throw new Error('Final API timeout'); } });
  operations.git = async () => { writes++; };
  operations.deployment = async () => { publishes++; };
  const state = await runStages({ mode: 'refresh' }, operations);
  assert.equal(state.success, false);
  assert.equal(state.api.new_transactions, undefined);
  assert.equal(writes, 0);
  assert.equal(publishes, 0);
  assert.equal(state.deployment.status, 'skipped');
});
test('Validation failure never writes Git or prepares a Pages artifact', async () => {
  let writes = 0, artifacts = 0;
  const operations = ops({ validate: async () => { throw new Error('Invalid candidate'); } });
  operations.git = async () => { writes++; };
  operations.pages_source = async () => { artifacts++; };
  const state = await runStages({ mode: 'refresh' }, operations);
  assert.equal(state.success, false);
  assert.equal(writes, 0);
  assert.equal(artifacts, 0);
});
test('Pages failure after successful Git storage remains FAILED; no API retry', async () => {
  let apiCalls = 0;
  const state = await runStages({ mode: 'refresh' }, ops({
    changed: true, collect: async () => { apiCalls++; return { new_transactions: 1 }; }, deployOutcome: 'failure',
  }));
  assert.equal(state.success, false);
  assert.equal(state.git.status, 'success');
  assert.equal(state.deployment.status, 'failed');
  assert.equal(apiCalls, 1);
});
test('Deployment-only recovery does not collect, rewrite data or create a commit', async () => {
  let calls = 0;
  const operations = ops({ collect: async () => { calls++; } });
  operations.git = async () => { calls++; };
  const state = await runStages({ mode: 'deploy-only' }, operations);
  assert.equal(state.success, true);
  assert.equal(calls, 0);
  assert.equal(state.api.status, 'skipped');
  assert.equal(state.git.status, 'skipped');
});
test('Skipped, cancelled and missing Pages action results are not success', async () => {
  for (const deployOutcome of ['skipped', 'cancelled', '']) {
    const state = await runStages({ mode: 'deploy-only' }, ops({ deployOutcome }));
    assert.equal(state.success, false);
  }
});
test('Regression success is required even if the Pages action claims success', async () => {
  const state = await runStages({ mode: 'refresh' }, ops());
  for (const tests of [undefined, 'failure', 'cancelled', 'skipped']) assert.equal(finalSucceeded({ ...state, tests }), false);
});
test('Newer main or wrong artifact source prevents stale deployment', () => {
  assert.doesNotThrow(() => assertCurrentSource(sha, sha, sha));
  assert.throws(() => assertCurrentSource(sha, sha, later), /stale/);
  assert.throws(() => assertCurrentSource(sha, later, sha), /stale/);
});
test('Schedule refreshes; human pushes deploy; catalog pushes keep collection behavior', () => {
  assert.equal(resolveMode('schedule', 'deploy-only'), 'refresh');
  assert.equal(resolveMode('push', 'refresh', ['public/styles.css']), 'deploy-only');
  assert.equal(resolveMode('push', '', ['config/additional-apartments.json']), 'refresh');
  assert.equal(resolveMode('workflow_dispatch', 'deploy-only'), 'deploy-only');
  assert.equal(resolveMode('workflow_dispatch', 'auto'), 'auto');
  assert.throws(() => resolveMode('workflow_dispatch', 'invalid'), /Unknown/);
});
test('Unexpected Pages URL cannot be reported as successful', async () => {
  const state = await runStages({ mode: 'refresh' }, ops());
  assert.throws(() => pagesDeploymentResult(state, { ...pagesEnv, PAGES_URL: 'https://other.example/' }), /unexpected/);
});
test('Concurrent collection-code/data changes keep the original overwrite protection', () => {
  for (const file of ['public/data/transactions.js', 'scripts/update-data-github.ps1', 'reports/molit-openapi-matching.md', 'config/additional-apartments.json']) {
    assert.throws(() => assertSafeMainAdvance([file]), /refuse stale overwrite/);
  }
  assert.doesNotThrow(() => assertSafeMainAdvance(['public/styles.css', 'public/app.js']));
});
