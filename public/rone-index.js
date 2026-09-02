(() => {
  'use strict';
  const host = document.querySelector('#rone-chart');
  if (!host) return;
  window.RONE_INDEX_READY=false;
  const status = document.querySelector('#rone-status'), latest = document.querySelector('#rone-latest'), source = document.querySelector('#rone-source');
  const fmt = value => Number(value).toFixed(1), monthLabel = month => month.replace('-', '.');
  function validate(data) {
    if (!data || data.source !== '한국부동산원 R-ONE' || data.statbl_id !== 'A_2024_00178' || data.category !== '공동주택 실거래가격지수' || data.housing_type !== '아파트' || data.transaction_type !== '매매' || data.base !== '2015-01=100' || !Array.isArray(data.data) || data.data.length < 100) throw new Error('공식 아파트 매매 실거래가격지수 장기 시계열을 확인할 수 없습니다.');
    if (data.data[0].month !== '2015-01' || Math.abs(data.data[0].seoul - 100) > 1e-8 || Math.abs(data.data[0].busan - 100) > 1e-8) throw new Error('기준월 데이터가 올바르지 않습니다.');
    return data;
  }
  function render(data) {
    const points=data.data,width=1120,height=390,margin={top:24,right:26,bottom:48,left:58},innerW=width-margin.left-margin.right,innerH=height-margin.top-margin.bottom;
    const values=points.flatMap(p=>[p.seoul,p.busan]),low=Math.floor((Math.min(...values)-5)/10)*10,high=Math.ceil((Math.max(...values)+5)/10)*10;
    const x=i=>margin.left+i/(points.length-1)*innerW,y=value=>margin.top+(1-(value-low)/(high-low))*innerH;
    const path=key=>points.map((p,i)=>`${i?'L':'M'}${x(i).toFixed(2)},${y(p[key]).toFixed(2)}`).join(' ');
    const yTicks=Array.from({length:6},(_,i)=>low+(high-low)*i/5),yearTicks=points.map((p,i)=>({p,i})).filter(({p})=>p.month.endsWith('-01'));
    host.innerHTML=`<svg viewBox="0 0 ${width} ${height}" aria-hidden="true">${yTicks.map(v=>`<line x1="${margin.left}" y1="${y(v)}" x2="${width-margin.right}" y2="${y(v)}" class="rone-grid"/><text x="${margin.left-12}" y="${y(v)+4}" text-anchor="end">${Math.round(v)}</text>`).join('')}${yearTicks.map(({p,i})=>`<line x1="${x(i)}" y1="${margin.top}" x2="${x(i)}" y2="${height-margin.bottom}" class="rone-year-grid"/><text x="${x(i)}" y="${height-17}" text-anchor="middle">${p.month.slice(0,4)}</text>`).join('')}<path d="${path('seoul')}" class="rone-line seoul"/><path d="${path('busan')}" class="rone-line busan"/><line class="rone-focus-line" x1="0" y1="${margin.top}" x2="0" y2="${height-margin.bottom}" hidden/><circle class="rone-focus-dot seoul" r="5" hidden/><circle class="rone-focus-dot busan" r="5" hidden/><rect class="rone-hit" x="${margin.left}" y="${margin.top}" width="${innerW}" height="${innerH}" fill="transparent"/></svg><div class="rone-tooltip" role="status" aria-live="polite"></div>`;
    const svg=host.querySelector('svg'),hit=host.querySelector('.rone-hit'),line=host.querySelector('.rone-focus-line'),dots=[host.querySelector('.rone-focus-dot.seoul'),host.querySelector('.rone-focus-dot.busan')],tooltip=host.querySelector('.rone-tooltip');
    const show=event=>{const rect=svg.getBoundingClientRect(),clientX=event.touches?.[0]?.clientX??event.clientX,svgX=(clientX-rect.left)/rect.width*width,index=Math.max(0,Math.min(points.length-1,Math.round((svgX-margin.left)/innerW*(points.length-1)))),point=points[index],px=x(index);line.hidden=false;line.setAttribute('x1',px);line.setAttribute('x2',px);[['seoul',0],['busan',1]].forEach(([key,n])=>{dots[n].hidden=false;dots[n].setAttribute('cx',px);dots[n].setAttribute('cy',y(point[key]));});tooltip.innerHTML=`<strong>${monthLabel(point.month)}</strong><span class="rone-tooltip-region">서울</span><span>2015.01=100 지수 <b>${fmt(point.seoul)}</b></span><span>R-ONE 공식지수 <b>${Number(point.seoul_raw).toFixed(4)}</b></span><span class="rone-tooltip-region">부산</span><span>2015.01=100 지수 <b>${fmt(point.busan)}</b></span><span>R-ONE 공식지수 <b>${Number(point.busan_raw).toFixed(4)}</b></span>`;tooltip.classList.add('is-visible');tooltip.style.left=`${Math.max(92,Math.min(rect.width-92,clientX-rect.left))}px`;};
    hit.addEventListener('mousemove',show);hit.addEventListener('touchstart',show,{passive:true});hit.addEventListener('touchmove',show,{passive:true});hit.addEventListener('mouseleave',()=>tooltip.classList.remove('is-visible'));
    const last=points.at(-1);latest.innerHTML=['seoul','busan'].map(key=>`<article><span>${key==='seoul'?'서울':'부산'}</span><strong>현재 ${fmt(last[key])}</strong><p>2015.01 대비 <b>${last[key]>=100?'+':''}${fmt(last[key]-100)}%</b></p></article>`).join('');
    source.innerHTML=`<span>자료: 한국부동산원 R-ONE 공동주택 실거래가격지수</span><span>대상: 아파트 매매 · 최신 발표월: ${monthLabel(data.latest_month)}</span><span>비교지수: 2015.01=100으로 재산정</span><em>실제 신고된 아파트 거래가격을 기반으로 산출되는 실거래가격지수입니다.</em>`;status.hidden=true;window.RONE_INDEX_READY=true;if(!location.hash)document.querySelector('#rone-section').hidden=false;
  }
  fetch('data/apartment-transaction-price-index.json',{cache:'no-store'}).then(response=>{if(!response.ok)throw new Error(`HTTP ${response.status}`);return response.json();}).then(data=>render(validate(data))).catch(error=>{status.textContent=`가격지수를 표시하지 못했습니다. (${error.message})`;status.classList.add('is-error');document.querySelector('#rone-section').hidden=true;});
})();
