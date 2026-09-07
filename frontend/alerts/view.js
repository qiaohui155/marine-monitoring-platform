import { escapeHtml as e, timeText, riskLabel, geometryPositions, splitTrack } from './model.js';
import { renderVesselList, anomalyText } from './vessel-list.js';
const val=(n,unit='')=>n===null || n===undefined?'待接入':`${e(n)}${unit}`;

export class AlertView {
  constructor({manager,onAction,onSelect}) {
    Object.assign(this,{manager,onAction,onSelect});
    this.element=document.createElement('section');
    this.element.className='floating-panel business-dialog oil-alert-window';
    this.element.dataset.floatingPanel='oil-auto-alert';this.element.dataset.defaultX='76';this.element.dataset.defaultY='100';
    this.element.setAttribute('role','dialog');this.element.setAttribute('aria-labelledby','oilAlertTitle');this.element.setAttribute('aria-hidden','true');
    this.element.innerHTML=`<header class="floating-panel-header" data-drag-handle>
      <div class="oil-alert-title"><span class="oil-alert-beacon" aria-hidden="true">⚠</span><div><h2 id="oilAlertTitle">07 油污事件自动预警</h2><p id="oilAlertHeaderMeta"></p></div></div>
      <div class="panel-window-controls"><button type="button" data-panel-minimize title="最小化 / 恢复" aria-label="最小化 / 恢复">−</button><button type="button" data-panel-close title="关闭" aria-label="关闭预警窗口">×</button></div>
      </header>
      <div class="floating-panel-body oil-alert-body"><div id="oilAlertContext" class="oil-alert-context"></div>
        <div class="oil-alert-columns"><section class="oil-alert-event-column" aria-label="油污事件信息"><h3>油污事件信息</h3><div id="oilAlertEventContent"></div></section>
        <section class="oil-alert-vessel-column" aria-label="可疑船舶"><h3>可疑船舶 <small id="oilAlertCandidateCount"></small></h3><div id="oilAlertVessels"></div><p class="oil-alert-disclaimer">可疑船舶排序仅用于辅助调查，不代表最终责任认定。</p></section></div>
        <div id="oilAlertExtra" hidden></div></div>
      <footer class="oil-alert-footer"><p id="oilAlertActionStatus" role="status"></p><div class="oil-alert-actions">
        <button type="button" data-alert-action="locate">地图定位</button><button type="button" data-alert-action="details">查看油污详情</button>
        <button type="button" data-alert-action="track">查看船舶轨迹</button><button type="button" data-alert-action="playback" id="oilAlertPlayback">开始轨迹回放</button>
        <button type="button" data-alert-action="anomalies">查看AIS异常</button><button type="button" data-alert-action="acknowledge" id="oilAlertAcknowledge" class="oil-alert-primary">确认收到预警</button>
        <button type="button" data-alert-action="report">生成事件报告</button><button type="button" data-alert-action="close">关闭</button>
      </div></footer>`;
    document.querySelector('.map-workspace').append(this.element);manager.register(this.element);
    this.element.addEventListener('click',event=>{
      const action=event.target.closest('[data-alert-action]'),vessel=event.target.closest('[data-alert-vessel]');
      if(action)onAction(action.dataset.alertAction);if(vessel)onSelect(vessel.dataset.alertVessel);
    });
    this.element.querySelector('[data-panel-close]').addEventListener('click',()=>onAction('closed'));
    this.toast=document.createElement('aside');this.toast.className='oil-alert-toast';this.toast.hidden=true;this.toast.setAttribute('aria-live','assertive');
    document.body.append(this.toast);
    this.mapTools=document.createElement('div');this.mapTools.className='oil-alert-map-tools';this.mapTools.hidden=true;
    this.mapTools.innerHTML='<span>红：油污 / 选中船　橙：其他候选　虚线：AIS缺测<br>预测范围：橙 1h · 黄 3h · 蓝 6h</span><button type="button" data-map-action="restore">打开预警</button><button type="button" data-map-action="clear">清除预警定位</button>';
    this.mapTools.addEventListener('click',event=>{const a=event.target.closest('[data-map-action]');if(a)onAction(a.dataset.mapAction);});document.body.append(this.mapTools);
    this.setupInbox();
  }
  $(id){return this.element.querySelector(id);}
  get visible(){return Boolean(this.manager.get('oil-auto-alert')?.visible);}
  rect(){const state=this.manager.get('oil-auto-alert');return state?.visible && !state.minimized?this.element.getBoundingClientRect():null;}
  open(){const state=this.manager.get('oil-auto-alert');if(state.minimized)this.manager.toggleMinimized('oil-auto-alert');this.manager.open('oil-auto-alert');}
  close(){this.manager.close('oil-auto-alert');}
  render(record,selectedMmsi) {
    const event=record.event;this.record=record;this.selectedMmsi=selectedMmsi;
    this.$('#oilAlertHeaderMeta').textContent=`${riskLabel(event.risk)} · 检测 ${timeText(event.detectedAt)}`;
    this.$('#oilAlertContext').textContent=event.provenance==='development'?'开发测试事件 · 不写入业务数据库':'检测时间不等于泄漏时间；缺失的分析结果不会自动补造。';
    this.$('#oilAlertCandidateCount').textContent=`${event.candidates.length}艘 / 显示前5艘`;
    const rows=[['事件编号',event.id],['发现时间',timeText(event.detectedAt)],['经度 / 纬度',event.center.map(n=>n.toFixed(5)+'°').join(' / ')],
      ['油污面积',val(event.areaKm2,' km²')],['长度 / 宽度',`${val(event.lengthKm,' km')} / ${val(event.widthKm,' km')}`],['形态',event.morphology || '待接入'],
      ['数据来源',event.source],['检测置信度',val(event.confidence,'%')],['风险等级',riskLabel(event.risk)],['漂移方向',event.driftDirection || '待接入'],
      ['漂移速度',val(event.driftSpeedKnots,' kn')],...([1,3,6].map(h=>[`${h}小时预测范围`,val(event.forecasts.find(f=>f.hours===h)?.areaKm2,' km²')])),
      ['当前处理状态',record.status==='acknowledged'?'已确认':'未处理']];
    this.$('#oilAlertEventContent').innerHTML=`${this.thumbnail(event)}<dl class="oil-alert-event-data">${rows.map(([a,b])=>`<div><dt>${e(a)}</dt><dd>${e(b)}</dd></div>`).join('')}</dl>`;
    this.$('#oilAlertVessels').innerHTML=renderVesselList(event,selectedMmsi);
    const image=this.$('.oil-alert-thumbnail img');if(image)image.addEventListener('error',()=>{image.replaceWith(document.createTextNode('影像暂不可用，请核查影像服务'));},{once:true});
    const ack=this.$('#oilAlertAcknowledge');ack.disabled=record.status==='acknowledged';ack.textContent=ack.disabled?'已确认':'确认收到预警';
    this.status(record.status==='acknowledged'?`已确认 ${timeText(record.acknowledgedAt)} · ${record.acknowledgedBy || '未登录用户'} · ${record.acknowledgementScope==='local'?'仅本机保存':'已同步服务器'}`:'选择一艘船可查看轨迹；所有时间以 UTC 显示。');
  }
  thumbnail(event){
    if(event.imageUrl)return `<figure class="oil-alert-thumbnail"><img src="${e(event.imageUrl)}" alt="油污事件影像" referrerpolicy="no-referrer"><figcaption>事件影像</figcaption></figure>`;
    const p=geometryPositions(event.geometry),xs=p.map(c=>c[0]),ys=p.map(c=>c[1]),minx=Math.min(...xs),miny=Math.min(...ys);
    const dx=Math.max(...xs)-minx || .01,dy=Math.max(...ys)-miny || .01;
    const scale=Math.min(270/dx,88/dy),x=(300-dx*scale)/2,y=(110-dy*scale)/2;
    const points=p.map(c=>`${(x+(c[0]-minx)*scale).toFixed(1)},${(110-y-(c[1]-miny)*scale).toFixed(1)}`).join(' ');
    return `<figure class="oil-alert-thumbnail"><svg viewBox="0 0 300 110" role="img" aria-label="油污范围示意图"><path d="M0 36H300M0 74H300M75 0V110M150 0V110M225 0V110" stroke="#c5dbe5" fill="none"/><polygon points="${points}" fill="#d9454555" stroke="#c63838" stroke-width="2"/></svg><figcaption>油污范围示意 · 非原始卫星影像</figcaption></figure>`;
  }
  status(message){this.$('#oilAlertActionStatus').textContent=message;}
  refreshCandidates(event,selectedMmsi){this.$('#oilAlertVessels').innerHTML=renderVesselList(event,selectedMmsi);}
  playback({playing,time,gap}){this.$('#oilAlertPlayback').textContent=playing?'停止轨迹回放':'开始轨迹回放';if(time)this.status(`回放 ${timeText(time)}${gap?' · AIS缺测区间，暂不推算船位':''}`);}
  notify(record){
    this.toast.hidden=false;this.toast.innerHTML=`<span class="oil-alert-beacon">⚠</span><div><strong>${e(riskLabel(record.event.risk))} · 新油污事件</strong><span>${e(record.event.id)} · ${e(timeText(record.event.detectedAt))}</span></div><button type="button" data-toast-open>查看</button><button type="button" data-toast-dismiss aria-label="关闭通知">×</button>`;
    this.toast.querySelector('[data-toast-open]').onclick=()=>this.onAction('open-record',record.event.id);
    this.toast.querySelector('[data-toast-dismiss]').onclick=()=>{this.toast.hidden=true;};
  }
  setupInbox(){
    this.badges=[];
    for(const target of ['risk-signals','alert-center']){const button=document.querySelector(`[data-panel-target="${target}"]`);if(!button)continue;const b=document.createElement('span');b.className='oil-alert-count';b.hidden=true;button.append(b);this.badges.push(b);}
    this.inbox=document.createElement('section');this.inbox.className='oil-alert-inbox';
    const body=document.querySelector('[data-floating-panel="alert-center"] .floating-panel-body');body.prepend(this.inbox);
    this.inbox.addEventListener('click',event=>{const b=event.target.closest('[data-open-alert]');if(b)this.onAction('open-record',b.dataset.openAlert);});
  }
  updateInbox(store){
    this.badges.forEach(b=>{b.textContent=store.pending;b.hidden=!store.pending;b.title=`${store.pending}条未处理油污预警`;});
    const records=[...store.records.values()].reverse();
    this.inbox.innerHTML=`<h3>自动油污预警 <b>${store.pending} 条未处理</b></h3><p>${store.persistError?'浏览器存储不可用，刷新后确认记录可能丢失。':'确认状态仅在本机保存；历史数据库预警记录保持不变。'}</p><div>${records.length?records.map(r=>`<button type="button" data-open-alert="${e(r.event.id)}"><strong>${e(r.event.id)}</strong><span>${e(riskLabel(r.event.risk))} · ${r.status==='acknowledged'?'已确认':'未处理'}${r.event.provenance==='development'?' · 测试':''}</span></button>`).join(''):'尚未收到新的油污事件'}</div>`;
  }
  showDetails(event){this.extra(`<h3>油污事件详情</h3><p>事件 ${e(event.id)} · ${e(timeText(event.detectedAt))}</p><p>实际泄漏时间：${event.releaseTime?e(timeText(event.releaseTime)):'未知；不能以检测时间替代。'}</p><p>当前油污范围、预测范围与疑似船舶信息见上方。预测图形不是已经发生的污染范围。</p><p>候选筛选：事前24小时、附近10 NM；轨迹查看：默认检测前2小时至检测后1小时（不超过当前时间），必要时向前扩展至候选接近时间。测试事件使用夹具内附的时间范围。</p>`);}
  showAnomalies(vessel){
    const gaps=splitTrack(vessel.track).gaps;
    this.extra(`<h3>${e(vessel.name)} · AIS异常</h3><p>信号中断：${anomalyText(vessel.anomalies.signalGap)}；异常停留：${anomalyText(vessel.anomalies.loitering)}；减速：${anomalyText(vessel.anomalies.slowdown)}；主动关闭AIS：${anomalyText(vessel.anomalies.aisOff)}。</p><p>当前轨迹中超过10分钟的观测缺口：${gaps.length} 段。红色虚线仅连接缺口端点，不代表真实航行路径，也不能据此认定主动关闭AIS。</p>${gaps.map(f=>`<p>${e(timeText(f.properties.start))} → ${e(timeText(f.properties.end))}</p>`).join('')}`);
  }
  extra(html){const el=this.$('#oilAlertExtra');el.innerHTML=html;el.hidden=false;el.scrollIntoView({block:'nearest',behavior:'smooth'});}
  clearExtra(){this.$('#oilAlertExtra').hidden=true;}
  destroy(){this.element.remove();this.toast.remove();this.mapTools.remove();this.inbox.remove();this.badges.forEach(b=>b.remove());}
}
