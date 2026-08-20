import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

function loadBrowserData(path, globalName) {
  const context = { window: {} };
  vm.runInNewContext(fs.readFileSync(path, 'utf8'), context, { filename: path });
  assert.ok(context.window[globalName], `${globalName} was not loaded`);
  return context.window[globalName];
}

const transactions = loadBrowserData('public/data/transactions.js', 'APT_ARCHIVE_DATA');
const supply = loadBrowserData('public/data/supply-areas.js', 'APT_SUPPLY_AREA_DATA');
const appSource = fs.readFileSync('public/app.js', 'utf8');
const htmlSource = fs.readFileSync('public/index.html', 'utf8');

const areaKey = area => String(Number(area));
const mappingFor = record => supply.complexes[record.complexId]?.areas?.[areaKey(record.area)] ?? null;

assert.equal(Object.keys(supply.complexes).length, transactions.complexes.length, 'every complex must have a mapping entry');
assert.equal(supply.meta.complexCount, transactions.complexes.length);

let mappedAreas = 0;
let unresolvedAreas = 0;
let mappedRecords = 0;
let unresolvedRecords = 0;
const areaCounts = new Map();

for (const record of transactions.records) {
  const key = `${record.complexId}|${areaKey(record.area)}`;
  areaCounts.set(key, (areaCounts.get(key) ?? 0) + 1);
  const mapping = mappingFor(record);
  if (mapping) mappedRecords++;
  else unresolvedRecords++;
}

for (const [complexId, complex] of Object.entries(supply.complexes)) {
  assert.ok(transactions.complexes.some(item => item.id === complexId), `unknown complex ${complexId}`);
  for (const [area, mapping] of Object.entries(complex.areas)) {
    const recordCount = areaCounts.get(`${complexId}|${area}`) ?? 0;
    assert.ok(recordCount > 0, `${complexId} ${area} has no source record`);
    if (!mapping) {
      unresolvedAreas++;
      continue;
    }
    mappedAreas++;
    assert.ok(Number.isInteger(mapping.pyeong) && mapping.pyeong > 0, `${complexId} ${area} has invalid pyeong`);
    assert.equal(mapping.group, Math.floor(mapping.pyeong / 10) * 10, `${complexId} ${area} has invalid group`);
    assert.ok(['source-floor-plan', 'source-floor-plan-pyeong', 'source-pyeong-label'].includes(mapping.method), `${complexId} ${area} used an unsupported method`);
    if (mapping.supplyArea != null) {
      assert.equal(mapping.pyeong, Math.floor(mapping.supplyArea / 3.305785 + Number.EPSILON), `${complexId} ${area} supply pyeong mismatch`);
    } else {
      assert.notEqual(mapping.method, 'source-floor-plan', `${complexId} ${area} lost its exact supply area`);
    }
  }
}

assert.equal(mappedAreas, supply.meta.mappedAreaCount);
assert.equal(unresolvedAreas, supply.meta.unresolvedAreaCount);
assert.equal(mappedRecords, supply.meta.mappedRecordCount);
assert.equal(unresolvedRecords, supply.meta.unresolvedRecordCount);
assert.equal(mappedRecords + unresolvedRecords, transactions.records.length);

const expected = [
  ['busan-26290-20362232', '98.9922', 130.12, 39, 30],
  ['busan-26350-20145382', '80.572', 121.29, 36, 30],
  ['busan-26350-20145382', '110.447', 159, 48, 40],
  ['busan-26350-20069315', '158.74', 197.38, 59, 50],
  ['busan-26350-20069315', '171.7', 212.93, 64, 60],
  ['busan-26350-20069315', '187.88', 229.78, 69, 60],
  ['busan-26350-20069315', '217.95', 263.67, 79, 70],
  ['busan-26440-20412469', '80.7864', 109.06, 32, 30],
  ['busan-26440-20412469', '84.9584', 115.02, 34, 30],
  ['busan-26440-20412469', '84.997', 114.48, 34, 30],
  ['busan-26440-20412469', '99.9247', 135.16, 40, 40],
  ['busan-26440-20412469', '113.9349', 152.21, 46, 40],
  ['busan-26440-20414377', '80.7864', 108.82, 32, 30],
  ['busan-26440-20414377', '84.9584', 114.77, 34, 30],
  ['busan-26440-20414377', '84.997', 114.23, 34, 30],
  ['busan-26440-20414377', '99.9247', 134.87, 40, 40],
  ['busan-26440-20414377', '113.9349', 151.87, 45, 40]
];

for (const [complexId, area, supplyArea, pyeong, group] of expected) {
  const actual = supply.complexes[complexId]?.areas?.[area];
  assert.ok(actual, `required sample ${complexId} ${area} is unresolved`);
  assert.equal(actual.supplyArea, supplyArea, `${complexId} ${area} supply area`);
  assert.equal(actual.pyeong, pyeong, `${complexId} ${area} pyeong`);
  assert.equal(actual.group, group, `${complexId} ${area} group`);
}

assert.match(appSource, /const supplyDataset = window\.APT_SUPPLY_AREA_DATA/);
assert.match(appSource, /공급면적 확인 필요/);
assert.doesNotMatch(appSource, /EXCLUSIVE_PY_DIVISOR|roundedExclusivePy|exclusiveGroup/);
assert.match(htmlSource, /공급면적대별 가격 흐름/);
assert.match(htmlSource, /data\/supply-areas\.js/);

console.log(`PASS: ${transactions.records.length.toLocaleString('en-US')} records, ${mappedRecords.toLocaleString('en-US')} mapped, ${unresolvedRecords.toLocaleString('en-US')} unresolved`);
console.log('PASS: required W, Haeundae I PARK, Trump World Marine, Myeongji 2/3 samples');
