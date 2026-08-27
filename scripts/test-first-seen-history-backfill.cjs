'use strict';

const assert = require('node:assert/strict');
const { reconcileRows } = require('./backfill-first-seen-from-git.cjs');

const make = (id, date, price = 100000, extra = {}) => ({
  complexId: 'test-complex', transactionId: id, date, area: 84.99, py: 25.7, group: 20,
  price, floor: 12, kind: '아파트 매매', dealType: '중개거래', broker: '서울 강남구',
  registration: '-', source: '국토교통부 실거래가 OpenAPI', ...extra
});

const provenance = new WeakMap();
const baseline = [make('old-provider-id', '2026-08-20')];
baseline[0].first_seen_at = null;

const day26 = [
  make('new-provider-id', '2026-08-20'),
  make('late-report', '2026-08-20', 110000, { floor: 15 }),
  make('same-day-report', '2026-08-26', 120000, { floor: 18 })
];
const first = reconcileRows(baseline, day26, { seenDate: '2026-08-26', sourceCommit: 'day26', provenance });
assert.equal(first.newCount, 2);
assert.equal(first.rekeyedCount, 1, 'Provider ID migration must reconnect the baseline transaction.');
assert.equal(first.rows.find(row => row.transactionId === 'new-provider-id').first_seen_at, null);
assert.equal(first.rows.find(row => row.transactionId === 'late-report').first_seen_at, '2026-08-26');

const day27 = [
  make('corrected-id', '2026-08-20', 111000, { floor: 15, tracking_key: 'stable-late' }),
  make('new-provider-id', '2026-08-20'),
  make('same-day-report', '2026-08-26', 120000, { floor: 18 }),
  make('new-day27', '2026-08-19', 130000, { floor: 20 })
];
first.rows.find(row => row.transactionId === 'late-report').tracking_key = 'stable-late';
const second = reconcileRows(first.rows, day27, { seenDate: '2026-08-27', sourceCommit: 'day27', provenance });
assert.equal(second.newCount, 1);
assert.equal(second.removedCount, 0);
assert.equal(second.rows.find(row => row.transactionId === 'corrected-id').first_seen_at, '2026-08-26', 'Correction must preserve discovery date.');
assert.equal(second.rows.find(row => row.transactionId === 'new-day27').first_seen_at, '2026-08-27');

const current = second.rows.filter(row => row.transactionId !== 'same-day-report');
const third = reconcileRows(second.rows, current, { seenDate: '2026-08-27', sourceCommit: 'current', provenance });
assert.equal(third.removedCount, 1, 'Removed/cancelled row must not remain in current output.');
assert.equal(third.rows.filter(row => row.first_seen_at).length, 2);

console.log('Git-history first-seen backfill tests passed: provider re-key, late report, correction preservation, multi-day discovery, and cancellation exclusion.');
