import { normalizeEvent, normalizeCandidate, normalizeTrack, distanceNm, sortCandidates, utc } from './model.js';

/** A single ingestion boundary for snapshots, REST and WebSocket messages. */
export class AlertReceiver {
  constructor({onEvent,onBaseline,onError=()=>{}}) { Object.assign(this,{onEvent,onBaseline,onError});this.initialized=false; }
  receive(raw) {
    try { return Promise.resolve(this.onEvent(normalizeEvent(raw))).catch(this.onError); }
    catch(e) { this.onError(e);return Promise.resolve(null); }
  }
  snapshot(collection) {
    if(!Array.isArray(collection?.features)) { this.onError(new Error('预警数据不是有效的事件集合'));return; }
    const events=[];
    for(const f of collection.features) { try{events.push(normalizeEvent(f));}catch(e){this.onError(e);} }
    // 首次成功快照只建立基线，防止打开页面时重播数据库中的全部旧事件。
    if(!this.initialized) {this.initialized=true;this.onBaseline(events);return;}
    events.sort((a,b)=>a.detectedAt.localeCompare(b.detectedAt)).forEach(e=>this.receive(e));
  }
  startPolling({url,intervalMs=5000,fetcher=fetch,mode='snapshot'}) {
    this.stopPolling();let cancelled=false;
    const poll=async()=>{
      try {
        this.abort=new AbortController();const timeout=setTimeout(()=>this.abort?.abort(),12000);
        let data;
        try {const res=await fetcher(url,{signal:this.abort.signal,cache:'no-store'});if(!res.ok)throw new Error(`预警接口 ${res.status}`);data=await res.json();}
        finally{clearTimeout(timeout);}
        if(!cancelled) { if(mode==='snapshot')this.snapshot(data);else for(const event of data.events || [])await this.receive(event); }
      }catch(e){if(!cancelled)this.onError(e);}
      if(!cancelled)this.pollTimer=setTimeout(poll,Math.max(1000,intervalMs));
    };
    this.cancelPoll=()=>{cancelled=true;this.abort?.abort();clearTimeout(this.pollTimer);};poll();
  }
  stopPolling(){this.cancelPoll?.();this.cancelPoll=null;}
  connectWebSocket(url) {
    this.stopWebSocket();this.wsStopped=false;let failures=0;
    const connect=()=>{
      if(this.wsStopped)return;
      try {this.socket=new WebSocket(url);}catch(e){this.onError(e);return;}
      this.socket.onopen=()=>{failures=0;};
      this.socket.onmessage=message=>{try{const data=JSON.parse(message.data);for(const e of data.events || [data.event || data])this.receive(e);}catch(e){this.onError(e);}};
      this.socket.onerror=()=>this.onError(new Error('预警推送连接异常，正在等待重连'));
      this.socket.onclose=()=>{if(!this.wsStopped)this.wsTimer=setTimeout(connect,Math.min(30000,1000*2**failures++));};
    };connect();
  }
  stopWebSocket(){this.wsStopped=true;clearTimeout(this.wsTimer);if(this.socket){this.socket.onclose=null;this.socket.close();this.socket=null;}}
  destroy(){this.stopPolling();this.stopWebSocket();}
}

/** Existing read-only PostGIS API adapter. Replace/extend this, not the window. */
export function createApiAdapter({apiBase,getVessels,fetcher=fetch,acknowledge=null}) {
  async function json(path) {
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),15000);
    try {const response=await fetcher(`${apiBase}${path}`,{signal:controller.signal,cache:'no-store'});if(!response.ok)throw new Error(`查询失败 (${response.status})`);return await response.json();}
    finally {clearTimeout(timer);}
  }
  return {
    acknowledge,
    async enrich(event) {
      if(event.provenance==='development' || event.candidateStatus==='ready')return event;
      try {
        const data=await json(`/api/pollution-events/${encodeURIComponent(event.id)}/candidate-vessels?nearby_nm=10&lookback_hours=24&limit=200`);
        const vessels=getVessels()?.features || [];
        const candidates=(data.items || []).map(c=>{
          const live=vessels.find(v=>String(v.properties.mmsi)===String(c.mmsi));
          const position=live?.geometry?.coordinates || null,p=live?.properties || {};
          return normalizeCandidate({mmsi:c.mmsi,name:c.ship_name,type:c.ship_type,position,positionTime:p.update_time,
            speedKnots:p.speed,course:p.course,flag:p.flag,probability:c.association_probability,
            distanceNm:position ? distanceNm(event.center,position) : null,passageTime:c.match_time,
            closest:{coordinates:[c.match_longitude,c.match_latitude],time:c.match_time,basis:'事前航段线性估算'},track:[]});
        });
        return {...event,candidates:sortCandidates(candidates),candidateStatus:'ready'};
      } catch(e){return {...event,candidateStatus:'error',candidateError:e.message};}
    },
    async loadTrack(event,vessel) {
      if(event.provenance==='development')return vessel;
      const t=Date.parse(event.detectedAt), passage=Date.parse(vessel.passageTime);
      const beginning=Number.isFinite(passage)?Math.max(t-24*3600000,Math.min(t-2*3600000,passage-30*60000)):t-2*3600000;
      const start=new Date(beginning).toISOString(),end=new Date(Math.min(Date.now(),t+3600000)).toISOString();
      const params=new URLSearchParams({start_time:start,end_time:end,limit:'20000'});
      const data=await json(`/api/ships/${encodeURIComponent(vessel.mmsi)}/track?${params}`);
      const track=normalizeTrack((data.features || []).map(f=>({coordinates:f.geometry.coordinates,time:utc(f.properties.update_time)})));
      return {...vessel,track,trackWindow:{start,end},trackTruncated:track.length>=20000};
    }
  };
}
