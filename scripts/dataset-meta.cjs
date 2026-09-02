'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const normalize = text => text.replace(/\r\n/g, '\n').trimEnd();
const hash = text => crypto.createHash('sha256').update(normalize(text), 'utf8').digest('hex');
const parse = text => {
  if (!/^\s*window\.APT_ARCHIVE_DATA\s*=/.test(text)) throw new Error('Unexpected dataset wrapper');
  return JSON.parse(text.replace(/^\s*window\.APT_ARCHIVE_DATA\s*=\s*/, '').replace(/;\s*$/, ''));
};
const koreaDate = (date = new Date()) => new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit',
}).format(date);
function validateDataset(data) {
  if (!Array.isArray(data.complexes) || !Array.isArray(data.records) || !data.records.length) throw new Error('Empty/invalid dataset');
  if (data.complexes.length !== data.meta.complexCount || data.records.length !== data.meta.recordCount) throw new Error('Metadata count mismatch');
  const complexes = new Set(data.complexes.map(c => c.id)), ids = new Set();
  if (complexes.size !== data.complexes.length) throw new Error('Duplicate complex id');
  let latest = '';
  const today = koreaDate();
  for (const r of data.records) {
    if (!complexes.has(r.complexId) || !Number.isFinite(r.area) || r.area <= 0 || !Number.isFinite(r.price) || r.price <= 0) throw new Error('Invalid required transaction field');
    if (!/^\d{4}-\d{2}-\d{2}$/.test(r.date) || !Number.isFinite(Date.parse(r.date)) ||
        new Date(r.date).toISOString().slice(0, 10) !== r.date || r.date < '2015-01-01' || r.date > today) throw new Error('Invalid contract date');
    if (!Object.hasOwn(r, 'first_seen_at')) throw new Error('Missing first_seen_at');
    if (r.first_seen_at != null && (!/^\d{4}-\d{2}-\d{2}$/.test(r.first_seen_at) ||
        !Number.isFinite(Date.parse(r.first_seen_at)) || new Date(r.first_seen_at).toISOString().slice(0, 10) !== r.first_seen_at || r.first_seen_at > today)) throw new Error('Invalid first_seen_at');
    const py = Math.round(r.area / 3.305785 * 10) / 10, group = Math.floor(r.area / 3.305785 / 10) * 10;
    if (Math.abs(r.py - py) > 0.0001 || r.group !== group) throw new Error('Exclusive area conversion changed');
    if (r.transactionId) {
      const id = r.complexId + '|' + r.transactionId;
      if (ids.has(id)) throw new Error('Duplicate transactionId');
      ids.add(id);
    }
    if (r.date > latest) latest = r.date;
  }
  if (data.meta.rangeEnd !== latest) throw new Error('Latest contract date mismatch');
  return data;
}
function makeMeta(text, commitSha, extra = {}) {
  if (!/^[a-f0-9]{40}$/.test(commitSha)) throw new Error('A full Git commit SHA is required');
  const data = validateDataset(parse(text));
  return {
    schema_version: 1, commit_sha: commitSha, generated_at: data.meta.generatedAt,
    data_refreshed_at: data.meta.lastRefresh?.completedAt || data.meta.generatedAt,
    latest_contract_date: data.meta.rangeEnd, transaction_count: data.records.length,
    complex_count: data.complexes.length, data_sha256: hash(text), ...extra,
  };
}
function readMeta(root, commitSha, extra = {}) {
  const assets = {};
  for (const file of ['data/supply-areas.js', 'data/apartment-transaction-price-index.json', 'rone-index.js', 'app.js', 'styles.css', 'index.html']) {
    const full = path.join(root, 'public', file);
    if (fs.existsSync(full)) assets[file] = hash(fs.readFileSync(full, 'utf8'));
  }
  return makeMeta(fs.readFileSync(path.join(root, 'public/data/transactions.js'), 'utf8'), commitSha, { asset_hashes: assets, ...extra });
}
module.exports = { normalize, hash, parse, validateDataset, makeMeta, readMeta, koreaDate };
