(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.APT_WEEKLY_NEW = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';

  function getKoreaWeekRange(now = new Date()) {
    const parts = Object.fromEntries(new Intl.DateTimeFormat('en-CA', {
      timeZone: 'Asia/Seoul', year: 'numeric', month: '2-digit', day: '2-digit'
    }).formatToParts(now).filter(part => part.type !== 'literal').map(part => [part.type, part.value]));
    const today = `${parts.year}-${parts.month}-${parts.day}`;
    const utcDate = new Date(Date.UTC(Number(parts.year), Number(parts.month) - 1, Number(parts.day)));
    const mondayOffset = (utcDate.getUTCDay() + 6) % 7;
    utcDate.setUTCDate(utcDate.getUTCDate() - mondayOffset);
    return { monday: utcDate.toISOString().slice(0, 10), today };
  }

  function getWeeklyNewTransactions(records, now = new Date()) {
    const { monday, today } = getKoreaWeekRange(now);
    const rows = records
      .filter(record => record.kind === '아파트 매매'
        && typeof record.first_seen_at === 'string'
        && record.first_seen_at >= monday
        && record.first_seen_at <= today)
      .sort((a, b) => b.first_seen_at.localeCompare(a.first_seen_at)
        || b.date.localeCompare(a.date)
        || String(b.transactionId || '').localeCompare(String(a.transactionId || '')));
    return { monday, today, weekly: rows, rows, isFallback: false };
  }

  return { getKoreaWeekRange, getWeeklyNewTransactions };
});
