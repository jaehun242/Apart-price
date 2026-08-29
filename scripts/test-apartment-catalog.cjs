#!/usr/bin/env node
'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const repositoryRoot = path.resolve(__dirname, '..');
const sourceData = path.join(repositoryRoot, 'public/data/transactions.js');
const catalogPath = path.join(repositoryRoot, 'config/additional-apartments.json');
const syncScript = path.join(repositoryRoot, 'scripts/sync-apartment-catalog.cjs');
const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'apart-price-catalog-'));
const temporaryData = path.join(temporaryDirectory, 'transactions.js');
const parseDataset = filePath => {
  const text = fs.readFileSync(filePath, 'utf8');
  return JSON.parse(text.slice(text.indexOf('{'), text.lastIndexOf(';')));
};

try {
  fs.copyFileSync(sourceData, temporaryData);
  const before = parseDataset(temporaryData);
  const beforeRecordText = JSON.stringify(before.records);
  const catalog = JSON.parse(fs.readFileSync(catalogPath, 'utf8'));
  const catalogMapped = catalog.complexes.filter(entry => entry.openApi?.identityKey);
  const catalogDeferred = catalog.complexes.filter(entry => entry.openApiDiscovery?.nextAttempt);
  assert.strictEqual(catalogMapped.length + catalogDeferred.length, catalog.complexes.length, 'Every added catalog complex must have a cached OpenAPI identity or an explicit deferred retry.');
  assert.strictEqual(new Set(catalogMapped.map(entry => entry.openApi.identityKey)).size, catalogMapped.length, 'Cached catalog OpenAPI identities must be unique.');
  const runSync = () => childProcess.execFileSync(process.execPath, [syncScript, '--data', temporaryData, '--catalog', catalogPath], { encoding: 'utf8' });

  runSync();
  const after = parseDataset(temporaryData);
  const expectedAdded = catalog.complexes.filter(entry => !before.complexes.some(item => item.id === entry.id)).length;
  assert.strictEqual(after.complexes.length, before.complexes.length + expectedAdded, 'Catalog additions were not merged exactly once.');
  assert.strictEqual(JSON.stringify(after.records), beforeRecordText, 'Catalog sync must not alter transaction records.');
  assert.strictEqual(after.meta.complexCount, after.complexes.length, 'Complex metadata count is stale.');

  const ids = new Set();
  const names = new Set();
  for (const item of after.complexes) {
    assert(!ids.has(item.id), `Duplicate complex id: ${item.id}`);
    ids.add(item.id);
    const key = `${item.city}|${item.district}|${String(item.displayName || item.name).replace(/[^0-9a-z가-힣]/gi, '').toLowerCase()}`;
    assert(!names.has(key), `Duplicate complex name: ${key}`);
    names.add(key);
  }

  const grouped = new Map();
  for (const item of after.complexes) {
    const key = `${item.city}|${item.district}`;
    grouped.set(key, (grouped.get(key) || 0) + 1);
  }
  for (const [key, count] of grouped) assert(count >= catalog.minimumPerDistrict, `${key} has only ${count} complexes.`);

  const oryukdo = after.complexes.find(item => (item.displayName || item.name) === '오륙도SK뷰');
  assert(oryukdo, '오륙도SK뷰 must remain in the catalog.');
  assert.strictEqual(oryukdo.featured, true, '오륙도SK뷰 must be pinned as a featured complex.');

  const requiredLandmarks = [
    ['busan-26290-20362232', '부산 남구 W'],
    ['busan-26290-20106194', '부산 남구 오륙도SK뷰'],
    ['busan-26350-20147549', '부산 해운대 두산위브더제니스'],
    ['busan-26350-20145382', '부산 해운대 아이파크'],
    ['busan-26350-20396002', '부산 해운대 엘시티'],
    ['busan-26350-20394309', '부산 마린시티자이'],
    ['busan-26350-20108501', '부산 더샵센텀스타'],
    ['seoul-11680-20325153', '서울 래미안대치팰리스'],
    ['seoul-11680-20027111', '서울 도곡렉슬'],
    ['seoul-11680-51427', '서울 압구정현대'],
    ['seoul-11680-catalog-005', '서울 은마'],
    ['seoul-11680-catalog-006', '서울 타워팰리스'],
    ['seoul-11650-20447603', '서울 래미안원베일리'],
    ['seoul-11650-20345416', '서울 아크로리버파크'],
    ['seoul-11170-20135016', '서울 한남더힐'],
    ['seoul-11170-20395488', '서울 나인원한남'],
    ['seoul-11710-20107304', '서울 잠실엘스'],
    ['seoul-11710-20099495', '서울 리센츠']
  ];
  for (const [id, label] of requiredLandmarks) {
    const landmark = after.complexes.find(item => item.id === id);
    assert(landmark, `${label} must remain in the catalog.`);
    assert.strictEqual(landmark.featured, true, `${label} must remain featured.`);
  }
  const w = after.complexes.find(item => item.id === 'busan-26290-20362232');
  assert(/W아파트/.test(w.displayName), 'W must use the recognizable W아파트 display name.');

  runSync();
  const second = parseDataset(temporaryData);
  assert.strictEqual(second.complexes.length, after.complexes.length, 'Catalog sync must be idempotent.');
  assert.strictEqual(JSON.stringify(second.records), beforeRecordText, 'Idempotent sync altered transactions.');
  console.log(`Apartment catalog tests passed: ${before.complexes.length} -> ${after.complexes.length}, ${catalogMapped.length} cached OpenAPI identities, ${catalogDeferred.length} deferred retries, every district >= ${catalog.minimumPerDistrict}, ${requiredLandmarks.length} landmarks protected.`);
} finally {
  fs.rmSync(temporaryDirectory, { recursive: true, force: true });
}
