'use strict';
// Build-time output, never committed: a tracked file cannot contain its own commit SHA.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { readMeta } = require('./dataset-meta.cjs');
const root = path.resolve(__dirname, '..');
// HEAD includes any data commit created earlier in this same workflow.
// GITHUB_SHA still identifies the workflow's trigger commit, not that later data commit.
const commit = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const meta = readMeta(root, commit, {
  provider: process.env.GITHUB_ACTIONS ? 'github-pages' : 'local',
  context: process.env.GITHUB_ACTIONS ? 'production' : 'local',
  workflow_commit_sha: process.env.GITHUB_SHA || null,
  workflow_run_id: process.env.GITHUB_RUN_ID || null,
  built_at: new Date().toISOString(),
});
fs.writeFileSync(path.join(root, 'public/data/build-meta.json'), JSON.stringify(meta, null, 2) + '\n');
console.log('[BUILD META] commit ' + meta.commit_sha + ' / ' + meta.transaction_count + ' transactions');
