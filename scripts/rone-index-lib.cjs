'use strict';
const fs = require('node:fs');
const path = require('node:path');

const CONFIG = Object.freeze({
  endpoint: 'https://www.reb.or.kr/r-one/openapi/SttsApiTblData.do',
  statblId: 'A_2024_00178', cycle: 'MM', itemId: '100001', startMonth: '201501',
  regions: Object.freeze({ seoul: Object.freeze({ id: '500007', name: '서울' }), busan: Object.freeze({ id: '500008', name: '부산' }) }),
});
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function normalizeSecret(value) {
  let secret=String(value||'').trim();
  if ((secret.startsWith('"')&&secret.endsWith('"'))||(secret.startsWith("'")&&secret.endsWith("'"))) secret=secret.slice(1,-1).trim();
  if (/^https?:\/\//i.test(secret)) { try { secret=new URL(secret).searchParams.get('KEY')||new URL(secret).searchParams.get('key')||secret; } catch {} }
  secret=secret.replace(/^RONE_API_KEY\s*=\s*/i,'').replace(/^KEY\s*=\s*/i,'').trim();
  if (/%[0-9a-f]{2}/i.test(secret)) { try { secret=decodeURIComponent(secret); } catch {} }
  return secret;
}

function apiError(message, category = 'data') { const error = new Error(message); error.category = category; return error; }
function parsePayload(payload) {
  if (payload?.RESULT) throw apiError(`R-ONE ${payload.RESULT.CODE}: ${payload.RESULT.MESSAGE}`, /KEY|인증|SERVICE/i.test(`${payload.RESULT.CODE} ${payload.RESULT.MESSAGE}`) ? 'auth' : 'data');
  const blocks = payload?.SttsApiTblData;
  if (!Array.isArray(blocks)) throw apiError('R-ONE 응답 구조가 올바르지 않습니다.');
  const head = blocks.find(block => Array.isArray(block.head))?.head || [];
  const result = head.find(item => item.RESULT)?.RESULT;
  if (result && result.CODE !== 'INFO-000') throw apiError(`R-ONE ${result.CODE}: ${result.MESSAGE}`, /KEY|인증|SERVICE/i.test(`${result.CODE} ${result.MESSAGE}`) ? 'auth' : 'data');
  return { total: Number(head.find(item => Number.isFinite(Number(item.list_total_count)))?.list_total_count || 0), rows: blocks.find(block => Array.isArray(block.row))?.row || [] };
}

async function requestJson(url, options = {}) {
  const delays = options.delays || [5000, 15000, 30000, 60000, 120000];
  for (let attempt = 0; ; attempt += 1) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs || 30000);
    try {
      const response = await (options.fetchImpl || fetch)(url, { signal: controller.signal, headers: { Accept: 'application/json' } });
      if (response.status === 401 || response.status === 403) throw apiError(`R-ONE 인증 오류 HTTP ${response.status}`, 'auth');
      if (response.status === 429 || response.status >= 500) throw apiError(`R-ONE 일시 오류 HTTP ${response.status}`, 'transient');
      if (!response.ok) throw apiError(`R-ONE HTTP ${response.status}`, 'data');
      return await response.json();
    } catch (error) {
      const transient = error.category === 'transient' || error.name === 'AbortError' || error instanceof TypeError;
      if (error.category === 'auth' || !transient || attempt >= delays.length) throw error;
      console.warn(`[R-ONE RETRY] attempt ${attempt + 1}/${delays.length} failed (${error.name === 'AbortError' ? 'timeout' : 'temporary network/server error'}); retry in ${delays[attempt]}ms`);
      await sleep(delays[attempt]);
    } finally { clearTimeout(timer); }
  }
}

async function collectRegion(key, secret, options = {}) {
  const region = CONFIG.regions[key];
  const endpoint = options.endpoint || CONFIG.endpoint;
  const pageSize = options.pageSize || 100;
  const rows = [];
  let total = null;
  for (let page = 1; total == null || rows.length < total; page += 1) {
    const params = new URLSearchParams({ KEY: secret, Type: 'json', pIndex: String(page), pSize: String(pageSize), STATBL_ID: CONFIG.statblId,
      DTACYCLE_CD: CONFIG.cycle, CLS_ID: region.id, ITM_ID: CONFIG.itemId, START_WRTTIME: '2015' });
    const parsed = parsePayload(await requestJson(`${endpoint}?${params}`, options));
    total ??= parsed.total;
    rows.push(...parsed.rows);
    console.log(`[R-ONE API] ${region.name} page ${page}: ${rows.length}/${total}`);
    if (!parsed.rows.length || page > 100) break;
  }
  if (total <= 10 || rows.length <= 10) throw apiError(`${region.name} 응답이 ${rows.length}건뿐입니다. 인증키 sample 모드 또는 pagination 오류입니다.`, 'sample');
  if (rows.length !== total) throw apiError(`${region.name} pagination 불완전: ${rows.length}/${total}`);
  return rows;
}

function monthText(id) { return `${id.slice(0, 4)}-${id.slice(4, 6)}`; }
function validateRows(rows, key) {
  const region = CONFIG.regions[key];
  const seen = new Set();
  return rows.map(row => {
    const month = String(row.WRTTIME_IDTFR_ID);
    const raw = Number(row.DTA_VAL);
    if (String(row.STATBL_ID) !== CONFIG.statblId || String(row.DTACYCLE_CD) !== CONFIG.cycle || String(row.ITM_ID) !== CONFIG.itemId || String(row.CLS_ID) !== region.id || row.CLS_NM !== region.name || row.ITM_NM !== '지수') throw apiError(`${region.name} 코드/통계표 불일치 (${month})`);
    if (!/^\d{6}$/.test(month) || month.slice(4) < '01' || month.slice(4) > '12' || month < CONFIG.startMonth || !Number.isFinite(raw)) throw apiError(`${region.name} 잘못된 월/지수 (${month})`);
    if (seen.has(month)) throw apiError(`${region.name} 중복 월 ${month}`);
    seen.add(month);
    return { month, raw };
  }).sort((a, b) => a.month.localeCompare(b.month));
}

function expectedMonths(start, end) {
  const result = []; let year = Number(start.slice(0, 4)), month = Number(start.slice(4));
  while (`${year}${String(month).padStart(2, '0')}` <= end) { result.push(`${year}${String(month).padStart(2, '0')}`); month += 1; if (month === 13) { year += 1; month = 1; } }
  return result;
}

function buildDataset(seoulRows, busanRows, generatedAt = new Date().toISOString(), previous = null) {
  const seoul = validateRows(seoulRows, 'seoul'), busan = validateRows(busanRows, 'busan');
  if (seoul.length < 100 || busan.length < 100) throw apiError(`장기 시계열 건수 부족: 서울 ${seoul.length}, 부산 ${busan.length}`, 'sample');
  const sm = seoul.map(x => x.month), bm = busan.map(x => x.month);
  if (sm.join(',') !== bm.join(',')) throw apiError('서울·부산 월 목록이 일치하지 않습니다. 누락 월을 보간하지 않습니다.');
  const latest = sm.at(-1), expected = expectedMonths(CONFIG.startMonth, latest);
  if (sm.join(',') !== expected.join(',')) throw apiError(`누락 월이 있습니다 (${sm.length}/${expected.length}). 보간하지 않고 배포를 중지합니다.`);
  const now=new Date(), recentBoundary=new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth()-3,1)), recentMonth=`${recentBoundary.getUTCFullYear()}${String(recentBoundary.getUTCMonth()+1).padStart(2,'0')}`;
  if(latest<recentMonth) throw apiError(`최신월 ${latest}이 공표 지연 허용범위 ${recentMonth}보다 오래됐습니다. 불완전 조회로 판단합니다.`);
  if (previous?.data?.length && sm.length < Math.floor(previous.data.length * 0.9)) throw apiError(`기존 대비 비정상 대량 누락: ${previous.data.length} -> ${sm.length}`);
  const baseS = seoul[0].raw, baseB = busan[0].raw;
  const data = seoul.map((item, index) => ({ month: monthText(item.month), seoul_raw: item.raw, busan_raw: busan[index].raw,
    seoul: item.raw / baseS * 100, busan: busan[index].raw / baseB * 100 }));
  if (Math.abs(data[0].seoul - 100) > 1e-12 || Math.abs(data[0].busan - 100) > 1e-12) throw apiError('2015.01 재기준 지수가 100이 아닙니다.');
  return { schema_version: 2, source: '한국부동산원 R-ONE', category: '공동주택 실거래가격지수', stat_name: '(월) 지역별 매매지수_아파트',
    housing_type: '아파트', transaction_type: '매매', index_basis: '실제 신고된 아파트 거래가격',
    statbl_id: CONFIG.statblId, item: { id: CONFIG.itemId, name: '지수' }, cycle: CONFIG.cycle,
    regions: { seoul: CONFIG.regions.seoul, busan: CONFIG.regions.busan }, base: '2015-01=100', latest_month: monthText(latest), generated_at: generatedAt,
    counts: { seoul: seoul.length, busan: busan.length }, warnings: [], data };
}

function comparable(data) { const copy = structuredClone(data); delete copy.generated_at; return JSON.stringify(copy); }
async function run(options = {}) {
  const secret = normalizeSecret(options.secret || process.env.RONE_API_KEY);
  if (!secret) throw apiError('RONE_API_KEY가 설정되지 않았습니다.', 'auth');
  const output = path.resolve(options.output || path.join(__dirname, '../public/data/apartment-transaction-price-index.json'));
  let previous = null; try { previous = JSON.parse(fs.readFileSync(output, 'utf8')); } catch {}
  const [seoul, busan] = await Promise.all(['seoul', 'busan'].map(key => collectRegion(key, secret, options)));
  let dataset = buildDataset(seoul, busan, new Date().toISOString(), previous);
  if (previous && comparable(previous) === comparable(dataset)) dataset = previous;
  else { fs.mkdirSync(path.dirname(output), { recursive: true }); const temp = `${output}.${process.pid}.tmp`; fs.writeFileSync(temp, JSON.stringify(dataset, null, 2) + '\n'); fs.renameSync(temp, output); }
  console.log(`[R-ONE FINAL] SUCCESS ${dataset.counts.seoul}/${dataset.counts.busan} months, latest ${dataset.latest_month}, changed=${dataset !== previous}`);
  return { dataset, changed: dataset !== previous, output };
}

module.exports = { CONFIG, normalizeSecret, parsePayload, requestJson, collectRegion, validateRows, buildDataset, comparable, run };
