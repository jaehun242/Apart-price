#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const valueAfter = flag => {
  const index = args.indexOf(flag);
  if (index < 0 || !args[index + 1]) throw new Error(`Missing ${flag}.`);
  return path.resolve(args[index + 1]);
};

const reportPath = valueAfter('--report');
const logPath = valueAfter('--log');
const catalogPath = path.resolve(args.includes('--catalog') ? args[args.indexOf('--catalog') + 1] : path.join(__dirname, '..', 'config', 'additional-apartments.json'));
const report = fs.readFileSync(reportPath, 'utf8');
const runLog = JSON.parse(fs.readFileSync(logPath, 'utf8'));
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));

const matchByNameAndLawd = new Map();
for (const line of report.split(/\r?\n/)) {
  if (!/^\| .+ \| \d{5} \|/.test(line) || /^\|---/.test(line)) continue;
  const [projectName, lawdCode, aptName, legalDong, jibun, aptSeq] = line.split('|').slice(1, -1).map(value => value.trim());
  if (!aptSeq) throw new Error(`Matched row has no aptSeq: ${line}`);
  const key = `${lawdCode}|${projectName}`;
  if (matchByNameAndLawd.has(key)) throw new Error(`Duplicate matched project row: ${key}`);
  matchByNameAndLawd.set(key, { lawdCode, aptName, legalDong, jibun, aptSeq });
}

const unmatchedById = new Map((runLog.unmatchedComplexes || []).map(item => [String(item.Id), item]));
const lastAttempt = String(runLog.finishedAt || '').slice(0, 10);
if (!/^\d{4}-\d{2}-\d{2}$/.test(lastAttempt)) throw new Error('Run log has no valid finishedAt date.');
const retryDate = new Date(`${lastAttempt}T00:00:00Z`);
retryDate.setUTCDate(retryDate.getUTCDate() + 7);
const nextAttempt = retryDate.toISOString().slice(0, 10);

let cached = 0;
let deferred = 0;
for (const entry of catalog.complexes) {
  const lawdCode = String(entry.id).split('-')[1];
  const match = matchByNameAndLawd.get(`${lawdCode}|${entry.name}`);
  if (match) {
    entry.openApi = {
      lawdCode: match.lawdCode,
      identityKey: `${match.lawdCode}|seq|${match.aptSeq}`,
      aptSeq: match.aptSeq,
      aptName: match.aptName,
      legalDong: match.legalDong,
      jibun: match.jibun,
      roadName: '',
      matchedBy: 'catalog-cache'
    };
    delete entry.openApiDiscovery;
    cached++;
    continue;
  }
  if (!unmatchedById.has(String(entry.id))) throw new Error(`Catalog entry was neither matched nor deferred: ${entry.id} ${entry.name}`);
  entry.openApiDiscovery = {
    status: 'deferred',
    lastAttempt,
    nextAttempt,
    reason: 'No unique MOLIT OpenAPI transaction identity was found during the 24-month discovery scan.'
  };
  delete entry.openApi;
  deferred++;
}

if (cached + deferred !== catalog.complexes.length) throw new Error('Catalog cache accounting failed.');
fs.writeFileSync(catalogPath, `${JSON.stringify(catalog, null, 2)}\n`, 'utf8');
console.log(JSON.stringify({ cached, deferred, total: catalog.complexes.length, lastAttempt, nextAttempt }, null, 2));
