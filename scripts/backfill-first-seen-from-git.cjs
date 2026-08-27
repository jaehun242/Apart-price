'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const childProcess = require('node:child_process');

const DATA_PREFIX = /^\s*window\.APT_ARCHIVE_DATA\s*=\s*/;
const DATA_SUFFIX = /;\s*$/;

function parseArgs(argv) {
  const options = { snapshots: [], apply: false, git: 'git' };
  for (let index = 0; index < argv.length; index += 1) {
    const name = argv[index];
    if (name === '--apply') options.apply = true;
    else if (name === '--baseline') options.baseline = argv[++index];
    else if (name === '--week-start') options.weekStart = argv[++index];
    else if (name === '--snapshot') options.snapshots.push(argv[++index]);
    else if (name === '--data') options.data = argv[++index];
    else if (name === '--report') options.report = argv[++index];
    else if (name === '--backup') options.backup = argv[++index];
    else if (name === '--git') options.git = argv[++index];
    else throw new Error(`Unknown argument: ${name}`);
  }
  if (!options.baseline || !options.weekStart || !options.snapshots.length) {
    throw new Error('Required: --baseline COMMIT --week-start YYYY-MM-DD --snapshot COMMIT:YYYY-MM-DD');
  }
  options.snapshotSpecs = options.snapshots.map(value => {
    const match = value.match(/^([0-9a-f]{7,40}):(\d{4}-\d{2}-\d{2})$/i);
    if (!match) throw new Error(`Invalid snapshot: ${value}`);
    return { commit: match[1], seenDate: match[2] };
  });
  return options;
}

function parseDataset(text) {
  return JSON.parse(text.replace(DATA_PREFIX, '').replace(DATA_SUFFIX, ''));
}

function loadGitDataset(gitExecutable, commit) {
  const text = childProcess.execFileSync(gitExecutable, ['show', `${commit}:public/data/transactions.js`], {
    encoding: 'utf8', maxBuffer: 96 * 1024 * 1024, windowsHide: true
  });
  return parseDataset(text);
}

const value = (record, name) => record?.[name] ?? '';
const areaText = record => Number(record.area).toFixed(4);
const floorText = record => record.floor == null ? '' : String(record.floor);
const dongText = record => ['-', ''].includes(String(value(record, 'apartmentDong')).trim()) ? '' : String(record.apartmentDong).trim();
const idKey = record => value(record, 'transactionId') ? `${record.complexId}|${record.transactionId}` : null;
const trackingKey = record => value(record, 'tracking_key') || null;
const exactComparableKey = record => `${record.complexId}|${record.date}|${areaText(record)}|${record.price}|${floorText(record)}`;
const strongCorrectionKey = record => dongText(record) ? `${record.complexId}|${record.date}|${areaText(record)}|${floorText(record)}|${dongText(record)}` : null;
const registrationKey = record => {
  const registration = String(value(record, 'registration')).trim();
  return registration && registration !== '-' ? `${record.complexId}|${registration}|${areaText(record)}|${floorText(record)}|${dongText(record)}` : null;
};
const dateCorrectionKey = record => dongText(record) ? `${record.complexId}|${areaText(record)}|${floorText(record)}|${dongText(record)}|${record.price}` : null;
const legacyCorrectionKey = record => `${record.complexId}|${record.date}|${areaText(record)}|${floorText(record)}`;

function visibleSignature(record) {
  return JSON.stringify({
    complexId: record.complexId, date: record.date, area: record.area,
    price: record.price, floor: record.floor, kind: record.kind
  });
}

function reconcileRows(existingRows, incomingRows, options = {}) {
  const existing = [...existingRows];
  const incoming = [...incomingRows];
  const oldMatched = new Uint8Array(existing.length);
  const newMatched = new Uint8Array(incoming.length);
  const pairs = [];
  const provenance = options.provenance || new WeakMap();

  for (const record of existing) if (!Object.hasOwn(record, 'first_seen_at')) record.first_seen_at = null;
  for (const record of incoming) if (!Object.hasOwn(record, 'first_seen_at')) record.first_seen_at = null;

  function matchByKey(keyFunction, uniqueOnly = false) {
    const oldGroups = new Map();
    const newGroups = new Map();
    existing.forEach((record, index) => {
      if (oldMatched[index]) return;
      const key = keyFunction(record);
      if (!key) return;
      if (!oldGroups.has(key)) oldGroups.set(key, []);
      oldGroups.get(key).push(index);
    });
    incoming.forEach((record, index) => {
      if (newMatched[index]) return;
      const key = keyFunction(record);
      if (!key) return;
      if (!newGroups.has(key)) newGroups.set(key, []);
      newGroups.get(key).push(index);
    });
    for (const [key, newIndexes] of newGroups) {
      const oldIndexes = oldGroups.get(key);
      if (!oldIndexes || (uniqueOnly && (oldIndexes.length !== 1 || newIndexes.length !== 1))) continue;
      const pairCount = Math.min(oldIndexes.length, newIndexes.length);
      for (let pairIndex = 0; pairIndex < pairCount; pairIndex += 1) {
        const oldIndex = oldIndexes[pairIndex];
        const newIndex = newIndexes[pairIndex];
        oldMatched[oldIndex] = 1;
        newMatched[newIndex] = 1;
        pairs.push([oldIndex, newIndex]);
      }
    }
  }

  matchByKey(idKey);
  matchByKey(trackingKey);
  matchByKey(exactComparableKey);
  matchByKey(strongCorrectionKey);
  matchByKey(registrationKey, true);
  matchByKey(dateCorrectionKey, true);
  matchByKey(legacyCorrectionKey, true);

  let correctedCount = 0;
  let rekeyedCount = 0;
  for (const [oldIndex, newIndex] of pairs) {
    const oldRecord = existing[oldIndex];
    const newRecord = incoming[newIndex];
    newRecord.first_seen_at = oldRecord.first_seen_at || null;
    if (provenance.has(oldRecord)) provenance.set(newRecord, provenance.get(oldRecord));
    if (visibleSignature(oldRecord) !== visibleSignature(newRecord)) correctedCount += 1;
    if (value(oldRecord, 'transactionId') !== value(newRecord, 'transactionId')) rekeyedCount += 1;
  }

  let newCount = 0;
  incoming.forEach((record, index) => {
    if (newMatched[index]) return;
    record.first_seen_at = options.seenDate;
    provenance.set(record, { commit: options.sourceCommit, seenDate: options.seenDate });
    newCount += 1;
  });

  return {
    rows: incoming, newCount, removedCount: existing.length - pairs.length,
    correctedCount, rekeyedCount, matchedCount: pairs.length, provenance
  };
}

function coreFingerprint(dataset) {
  const hash = crypto.createHash('sha256');
  hash.update(JSON.stringify(dataset.complexes));
  for (const record of dataset.records) {
    const copy = { ...record };
    delete copy.first_seen_at;
    hash.update(JSON.stringify(copy));
    hash.update('\n');
  }
  return hash.digest('hex');
}

function formatNumber(value) { return new Intl.NumberFormat('ko-KR').format(value); }

function makeReport(options, current, results, weeklyRows, provenance) {
  const complexById = new Map(current.complexes.map(item => [item.id, item]));
  const lines = [
    '# 이번 주 신규 실거래 Git 이력 복원 보고서', '',
    `- 주간 시작: ${options.weekStart} 00:00 KST`,
    `- 기준 커밋: \`${options.baseline}\``,
    `- 비교 커밋: ${options.snapshotSpecs.map(item => `\`${item.commit}\` (${item.seenDate})`).join(' → ')}`,
    `- 현재 남아 있는 이번 주 신규 실거래: **${weeklyRows.length}건**`,
    '- 판별 순서: transactionId → tracking_key → 계약일·면적·가격·층 동일키 → 정정키',
    '- 해제·삭제 거래는 현재 데이터에 없으므로 목록에서 제외', '',
    '## 커밋별 비교', '',
    '| 최초 등장일 | 커밋 | 기존 연결 | ID 변경 연결 | 내용 정정 연결 | 신규 | 삭제·해제 |',
    '|---|---|---:|---:|---:|---:|---:|'
  ];
  for (const result of results) {
    lines.push(`| ${result.seenDate} | \`${result.commit}\` | ${formatNumber(result.matchedCount)} | ${formatNumber(result.rekeyedCount)} | ${formatNumber(result.correctedCount)} | ${formatNumber(result.newCount)} | ${formatNumber(result.removedCount)} |`);
  }
  lines.push('', '## 현재 표시 대상 거래 검증', '', '| 최초수집일 | 계약일 | 지역·단지 | 전용면적 | 층 | 가격 | transactionId | 최초 등장 커밋 |', '|---|---|---|---:|---:|---:|---|---|');
  for (const record of weeklyRows) {
    const complex = complexById.get(record.complexId) || {};
    const source = provenance.get(record) || {};
    const name = complex.displayName || complex.name || record.complexId;
    lines.push(`| ${record.first_seen_at} | ${record.date} | ${complex.city || ''} ${complex.district || ''} · ${name} | ${Number(record.area).toFixed(2)}㎡ | ${record.floor == null ? '—' : `${record.floor}층`} | ${formatNumber(record.price)}만원 | \`${record.transactionId || '—'}\` | \`${source.commit || '—'}\` |`);
  }
  return lines.join('\n');
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const repository = path.resolve(__dirname, '..');
  const dataPath = path.resolve(repository, options.data || 'public/data/transactions.js');
  const reportPath = path.resolve(repository, options.report || `reports/weekly-first-seen-backfill-${options.weekStart}.md`);
  const backupPath = path.resolve(options.backup || path.join(os.tmpdir(), 'apart-price-transactions.before-weekly-backfill.js'));
  const currentText = fs.readFileSync(dataPath, 'utf8');
  const current = parseDataset(currentText);
  const recordCountBefore = current.records.length;
  const fingerprintBefore = coreFingerprint(current);
  const provenance = new WeakMap();
  const baseline = loadGitDataset(options.git, options.baseline);
  let stateRows = baseline.records.filter(record => record.kind === '아파트 매매');
  for (const record of stateRows) record.first_seen_at = null;
  const results = [];

  for (const snapshot of options.snapshotSpecs) {
    const dataset = loadGitDataset(options.git, snapshot.commit);
    const incoming = dataset.records.filter(record => record.kind === '아파트 매매');
    const result = reconcileRows(stateRows, incoming, {
      seenDate: snapshot.seenDate, sourceCommit: snapshot.commit, provenance
    });
    results.push({ ...snapshot, ...result });
    stateRows = result.rows;
  }

  const currentActual = current.records.filter(record => record.kind === '아파트 매매');
  const currentResult = reconcileRows(stateRows, currentActual, {
    seenDate: current.meta.generatedAt, sourceCommit: 'working-tree', provenance
  });
  if (currentResult.newCount || currentResult.removedCount) {
    throw new Error(`Current data differs from last audited snapshot: new=${currentResult.newCount}, removed=${currentResult.removedCount}`);
  }

  const weeklyRows = currentActual
    .filter(record => record.first_seen_at >= options.weekStart)
    .sort((a, b) => b.first_seen_at.localeCompare(a.first_seen_at)
      || b.date.localeCompare(a.date)
      || String(b.transactionId || '').localeCompare(String(a.transactionId || '')));
  const expectedCount = stateRows.filter(record => record.first_seen_at >= options.weekStart).length;
  if (weeklyRows.length !== expectedCount) {
    throw new Error(`Backfill count mismatch: current=${weeklyRows.length}, cumulative=${expectedCount}`);
  }
  if (current.records.length !== recordCountBefore || coreFingerprint(current) !== fingerprintBefore) {
    throw new Error('Backfill attempted to change existing transaction facts.');
  }

  current.meta.firstSeenTracking = {
    ...(current.meta.firstSeenTracking || {}),
    historyBackfill: {
      weekStart: options.weekStart,
      baselineCommit: options.baseline,
      snapshots: options.snapshotSpecs,
      restoredCount: weeklyRows.length,
      basis: 'Git 데이터 스냅샷에서 거래가 처음 등장한 한국 날짜'
    }
  };
  const report = makeReport(options, current, results, weeklyRows, provenance);
  const summary = {
    apply: options.apply, baseline: options.baseline, snapshots: options.snapshotSpecs,
    results: results.map(result => ({
      commit: result.commit, seenDate: result.seenDate, matched: result.matchedCount,
      rekeyed: result.rekeyedCount, corrected: result.correctedCount,
      new: result.newCount, removed: result.removedCount
    })), restoredCount: weeklyRows.length
  };

  if (options.apply) {
    const dataTemporary = `${dataPath}.history-backfill.tmp`;
    const reportTemporary = `${reportPath}.tmp`;
    fs.mkdirSync(path.dirname(reportPath), { recursive: true });
    fs.mkdirSync(path.dirname(backupPath), { recursive: true });
    fs.writeFileSync(dataTemporary, `window.APT_ARCHIVE_DATA = ${JSON.stringify(current)};\n`, 'utf8');
    const verification = parseDataset(fs.readFileSync(dataTemporary, 'utf8'));
    if (verification.records.length !== recordCountBefore || coreFingerprint(verification) !== fingerprintBefore) {
      fs.rmSync(dataTemporary, { force: true });
      throw new Error('Generated data failed preservation validation.');
    }
    fs.writeFileSync(reportTemporary, `${report}\n`, 'utf8');
    fs.copyFileSync(dataPath, backupPath);
    fs.renameSync(dataTemporary, dataPath);
    fs.renameSync(reportTemporary, reportPath);
  }

  process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
}

module.exports = { parseDataset, reconcileRows, coreFingerprint };
if (require.main === module) main();
