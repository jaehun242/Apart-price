'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync, spawnSync } = require('node:child_process');
const { hash, parse, validateDataset, readMeta, koreaDate } = require('./dataset-meta.cjs');
const root = path.resolve(__dirname, '..');
const version = '2026-08-31-github-pages-v1';
const dataFile = 'public/data/transactions.js';
const allowedFiles = [dataFile, 'public/data/supply-areas.js', 'reports/supply-area-verification.md', 'reports/molit-openapi-matching.md'];
const labels = { api: 'API', validation: 'DATA', git: 'GIT', pages_source: 'PAGES', pages_guard: 'PAGES', deployment: 'PAGES' };
const redact = value => {
  let text = String(value);
  for (const name of ['MOLIT_API_KEY', 'GH_TOKEN', 'GITHUB_TOKEN']) {
    const value = process.env[name];
    if (!value) continue;
    for (const form of new Set([value, encodeURIComponent(value)])) text = text.split(form).join('[REDACTED]');
    try { text = text.split(decodeURIComponent(value)).join('[REDACTED]'); } catch {}
  }
  return text.replace(/serviceKey=[^&\s]+/gi, 'serviceKey=[REDACTED]');
};
function command(file, args, options = {}) {
  try { return execFileSync(file, args, { cwd: root, encoding: 'utf8', maxBuffer: 128 * 1024 * 1024, ...options }).trimEnd(); }
  catch (error) { throw new Error(redact(error.stderr || error.message)); }
}
const git = (...args) => command('git', args);
function run(file, args) {
  const result = spawnSync(file, args, { cwd: root, stdio: 'inherit', env: process.env });
  if (result.error || result.status !== 0) throw new Error(redact(result.error?.message || file + ' exited ' + result.status));
}
const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, ''));
function save(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
}
function finalSucceeded(state) {
  const apiOK = state.api?.status === 'success' || (state.mode === 'deploy-only' && state.api?.status === 'skipped');
  const dataOK = state.mode === 'deploy-only' || (state.validation?.status === 'success' && state.git?.status === 'success');
  return apiOK && dataOK && state.pages_source?.status === 'success' && state.pages_guard?.status === 'success' &&
    state.deployment?.status === 'success' && state.tests === 'success';
}
function resolveMode(eventName, requestedMode, changedFiles = []) {
  if (eventName === 'push') return changedFiles.includes('config/additional-apartments.json') ? 'refresh' : 'deploy-only';
  if (eventName === 'schedule') return 'refresh';
  const mode = requestedMode || 'refresh';
  if (!['refresh', 'auto', 'deploy-only'].includes(mode)) throw new Error('Unknown pipeline mode');
  return mode;
}
function collectionReady(state) {
  return state.mode === 'deploy-only' || (state.api?.status === 'success' && state.validation?.status === 'success' && state.git?.status === 'success');
}
function assertCurrentSource(source, local, remote) {
  if (!/^[a-f0-9]{40}$/.test(source) || source !== local || source !== remote) {
    throw new Error('main changed or artifact source is stale; refuse an outdated Pages deployment');
  }
}
function pagesDeploymentResult(state, env) {
  const outcome = env.PAGES_DEPLOY_OUTCOME || 'not-run';
  if (!collectionReady(state) || state.pages_source?.status !== 'success' || state.pages_guard?.status !== 'success' || state.tests !== 'success') {
    return { status: 'skipped', provider: 'github-pages', action_outcome: outcome, reason: 'Collection, source or regression gate did not pass' };
  }
  if (outcome !== 'success') throw new Error('actions/deploy-pages@v4 ended with ' + outcome);
  const url = new URL(env.PAGES_URL || '');
  const configured = new URL(env.PAGES_BASE_URL || '');
  if (url.protocol !== 'https:' || url.href.replace(/\/$/, '') !== configured.href.replace(/\/$/, '')) {
    throw new Error('Pages action returned an unexpected site URL');
  }
  return { status: 'success', provider: 'github-pages', action: 'actions/deploy-pages@v4',
    action_outcome: outcome, page_url: url.href, commit_sha: state.pages_source.commit_sha,
    workflow_commit_sha: env.GITHUB_SHA || null, artifact_id: env.PAGES_ARTIFACT_ID || null,
    verification: 'official Pages action completed successfully; no external-provider URL check' };
}
function assertSafeMainAdvance(paths) {
  if (paths.some(p => /^(scripts\/|config\/|\.github\/|public\/data\/)/.test(p) || allowedFiles.includes(p))) {
    throw new Error('origin/main changed in data or collection code; refuse stale overwrite and recollect on next run');
  }
}
async function executeStage(name, state, operations) {
  if (name === 'api' && state.mode === 'deploy-only') {
    state.api = { status: 'skipped', reason: 'explicit deployment-only recovery; no API request' }; return;
  }
  if ((name === 'validation' && state.api?.status !== 'success') ||
      (name === 'git' && state.validation?.status !== 'success') ||
      (['pages_source', 'pages_guard', 'deployment'].includes(name) && !collectionReady(state)) ||
      (name === 'pages_guard' && state.pages_source?.status !== 'success')) {
    state[name] = { status: 'skipped', reason: 'upstream did not succeed' }; return;
  }
  try {
    state[name] = { status: 'success', ...await operations[name](state), completed_at: new Date().toISOString() };
  } catch (error) {
    state[name] = { status: 'failed', ...error.result, execution_failed: true, error: redact(error.message), completed_at: new Date().toISOString() };
    console.error('[' + labels[name] + ' ERROR] ' + redact(error.message));
  }
}
// Official Pages Actions run between pages_source and deployment in the workflow.
// Tests inject their result without making API requests or changing real data.
async function runStages(state, operations) {
  for (const name of ['api', 'validation', 'git', 'pages_source', 'pages_guard', 'deployment']) await executeStage(name, state, operations);
  state.success = finalSucceeded(state);
  return state;
}
function sameCollector(state, prior) {
  return prior.version === version && prior.collector_hash === state.collector_hash &&
    prior.api?.status === 'success' && prior.validation?.status === 'success' && prior.git?.status === 'success' &&
    prior.git.data_sha256 === state.baseline_data_hash &&
    koreaDate(new Date(prior.api.collected_at)) === koreaDate();
}
async function reusableReceipt(state, temp) {
  if (state.mode !== 'auto' || !process.env.GITHUB_REPOSITORY || !process.env.GH_TOKEN) return null;
  try {
    const repo = process.env.GITHUB_REPOSITORY;
    const runs = JSON.parse(command('gh', ['api', 'repos/' + repo + '/actions/workflows/daily-update.yml/runs?per_page=20'])).workflow_runs;
    for (const old of runs.filter(r => String(r.id) !== process.env.GITHUB_RUN_ID && r.status === 'completed' &&
        ['schedule', 'workflow_dispatch'].includes(r.event) && koreaDate(new Date(r.updated_at)) === koreaDate()).slice(0, 8)) {
      const folder = path.join(temp, 'receipt-' + old.id);
      try {
        command('gh', ['run', 'download', String(old.id), '--repo', repo, '--name', 'pipeline-diagnostics-' + old.id, '--dir', folder]);
        const prior = readJson(path.join(folder, 'report.json'));
        if (sameCollector(state, prior)) return prior;
      } catch { /* Old workflows may not have a receipt. Never treat that as API success. */ }
    }
  } catch { console.log('[API] No verifiable same-day receipt; perform collection'); }
  return null;
}
function operations(temp) {
  const candidate = path.join(temp, 'candidate'), candidateData = path.join(candidate, dataFile);
  return {
    async api(state) {
      const prior = await reusableReceipt(state, temp);
      if (prior) {
        console.log('[API] Reuse verified same-day collection; deployment recovery does not re-collect');
        return { ...prior.api, reused: true, reused_run: prior.run_id };
      }
      fs.mkdirSync(path.dirname(candidateData), { recursive: true });
      fs.copyFileSync(path.join(root, dataFile), candidateData);
      fs.copyFileSync(path.join(root, 'public/data/supply-areas.js'), path.join(candidate, 'public/data/supply-areas.js'));
      run(process.execPath, ['scripts/sync-apartment-catalog.cjs', '--data', candidateData]);
      const log = path.join(temp, 'api-log.json');
      try {
        run('pwsh', ['-NoProfile', '-File', 'scripts/update-data-github.ps1', '-DataPath', candidateData,
          '-ReadTimeoutSec', '60', '-ConnectTimeoutSec', '25', '-MaxRetries', '6',
          '-LogPath', log, '-BackupPath', path.join(temp, 'transactions.previous.js'),
          '-MatchReportPath', path.join(candidate, 'reports/molit-openapi-matching.md')]);
      } catch (error) {
        const detail = fs.existsSync(log) ? readJson(log) : null;
        error.result = { collected_at: null, new_transactions: null, original_preserved: hash(fs.readFileSync(path.join(root, dataFile), 'utf8')) === state.baseline_data_hash,
          failure: detail?.failedRequest || null, api_error: detail?.error || error.message };
        throw error;
      }
      const detail = readJson(log);
      if (!['success-changed', 'success-no-change'].includes(detail.status) || !detail.apiKeyRecognized ||
          !detail.validationPassed || detail.pairsCompleted !== detail.pairsRequested || detail.pairsFailed !== 0 ||
          detail.criticalUnmatched !== 0 || detail.complexesMatched + detail.complexesDeferred !== detail.complexesRequested) throw new Error('Collection completeness/authentication validation failed');
      return { status: 'success', outcome: detail.status, collected_at: detail.finishedAt, reused: false,
        new_transactions: detail.newTransactions, removed_transactions: detail.cancelledOrRemoved,
        corrected_transactions: detail.correctedTransactions, latest_contract_date: detail.latestContractDate,
        matched: detail.complexesMatched, requested: detail.complexesRequested, deferred: detail.complexesDeferred,
        pairs_completed: detail.pairsCompleted, pairs_requested: detail.pairsRequested, api_key_recognized: detail.apiKeyRecognized };
    },
    async validation(state) {
      const target = state.api.reused ? path.join(root, dataFile) : candidateData;
      const data = validateDataset(parse(fs.readFileSync(target, 'utf8')));
      const old = parse(fs.readFileSync(path.join(root, dataFile), 'utf8'));
      const ids = new Set(data.complexes.map(c => c.id));
      for (const c of old.complexes) if (!ids.has(c.id)) throw new Error('An existing complex was removed');
      const beforeSeen = new Map(old.records.filter(r => r.transactionId).map(r => [r.complexId + '|' + r.transactionId, r.first_seen_at]));
      for (const r of data.records) {
        const key = r.complexId + '|' + r.transactionId;
        if (beforeSeen.has(key) && beforeSeen.get(key) !== r.first_seen_at) throw new Error('Existing first_seen_at changed');
      }
      console.log('[VERIFY] ' + data.records.length + ' records validated');
      return { transaction_count: data.records.length, latest_contract_date: data.meta.rangeEnd, data_sha256: hash(fs.readFileSync(target, 'utf8')) };
    },
    async git(state) {
      git('fetch', 'origin', 'main');
      const remote = git('rev-parse', 'origin/main');
      if (remote !== state.baseline_sha) {
        const paths = git('diff', '--name-only', state.baseline_sha, remote).split(/\r?\n/);
        assertSafeMainAdvance(paths);
        git('merge', '--ff-only', 'origin/main');
      }
      const changed = state.validation.data_sha256 !== hash(fs.readFileSync(path.join(root, dataFile), 'utf8'));
      if (changed) {
        run('pwsh', ['-NoProfile', '-File', 'scripts/build-supply-area-map.ps1', '-DataPath', candidateData,
          '-OutputPath', path.join(candidate, 'public/data/supply-areas.js'),
          '-ReportPath', path.join(candidate, 'reports/supply-area-verification.md'), '-ReuseExistingTypes']);
        for (const file of allowedFiles) {
          if (fs.existsSync(path.join(candidate, file))) {
            fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
            fs.copyFileSync(path.join(candidate, file), path.join(root, file));
          }
        }
        run(process.execPath, ['scripts/test-supply-area-map.mjs']);
        git('add', '--', ...allowedFiles);
        const staged = git('diff', '--cached', '--name-only').split(/\r?\n/).filter(Boolean);
        if (staged.some(p => !allowedFiles.includes(p))) throw new Error('Unexpected staged file');
        git('config', 'user.name', 'github-actions[bot]');
        git('config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com');
        git('commit', '-m', 'data: refresh apartment transactions ' + koreaDate());
        git('fetch', 'origin', 'main');
        if (git('rev-parse', 'origin/main') !== remote) throw new Error('main advanced immediately before push; no force push performed');
        git('push', 'origin', 'HEAD:main');
      }
      const sha = git('rev-parse', 'HEAD');
      const remoteAfter = git('ls-remote', 'origin', 'refs/heads/main').split(/\s+/)[0];
      if (sha !== remoteAfter) throw new Error('GitHub main SHA does not match the validated local commit');
      console.log('[GIT] main commit ' + sha + ' / ' + (changed ? 'push verified' : 'no change; no data commit'));
      return { commit_sha: sha, data_sha256: state.validation.data_sha256, push: changed ? 'success' : 'not-needed' };
    },
    async pages_source(state) {
      git('fetch', 'origin', 'main');
      const sha = git('rev-parse', 'HEAD');
      assertCurrentSource(state.git?.commit_sha || state.baseline_sha, sha, git('rev-parse', 'origin/main'));
      if (git('status', '--porcelain', '--untracked-files=all', '--', 'public')) throw new Error('Uncommitted public files cannot be deployed');
      const expected = readMeta(root, sha);
      state.production_expected = expected;
      save(path.join(temp, 'expected-meta.json'), expected);
      run(process.execPath, ['scripts/write-build-meta.cjs']);
      const built = readJson(path.join(root, 'public/data/build-meta.json'));
      if (built.commit_sha !== sha || built.data_sha256 !== expected.data_sha256) throw new Error('Pages metadata does not match the validated source');
      console.log('[PAGES] Validated public/ from main ' + sha);
      return { commit_sha: sha, data_sha256: expected.data_sha256, transaction_count: expected.transaction_count };
    },
    async pages_guard(state) {
      const remote = git('ls-remote', 'origin', 'refs/heads/main').split(/\s+/)[0];
      assertCurrentSource(state.pages_source.commit_sha, git('rev-parse', 'HEAD'), remote);
      console.log('[PAGES] main unchanged immediately before deployment');
      return { commit_sha: remote };
    },
    async deployment(state) {
      const result = pagesDeploymentResult(state, process.env);
      console.log('[PAGES] ' + result.status + (result.page_url ? ' / ' + result.page_url : ''));
      return result;
    },
  };
}
async function cli() {
  const stage = process.argv[2];
  const temp = process.env.PIPELINE_DIR || path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'apart-price-pipeline');
  const reportFile = path.join(temp, 'report.json');
  if (stage === 'prepare') {
    const collector = git('ls-tree', '-r', 'HEAD', '--', 'scripts', 'config');
    let changedFiles = [];
    if (process.env.GITHUB_EVENT_NAME === 'push') {
      const event = readJson(process.env.GITHUB_EVENT_PATH);
      changedFiles = /^0+$/.test(event.before) ? ['config/additional-apartments.json'] :
        git('diff', '--name-only', event.before, event.after).split(/\r?\n/);
    }
    const mode = resolveMode(process.env.GITHUB_EVENT_NAME, process.env.PIPELINE_MODE, changedFiles);
    console.log('[MODE] ' + mode + ' / ' + (process.env.GITHUB_EVENT_NAME || 'manual'));
    save(reportFile, { version, run_id: process.env.GITHUB_RUN_ID || 'local', mode,
      started_at: new Date().toISOString(), baseline_sha: git('rev-parse', 'HEAD'), collector_hash: hash(collector),
      baseline_data_hash: hash(fs.readFileSync(path.join(root, dataFile), 'utf8')) });
    return;
  }
  const state = readJson(reportFile);
  if (process.env.TEST_OUTCOME) state.tests = process.env.TEST_OUTCOME;
  if (stage === 'final') {
    state.tests = process.env.TEST_OUTCOME;
    state.finished_at = new Date().toISOString();
    state.elapsed_seconds = Math.round((Date.parse(state.finished_at) - Date.parse(state.started_at)) / 1000);
    state.success = finalSucceeded(state);
    const rows = [
      ['API collection', state.api?.status || 'not-run'],
      ['New transactions', state.api?.new_transactions ?? 'not determined'],
      ['Removed/cancelled', state.api?.removed_transactions ?? 'not determined'],
      ['Corrected', state.api?.corrected_transactions ?? 'not determined'],
      ['Data validation', state.validation?.status || 'not-run'],
      ['GitHub main', state.git?.commit_sha || state.production_expected?.commit_sha || 'unknown'],
      ['GitHub push', state.git?.push || 'not-performed'],
      ['Pages artifact source', state.pages_source?.commit_sha || 'not-prepared'],
      ['GitHub Pages deployment', state.deployment?.status || 'not-run'],
      ['Published site', state.deployment?.page_url || 'not-published'],
      ['Deployment verification', 'Official actions/deploy-pages result'],
      ['Elapsed seconds', state.elapsed_seconds], ['Final', state.success ? 'SUCCESS' : 'FAILED'],
    ];
    const summary = '| Stage | Result |\n|---|---|\n' + rows.map(r => '| ' + r.join(' | ') + ' |').join('\n') + '\n';
    if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary);
    save(reportFile, state);
    console.log(summary + '[FINAL] ' + (state.success ? 'SUCCESS' : 'FAILED'));
    if (!state.success) process.exitCode = 1;
    return;
  }
  if (!Object.hasOwn(labels, stage)) throw new Error('Unknown pipeline stage');
  await executeStage(stage, state, operations(temp));
  save(reportFile, state);
  if (state[stage]?.status === 'failed' || state[stage]?.execution_failed) process.exitCode = 1;
}
module.exports = { finalSucceeded, executeStage, runStages, sameCollector, assertSafeMainAdvance, resolveMode, collectionReady, assertCurrentSource, pagesDeploymentResult };
if (require.main === module) cli().catch(error => { console.error('[FINAL ERROR] ' + redact(error.message)); process.exitCode = 1; });
