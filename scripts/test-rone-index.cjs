'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { CONFIG, normalizeSecret, buildDataset, parsePayload, requestJson } = require('./rone-index-lib.cjs');
function rows(key, count = 139) {
  const region = CONFIG.regions[key], result = [];
  for (let i = 0; i < count; i++) { const d = new Date(Date.UTC(2015, i, 1)); result.push({ STATBL_ID: CONFIG.statblId, DTACYCLE_CD: 'MM', WRTTIME_IDTFR_ID: `${d.getUTCFullYear()}${String(d.getUTCMonth()+1).padStart(2,'0')}`, CLS_ID: Number(region.id), CLS_NM: region.name, ITM_ID: Number(CONFIG.itemId), ITM_NM: '지수', DTA_VAL: key === 'seoul' ? 66+i*.2 : 94+i*.1 }); }
  return result;
}
test('full official series preserves raw and rebases precisely', () => { const d = buildDataset(rows('seoul'), rows('busan')); assert.equal(d.data.length, 139); assert.equal(d.data[0].seoul, 100); assert.equal(d.data[0].busan, 100); assert.equal(d.data[0].seoul_raw, 66); });
test('sample response is rejected', () => assert.throws(() => buildDataset(rows('seoul', 5), rows('busan', 5)), /건수 부족/));
test('missing or mismatched month is rejected', () => assert.throws(() => buildDataset(rows('seoul'), rows('busan').slice(1)), /월 목록/));
test('official response parser finds head and rows', () => assert.deepEqual(parsePayload({SttsApiTblData:[{head:[{list_total_count:1},{RESULT:{CODE:'INFO-000'}}]},{row:[{x:1}]}]}), {total:1,rows:[{x:1}]}));
test('secret normalization safely handles common copied forms',()=>{assert.equal(normalizeSecret('  "abc%2Bdef%2Fghi%3D"  '),'abc+def/ghi=');assert.equal(normalizeSecret('RONE_API_KEY=plain-key'),'plain-key');assert.equal(normalizeSecret('https://example.test/?KEY=url-key'),'url-key');});
test('transient timeout/server failure retries, auth does not', async () => { let calls=0; const fetchImpl=async()=>{ calls++; if(calls===1)return {status:500,ok:false}; return {status:200,ok:true,json:async()=>({ok:true})}; }; assert.deepEqual(await requestJson('https://example.invalid',{fetchImpl,delays:[0]}),{ok:true}); assert.equal(calls,2); calls=0; await assert.rejects(requestJson('https://example.invalid',{fetchImpl:async()=>{calls++;return {status:403,ok:false}},delays:[0,0]}),/인증/); assert.equal(calls,1); });
