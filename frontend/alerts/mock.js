import { distanceNm } from './model.js';

// 独立开发夹具：穆桑达姆东侧离岸海域。仅演示，不写入 PostGIS。
export function createMockAlert({id=`DEV-OIL-${Date.now()}`,risk='high',now=Date.now()}={}) {
  const detected=now-30*60000, center=[56.65,26.35];
  const polygon=(c,s=1)=>({type:'Polygon',coordinates:[[
    [c[0]-.018*s,c[1]-.009*s],[c[0]-.005*s,c[1]-.014*s],[c[0]+.021*s,c[1]-.004*s],
    [c[0]+.015*s,c[1]+.010*s],[c[0]-.003*s,c[1]+.013*s],[c[0]-.018*s,c[1]-.009*s]
  ]]});
  const iso=minutes=>new Date(detected+minutes*60000).toISOString();
  const candidates=[
    {mmsi:'990000101',name:'MUSANDAM TEST 01',type:'Tanker',flag:'阿曼',probability:91,speedKnots:7.2,course:72},
    {mmsi:'990000102',name:'STRAIT TEST 02',type:'Cargo',flag:'巴拿马',probability:73,speedKnots:10.8,course:108},
    {mmsi:'990000103',name:'COAST TEST 03',type:'Tanker',flag:'利比里亚',probability:48,speedKnots:5.4,course:55}
  ].map((v,i)=>{
    const track=[];
    for(let m=-60;m<=30;m+=5) {
      if(i===0 && [-20,-15,-10].includes(m)) continue;
      track.push({time:iso(m),coordinates:[center[0]+(m+5)*.0012,center[1]+i*.013+(m+5)*.00032]});
    }
    const position=track.at(-1).coordinates;
    return {...v,position,positionTime:iso(30),distanceNm:distanceNm(center,position),passageTime:iso(-5),track,
      trackWindow:{start:iso(-60),end:iso(30)},closest:{coordinates:track.find(p=>p.time===iso(-5)).coordinates,time:iso(-5),basis:'演示最近接近点'},
      anomalies:{signalGap:i===0,loitering:i===1,slowdown:i===0,aisOff:null}};
  });
  return {id,detectedAt:iso(0),releaseTime:null,center,geometry:polygon(center),areaKm2:9.8,lengthKm:4.1,widthKm:2.9,
    risk,confidence:92,morphology:'不规则条带状',source:'Sentinel-1（测试夹具）',provenance:'development',
    driftDirection:'东北偏东 · 65°',driftSpeedKnots:1.2,
    forecasts:[1,3,6].map(h=>({hours:h,geometry:polygon([center[0]+h*.022,center[1]+h*.009],1+h*.16),areaKm2:Number((9.8*(1+h*.16)**2).toFixed(2))})),candidates};
}
