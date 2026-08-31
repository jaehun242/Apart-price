'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { execFileSync, spawnSync } = require('node:child_process');
const { hash, parse, validateDataset, makeMeta, koreaDate } = require('./dataset-meta.cjs');
const { ensureProduction } = require('./verify-production.cjs');
const root = path.resolve(__dirname, '..');
const version = '2026-08-31-reliability-v1';
const dataFile = 'public/data/transactions.js';
const allowedFiles = [dataFile, 'public/data/supply-areas.js', 'reports/supply-area-verification.md', 'reports/molit-openapi-matching.md'];
const labels = { api: 'API', validation: 'DATA', git: 'GIT', deployment: 'DEPLOY' };
const redact = value => {
  let text = String(value);
  for (const name of ['MOLIT_API_KEY', 'NETLIFY_AUTH_TOKEN', 'NETLIFY_BUILD_HOOK', 'GH_TOKEN', 'GITHUB_TOKEN']) {
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
  return apiOK && dataOK && state.deployment?.status === 'success' && state.site?.status === 'success' && state.tests !== 'failure';
}
function assertSafeMainAdvance(paths) {
  if (paths.some(p => /^(scripts\/|config\/|\.github\/|netlify\.toml$|public\/data\/)/.test(p) || allowedFiles.includes(p))) {
    throw new Error('origin/main changed in data or collection code; refuse stale overwrite and recollect on next run');
  }
}
async function executeStage(name, state, operations) {
  if (name === 'api' && state.mode === 'deploy-only') {
    state.api = { status: 'skipped', reason: 'explicit deployment-only recovery; no API request' }; return;
  }
  if ((name === 'validation' && state.api?.status !== 'success') ||
      (name === 'git' && state.validation?.status !== 'success')) {
    state[name] = { status: 'skipped', reason: 'upstream did not succeed' }; return;
  }
  try {
    state[name] = { status: 'success', ...await operations[name](state), completed_at: new Date().toISOString() };
    if (name === 'deployment') state.site = { status: state.deployment.site_status, commit_sha: state.deployment.actual_sha };
  } catch (error) {
    state[name] = { status: 'failed', ...error.result, execution_failed: true, error: redact(error.message), completed_at: new Date().toISOString() };
    if (name === 'deployment') state.site = { status: 'failed', commit_sha: error.result?.actual_sha || null };
    console.error('[' + labels[name] + ' ERROR] ' + redact(error.message));
  }
}
// The same orchestration is exercised by scenarios A-H without using production data.
async function runStages(state, operations) {
  for (const name of ['api', 'validation', 'git', 'deployment']) await executeStage(name, state, operations);
  state.success = finalSucceeded(state);
  return state;
}
function mainSnapshot() {
  git('fetch', 'origin', 'main');
  const sha = git('rev-parse', 'origin/main');
  const text = git('show', sha + ':' + dataFile);
  const assets = {};
  for (const file of ['data/supply-areas.js', 'app.js', 'styles.css', 'index.html']) assets[file] = hash(git('show', sha + ':public/' + file));
  return makeMeta(text, sha, { asset_hashes: assets });
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
    async deployment(state) {
      for (let change = 0; change < 3; change++) {
        const expected = mainSnapshot();
        state.production_expected = expected;
        save(path.join(temp, 'expected-meta.json'), expected);
        console.log('[NETLIFY] Verify production of current main ' + expected.commit_sha + ' (independent of API result)');
        const result = await ensureProduction(expected);
        const latest = git('ls-remote', 'origin', 'refs/heads/main').split(/\s+/)[0];
        if (latest === expected.commit_sha) return result;
        console.log('[SITE VERIFY] main moved; verify the newer commit before success');
      }
      throw new Error('main kept changing during production verification');
    },
  };
}
async function cli() {
  const stage = process.argv[2];
  const temp = process.env.PIPELINE_DIR || path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'apart-price-pipeline');
  const reportFile = path.join(temp, 'report.json');
  if (stage === 'prepare') {
    const collector = git('ls-tree', '-r', 'HEAD', '--', 'scripts', 'config');
    save(reportFile, { version, run_id: process.env.GITHUB_RUN_ID || 'local', mode: process.env.PIPELINE_MODE || 'auto',
      started_at: new Date().toISOString(), baseline_sha: git('rev-parse', 'HEAD'), collector_hash: hash(collector),
      baseline_data_hash: hash(fs.readFileSync(path.join(root, dataFile), 'utf8')) });
    return;
  }
  const state = readJson(reportFile);
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
      ['Netlify deployment', state.deployment?.status || 'not-run'],
      ['Production data verification', state.site?.status || 'not-run'],
      ['GitHub / site match', state.site?.status === 'success' ? 'YES' : 'NO'],
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
module.exports = { finalSucceeded, executeStage, runStages, sameCollector, assertSafeMainAdvance };
if (require.main === module) cli().catch(error => { console.error('[FINAL ERROR] ' + redact(error.message)); process.exitCode = 1; });
