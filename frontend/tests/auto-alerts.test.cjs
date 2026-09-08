const {test}=require('node:test');
const assert=require('node:assert/strict');
const modules=Promise.all([import('../alerts/model.js'),import('../alerts/source.js'),import('../alerts/mock.js')]);
function memory(){const data=new Map();return {getItem:k=>data.get(k),setItem:(k,v)=>data.set(k,v)};}

test('normalizes offshore fixture, UTC, probabilities and 1/3/6h geometry',async()=>{
  const [m,,mock]=await modules,e=m.normalizeEvent(mock.createMockAlert({id:'TEST'}));
  assert.equal(e.id,'TEST');assert.deepEqual(e.candidates.map(c=>c.probability),[91,73,48]);
  assert.deepEqual(e.forecasts.map(f=>f.hours),[1,3,6]);assert.equal(m.utc('2026-09-03T10:00:00'),'2026-09-03T10:00:00.000Z');
  assert.equal(m.timeText(null),'未提供');assert.ok(m.geometryPositions(e.geometry).every(([x,y])=>x>56.60&&x<56.70&&y>26.30&&y<26.40));
  assert.equal(e.candidates[0].anomalies.aisOff,null);
});
test('rejects missing IDs, timestamps, invalid coordinates and unclosed polygons',async()=>{
  const [m,,mock]=await modules,raw=mock.createMockAlert();
  for(const change of [{id:''},{detectedAt:'bad'},{geometry:{type:'Point',coordinates:[200,26]}},{geometry:{type:'Polygon',coordinates:[[[1,2],[2,3],[3,4],[4,5]]]}}])assert.throws(()=>m.normalizeEvent({...raw,...change}));
});
test('real feature leaves forecasts, probabilities and anomaly diagnosis unknown',async()=>{
  const [m]=await modules,e=m.normalizeEvent({type:'Feature',geometry:{type:'Point',coordinates:[56.65,26.35]},properties:{event_id:'REAL',event_time:'2026-09-03T10:00:00',level:'中'}});
  assert.equal(e.risk,'medium');assert.equal(e.confidence,null);assert.equal(e.forecasts.length,0);assert.equal(e.candidateStatus,'pending');
  const c=m.normalizeCandidate({mmsi:'123',probability:105});assert.equal(c.probability,null);assert.equal(c.anomalies.aisOff,null);
});
test('deduplicates across receive, acknowledgements and browser reload without losing pending records',async()=>{
  const [m,,mock]=await modules,storage=memory(),store=new m.AlertStore(storage),event=m.normalizeEvent(mock.createMockAlert({id:'A'}));
  assert.ok(store.receive(event));assert.equal(store.receive(event),null);assert.equal(store.pending,1);
  const first=store.acknowledge('A',{id:'operator'});const time=first.acknowledgedAt;store.acknowledge('A');assert.equal(first.acknowledgedAt,time);assert.equal(store.pending,0);
  for(let i=0;i<105;i++)store.receive({...event,id:`P${i}`});
  const restored=new m.AlertStore(storage);assert.equal(restored.pending,105);assert.equal(restored.receive(event),null);assert.equal(restored.records.get('A').acknowledgedBy,'operator');
});
test('storage failure does not crash delivery or acknowledgement',async()=>{
  const [m,,mock]=await modules,store=new m.AlertStore({getItem(){throw Error('blocked')},setItem(){throw Error('quota')}});
  store.receive(m.normalizeEvent(mock.createMockAlert({id:'A'})));store.acknowledge('A');assert.ok(store.persistError);assert.equal(store.pending,0);
});
test('baseline snapshot suppresses historical alerts; new IDs delivered only once',async()=>{
  const [m,s,mock]=await modules,store=new m.AlertStore(memory()),delivered=[];
  const receiver=new s.AlertReceiver({onBaseline:es=>store.baseline(es),onEvent:e=>{if(store.receive(e))delivered.push(e.id)}});
  const a=mock.createMockAlert({id:'OLD'}),b=mock.createMockAlert({id:'NEW'});
  receiver.snapshot({features:[a]});receiver.snapshot({features:[a,b]});await receiver.receive(b);await receiver.receive(a);
  assert.deepEqual(delivered,['NEW']);receiver.destroy();
});
test('track sorting, timestamp deduplication and gaps never invent a solid line',async()=>{
  const [m,,mock]=await modules,track=m.normalizeEvent(mock.createMockAlert()).candidates[0].track;
  const {lines,gaps}=m.splitTrack([...track].reverse().concat(track[0]));assert.equal(gaps.length,1);
  assert.ok(lines.every(l=>Date.parse(l.properties.end)-Date.parse(l.properties.start)<=600000));
  assert.equal(lines.length+gaps.length,track.length-1);
});
test('production adapter calls existing candidate and timestamped AIS endpoints',async()=>{
  const [m,s,mock]=await modules,raw=mock.createMockAlert({id:'DB',now:Date.parse('2026-09-03T12:00:00Z')});
  const event=m.normalizeEvent({...raw,provenance:'api',candidates:undefined});const calls=[];
  const adapter=s.createApiAdapter({apiBase:'http://local',getVessels:()=>({features:[{geometry:{coordinates:[56.6,26.3]},properties:{mmsi:'123',speed:4,course:90}}]}),fetcher:async url=>{
    calls.push(url);return {ok:true,json:async()=>url.includes('candidate-vessels')?{items:[{mmsi:'123',ship_name:'SHIP',ship_type:'Cargo',match_time:'2026-09-03T08:00:00',match_longitude:56.64,match_latitude:26.34}]}:{features:[{geometry:{coordinates:[56.6,26.3]},properties:{update_time:'2026-09-03T08:00:00'}}]}};
  }});
  const enriched=await adapter.enrich(event);assert.equal(enriched.candidateStatus,'ready');assert.equal(enriched.candidates[0].probability,null);assert.ok(enriched.candidates[0].distanceNm>0);
  const v=await adapter.loadTrack(enriched,enriched.candidates[0]);assert.equal(v.track.length,1);assert.match(calls[0],/lookback_hours=24/);assert.match(calls[1],/\/api\/ships\/123\/track\?/);
  assert.equal(new URL(calls[1]).searchParams.get('start_time'),'2026-09-03T07:30:00.000Z');
});
test('API errors remain errors, never fake empty successful candidate results',async()=>{
  const [m,s,mock]=await modules,adapter=s.createApiAdapter({apiBase:'http://local',getVessels:()=>null,fetcher:async()=>({ok:false,status:503})});
  const event=m.normalizeEvent({...mock.createMockAlert(),provenance:'api',candidates:undefined}),result=await adapter.enrich(event);
  assert.equal(result.candidateStatus,'error');assert.match(result.candidateError,/503/);
});
test('development storage namespace does not contaminate production alert state',async()=>{
  const [m,,mock]=await modules,storage=memory(),dev=new m.AlertStore(storage,'dev'),prod=new m.AlertStore(storage,'prod');dev.receive(m.normalizeEvent(mock.createMockAlert()));assert.equal(prod.pending,0);
});

test('WebSocket messages share deduplication; malformed data is contained; shutdown closes connection',async()=>{
  const [m,s,mock]=await modules,previous=global.WebSocket,sockets=[],errors=[],store=new m.AlertStore(memory());
  global.WebSocket=class{constructor(){sockets.push(this)}close(){this.closed=true}};
  try{
    const receiver=new s.AlertReceiver({onEvent:e=>store.receive(e),onBaseline:()=>{},onError:e=>errors.push(e.message)});
    receiver.connectWebSocket('ws://example');const socket=sockets[0],event=mock.createMockAlert({id:'WS'});
    socket.onmessage({data:JSON.stringify({event})});socket.onmessage({data:JSON.stringify({events:[event]})});socket.onmessage({data:'invalid JSON'});
    assert.equal(store.pending,1);assert.equal(errors.length,1);receiver.destroy();assert.equal(socket.closed,true);
  }finally{global.WebSocket=previous;}
});

test('REST event polling feeds receiver and can be cancelled without lingering work',async()=>{
  const [,s,mock]=await modules;let resolveEvent;const delivered=new Promise(resolve=>{resolveEvent=resolve});
  const receiver=new s.AlertReceiver({onEvent:e=>resolveEvent(e.id),onBaseline:()=>{}});
  receiver.startPolling({url:'http://example',mode:'events',fetcher:async()=>({ok:true,json:async()=>({events:[mock.createMockAlert({id:'REST'})]})})});
  assert.equal(await delivered,'REST');receiver.destroy();
});
