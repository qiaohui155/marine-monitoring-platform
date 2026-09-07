import { AlertStore, escapeHtml as e, timeText, riskLabel, coordinate, utc, numberOrNull, distanceNm } from './model.js';
import { AlertReceiver, createApiAdapter } from './source.js';
import { AlertView } from './view.js';
import { AlertMapController } from './map-controller.js';

export function createOilAlerts({map,maplibre,manager,apiBase,getVessels,getCurrentUser=()=>null,config={}}) {
  const isLoopback=['localhost','127.0.0.1','::1','[::1]'].includes(location.hostname);
  const development=isLoopback && new URLSearchParams(location.search).get('devAlerts')==='1';
  let storage=null;try{storage=window.localStorage;}catch{}
  const store=new AlertStore(storage,development?'oman.oil-alerts.dev.v1':'oman.oil-alerts.v1'),adapter=config.adapter || createApiAdapter({apiBase,getVessels});
  let currentId=null,selectionRevision=0,selectedMmsi=null,acknowledging=false;
  const current=()=>store.records.get(currentId);
  const selected=()=>current()?.event.candidates.find(v=>v.mmsi===selectedMmsi);
  const view=new AlertView({manager,onAction:(action,id)=>runAction(action,id).catch(err=>view.status(err.message)),onSelect:mmsi=>select(mmsi).catch(err=>view.status(err.message))});
  const mapController=new AlertMapController({map,maplibre,getPanelRect:()=>view.rect(),onSelect:mmsi=>select(mmsi).catch(err=>view.status(err.message)),onPlayback:state=>view.playback(state)});
  const render=()=>{if(current())view.render(current(),selectedMmsi);view.updateInbox(store);};

  async function enrich(record) {
    const event=await adapter.enrich(record.event);store.update(event);view.updateInbox(store);
    if(currentId===event.id){render();mapController.updateEvent(event);}
    return event;
  }
  function display(record,open=true) {
    currentId=record.event.id;selectedMmsi=null;selectionRevision++;view.clearExtra();render();
    if(open)view.open();mapController.setEvent(record.event);view.mapTools.hidden=false;
  }
  async function onEvent(event) {
    const record=store.receive(event);if(!record)return false;
    view.updateInbox(store);view.notify(record);
    // Low risk notifications must not open or replace a currently open high-risk dialog.
    if(event.risk==='high' || event.risk==='medium')display(record,true);
    else if(!view.visible)display(record,false);
    await enrich(record);return true;
  }
  async function openRecord(id) {
    const record=store.records.get(id);if(!record)return;
    display(record,true);view.toast.hidden=true;
    if(record.event.candidateStatus!=='ready')await enrich(record);
  }
  async function select(mmsi) {
    const record=current();if(!record)return false;
    const vessel=record.event.candidates.find(v=>v.mmsi===mmsi);if(!vessel)return false;
    const revision=++selectionRevision,eventId=record.event.id;selectedMmsi=mmsi;
    // Selection also restores the alert overlay after the explicit clear action.
    if(mapController.active?.id!==eventId)mapController.setEvent(record.event);
    view.mapTools.hidden=false;render();mapController.select(vessel);view.status('正在读取检测前后带时间戳的历史轨迹…');
    try {
      const updated=await adapter.loadTrack(record.event,vessel);
      if(revision!==selectionRevision || currentId!==eventId)return false;
      record.event.candidates=record.event.candidates.map(v=>v.mmsi===mmsi?updated:v);store.update(record.event);
      render();mapController.updateEvent(record.event);mapController.select(updated);
      view.status(updated.track.length>=2?`${updated.name}：${updated.track.length}个历史点${updated.trackTruncated?'（达到接口上限，可能截断）':''}；深红实线为已记录航段，红色虚线为缺测连接。`:'该时间段没有足够历史点；不会使用其他船舶或整段历史轨迹替代。');
      return true;
    }catch(error){if(revision===selectionRevision)view.status(`历史轨迹读取失败：${error.message}`);return false;}
  }
  async function ensureSelected() {
    if(selected())return selected();
    const first=current()?.event.candidates[0];if(!first)throw new Error('当前没有可用候选船舶，请等待查询结果。');
    await select(first.mmsi);return selected();
  }
  async function runAction(action,id) {
    if(action==='open-record'){await openRecord(id);return;}
    if(action==='clear'){selectionRevision++;selectedMmsi=null;mapController.clear();view.mapTools.hidden=true;render();view.status('预警地图高亮已清除，业务数据和确认状态保留。');return;}
    if(action==='close' || action==='closed'){selectionRevision++;mapController.stopPlayback();view.close();return;}
    if(action==='restore'){if(current()){render();view.open();}return;}
    const record=current();if(!record)return;
    switch(action){
      case 'locate': if(mapController.active?.id!==record.event.id)mapController.setEvent(record.event);else mapController.locateEvent();view.mapTools.hidden=false;break;
      case 'details':view.showDetails(record.event);break;
      case 'track':{const v=await ensureSelected();if(v)await select(v.mmsi);break;}
      case 'playback':{const v=await ensureSelected();if(v)mapController.startPlayback(v);break;}
      case 'anomalies':{const v=await ensureSelected();if(v)view.showAnomalies(v);break;}
      case 'acknowledge':{
        if(acknowledging || record.status==='acknowledged')return;acknowledging=true;
        const button=view.$('#oilAlertAcknowledge');button.disabled=true;button.textContent='正在确认…';
        try{const user=getCurrentUser();const result=adapter.acknowledge?await adapter.acknowledge(record,user):null;
          store.acknowledge(record.event.id,user,result);render();}
        catch(err){render();throw new Error(`确认未完成：${err.message}`);}finally{acknowledging=false;}
        break;
      }
      case 'report':downloadReport(record);view.status('已生成HTML事件报告（调查参考），包含时间、候选依据及数据缺口。');break;
    }
  }
  function downloadReport(record){
    const event=record.event;
    const text=JSON.stringify(record,null,2);
    const html=`<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>${e(event.id)} 油污事件报告</title><style>body{font:15px/1.7 "Microsoft YaHei",sans-serif;max-width:900px;margin:40px auto;color:#27394d}h1{color:#a52c38}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f4f6f8;padding:20px}td,th{padding:9px;border:1px solid #ddd}table{border-collapse:collapse;width:100%}</style><h1>油污事件调查参考报告</h1><p>${e(event.id)} · ${e(riskLabel(event.risk))} · 检测 ${e(timeText(event.detectedAt))}</p><p>数据性质：${event.provenance==='development'?'开发测试数据':'业务接口数据'}。确认状态：${record.status==='acknowledged'?'已确认':'未处理'}。确认时间：${e(record.acknowledgedAt?timeText(record.acknowledgedAt):'—')}；确认人：${e(record.acknowledgedBy || '未记录')}。</p><p>可疑船舶排序仅用于辅助调查，不代表最终责任认定。检测时间不等于泄漏时间；AIS缺测不等于主动关闭AIS。本报告不是经过审核的法律证据包。空值表示数据未提供或未评估。</p><h2>候选船舶</h2><table><tr><th>船名</th><th>MMSI</th><th>关联概率</th><th>事前接近时间</th></tr>${event.candidates.map(v=>`<tr><td>${e(v.name)}</td><td>${e(v.mmsi)}</td><td>${v.probability===null?'未评估':v.probability+'%'}</td><td>${e(v.passageTime?timeText(v.passageTime):'未提供')}</td></tr>`).join('')}</table><h2>事件、预测、历史轨迹及确认记录</h2><pre>${e(text)}</pre></html>`;
    const url=URL.createObjectURL(new Blob([html],{type:'text/html;charset=utf-8'}));const a=document.createElement('a');a.href=url;a.download=`${event.id.replace(/[^a-zA-Z0-9_-]/g,'_')}-report.html`;a.click();setTimeout(()=>URL.revokeObjectURL(url),10000);
  }
  const receiver=new AlertReceiver({onEvent,onBaseline:events=>store.baseline(events),onError:error=>{view.status(error.message);console.warn('Oil alert:',error.message);}});
  view.updateInbox(store);
  function refreshVessels(collection) {
    const record=current();if(!record || record.event.provenance==='development')return;
    const live=new Map((collection.features || []).map(f=>[String(f.properties.mmsi),f]));
    record.event.candidates=record.event.candidates.map(v=>{
      const f=live.get(v.mmsi);if(!f || !coordinate(f.geometry?.coordinates))return v;
      return {...v,position:f.geometry.coordinates,positionTime:utc(f.properties.update_time),speedKnots:numberOrNull(f.properties.speed),course:numberOrNull(f.properties.course),distanceNm:distanceNm(record.event.center,f.geometry.coordinates)};
    });
    view.refreshCandidates(record.event,selectedMmsi);
    if(mapController.selected)mapController.selected=selected();
    mapController.updateEvent(record.event);
  }
  const controller={acceptSnapshot:data=>receiver.snapshot(data),receive:data=>receiver.receive(data),
    refreshVessels,
    startPolling:options=>receiver.startPolling(options),connectWebSocket:url=>receiver.connectWebSocket(url),
    open:id=>openRecord(id),clear:()=>runAction('clear'),store,view,mapController,
    destroy(){receiver.destroy();mapController.destroy();view.destroy();}};
  if(config.polling)receiver.startPolling(config.polling);
  if(config.webSocketUrl)receiver.connectWebSocket(config.webSocketUrl);
  if(development){
    const dev=document.createElement('section');dev.className='oil-alert-dev-tools';
    dev.innerHTML='<strong>开发测试 · 油污自动预警</strong><p>独立测试事件，不写入数据库；重复发送同一事件用于验证去重。</p><select aria-label="测试预警风险"><option value="high">高风险</option><option value="medium">中风险</option><option value="low">低风险</option></select><button id="simulateOilAlert" type="button">模拟油污预警</button><button id="repeatOilAlert" type="button">重复发送同一事件</button>';
    document.querySelector('[data-floating-panel="system"] .floating-panel-body').append(dev);
    let lastMock=null;
    const triggerDemo=async()=>{
      const button=dev.querySelector('#simulateOilAlert');button.disabled=true;
      try {
        const {createMockAlert}=await import('./mock.js');
        lastMock=createMockAlert({risk:dev.querySelector('select').value});manager.hide('system');
        await controller.receive(lastMock);
      } catch(err) {view.status(err.message);}
      finally {button.disabled=false;}
    };
    dev.querySelector('#simulateOilAlert').onclick=triggerDemo;
    dev.querySelector('#repeatOilAlert').onclick=()=>{if(lastMock)controller.receive(lastMock);else view.status('请先生成一条测试事件。');};
    // The dedicated launcher opts into one demo per tab, not another demo on every refresh.
    if(new URLSearchParams(location.search).get('demoAlert')==='1'){
      let alreadyOpened=false;
      try {alreadyOpened=sessionStorage.getItem('oil-alert-auto-demo.v1')==='opened';}catch{}
      if(!alreadyOpened){
        try{sessionStorage.setItem('oil-alert-auto-demo.v1','opened');}catch{}
        triggerDemo();
      }
    }
  }
  return controller;
}
