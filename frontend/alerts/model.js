export const riskLabel = risk => ({high:'高风险',medium:'中风险',low:'低风险',unknown:'风险待评估'}[risk] || '风险待评估');
export const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function utc(value) {
  if (!value) return null;
  const input = String(value);
  const d = new Date(/(?:Z|[+-]\d{2}:?\d{2})$/i.test(input) ? input : `${input}Z`);
  return Number.isFinite(d.getTime()) ? d.toISOString() : null;
}
export const timeText = value => { const stamp=utc(value);return stamp?`${stamp.replace('T',' ').slice(0,19)} UTC`:'未提供'; };
export const coordinate = p => Array.isArray(p) && p.length >= 2 && Number.isFinite(p[0]) && Number.isFinite(p[1]) && Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 90;
export const numberOrNull = value => value !== '' && value !== null && value !== undefined && Number.isFinite(Number(value)) ? Number(value) : null;
const percent = v => { const n = numberOrNull(v); return n !== null && n >= 0 && n <= 100 ? n : null; };
export function geometryPositions(geometry) {
  if (!geometry) return [];
  if (geometry.type === 'Point') return coordinate(geometry.coordinates) ? [geometry.coordinates] : [];
  if (!['Polygon','MultiPolygon','LineString','MultiLineString'].includes(geometry.type)) return [];
  const out = [];
  const visit = xs => { if (coordinate(xs)) out.push(xs); else if (Array.isArray(xs)) xs.forEach(visit); };
  visit(geometry.coordinates); return out;
}
function validGeometry(g) {
  if (!g || !['Point','Polygon','MultiPolygon'].includes(g.type)) return false;
  if (g.type === 'Point') return coordinate(g.coordinates);
  const polygons = g.type === 'Polygon' ? [g.coordinates] : g.coordinates;
  return Array.isArray(polygons) && polygons.length > 0 && polygons.every(rings =>
    Array.isArray(rings) && rings.length > 0 && rings.every(r => Array.isArray(r) && r.length >= 4 && r.every(coordinate) && r[0][0] === r.at(-1)[0] && r[0][1] === r.at(-1)[1]));
}
export function normalizeTrack(points = []) {
  const seen = new Set();
  return points.filter(p => coordinate(p.coordinates) && utc(p.time)).map(p => ({coordinates:p.coordinates.slice(0,2),time:utc(p.time)}))
    .sort((a,b)=>a.time.localeCompare(b.time)).filter(p=> { if(seen.has(p.time)) return false; seen.add(p.time); return true; });
}
export function normalizeCandidate(v) {
  const a = v.anomalies || {};
  return {...v, mmsi:String(v.mmsi || ''), name:String(v.name || v.mmsi || '未命名船舶'), type:String(v.type || '未知'),
    flag:v.flag || null, position:coordinate(v.position) ? v.position : null, positionTime:utc(v.positionTime),
    probability:percent(v.probability), speedKnots:numberOrNull(v.speedKnots), course:numberOrNull(v.course), distanceNm:numberOrNull(v.distanceNm),
    passageTime:utc(v.passageTime), closest:coordinate(v.closest?.coordinates) && utc(v.closest?.time) ? {...v.closest,time:utc(v.closest.time)} : null,
    anomalies:Object.fromEntries(['signalGap','loitering','slowdown','aisOff'].map(k=>[k,typeof a[k] === 'boolean' ? a[k] : null])), track:normalizeTrack(v.track)};
}
export function normalizeEvent(input) {
  const p = input.type === 'Feature' ? input.properties || {} : input;
  const id = String(p.id && input.type !== 'Feature' ? p.id : p.event_id || input.id || '').trim();
  const detectedAt = utc(p.detectedAt || p.event_time);
  const geometry = input.geometry;
  if (!id || !detectedAt || !validGeometry(geometry)) throw new Error('预警缺少有效事件编号、检测时间或地理范围');
  const points = geometryPositions(geometry);
  const fallback = points.reduce((a,c)=>[a[0]+c[0]/points.length,a[1]+c[1]/points.length],[0,0]);
  const providedCenter = p.center || [numberOrNull(p.center_longitude),numberOrNull(p.center_latitude)];
  const risk = ({高:'high',中:'medium',低:'low',high:'high',medium:'medium',low:'low'})[p.risk || p.level] || 'unknown';
  const candidates = (p.candidates || []).map(normalizeCandidate).filter(v=>v.mmsi);
  const imageUrl = /^https?:\/\//i.test(p.imageUrl || '') ? p.imageUrl : null;
  return {id,detectedAt,releaseTime:utc(p.releaseTime),risk,center:coordinate(providedCenter) ? providedCenter : fallback,geometry,
    areaKm2:numberOrNull(p.areaKm2 ?? p.area_km2),lengthKm:numberOrNull(p.lengthKm),widthKm:numberOrNull(p.widthKm),
    morphology:p.morphology || null,source:p.source || '未提供',confidence:percent(p.confidence),imageUrl,
    driftDirection:p.driftDirection || null,driftSpeedKnots:numberOrNull(p.driftSpeedKnots),
    forecasts:(p.forecasts || []).filter(f=>[1,3,6].includes(f.hours) && validGeometry(f.geometry)).map(f=>({...f,areaKm2:numberOrNull(f.areaKm2)})),
    candidates:sortCandidates(candidates),provenance:p.provenance === 'development' ? 'development' : 'api',
    candidateStatus:['ready','pending','error'].includes(p.candidateStatus)?p.candidateStatus:p.candidates?'ready':'pending',candidateError:p.candidateError};
}
export function sortCandidates(items) { return [...items].sort((a,b)=>(b.probability ?? -1)-(a.probability ?? -1) || (a.distanceNm ?? Infinity)-(b.distanceNm ?? Infinity)); }
export function probabilityClass(p) { return p === null ? 'unknown' : p >= 80 ? 'high' : p >= 60 ? 'medium' : p >= 40 ? 'low' : 'unknown'; }
export function distanceNm(a,b) {
  const r = Math.PI/180, dlat=(b[1]-a[1])*r,dlon=(b[0]-a[0])*r;
  const h=Math.sin(dlat/2)**2+Math.cos(a[1]*r)*Math.cos(b[1]*r)*Math.sin(dlon/2)**2;
  return 3440.065*2*Math.asin(Math.sqrt(Math.min(1,h)));
}
export function splitTrack(points, gapMinutes = 10) {
  const track=normalizeTrack(points), lines=[], gaps=[];
  for(let i=1;i<track.length;i++) {
    const segment={type:'Feature',properties:{start:track[i-1].time,end:track[i].time},geometry:{type:'LineString',coordinates:[track[i-1].coordinates,track[i].coordinates]}};
    ((Date.parse(track[i].time)-Date.parse(track[i-1].time))>gapMinutes*60000 ? gaps : lines).push(segment);
  }
  return {lines,gaps};
}
export class AlertStore {
  constructor(storage, key='oman.oil-alerts.v1') {
    this.storage=storage;this.key=key;this.records=new Map();this.seen=new Set();this.persistError=false;
    try {
      const saved=JSON.parse(storage?.getItem(key) || '{}');
      (saved.seen || []).forEach(id=>this.seen.add(String(id)));
      (saved.records || []).forEach(r=>{ try { const event=normalizeEvent(r.event);this.records.set(event.id,{...r,event});this.seen.add(event.id); } catch {} });
    } catch { this.persistError=true; }
  }
  persist() {
    try {
      if(!this.storage){this.persistError=true;return;}
      const records=[...this.records.values()];
      const keep=new Set(records.filter(r=>r.status==='acknowledged').slice(-100).map(r=>r.event.id));
      this.storage.setItem(this.key,JSON.stringify({seen:[...this.seen],records:records.filter(r=>r.status==='unhandled'||keep.has(r.event.id))}));
    }
    catch { this.persistError=true; }
  }
  baseline(events) { events.forEach(e=>this.seen.add(e.id));this.persist(); }
  receive(event) {
    if(this.seen.has(event.id)) return null;
    this.seen.add(event.id);
    const record={event,receivedAt:new Date().toISOString(),status:'unhandled',acknowledgedAt:null,acknowledgedBy:null,acknowledgementScope:'local'};
    this.records.set(event.id,record);this.persist();return record;
  }
  update(event) { const r=this.records.get(event.id);if(r){r.event=event;this.persist();}return r; }
  acknowledge(id, user=null, result=null) {
    const r=this.records.get(id);if(!r || r.status==='acknowledged') return r;
    Object.assign(r,{status:'acknowledged',acknowledgedAt:result?.acknowledgedAt || new Date().toISOString(),acknowledgedBy:result?.acknowledgedBy || user?.name || user?.id || null,acknowledgementScope:result ? 'server' : 'local'});
    this.persist();return r;
  }
  get pending() { return [...this.records.values()].filter(r=>r.status==='unhandled').length; }
}
