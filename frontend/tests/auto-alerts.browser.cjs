// Run against the existing read-only frontend/API; all test alerts stay in this isolated browser.
const assert=require('node:assert/strict');
const path=require('node:path');
const os=require('node:os');
const {chromium}=require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const base=process.env.FRONTEND_URL || 'http://127.0.0.1:5173/';

(async()=>{
  const browser=await chromium.launch({headless:true,...(process.env.BROWSER_PATH?{executablePath:process.env.BROWSER_PATH}:{})});
  const checks=[];const ok=name=>{checks.push(name);console.log('PASS '+name);};
  try {
    const context=await browser.newContext({viewport:{width:1440,height:900},acceptDownloads:true});
    const page=await context.newPage(),errors=[];page.on('pageerror',err=>errors.push(err.message));
    await page.goto(base,{waitUntil:'domcontentloaded'});await page.waitForFunction(()=>!!window.oilAlerts);
    assert.equal(await page.locator('#simulateOilAlert').count(),0);ok('normal mode hides developer controls');
    await page.goto(`${base}?devAlerts=1`,{waitUntil:'domcontentloaded'});await page.waitForFunction(()=>!!window.oilAlerts);
    await page.locator('[data-panel-target="system"]').click();await page.locator('#simulateOilAlert').click();
    await page.waitForFunction(()=>oilAlerts.view.visible && oilAlerts.mapController.active?.candidates.length===3);
    const firstId=await page.evaluate(()=>oilAlerts.mapController.active.id);
    const initial=await page.evaluate(()=>({pending:oilAlerts.store.pending,prob:oilAlerts.mapController.active.candidates.map(c=>c.probability),
      forecasts:oilAlerts.mapController.active.forecasts.map(f=>f.hours),opacity:map.getPaintProperty('vessels','icon-opacity'),layer:!!map.getLayer('oil-alert-event-fill')}));
    assert.equal(initial.pending,1);assert.deepEqual(initial.prob,[91,73,48]);assert.deepEqual(initial.forecasts,[1,3,6]);assert.equal(initial.opacity,.25);assert.ok(initial.layer);ok('test button opens alert, locates event, displays forecasts, ranks candidates and dims vessels');
    await page.locator('[data-alert-vessel]').first().click();await page.waitForFunction(()=>oilAlerts.mapController.selected?.mmsi==='990000101' && oilAlerts.mapController.frame===null);
    const track=await page.evaluate(()=>({gap:map.getStyle().sources['oil-alert-gaps'].data.features.length,line:map.getStyle().sources['oil-alert-track'].data.features.length}));
    assert.equal(track.gap,1);assert.ok(track.line>1);assert.equal(await page.locator('.oil-alert-ship.selected').count(),1);ok('candidate selection highlights ship, displays timestamped track and dashed AIS gap');
    await page.locator('[data-alert-action="playback"]').click();await page.waitForFunction(()=>oilAlerts.mapController.frame!==null);
    await page.locator('[data-alert-action="playback"]').click();await page.waitForFunction(()=>oilAlerts.mapController.frame===null);ok('track playback starts and stops');
    await page.locator('[data-alert-action="anomalies"]').click();assert.match(await page.locator('#oilAlertExtra').innerText(),/不能据此认定主动关闭AIS/);
    await page.locator('[data-alert-action="details"]').click();assert.match(await page.locator('#oilAlertExtra').innerText(),/实际泄漏时间/);ok('AIS anomaly and event detail buttons show contextual information');
    const panel=page.locator('.oil-alert-window'),before=await panel.boundingBox();
    await page.mouse.move(before.x+200,before.y+25);await page.mouse.down();await page.mouse.move(before.x+270,before.y+65,{steps:8});await page.mouse.up();
    const after=await panel.boundingBox();assert.ok(after.x>before.x+50);
    await panel.locator('[data-panel-minimize]').click();assert.equal(await panel.locator('.oil-alert-footer').isVisible(),false);
    await panel.locator('[data-panel-minimize]').click();assert.equal(await panel.locator('.oil-alert-footer').isVisible(),true);ok('shared window manager supports drag, minimize and restore');
    await page.locator('[data-alert-action="close"]').click();assert.equal(await panel.getAttribute('aria-hidden'),'true');
    assert.equal(await page.evaluate(()=>map.getStyle().sources['oil-alert-event'].data.features.length),1);
    await page.locator('[data-map-action="restore"]').click();assert.equal(await panel.getAttribute('aria-hidden'),'false');ok('close retains map event and restore reopens it');
    await page.locator('#oilAlertAcknowledge').click();assert.equal(await page.evaluate(()=>oilAlerts.store.pending),0);assert.equal(await page.locator('#oilAlertAcknowledge').isDisabled(),true);
    const acknowledged=await page.evaluate(id=>oilAlerts.store.records.get(id).acknowledgedAt,firstId);assert.ok(acknowledged);ok('acknowledgement persists timestamp, disables repeat and updates badge');
    const downloadPromise=page.waitForEvent('download');await page.locator('[data-alert-action="report"]').click();const download=await downloadPromise;assert.match(download.suggestedFilename(),/report\.html$/);ok('event report downloads');
    await page.locator('[data-alert-action="close"]').click();
    await page.evaluate(async id=>{await oilAlerts.receive(oilAlerts.store.records.get(id).event);},firstId);
    assert.equal(await panel.getAttribute('aria-hidden'),'true');assert.equal(await page.evaluate(()=>oilAlerts.store.pending),0);ok('duplicate event does not reopen or increment pending');
    await page.reload({waitUntil:'domcontentloaded'});await page.waitForFunction(()=>!!window.oilAlerts);
    assert.equal(await page.evaluate(id=>oilAlerts.store.records.get(id).acknowledgedAt,firstId),acknowledged);
    assert.equal(await page.evaluate(()=>oilAlerts.view.visible),false);ok('refresh preserves confirmation and does not replay alerts');
    await page.evaluate(async()=>{const {createMockAlert}=await import('/alerts/mock.js');await oilAlerts.receive(createMockAlert({id:'BROWSER-LOW',risk:'low'}));});
    assert.equal(await page.evaluate(()=>oilAlerts.view.visible),false);assert.equal(await page.locator('.oil-alert-toast').isVisible(),true);ok('low risk only notifies without opening full window');
    await page.evaluate(async()=>{const {createMockAlert}=await import('/alerts/mock.js');await oilAlerts.receive(createMockAlert({id:'BROWSER-MEDIUM',risk:'medium'}));});
    assert.equal(await page.evaluate(()=>oilAlerts.view.visible),true);ok('medium risk opens full window');
    for(const [width,height] of [[1920,1080],[1366,768],[1280,720],[1024,768],[800,600]]) {
      await page.setViewportSize({width,height});
      const layout=await page.evaluate(()=>{const p=document.querySelector('.oil-alert-window'),r=p.getBoundingClientRect();return {x:r.x,y:r.y,right:r.right,bottom:r.bottom,overflow:p.scrollWidth>p.clientWidth+1,
        clipped:[...p.querySelectorAll('.oil-alert-actions button')].some(b=>{const q=b.getBoundingClientRect();return q.bottom>r.bottom || q.right>r.right;})};});
      assert.ok(layout.x>=0&&layout.y>=60&&layout.right<=width&&layout.bottom<=height,JSON.stringify(layout));assert.equal(layout.overflow,false);assert.equal(layout.clipped,false);
    }ok('responsive layout and footer buttons fit 1920/1366/1280/1024/800 viewports');
    await page.setViewportSize({width:1366,height:768});await page.locator('[data-alert-action="locate"]').click();
    await page.waitForFunction(()=>!map.isMoving());
    await page.screenshot({path:path.join(os.tmpdir(),'auto-alert-acceptance.png')});
    await page.locator('[data-map-action="clear"]').click();assert.equal(await page.evaluate(()=>map.getStyle().sources['oil-alert-event'].data.features.length),0);
    assert.equal(await page.evaluate(()=>map.getPaintProperty('vessels','icon-opacity') ?? 1),1);ok('explicit clear removes only alert overlays and restores vessel opacity');
    await page.goto(base,{waitUntil:'domcontentloaded'});await page.waitForFunction(()=>!!window.oilAlerts);
    assert.equal(await page.evaluate(()=>oilAlerts.store.pending),0);assert.equal(await page.locator('#simulateOilAlert').count(),0);
    await page.locator('[data-panel-target="operational-watch"]').click();assert.equal(await page.locator('[data-floating-panel="operational-watch"]').getAttribute('aria-hidden'),'false');
    assert.equal(await page.evaluate(()=>!!map.getLayer('track-lines')&&!!map.getLayer('pollution-fills')&&!!map.getLayer('vessels')),true);ok('normal mode stays isolated; original history and business layers remain');
    await page.waitForFunction(()=>pollutionSnapshotLoaded && pollutionData.features.length>0);
    const actual=await page.evaluate(async()=>{
      const f=pollutionData.features.find(f=>f.properties.level==='高') || pollutionData.features[0];
      // Remove only the baseline entry inside this isolated test browser, never a database row.
      oilAlerts.store.seen.delete(String(f.properties.event_id));await oilAlerts.receive(f);
      const r=oilAlerts.store.records.get(String(f.properties.event_id));
      return {status:r.event.candidateStatus,count:r.event.candidates.length,forecasts:r.event.forecasts.length,probabilities:r.event.candidates.map(v=>v.probability)};
    });
    assert.equal(actual.status,'ready');assert.equal(actual.forecasts,0);assert.ok(actual.probabilities.every(p=>p===null));
    if(actual.count){await page.locator('[data-alert-vessel]').first().click();await page.waitForFunction(()=>oilAlerts.mapController.selected?.trackWindow);}
    ok('actual PostGIS candidate/track APIs work without inventing forecasts or probabilities');
    await page.evaluate(async()=>{await oilAlerts.receive({id:'MISSING-BACKEND-EVENT',detectedAt:new Date().toISOString(),risk:'high',geometry:{type:'Point',coordinates:[56.65,26.35]}});});
    assert.match(await page.locator('#oilAlertVessels').innerText(),/暂不可用/);ok('candidate API failure shows an explicit unavailable state');
    const launchContext=await browser.newContext({viewport:{width:1366,height:768}});
    const launchPage=await launchContext.newPage();launchPage.on('pageerror',err=>errors.push(err.message));
    await launchPage.goto(`${base}?devAlerts=1&demoAlert=1`,{waitUntil:'domcontentloaded'});
    await launchPage.waitForFunction(()=>window.oilAlerts?.view.visible && oilAlerts.store.records.size===1);
    assert.equal(await launchPage.evaluate(()=>oilAlerts.mapController.active.candidates.length),3);
    await launchPage.reload({waitUntil:'domcontentloaded'});await launchPage.waitForFunction(()=>!!window.oilAlerts);
    assert.equal(await launchPage.evaluate(()=>oilAlerts.store.records.size),1);
    assert.equal(await launchPage.evaluate(()=>oilAlerts.view.visible),false);
    await launchContext.close();ok('original launcher URL auto-opens one demonstration; reload never generates another');
    assert.deepEqual(errors,[]);ok('no browser JavaScript errors');
    console.log(JSON.stringify({checks:checks.length,screenshot:path.join(os.tmpdir(),'auto-alert-acceptance.png')}));
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
