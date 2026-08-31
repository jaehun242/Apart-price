'use strict';
// Build-time output, never committed: a tracked file cannot contain its own commit SHA.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { readMeta } = require('./dataset-meta.cjs');
const root = path.resolve(__dirname, '..');
const commit = process.env.COMMIT_REF || execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim();
const meta = readMeta(root, commit, {
  provider: process.env.NETLIFY ? 'netlify' : 'local',
  context: process.env.CONTEXT || 'local', deploy_id: process.env.DEPLOY_ID || null,
  built_at: new Date().toISOString(),
});
fs.writeFileSync(path.join(root, 'public/data/build-meta.json'), JSON.stringify(meta, null, 2) + '\n');
console.log('[BUILD META] commit ' + meta.commit_sha + ' / ' + meta.transaction_count + ' transactions');
