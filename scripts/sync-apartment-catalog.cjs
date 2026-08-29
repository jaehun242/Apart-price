#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const valueAfter = (flag, fallback) => {
  const index = args.indexOf(flag);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
};

const repositoryRoot = path.resolve(__dirname, '..');
const dataPath = path.resolve(repositoryRoot, valueAfter('--data', 'public/data/transactions.js'));
const catalogPath = path.resolve(repositoryRoot, valueAfter('--catalog', 'config/additional-apartments.json'));
const dryRun = args.includes('--dry-run');
const wrapper = 'window.APT_ARCHIVE_DATA = ';

const readDataset = filePath => {
  const text = fs.readFileSync(filePath, 'utf8');
  if (!text.trimStart().startsWith(wrapper)) throw new Error(`Unexpected dataset wrapper: ${filePath}`);
  return JSON.parse(text.slice(text.indexOf('{'), text.lastIndexOf(';')));
};

const normalizeName = value => String(value || '')
  .normalize('NFKC')
  .toLowerCase()
  .replace(/i\s*[- ]?\s*park/g, '아이파크')
  .replace(/sk\s*view/g, '에스케이뷰')
  .replace(/아파트$/g, '')
  .replace(/[^0-9a-z가-힣]/g, '');

const dataset = readDataset(dataPath);
const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
if (!Array.isArray(dataset.complexes) || !Array.isArray(dataset.records)) throw new Error('Dataset must contain complexes and records arrays.');
if (!Array.isArray(catalog.complexes)) throw new Error('Catalog must contain a complexes array.');

const byId = new Map(dataset.complexes.map(item => [String(item.id), item]));
const normalizedByLocation = new Map();
for (const item of dataset.complexes) {
  const key = `${item.city}|${item.district}|${normalizeName(item.displayName || item.name)}`;
  normalizedByLocation.set(key, String(item.id));
}

let added = 0;
let updated = 0;
for (const entry of catalog.complexes) {
  for (const field of ['id', 'city', 'district', 'name']) {
    if (!String(entry[field] || '').trim()) throw new Error(`Catalog entry is missing ${field}: ${JSON.stringify(entry)}`);
  }
  const id = String(entry.id);
  const locationKey = `${entry.city}|${entry.district}|${normalizeName(entry.displayName || entry.name)}`;
  const duplicateId = normalizedByLocation.get(locationKey);
  if (duplicateId && duplicateId !== id) throw new Error(`Duplicate apartment name in ${entry.city} ${entry.district}: ${entry.name} (${duplicateId}, ${id})`);

  const existing = byId.get(id);
  if (existing) {
    const before = JSON.stringify(existing);
    if (entry.displayName) existing.displayName = entry.displayName;
    if (entry.featured != null) existing.featured = Boolean(entry.featured);
    if (entry.officialComplexCode) existing.officialComplexCode = String(entry.officialComplexCode);
    if (entry.openApi && !existing.openApi) existing.openApi = { ...entry.openApi };
    if (entry.openApiDiscovery && !existing.openApi && !existing.openApiDiscovery) existing.openApiDiscovery = { ...entry.openApiDiscovery };
    if (entry.aliases) existing.aliases = [...new Set([...(existing.aliases || []), ...entry.aliases].map(String))];
    if (entry.tags) existing.tags = [...new Set([...(existing.tags || []), ...entry.tags].map(String))];
    if (JSON.stringify(existing) !== before) updated++;
    continue;
  }

  const item = {
    id,
    city: entry.city,
    district: entry.district,
    name: entry.name,
    ...(entry.displayName ? { displayName: entry.displayName } : {}),
    leader: Boolean(entry.leader),
    featured: Boolean(entry.featured),
    tags: [...new Set((entry.tags || ['대표·신축 추가']).map(String))],
    ...(entry.aliases ? { aliases: [...new Set(entry.aliases.map(String))] } : {}),
    ...(entry.officialComplexCode ? { officialComplexCode: String(entry.officialComplexCode) } : {}),
    ...(entry.openApi ? { openApi: { ...entry.openApi } } : {}),
    ...(entry.openApiDiscovery ? { openApiDiscovery: { ...entry.openApiDiscovery } } : {}),
    catalogAddedAt: String(catalog.version || new Date().toISOString().slice(0, 10)),
    supplyMapping: entry.officialComplexCode ? 'verified-source' : 'pending-source-code',
    stats: { valid: 0, cancelled: 0, recentCancelled: 0, firstDate: null, lastDate: null, years: 0, groups: {} },
    dataMode: 'transactions',
    sourceLabel: '국토교통부 실거래가'
  };
  dataset.complexes.push(item);
  byId.set(id, item);
  normalizedByLocation.set(locationKey, id);
  added++;
}

const cityStats = {};
for (const item of dataset.complexes) {
  const city = String(item.city);
  cityStats[city] ||= { districtSet: new Set(), complexes: 0 };
  cityStats[city].districtSet.add(String(item.district));
  cityStats[city].complexes++;
}
dataset.meta ||= {};
dataset.meta.complexCount = dataset.complexes.length;
dataset.meta.cities = Object.fromEntries(Object.entries(cityStats).map(([city, info]) => [city, {
  districts: info.districtSet.size,
  complexes: info.complexes
}]));

if (!dryRun && (added || updated)) {
  fs.writeFileSync(dataPath, `${wrapper}${JSON.stringify(dataset)};\n`, 'utf8');
}

console.log(JSON.stringify({
  status: dryRun ? 'dry-run' : 'success',
  catalogVersion: catalog.version,
  added,
  updated,
  complexCount: dataset.complexes.length,
  recordCount: dataset.records.length,
  cities: dataset.meta.cities
}, null, 2));
