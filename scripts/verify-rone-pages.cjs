'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const fileName='apartment-transaction-price-index.json';
const localText = fs.readFileSync(path.resolve(__dirname, `../public/data/${fileName}`), 'utf8').replace(/\r\n/g,'\n').trimEnd();
const expected = crypto.createHash('sha256').update(localText).digest('hex');
const base = (process.env.PAGES_URL || 'https://jaehun242.github.io/Apart-price/').replace(/\/?$/, '/');
const sleep = ms => new Promise(resolve => setTimeout(resolve,ms));
(async()=>{
  for(let attempt=1;attempt<=12;attempt++){
    try { const response=await fetch(`${base}data/${fileName}?verify=${Date.now()}`,{cache:'no-store'}); const text=(await response.text()).replace(/\r\n/g,'\n').trimEnd(); const actual=crypto.createHash('sha256').update(text).digest('hex'); if(response.ok&&actual===expected){console.log(`[SITE VERIFY] SUCCESS ${base} / ${fileName} / sha256 ${expected}`);return;} console.log(`[SITE VERIFY] attempt ${attempt}/12 expected ${expected.slice(0,12)} actual ${actual.slice(0,12)} HTTP ${response.status}`); }
    catch(error){console.log(`[SITE VERIFY] attempt ${attempt}/12 temporary error: ${error.message}`);}
    if(attempt<12) await sleep(10000);
  }
  throw new Error('GitHub Pages production R-ONE JSON did not match the deployed main artifact.');
})().catch(error=>{console.error(`[SITE VERIFY ERROR] ${error.message}`);process.exitCode=1;});
