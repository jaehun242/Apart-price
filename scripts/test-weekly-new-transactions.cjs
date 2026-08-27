'use strict';

const assert = require('node:assert/strict');
const { getKoreaWeekRange, getWeeklyNewTransactions } = require('../public/weekly-new-transactions.js');

const now = new Date('2026-08-26T03:00:00Z'); // 2026-08-26 12:00 KST
assert.deepEqual(getKoreaWeekRange(now), { monday: '2026-08-24', today: '2026-08-26' });

const base = { complexId: 'test', kind: '아파트 매매', area: 84.99, price: 100000, floor: 10 };
const records = [
  { ...base, transactionId: 'late-report', date: '2026-08-20', first_seen_at: '2026-08-26' },
  { ...base, transactionId: 'same-day', date: '2026-08-26', first_seen_at: '2026-08-26' },
  { ...base, transactionId: 'old-discovery', date: '2026-08-20', first_seen_at: '2026-08-20' },
  { ...base, transactionId: 'legacy-null', date: '2026-08-26', first_seen_at: null },
  { ...base, transactionId: 'legacy-missing', date: '2026-08-26' },
  { ...base, transactionId: 'not-an-actual-sale', date: '2026-08-26', first_seen_at: '2026-08-26', kind: '월평균 집계' }
];

const result = getWeeklyNewTransactions(records, now);
assert.deepEqual(result.rows.map(record => record.transactionId), ['same-day', 'late-report']);
assert.equal(result.isFallback, false);
assert.equal(result.rows[0].date, '2026-08-26', 'Actual contract date must remain unchanged.');
assert.equal(result.rows[1].date, '2026-08-20', 'Late-reported contract date must remain unchanged.');

const empty = getWeeklyNewTransactions(records, new Date('2026-08-30T03:00:00Z'));
assert.equal(empty.rows.length, 2, 'The same Korean week should still include both newly seen transactions.');

console.log('Weekly-new filter tests passed: discovery date drives inclusion while contract date stays intact and legacy rows remain excluded.');
