'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const folder = path.join(root, '.github/workflows');
const workflows = fs.readdirSync(folder).filter(f => /\.ya?ml$/.test(f));
assert.deepEqual(workflows, ['daily-update.yml'], 'A second push deployment could conflict with daily Pages publication');
const workflow = fs.readFileSync(path.join(folder, workflows[0]), 'utf8');
assert.match(workflow, /push:\s*\n\s+branches: \[main\]/);
assert.match(workflow, /cron: "0 22 \* \* \*"/, '22:00 UTC must remain 07:00 KST');
assert.equal((workflow.match(/cron:/g) || []).length, 1);
for (const permission of ['contents: write', 'pages: write', 'id-token: write', 'actions: read']) assert.ok(workflow.includes(permission));
assert.match(workflow, /group: daily-apartment-transaction-update\s+cancel-in-progress: false/);
assert.match(workflow, /name: github-pages/);
assert.match(workflow, /secrets\.MOLIT_API_KEY/);
assert.doesNotMatch(workflow, /NETLIFY|netlify\.app|verify\.outputs\.changed/i);
const steps = [
  'run: node scripts/update-pipeline.cjs git',
  'run: node scripts/update-pipeline.cjs pages_source',
  'uses: actions/configure-pages@v5',
  'uses: actions/upload-pages-artifact@v4',
  'run: node scripts/update-pipeline.cjs pages_guard',
  'uses: actions/deploy-pages@v4',
  'run: node scripts/update-pipeline.cjs deployment',
];
let last = -1;
for (const step of steps) {
  const index = workflow.indexOf(step);
  assert.ok(index > last, 'Pages must follow validated storage in the same workflow: ' + step);
  last = index;
}
assert.match(workflow, /uses: actions\/upload-pages-artifact@v4\s+with:\s+path: public\//);
assert.match(workflow, /id: pages_deploy\s+if:.*success\(\)/);
assert.match(workflow, /PAGES_DEPLOY_OUTCOME:.*steps\.pages_deploy\.outcome/);
assert.doesNotMatch(workflow, /continue-on-error:/);
for (const file of ['update-pipeline.cjs', 'write-build-meta.cjs']) {
  assert.doesNotMatch(fs.readFileSync(path.join(root, 'scripts', file), 'utf8'), /NETLIFY|netlify\.app|verify-production/i);
}
assert.equal(fs.existsSync(path.join(root, 'netlify.toml')), false);
assert.equal(fs.existsSync(path.join(root, 'scripts/verify-production.cjs')), false);
console.log('PASS: one serialized workflow, 07:00 KST, exact Pages Actions/permissions, public-only upload, failure gates and no legacy deployment dependency');
