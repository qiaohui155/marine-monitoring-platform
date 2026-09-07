import { geometryPositions, splitTrack, timeText, distanceNm, normalizeTrack } from './model.js';
const fc=features=>({type:'FeatureCollection',features});
const feature=(geometry,properties={})=>({type:'Feature',geometry,properties});

/** Owns only oil-alert-* sources, layers and markers. Does not change business data. */
export class AlertMapController {
  constructor({map,maplibre,getPanelRect,onSelect=()=>{},onPlayback=()=>{}}) {
    Object.assign(this,{map,maplibre,getPanelRect,onSelect,onPlayback});
    this.markers=[];this.savedPaint=new Map();this.selected=null;this.active=null;this.frame=null;
    this.reducedMotion=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    this.onStyle=()=>{if(this.active && map.isStyleLoaded() && !map.getSource('oil-alert-event'))this.render();};
    map.on('style.load',this.onStyle);
  }
  ensureLayers() {
    const map=this.map;
    for(const name of ['event','forecasts','drift','track','gaps'])if(!map.getSource(`oil-alert-${name}`))map.addSource(`oil-alert-${name}`,{type:'geojson',data:fc([])});
    const layers=[
      {id:'forecast-fill',type:'fill',source:'forecasts',paint:{'fill-color':['match',['get','hours'],1,'#ef8b42',3,'#dfb63e','#648bd3'],'fill-opacity':.12}},
      {id:'forecast-line',type:'line',source:'forecasts',paint:{'line-color':['match',['get','hours'],1,'#ef8b42',3,'#dfb63e','#648bd3'],'line-width':2,'line-dasharray':[4,2]}},
      {id:'drift-line',type:'line',source:'drift',paint:{'line-color':'#f2b754','line-width':2.5,'line-dasharray':[3,2]}},
      {id:'event-fill',type:'fill',source:'event',filter:['!=','$type','Point'],paint:{'fill-color':'#d73939','fill-opacity':.38}},
      {id:'event-point',type:'circle',source:'event',filter:['==','$type','Point'],paint:{'circle-radius':12,'circle-color':'#d73939','circle-opacity':.65}},
      {id:'event-line',type:'line',source:'event',paint:{'line-color':'#e03131','line-width':3.5,'line-opacity':1}},
      {id:'track-halo',type:'line',source:'track',paint:{'line-color':'#fff4e6','line-width':7}},
      {id:'track-line',type:'line',source:'track',paint:{'line-color':'#991b36','line-width':4}},
      {id:'gap-line',type:'line',source:'gaps',paint:{'line-color':'#ef3434','line-width':3,'line-dasharray':[2,2]}}
    ];
    layers.forEach(l=>{const id=`oil-alert-${l.id}`;if(!map.getLayer(id))map.addLayer({...l,id,source:`oil-alert-${l.source}`});});
  }
  setEvent(event) {this.stopPlayback();this.active=event;this.selected=null;this.render();this.locateEvent();}
  updateEvent(event) {if(this.active?.id!==event.id)return;this.active=event;this.renderMarkers();}
  render() {
    if(!this.active)return;this.ensureLayers();const e=this.active;
    this.map.getSource('oil-alert-event').setData(fc([feature(e.geometry)]));
    this.map.getSource('oil-alert-forecasts').setData(fc(e.forecasts.map(f=>feature(f.geometry,{hours:f.hours}))));
    const drift=[e.center,...e.forecasts.map(f=>this.centerOf(f.geometry))];
    this.map.getSource('oil-alert-drift').setData(fc(drift.length>1 ? [feature({type:'LineString',coordinates:drift})] : []));
    this.dimVessels();this.renderMarkers();this.drawTrack();
    clearInterval(this.blink);
    if(!this.reducedMotion){let bright=true;this.blink=setInterval(()=>{bright=!bright;if(this.map.getLayer('oil-alert-event-line'))this.map.setPaintProperty('oil-alert-event-line','line-opacity',bright?1:.35);},750);}
  }
  centerOf(g){const points=geometryPositions(g);return points.reduce((a,c)=>[a[0]+c[0]/points.length,a[1]+c[1]/points.length],[0,0]);}
  dimVessels() {
    for(const [id,property] of [['vessels','icon-opacity'],['vessels-overview','icon-opacity'],['vessel-labels','text-opacity'],['vessel-selection','circle-opacity']]){
      if(!this.map.getLayer(id))continue;
      if(!this.savedPaint.has(id))this.savedPaint.set(id,{property,value:this.map.getPaintProperty(id,property)});
      this.map.setPaintProperty(id,property,id==='vessel-selection'?0:.25);
    }
  }
  marker(coordinates,element){const marker=new this.maplibre.Marker({element}).setLngLat(coordinates).addTo(this.map);this.markers.push(marker);return marker;}
  renderMarkers() {
    this.markers.forEach(m=>m.remove());this.markers=[];
    if(!this.active)return;
    this.active.forecasts.forEach(f=>{
      const el=document.createElement('span');el.className=`oil-alert-map-label forecast-${f.hours}`;el.textContent=`${f.hours}h 预测`;
      this.marker(this.centerOf(f.geometry),el);
    });
    if(this.active.forecasts.length){
      const end=this.centerOf(this.active.forecasts.at(-1).geometry),start=this.active.center;
      const angle=Math.atan2(end[0]-start[0],end[1]-start[1])*180/Math.PI;
      const arrow=document.createElement('div');arrow.className='oil-alert-drift-arrow';arrow.title='预测漂移方向';
      const tip=document.createElement('span');tip.textContent='➤';tip.style.transform=`rotate(${angle-90}deg)`;arrow.append(tip);this.marker(end,arrow);
    }
    for(const vessel of this.active.candidates.slice(0,5)) {
      if(!vessel.position)continue;
      const selected=vessel.mmsi===this.selected?.mmsi,button=document.createElement('button');
      button.type='button';button.className=`oil-alert-ship ${selected?'selected':''}`;
      button.setAttribute('aria-label',`${vessel.name} MMSI ${vessel.mmsi} 当前船位`);
      const icon=document.createElement('span');icon.textContent='▲';icon.style.transform=`rotate(${vessel.course || 0}deg)`;
      const label=document.createElement('b');label.textContent=`${vessel.name} · ${vessel.mmsi}`;button.append(icon,label);
      button.addEventListener('click',e=>{e.stopPropagation();this.onSelect(vessel.mmsi);});this.marker(vessel.position,button);
    }
    if(this.selected){
      let closest=this.selected.closest;
      if(!closest && this.selected.track.length) {
        const point=[...this.selected.track].sort((a,b)=>distanceNm(a.coordinates,this.active.center)-distanceNm(b.coordinates,this.active.center))[0];
        closest={...point,basis:'距中心最近的已记录轨迹点'};
      }
      if(closest){const el=document.createElement('div');el.className='oil-alert-passage-label';
        const name=document.createElement('strong');name.textContent=`${this.selected.name} · 最近接近点`;
        const time=document.createElement('span');time.textContent=timeText(closest.time);
        const basis=document.createElement('small');basis.textContent=closest.basis || '历史位置';el.append(name,time,basis);this.marker(closest.coordinates,el);}
    }
  }
  drawTrack(){
    if(!this.map.getSource('oil-alert-track'))return;
    const {lines,gaps}=splitTrack(this.selected?.track || []);
    this.map.getSource('oil-alert-track').setData(fc(lines));this.map.getSource('oil-alert-gaps').setData(fc(gaps));
  }
  select(vessel){this.stopPlayback();this.selected=vessel;this.drawTrack();this.renderMarkers();this.locateVessel(vessel);}
  padding(){
    const rect=this.getPanelRect?.(),width=this.map.getContainer().clientWidth;
    const pad={top:100,bottom:110,left:70,right:90};
    if(rect && rect.width < width-300){if(rect.left<width/2)pad.left=Math.min(rect.right+25,width-300);else pad.right=Math.min(width-rect.left+25,width-300);}
    return pad;
  }
  fit(points,maxZoom=12){
    if(!points.length)return;
    const bounds=new this.maplibre.LngLatBounds();points.forEach(p=>bounds.extend(p));this.map.stop();
    this.map.fitBounds(bounds,{padding:this.padding(),maxZoom,duration:this.reducedMotion?0:800});
  }
  locateEvent(){if(this.active)this.fit([this.active.center,...geometryPositions(this.active.geometry),...this.active.forecasts.flatMap(f=>geometryPositions(f.geometry))],12);}
  locateVessel(v){this.fit([...(v.position?[v.position]:[]),...v.track.map(p=>p.coordinates)],13);}
  startPlayback(vessel) {
    if(this.frame!==null){this.stopPlayback();return;}
    const track=normalizeTrack(vessel.track);if(track.length<2)throw new Error('至少需要两个带时间戳的轨迹点才能回放');
    const el=document.createElement('div');el.className='oil-alert-replay';el.textContent='▶';
    this.replayMarker=new this.maplibre.Marker({element:el}).setLngLat(track[0].coordinates).addTo(this.map);
    const start=performance.now(),first=Date.parse(track[0].time),last=Date.parse(track.at(-1).time);
    this.onPlayback({playing:true,time:track[0].time});
    const tick=now=>{
      const progress=Math.min((now-start)/15000,1),target=first+(last-first)*progress;
      let j=1;while(j<track.length-1 && Date.parse(track[j].time)<target)j++;
      const a=track[j-1],b=track[j],dt=Date.parse(b.time)-Date.parse(a.time),gap=dt>10*60000;
      const portion=dt?Math.max(0,Math.min(1,(target-Date.parse(a.time))/dt)):0;
      el.hidden=gap; // No invented motion through an AIS observation gap.
      if(!gap)this.replayMarker.setLngLat(a.coordinates.map((n,i)=>n+(b.coordinates[i]-n)*portion));
      this.onPlayback({playing:true,time:new Date(target).toISOString(),gap});
      if(progress<1)this.frame=requestAnimationFrame(tick);else this.stopPlayback();
    };this.frame=requestAnimationFrame(tick);
  }
  stopPlayback(){if(this.frame!==null)cancelAnimationFrame(this.frame);this.frame=null;this.replayMarker?.remove();this.replayMarker=null;this.onPlayback({playing:false});}
  clear(){
    this.map.stop();
    this.stopPlayback();clearInterval(this.blink);this.active=null;this.selected=null;
    this.markers.forEach(m=>m.remove());this.markers=[];
    for(const name of ['event','forecasts','drift','track','gaps'])this.map.getSource(`oil-alert-${name}`)?.setData(fc([]));
    for(const [id,{property,value}]of this.savedPaint)if(this.map.getLayer(id))this.map.setPaintProperty(id,property,value ?? null);
    this.savedPaint.clear();
  }
  destroy(){this.clear();this.map.off('style.load',this.onStyle);}
}
