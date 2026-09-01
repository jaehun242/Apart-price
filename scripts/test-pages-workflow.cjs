'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),folder=path.join(root,'.github/workflows'),workflows=fs.readdirSync(folder).filter(f=>/\.ya?ml$/.test(f)).sort();
assert.deepEqual(workflows,['daily-update.yml','rone-monthly-index.yml']);
const daily=fs.readFileSync(path.join(folder,'daily-update.yml'),'utf8'),rone=fs.readFileSync(path.join(folder,'rone-monthly-index.yml'),'utf8');
assert.match(daily,/push:\s*\n\s+branches: \[main\]/);assert.match(daily,/cron: "0 22 \* \* \*"/);assert.match(rone,/cron: "20 2 \* \* 3"/);
for(const workflow of [daily,rone]){for(const permission of ['contents: write','pages: write','id-token: write'])assert.ok(workflow.includes(permission));assert.match(workflow,/group: apartment-data-pages-production\s+cancel-in-progress: false/);for(const action of ['actions\/configure-pages@v5','actions\/upload-pages-artifact@v4','actions\/deploy-pages@v4'])assert.match(workflow,new RegExp(action));assert.match(workflow,/path: public\//);assert.doesNotMatch(workflow,/NETLIFY|netlify\.app/i);}
assert.match(rone,/secrets\.RONE_API_KEY/);assert.match(rone,/node scripts\/update-rone-index\.cjs/);assert.match(rone,/node scripts\/validate-rone-index\.cjs/);assert.match(rone,/node scripts\/crosscheck-rone-points\.cjs/);assert.match(rone,/git status --porcelain -- public\/data\/rone-apartment-index\.json/);assert.match(rone,/node scripts\/verify-rone-pages\.cjs/);
console.log('PASS: daily and R-ONE workflows share one production lock, deploy public with official Pages actions, and contain no Netlify dependency');
