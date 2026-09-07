import { escapeHtml as e, probabilityClass, timeText } from './model.js';
const num=(n,unit='')=>n===null || n===undefined ? '未提供' : `${Number(n).toFixed(1)}${unit}`;
export const anomalyText=value=>value===null || value===undefined?'未评估':value?'有记录':'未发现';
export function renderVesselList(event,selectedMmsi) {
  if(event.candidateStatus==='pending')return '<p class="oil-alert-empty">正在查询事前24小时内、油污附近10海里的候选船舶…</p>';
  if(event.candidateStatus==='error')return `<p class="oil-alert-empty">候选查询暂不可用：${e(event.candidateError)}。可关闭后重新打开重试。</p>`;
  if(!event.candidates.length)return '<p class="oil-alert-empty">未查询到符合条件的历史航段。可能存在AIS缺失或油污漂移，不代表已排除船舶来源。</p>';
  return event.candidates.slice(0,5).map((v,i)=>`<button type="button" class="oil-alert-vessel ${v.mmsi===selectedMmsi?'selected':''}" data-alert-vessel="${e(v.mmsi)}" aria-pressed="${v.mmsi===selectedMmsi}">
    <div class="oil-alert-vessel-heading"><span class="oil-alert-rank">${i+1}</span><strong>${e(v.name)}</strong><b class="oil-alert-probability ${probabilityClass(v.probability)}">${v.probability===null?'未评估':`${v.probability}%`}</b></div>
    <div class="oil-alert-vessel-identity">MMSI ${e(v.mmsi)} · ${e(v.type)} · ${e(v.flag || '船旗未提供')}</div>
    <dl class="oil-alert-vessel-data">
      <div><dt>当前经纬度</dt><dd>${v.position?v.position.map(n=>n.toFixed(5)+'°').join(' / '):'未提供'}</dd></div>
      <div><dt>船位更新时间</dt><dd>${e(v.positionTime?timeText(v.positionTime):'未提供')}</dd></div>
      <div><dt>航速 / 航向</dt><dd>${num(v.speedKnots,' kn')} / ${num(v.course,'°')}</dd></div>
      <div><dt>距油污中心</dt><dd>${num(v.distanceNm,' NM')}</dd></div>
      <div><dt>事前接近时间</dt><dd>${e(v.passageTime?timeText(v.passageTime):'未提供')}</dd></div>
      <div><dt>AIS中断</dt><dd>${anomalyText(v.anomalies.signalGap)}</dd></div>
      <div><dt>异常停留 / 减速</dt><dd>${anomalyText(v.anomalies.loitering)} / ${anomalyText(v.anomalies.slowdown)}</dd></div>
      <div><dt>主动关闭AIS</dt><dd>${anomalyText(v.anomalies.aisOff)}</dd></div>
    </dl><span class="oil-alert-vessel-hint">点击定位船舶并显示事件前后轨迹</span>
  </button>`).join('');
}
