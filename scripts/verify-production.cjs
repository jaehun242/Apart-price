'use strict';
const { hash, parse, validateDataset } = require('./dataset-meta.cjs');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const fields = ['commit_sha', 'generated_at', 'data_refreshed_at', 'latest_contract_date', 'transaction_count', 'complex_count', 'data_sha256'];
function compareSite(expected, snapshot) {
  const differences = [];
  if (!snapshot.meta) return ['build-meta.json missing'];
  for (const field of fields) if (expected[field] !== snapshot.meta[field]) differences.push(field);
  if (snapshot.meta.provider !== 'netlify' || snapshot.meta.context !== 'production' || !snapshot.meta.deploy_id) differences.push('production deploy identity');
  for (const [file, value] of Object.entries(expected.asset_hashes || {})) {
    if (snapshot.meta.asset_hashes?.[file] !== value) differences.push('build asset ' + file);
  }
  if (snapshot.text == null || hash(snapshot.text) !== expected.data_sha256) differences.push('served transactions.js hash');
  if (snapshot.text != null) {
    try {
      const data = validateDataset(parse(snapshot.text));
      if (data.meta.generatedAt !== expected.generated_at || data.meta.rangeEnd !== expected.latest_contract_date || data.records.length !== expected.transaction_count) differences.push('served dataset metadata');
    } catch { differences.push('served dataset validation'); }
  }
  if (expected.asset_hashes?.['data/supply-areas.js'] && snapshot.supplyHash !== expected.asset_hashes['data/supply-areas.js']) differences.push('served supply mappings hash');
  if (snapshot.providerDeploy && (snapshot.providerDeploy.state !== 'ready' || snapshot.providerDeploy.commit_ref !== expected.commit_sha ||
      snapshot.providerDeploy.id !== snapshot.meta.deploy_id)) differences.push('Netlify production API');
  return differences;
}
async function fetchText(url, options = {}) {
  const response = await fetch(url, { signal: AbortSignal.timeout(60000), redirect: 'error', ...options });
  if (!response.ok) throw new Error('HTTP ' + response.status);
  return response.text();
}
async function readProduction(expected, siteUrl, env = process.env) {
  const origin = new URL(siteUrl);
  if (origin.protocol !== 'https:') throw new Error('Production URL must use HTTPS');
  const suffix = '?verify=' + expected.commit_sha + '-' + Date.now();
  const options = { headers: { 'Cache-Control': 'no-cache' } };
  const meta = JSON.parse(await fetchText(new URL('/data/build-meta.json' + suffix, origin), options));
  const snapshot = { meta };
  // Do not download the multi-MB archive repeatedly while waiting for the new build.
  if (meta.commit_sha === expected.commit_sha) {
    snapshot.text = await fetchText(new URL('/data/transactions.js' + suffix, origin), options);
    if (expected.asset_hashes?.['data/supply-areas.js']) snapshot.supplyHash = hash(await fetchText(new URL('/data/supply-areas.js' + suffix, origin), options));
  }
  if (env.NETLIFY_AUTH_TOKEN) {
    const site = JSON.parse(await fetchText('https://api.netlify.com/api/v1/sites/' + encodeURIComponent(origin.hostname), {
      headers: { Authorization: 'Bearer ' + env.NETLIFY_AUTH_TOKEN },
    }));
    if (![site.url, site.ssl_url, site.custom_domain && 'https://' + site.custom_domain].filter(Boolean).some(u => new URL(u).hostname === origin.hostname)) throw new Error('Netlify site identity mismatch');
    snapshot.providerDeploy = site.published_deploy;
  }
  return snapshot;
}
async function triggerRecovery(siteUrl, env = process.env) {
  if (env.NETLIFY_BUILD_HOOK) {
    const hook = new URL(env.NETLIFY_BUILD_HOOK);
    if (hook.protocol !== 'https:' || hook.hostname !== 'api.netlify.com' || !hook.pathname.startsWith('/build_hooks/')) throw new Error('Invalid Netlify build hook origin');
    hook.searchParams.set('trigger_branch', 'main');
    hook.searchParams.set('clear_cache', 'true');
    await fetchText(hook, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    return 'existing-netlify-build-hook';
  }
  if (env.NETLIFY_AUTH_TOKEN) {
    const headers = { Authorization: 'Bearer ' + env.NETLIFY_AUTH_TOKEN, 'Content-Type': 'application/json' };
    const hostname = new URL(siteUrl).hostname;
    const site = JSON.parse(await fetchText('https://api.netlify.com/api/v1/sites/' + encodeURIComponent(hostname), { headers }));
    if (![site.url, site.ssl_url].filter(Boolean).some(u => new URL(u).hostname === hostname)) throw new Error('Netlify recovery target mismatch');
    await fetchText('https://api.netlify.com/api/v1/sites/' + encodeURIComponent(site.id) + '/builds', {
      method: 'POST', headers, body: JSON.stringify({ branch: 'main', clear_cache: true }),
    });
    return 'existing-netlify-api-authorization';
  }
  throw new Error('No existing Netlify recovery authorization is available; the GitHub webhook alone cannot request a new build');
}
async function ensureProduction(expected, {
  read = () => readProduction(expected, process.env.PUBLIC_SITE_URL),
  trigger = () => triggerRecovery(process.env.PUBLIC_SITE_URL),
  wait = sleep, attempts = 31, intervalMs = 20000, log = console.log,
} = {}) {
  const result = { status: 'failed', site_status: 'failed', expected_sha: expected.commit_sha, actual_sha: null, recovery_attempts: 0, differences: [], recovery_errors: [] };
  for (let attempt = 1; attempt <= attempts; attempt++) {
    try {
      const snapshot = await read();
      result.actual_sha = snapshot.meta?.commit_sha || null;
      result.deploy_id = snapshot.meta?.deploy_id || null;
      result.status = snapshot.meta?.commit_sha === expected.commit_sha && snapshot.meta?.provider === 'netlify' &&
        snapshot.meta?.context === 'production' && snapshot.meta?.deploy_id &&
        (!snapshot.providerDeploy || (snapshot.providerDeploy.state === 'ready' && snapshot.providerDeploy.commit_ref === expected.commit_sha &&
          snapshot.providerDeploy.id === snapshot.meta.deploy_id)) ? 'success' : 'failed';
      result.deployment_evidence = snapshot.providerDeploy ? 'Netlify production API and build metadata' : 'Netlify build-time production metadata';
      result.differences = compareSite(expected, snapshot);
      log('[SITE VERIFY] expected ' + expected.commit_sha + ' / actual ' + (result.actual_sha || 'missing') + ' / ' + result.differences.join(', '));
      if (!result.differences.length) return { ...result, status: 'success', site_status: 'success' };
    } catch (error) {
      result.differences = [error.message];
      log('[NETLIFY] production not verified (' + attempt + '/' + attempts + '): ' + error.message);
    }
    if ([4, 13].includes(attempt)) {
      result.recovery_attempts++;
      try { result.recovery_method = await trigger(); log('[NETLIFY] deployment-only recovery requested'); }
      catch (error) { result.recovery_errors.push(error.message); log('[DEPLOY ERROR] ' + error.message); }
    }
    if (attempt < attempts) await wait(intervalMs);
  }
  const error = new Error('[SITE VERIFY ERROR] Production does not match GitHub main; workflow must fail');
  error.result = result;
  throw error;
}
module.exports = { compareSite, ensureProduction, readProduction, triggerRecovery };
