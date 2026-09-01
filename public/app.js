(() => {
  'use strict';

  const dataset = window.APT_ARCHIVE_DATA;
  const supplyDataset = window.APT_SUPPLY_AREA_DATA;
  const weeklyNew = window.APT_WEEKLY_NEW;
  if (!dataset || !Array.isArray(dataset.complexes) || !Array.isArray(dataset.records) || !supplyDataset?.complexes || !weeklyNew) {
    document.body.innerHTML = '<p style="padding:40px;font-family:sans-serif">통합 데이터 또는 공급면적 매핑 파일을 불러오지 못했습니다. data 폴더를 확인해 주세요.</p>';
    return;
  }

  const complexes = dataset.complexes;
  const areaKey = area => String(Number(area));
  const supplyMappingFor = record => supplyDataset.complexes[record.complexId]?.areas?.[areaKey(record.area)] || null;
  const allRecords = dataset.records.map(record => {
    const mapping=supplyMappingFor(record);
    return {
      ...record,
      supplyArea:mapping?.supplyArea??null,
      py:mapping?.pyeong??null,
      group:mapping?.group??null,
      areaStatus:mapping?'verified':'needs-verification',
      supplySourceMethod:mapping?.method??null
    };
  });
  const complexById = new Map(complexes.map(item => [item.id,item]));
  const wId = 'busan-26290-20362232';
  const hashId = decodeURIComponent(location.hash.slice(1));
  const palette = { 0:'#d0d46d', 10:'#b7d85b', 20:'#47a5d8', 30:'#31b9aa', 40:'#7295f3', 50:'#f07a56', 60:'#d58be7', 70:'#efb84d', 80:'#8bc875', 90:'#dd7798', 100:'#65c9b7', 110:'#c49170' };
  const state = {
    selectedId: complexById.has(hashId) ? hashId : null,
    aggregation:'monthly', group:'all', year:'all', kind:'all', sort:'date-desc', visible:25, homeExpanded:false
  };

  const $ = (selector, root=document) => root.querySelector(selector);
  const $$ = (selector, root=document) => [...root.querySelectorAll(selector)];
  const won = new Intl.NumberFormat('ko-KR');
  const currentComplex = () => complexById.get(state.selectedId) || null;
  const displayName = item => item.displayName || item.name;
  const groupLabel = group => group==null ? '공급면적 확인 필요' : group===0 ? '10평 미만' : `${group}평대`;
  const supplyGroupLabel = group => group==null ? '공급면적 확인 필요' : group===0 ? '공급 10평 미만' : `공급 ${group}평대`;
  const formatSupplyPyeong = record => record.py==null ? '공급면적 확인 필요' : `${record.py}평`;
  const selectedRecords = () => allRecords.filter(record => record.complexId === state.selectedId);
  const escapeHtml = value => String(value??'').replace(/[&<>'"]/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[character]));

  function median(values) {
    if (!values.length) return null;
    const sorted = [...values].sort((a,b) => a-b), middle = Math.floor(sorted.length/2);
    return sorted.length%2 ? sorted[middle] : (sorted[middle-1]+sorted[middle])/2;
  }
  const average = values => values.length ? values.reduce((sum,value) => sum+value,0)/values.length : null;
  function formatPrice(price, compact=false) {
    if (price == null) return '—';
    if (compact) return `${(price/10000).toFixed(price%10000 ? 1 : 0)}억`;
    const rounded=Math.round(price), eok=Math.floor(rounded/10000), remainder=rounded%10000;
    if (!eok) return `${won.format(remainder)}만원`;
    return remainder ? `${eok}억 ${won.format(remainder)}만원` : `${eok}억원`;
  }
  function formatDate(date) {
    if (!date) return '—';
    const [year,month,day] = date.split('-');
    return `${year}. ${month}. ${day}.`;
  }
  const formatHomeDate = date => { const [,month,day]=date.split('-').map(Number); return `${month}월 ${day}일`; };
  const percentChange = (from,to) => from&&to ? ((to-from)/from)*100 : null;
  const latestYear = (rows=selectedRecords()) => rows.length ? Math.max(...rows.map(row => Number(row.date.slice(0,4)))) : Number(dataset.meta?.rangeEnd?.slice(0,4))||new Date().getFullYear();

  function availableGroups(rows=selectedRecords()) {
    const counts = new Map();
    rows.forEach(row => counts.set(row.group,(counts.get(row.group)||0)+1));
    return [...counts].filter(([group]) => Number.isInteger(group)&&group>=0).sort((a,b) => b[1]-a[1]);
  }
  function chartGroups() {
    return availableGroups().map(([group]) => group).sort((a,b) => a-b);
  }

  function initSelectors() {
    const citySelect=$('#city-select');
    citySelect.innerHTML='<option value="">도시 선택</option>'+['부산','서울'].map(city => `<option value="${city}">${city}</option>`).join('');
    if (currentComplex()) syncSelectorToCurrent();
    else {
      citySelect.value='';
      populateDistricts();
      populateApartments();
    }
    citySelect.addEventListener('change',() => {
      populateDistricts();
      populateApartments();
    });
    $('#district-select').addEventListener('change',() => populateApartments($('#district-select').value));
    $('#apartment-select').addEventListener('change',event => selectComplex(event.target.value));
  }
  function populateDistricts(selectedDistrict) {
    const city=$('#city-select').value;
    const districts=[...new Set(complexes.filter(item => item.city===city).map(item => item.district))].sort((a,b) => a.localeCompare(b,'ko'));
    const select=$('#district-select');
    select.innerHTML='<option value="">구·군 선택</option>'+districts.map(district => `<option value="${district}">${district}</option>`).join('');
    select.value=districts.includes(selectedDistrict) ? selectedDistrict : '';
    select.disabled=!city;
  }
  function populateApartments(district,selectedId) {
    const city=$('#city-select').value;
    const items=complexes.filter(item => item.city===city&&item.district===district)
      .sort((a,b) => Number(b.featured)-Number(a.featured)||Number(b.leader)-Number(a.leader)||displayName(a).localeCompare(displayName(b),'ko'));
    const select=$('#apartment-select'); select.innerHTML='<option value="">아파트 선택</option>';
    items.forEach(item => {
      const option=document.createElement('option'); option.value=item.id;
      option.textContent=`${item.featured||item.leader?'★ ':''}${displayName(item)} · ${(item.tags||[]).join(' / ')}`;
      select.appendChild(option);
    });
    select.value=items.some(item => item.id===selectedId) ? selectedId : '';
    select.disabled=!city||!district;
  }
  function selectComplex(id) {
    if (!complexById.has(id)) return;
    state.selectedId=id; state.group='all'; state.year='all'; state.kind='all'; state.visible=25;
    if (location.hash!==`#${id}`) history.pushState(null,'',`#${id}`);
    renderAll();
  }
  function syncSelectorToCurrent() {
    const item=currentComplex(); if (!item) return;
    $('#city-select').value=item.city;
    populateDistricts(item.district); populateApartments(item.district,item.id);
  }

  function renderHero() {
    const item=currentComplex(), rows=selectedRecords(), groups=chartGroups();
    const isMonthly=item.dataMode==='monthly-average';
    const isHybrid=item.dataMode==='hybrid';
    const refreshedYears=Object.keys(item.refresh?.years||{}).sort().join('·');
    $('#hero-eyebrow').textContent=`${item.city==='부산'?'BUSAN':'SEOUL'} · ${item.district.toUpperCase()} · ${isMonthly?'MONTHLY AVERAGE PRICE':isHybrid?'ARCHIVE + LIVE TRANSACTIONS':'ACTUAL TRANSACTION DATA'}`;
    $('#hero-location').textContent=`${item.city} · ${item.district}`;
    $('#hero-apartment').textContent=displayName(item);
    $('#hero-description').innerHTML=isMonthly
      ? `2015년부터 2026년 현재까지 공개 실거래 기반 평형별 월평균을 정리했습니다.<br>공급면적 ${groups.map(groupLabel).join(' · ')||'전체'}의 가격 흐름을 비교합니다.`
      : isHybrid
        ? `과거 평형별 월평균과 ${refreshedYears||'최근 연도'} 국토교통부 개별 실거래를 연결해 보여줍니다.<br>공급면적 ${groups.map(groupLabel).join(' · ')||'전체'}의 가격 흐름을 비교합니다.`
        : `2015년부터 2026년 현재까지 국토교통부 실거래를 정리했습니다.<br>공급면적 ${groups.map(groupLabel).join(' · ')||'전체'}의 가격 흐름을 비교합니다.`;
    $('#fact-apartment').textContent=displayName(item);
    $('#fact-location').textContent=`${item.city} ${item.district}`;
    $('#fact-tag').textContent=item.tags.join(' · ');
    $('#fact-source').textContent=item.sourceLabel||'국토교통부 실거래가';
    const latest=rows.map(row => row.date).sort().at(-1), stats=item.stats||{};
    const dataItems=isMonthly
      ? [['수록 가격 자료',`${won.format(rows.length)}개`],['자료 유형','공급평형별 월평균'],['최근 기준월',latest?latest.slice(0,7):'자료 없음'],['가격 확인 연도',`${new Set(rows.map(row => row.date.slice(0,4))).size}개 연도`]]
      : isHybrid
        ? [['수록 가격 자료',`${won.format(rows.length)}개`],['자료 유형','공급평형 월평균 + 실거래'],['최근 기준',latest?formatDate(latest):'자료 없음'],['최근 재조회 취소 제외',`${won.format(stats.recentCancelled||0)}건`]]
        : [['수록 유효 거래',`${won.format(rows.length)}건`],[item.refresh?'최근 재조회 취소 제외':'해제·취소 제외',`${won.format(item.refresh?(stats.recentCancelled||0):(stats.cancelled||0))}건`],['최근 계약',latest?formatDate(latest):'거래 없음'],['거래 확인 연도',`${new Set(rows.map(row => row.date.slice(0,4))).size}개 연도`]];
    $('#data-strip').innerHTML=dataItems.map(([label,value]) => `<div class="strip-item"><span>${label}</span><strong>${value}</strong></div>`).join('');
  }

  function renderSummary() {
    const rows=selectedRecords(), mode=currentComplex().dataMode, isMonthly=mode==='monthly-average', isHybrid=mode==='hybrid', groups=chartGroups();
    const countUnit=isMonthly?'개월':isHybrid?'개':'건';
    const html=groups.map(group => {
      const groupRows=rows.filter(row => row.group===group);
      if (!groupRows.length) {
        return `<article class="summary-card" data-group="${group}" style="--group-color:${palette[group]||'#fff'}"><div class="summary-card-top"><span class="group-label"><i class="group-dot"></i>${supplyGroupLabel(group)}</span><span class="summary-count">전체 0${countUnit}</span></div><p class="summary-price">${isMonthly?'월평균 없음':isHybrid?'가격 자료 없음':'거래 없음'}</p><p class="summary-caption">2015~2026 ${isMonthly||isHybrid?'가격 자료 없음':'신고 내역 없음'}</p><span class="summary-delta">해당 단지·평형 기준</span></article>`;
      }
      const years=[...new Set(groupRows.map(row => Number(row.date.slice(0,4))))].sort((a,b) => a-b);
      const lastYear=years.at(-1), firstYear=years[0];
      const currentRows=groupRows.filter(row => row.date.startsWith(String(lastYear)));
      const firstRows=groupRows.filter(row => row.date.startsWith(String(firstYear)));
      const currentMedian=median(currentRows.map(row => row.price)), firstMedian=median(firstRows.map(row => row.price));
      const change=percentChange(firstMedian,currentMedian), sign=change!=null&&change>=0?'+':'';
      return `<article class="summary-card" data-group="${group}" style="--group-color:${palette[group]||'#fff'}"><div class="summary-card-top"><span class="group-label"><i class="group-dot"></i>${supplyGroupLabel(group)}</span><span class="summary-count">전체 ${won.format(groupRows.length)}${countUnit}</span></div><p class="summary-price">${formatPrice(currentMedian)}</p><p class="summary-caption">${lastYear}년 ${isMonthly?'월평균 ':isHybrid?'가격 자료 ':''}중앙값 · ${currentRows.length}${countUnit} 기준</p><span class="summary-delta ${change!=null&&change<0?'down':''}">${firstYear} 대비 ${sign}${change?.toFixed(1)??'—'}%</span></article>`;
    }).join('');
    $('#summary-grid').classList.toggle('has-four',groups.length>=4);
    $('#summary-grid').innerHTML=html||'<p>표시할 면적대 거래가 없습니다.</p>';
    $('#summary-note').textContent=isMonthly
      ? `${latestYear(rows)}년 또는 공급면적대별 최근 연도 월평균 중앙값 · 금액 단위는 만원`
      : isHybrid
        ? `${latestYear(rows)}년 또는 공급면적대별 최근 가격 자료 중앙값 · 과거 월평균과 최근 실거래 혼합`
        : `${latestYear(rows)}년 또는 공급면적대별 최근 연도 중앙값 · 거래금액 단위는 만원`;
  }

  const bucketKey=(record,aggregation) => aggregation==='monthly'?record.date.slice(0,7):record.date.slice(0,4);
  function bucketTimestamp(key,aggregation) {
    if (aggregation==='monthly') { const [year,month]=key.split('-').map(Number); return Date.UTC(year,month-1,15); }
    return Date.UTC(Number(key),6,1);
  }
  function aggregate(rows,group,kind,aggregation) {
    const buckets=new Map();
    rows.filter(record => record.group===group&&record.kind===kind).forEach(record => {
      const key=bucketKey(record,aggregation); if (!buckets.has(key)) buckets.set(key,[]); buckets.get(key).push(record);
    });
    return [...buckets.entries()].map(([key,items]) => ({key,time:bucketTimestamp(key,aggregation),value:aggregation==='monthly'?median(items.map(item => item.price)):average(items.map(item => item.price)),count:items.length,kind})).sort((a,b) => a.time-b.time);
  }
  function niceRange(values) {
    const min=Math.min(...values), max=Math.max(...values), span=max-min||max*.2||10000;
    return [Math.max(0,min-span*.16),max+span*.16];
  }
  function pathSegments(points,aggregation,xScale,yScale) {
    if (!points.length) return [];
    const maxGap=aggregation==='monthly'?120*86400000:550*86400000, segments=[[]];
    points.forEach((point,index) => { if (index&&point.time-points[index-1].time>maxGap) segments.push([]); segments.at(-1).push(point); });
    return segments.map(segment => segment.map((point,index) => `${index?'L':'M'} ${xScale(point.time).toFixed(2)} ${yScale(point.value).toFixed(2)}`).join(' '));
  }

  function renderCharts() {
    const rows=selectedRecords(), groups=chartGroups(), kinds=[...new Set(rows.map(row => row.kind))], mode=currentComplex().dataMode, isMonthly=mode==='monthly-average', isHybrid=mode==='hybrid';
    const hasPresale=kinds.includes('분양·입주권');
    $('#chart-legend').innerHTML=isMonthly
      ? '<span><i class="legend-line legend-sale"></i>공급평형별 월평균</span>'
      : isHybrid
        ? '<span><i class="legend-line legend-presale"></i>과거 공급평형별 월평균</span><span><i class="legend-line legend-sale"></i>최근 개별 실거래</span>'
        : `${hasPresale?'<span><i class="legend-line legend-presale"></i>분양·입주권</span>':''}<span><i class="legend-line legend-sale"></i>아파트 매매</span>${state.selectedId===wId?'<span><i class="legend-boundary"></i>2018. 03. 27. 준공</span>':''}`;
    const aggregation=state.aggregation, start=Date.UTC(2015,0,1), end=Date.UTC(Number(dataset.meta?.rangeEnd?.slice(0,4))||2026,11,31), boundary=Date.UTC(2018,2,27);
    const width=1040,height=220,margin={top:18,right:66,bottom:34,left:12},innerW=width-margin.left-margin.right,innerH=height-margin.top-margin.bottom;
    const xScale=time => margin.left+((time-start)/(end-start))*innerW;
    $('#chart-stack').innerHTML=groups.map(group => {
      const series=kinds.map(kind => ({kind,points:aggregate(rows,group,kind,aggregation)})), all=series.flatMap(item => item.points);
      if (!all.length) {
        const years=Array.from({length:12},(_,i) => 2015+i);
        const xGrid=years.map(year => { const x=xScale(Date.UTC(year,0,1)); return `<line x1="${x}" y1="${margin.top}" x2="${x}" y2="${height-margin.bottom}" stroke="rgba(255,255,255,.045)"/><text x="${x}" y="${height-10}" text-anchor="middle" fill="rgba(255,255,255,.36)" font-size="9">${String(year).slice(2)}</text>`; }).join('');
        return `<article class="chart-row" style="--group-color:${palette[group]}" data-chart-group="${group}"><div class="chart-label"><span>SUPPLY AREA</span><strong>${groupLabel(group)}</strong><p>${isMonthly?'월평균':'거래'} 없음<br>2015~2026</p></div><div class="chart-canvas"><div class="chart-scroll"><svg viewBox="0 0 ${width} ${height}" role="img" aria-label="공급면적 ${groupLabel(group)} ${isMonthly?'월평균':'거래'} 없음">${xGrid}<line x1="${margin.left}" y1="${height/2}" x2="${width-margin.right}" y2="${height/2}" stroke="rgba(255,255,255,.09)"/><text x="${width/2}" y="${height/2-10}" text-anchor="middle" fill="rgba(255,255,255,.42)" font-size="12">해당 평형의 ${isMonthly?'월평균 가격 자료':'신고 거래'}가 없습니다</text></svg></div><div class="chart-tooltip" role="status" aria-live="polite"></div></div></article>`;
      }
      const [low,high]=niceRange(all.map(point => point.value)), yScale=value => margin.top+(1-(value-low)/(high-low))*innerH;
      const ticks=Array.from({length:4},(_,i) => low+((high-low)*i/3)), years=Array.from({length:12},(_,i) => 2015+i);
      const yGrid=ticks.map(tick => { const y=yScale(tick); return `<line x1="${margin.left}" y1="${y}" x2="${width-margin.right}" y2="${y}" stroke="rgba(255,255,255,.09)"/><text x="${width-margin.right+10}" y="${y+4}" fill="rgba(255,255,255,.38)" font-size="10">${formatPrice(tick,true)}</text>`; }).join('');
      const xGrid=years.map(year => { const x=xScale(Date.UTC(year,0,1)); return `<line x1="${x}" y1="${margin.top}" x2="${x}" y2="${height-margin.bottom}" stroke="rgba(255,255,255,.045)"/><text x="${x}" y="${height-10}" text-anchor="middle" fill="rgba(255,255,255,.36)" font-size="9">${String(year).slice(2)}</text>`; }).join('');
      const flatPoints=series.flatMap(item => item.points);
      const paths=series.map(item => { const archived=item.kind==='분양·입주권'||item.kind==='월평균 집계'; return pathSegments(item.points,aggregation,xScale,yScale).map(path => `<path d="${path}" fill="none" stroke="${palette[group]}" stroke-width="${archived?2.1:2.7}" ${archived?'stroke-dasharray="6 5" opacity=".72"':''} stroke-linecap="round" stroke-linejoin="round"/>`).join(''); }).join('');
      const points=flatPoints.map((point,index) => `<circle class="data-point" data-point="${index}" cx="${xScale(point.time)}" cy="${yScale(point.value)}" r="3.2" fill="${palette[group]}" stroke="#111923" stroke-width="1.4"/>`).join('');
      const boundaryX=xScale(boundary), groupRows=rows.filter(row => row.group===group), lastYear=Math.max(...groupRows.map(row => Number(row.date.slice(0,4)))), lastRows=groupRows.filter(row => row.date.startsWith(String(lastYear)));
      return `<article class="chart-row" style="--group-color:${palette[group]}" data-chart-group="${group}"><div class="chart-label"><span>SUPPLY AREA</span><strong>${groupLabel(group)}</strong><p>${lastYear} 중앙값<br>${formatPrice(median(lastRows.map(row => row.price)))}</p></div><div class="chart-canvas"><div class="chart-scroll"><svg viewBox="0 0 ${width} ${height}" role="img" aria-label="공급면적 ${groupLabel(group)} 가격 그래프">${yGrid}${xGrid}${state.selectedId===wId?`<rect x="${boundaryX-5}" y="${margin.top}" width="10" height="${innerH}" fill="rgba(255,255,255,.065)"/><line x1="${boundaryX}" y1="${margin.top}" x2="${boundaryX}" y2="${height-margin.bottom}" stroke="rgba(255,255,255,.27)" stroke-dasharray="2 4"/><text x="${boundaryX+7}" y="${margin.top+10}" fill="rgba(255,255,255,.46)" font-size="9">준공</text>`:''}${paths}${points}</svg></div><div class="chart-tooltip" role="status" aria-live="polite"></div></div></article>`;
    }).join('');
    $$('.chart-row').forEach(row => {
      const group=Number(row.dataset.chartGroup), points=kinds.flatMap(kind => aggregate(rows,group,kind,aggregation)), tooltip=$('.chart-tooltip',row);
      $$('.data-point',row).forEach(circle => {
        const point=points[Number(circle.dataset.point)];
        const show=() => { const svgRect=circle.ownerSVGElement.getBoundingClientRect(),rowRect=$('.chart-canvas',row).getBoundingClientRect(); tooltip.style.left=`${circle.cx.baseVal.value/1040*svgRect.width+svgRect.left-rowRect.left}px`; tooltip.style.top=`${circle.cy.baseVal.value/220*svgRect.height+svgRect.top-rowRect.top}px`; tooltip.innerHTML=`<strong>${formatPrice(point.value)}</strong><span>${point.key} · ${point.kind==='월평균 집계'||isMonthly?'월평균':`${point.count}건`}<br>${point.kind}</span>`; tooltip.classList.add('is-visible'); };
        circle.addEventListener('mouseenter',show); circle.addEventListener('mouseleave',() => tooltip.classList.remove('is-visible'));
      });
    });
  }

  function renderGroupFilters() {
    const groups=availableGroups().map(([group]) => group).sort((a,b) => a-b);
    const hasUnresolved=selectedRecords().some(record => record.group==null);
    $('.filter-group').innerHTML=`<button class="filter-pill is-active" type="button" data-group="all">전체</button>${groups.map(group => `<button class="filter-pill" type="button" data-group="${group}">${supplyGroupLabel(group)}</button>`).join('')}${hasUnresolved?'<button class="filter-pill filter-pill-unresolved" type="button" data-group="unresolved">공급면적 확인 필요</button>':''}`;
    $$('.filter-pill').forEach(button => button.addEventListener('click',() => { $$('.filter-pill').forEach(item => item.classList.toggle('is-active',item===button)); state.group=button.dataset.group; state.visible=25; renderTable(); }));
    const kinds=[...new Set(selectedRecords().map(row => row.kind))];
    $('#kind-filter').innerHTML='<option value="all">전체 구분</option>'+kinds.map(kind => `<option value="${kind}">${kind}</option>`).join(''); $('#kind-filter').value='all';
  }
  function filteredRecords() {
    const result=selectedRecords().filter(record => (state.group==='all'||(state.group==='unresolved'?record.group==null:record.group===Number(state.group)))&&(state.year==='all'||record.date.startsWith(state.year))&&(state.kind==='all'||record.kind===state.kind));
    return [...result].sort((a,b) => { if(state.sort==='date-asc')return a.date.localeCompare(b.date); if(state.sort==='price-desc')return b.price-a.price||b.date.localeCompare(a.date); if(state.sort==='price-asc')return a.price-b.price||b.date.localeCompare(a.date); return b.date.localeCompare(a.date); });
  }
  function renderTable() {
    const filtered=filteredRecords(),visible=filtered.slice(0,state.visible); $('#table-count').textContent=won.format(filtered.length);
    $('#transaction-body').innerHTML=visible.length?visible.map(record => `<tr><td>${formatDate(record.date)}</td><td><span class="kind-badge ${record.kind==='아파트 매매'?'sale':''}">${record.kind}</span></td><td><strong class="${record.py==null?'area-unresolved':''}">${formatSupplyPyeong(record)}</strong>${record.py==null?'':`<span class="area-detail"> · ${groupLabel(record.group)}</span>`}</td><td>전용 ${record.area.toFixed(2)}㎡</td><td>${record.floor==null?'—':`${record.floor}층`}</td><td class="price-cell">${formatPrice(record.price)}</td></tr>`).join(''):'<tr class="empty-row"><td colspan="6">선택한 조건에 해당하는 가격 자료가 없습니다.</td></tr>';
    $('#load-more').hidden=state.visible>=filtered.length;
  }
  function populateYearFilter() {
    const endYear=Number(dataset.meta?.rangeEnd?.slice(0,4))||new Date().getFullYear();
    $('#year-filter').innerHTML='<option value="all">전체 연도</option>'+Array.from({length:endYear-2014},(_,i) => endYear-i).map(year => `<option value="${year}">${year}년</option>`).join(''); $('#year-filter').value='all';
  }
  const csvEscape=value => `"${String(value??'').replaceAll('"','""')}"`;
  function downloadCurrent() {
    const item=currentComplex(); if (!item) return;
    const rows=filteredRecords(),isMonthly=item.dataMode==='monthly-average',isHybrid=item.dataMode==='hybrid',headers=['도시','구·군','단지명',isMonthly?'기준월':isHybrid?'기준일':'계약일','공급면적 평형','공급면적대','공급면적(㎡)','전용면적(㎡)',isMonthly?'월평균금액(만원)':isHybrid?'가격(만원)':'거래금액(만원)','층','거래구분','거래유형',isMonthly?'자료출처':isHybrid?'중개사/자료출처':'중개사소재지','등기일자'];
    const body=rows.map(record => [item.city,item.district,displayName(item),record.date,record.py??'공급면적 확인 필요',groupLabel(record.group),record.supplyArea??'',record.area,record.price,record.floor??'',record.kind,record.dealType,record.broker,record.registration]);
    const blob=new Blob(['\ufeff'+[headers,...body].map(row => row.map(csvEscape).join(',')).join('\r\n')],{type:'text/csv;charset=utf-8'}),url=URL.createObjectURL(blob),anchor=document.createElement('a');
    anchor.href=url; anchor.download=`${item.city}_${item.district}_${displayName(item).replace(/[\\/:*?"<>|]/g,'')}_${isMonthly?'월평균가격':isHybrid?'가격자료':'실거래가'}.csv`; anchor.click(); URL.revokeObjectURL(url);
  }
  const getKoreaWeekRange=weeklyNew.getKoreaWeekRange;
  function homeRows(now=new Date(),records=allRecords) { return weeklyNew.getWeeklyNewTransactions(records,now); }
  function renderHomeList(result) {
    const limit=state.homeExpanded?result.rows.length:25;
    const visible=result.rows.slice(0,limit);
    $('#weekly-list').innerHTML=visible.map(record => {
      const item=complexById.get(record.complexId); if (!item) return '';
      return `<button class="weekly-card" type="button" data-complex-id="${escapeHtml(item.id)}" aria-label="${escapeHtml(displayName(item))} 상세 보기"><span class="weekly-place"><i>${escapeHtml(item.city)}</i>${escapeHtml(item.district)} · ${escapeHtml(displayName(item))}</span><span class="weekly-date ${record.py==null?'area-unresolved':''}">${formatSupplyPyeong(record)} · 계약 ${formatHomeDate(record.date)}</span><strong>${formatPrice(record.price)}</strong><span class="weekly-detail ${record.py==null?'area-unresolved':''}">신규 ${formatHomeDate(record.first_seen_at)} · 전용 ${record.area.toFixed(2)}㎡${record.py==null?'':` (${formatSupplyPyeong(record)})`} · ${record.floor==null?'층 정보 없음':`${record.floor}층`}</span></button>`;
    }).join('');
    $$('.weekly-card').forEach(card => card.addEventListener('click',() => selectComplex(card.dataset.complexId)));
    const toggle=$('#weekly-toggle');
    toggle.hidden=result.rows.length<=25;
    toggle.innerHTML=state.homeExpanded?'처음 25건만 보기 <span>−</span>':'이번 주 신규 거래 전체보기 <span>＋</span>';
  }
  function renderHome() {
    state.selectedId=null;
    $('#home-view').hidden=false; $('#detail-hero').hidden=true;
    $('#home-content').hidden=false; $('#detail-content').hidden=true;
    $('#rone-section').hidden=false;
    $('#download-current-top').hidden=true;
    const result=homeRows(),latest=result.rows[0]?.first_seen_at;
    $('#home-range-note').textContent=`한국시간 기준 ${formatHomeDate(result.monday)}부터 ${formatHomeDate(result.today)}까지 우리 데이터에 처음 추가된 거래입니다.`;
    $('#weekly-range').textContent=`${result.monday} — ${result.today} · 최초 수집일 기준`;
    $('#home-week-count').textContent=`${won.format(result.weekly.length)}건`;
    $('#home-today-count').textContent=`${won.format(result.weekly.filter(record => record.first_seen_at===result.today).length)}건`;
    $('#home-latest-date').textContent=latest?formatHomeDate(latest):'—';
    $('#home-complex-count').textContent=`${won.format(complexes.length)}개`;
    $('#weekly-status').textContent=result.weekly.length?`이번 주 처음 수집된 실제 거래 ${won.format(result.weekly.length)}건을 최신 수집일부터 표시합니다.`:'이번 주에 처음 수집된 실제 거래가 없습니다.';
    $('#weekly-status').classList.toggle('is-fallback',result.weekly.length===0);
    renderHomeList(result);
  }
  function renderAll() {
    if (!currentComplex()) { renderHome(); return; }
    $('#home-view').hidden=true; $('#detail-hero').hidden=false;
    $('#home-content').hidden=true; $('#detail-content').hidden=false;
    $('#rone-section').hidden=true;
    $('#download-current-top').hidden=false;
    syncSelectorToCurrent(); renderHero(); renderSummary(); renderCharts(); renderGroupFilters(); populateYearFilter(); renderTable();
  }
  function bindStaticEvents() {
    $$('.segment').forEach(button => button.addEventListener('click',() => { $$('.segment').forEach(item => item.classList.toggle('is-active',item===button)); state.aggregation=button.dataset.aggregation; renderCharts(); }));
    $('#year-filter').addEventListener('change',event => { state.year=event.target.value; state.visible=25; renderTable(); });
    $('#kind-filter').addEventListener('change',event => { state.kind=event.target.value; state.visible=25; renderTable(); });
    $('#sort-filter').addEventListener('change',event => { state.sort=event.target.value; state.visible=25; renderTable(); });
    $('#load-more').addEventListener('click',() => { state.visible+=25; renderTable(); });
    $('#weekly-toggle').addEventListener('click',() => { state.homeExpanded=!state.homeExpanded; renderHomeList(homeRows()); });
    $('#download-filtered').addEventListener('click',downloadCurrent); $('#download-current-top').addEventListener('click',downloadCurrent);
  }
  window.addEventListener('popstate',() => {
    const id=decodeURIComponent(location.hash.slice(1));
    state.selectedId=complexById.has(id)?id:null;
    state.homeExpanded=false;
    if (state.selectedId) renderAll();
    else {
      $('#city-select').value=''; populateDistricts(); populateApartments(); renderHome();
    }
  });
  window.__APT_TEST__={getKoreaWeekRange,areaKey,supplyMappingFor,formatSupplyPyeong,allRecords,homeRows};
  initSelectors(); bindStaticEvents(); renderAll();
})();
