const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const appSource = readFileSync(resolve(__dirname, '../app.js'), 'utf8');
const html = readFileSync(resolve(__dirname, '../index.html'), 'utf8');

function harness() {
  const layers = new Map();
  const sources = new Map();
  const handlers = [];
  const flights = [];
  const elements = new Map();
  const markers = [];
  let hiddenPanels = 0;
  const context = vm.createContext({
    console, URLSearchParams,
    hidePanels: () => { hiddenPanels += 1; },
    maplibregl: {
      Popup: class {
        setHTML(html) { this.html = html; return this; }
        remove() { this.removed = true; }
      },
      Marker: class {
        constructor(options = {}) { this.element = options.element || {}; markers.push(this); }
        setLngLat(coordinates) { this.coordinates = coordinates; return this; }
        setPopup(popup) { this.popup = popup; return this; }
        addTo() { return this; }
        getPopup() { return this.popup; }
        getElement() { return this.element; }
        remove() { this.removed = true; }
      },
      LngLatBounds: class {
        constructor() { this.points = []; }
        extend(point) { this.points.push(point); return this; }
      }
    },
    window: { location: { search: '' }, addEventListener() {} },
    document: {
      createElement: () => ({}),
      addEventListener() {},
      querySelectorAll: () => [],
      querySelector(selector) {
        if (!elements.has(selector)) elements.set(selector, {
          checked: false,
          listeners: {},
          addEventListener(type, listener) { this.listeners[type] = listener; }
        });
        return elements.get(selector);
      }
    },
    mapMock: {
      addSource(id, source) {
        sources.set(id, { ...source, setData(data) { this.data = data; } });
      },
      addLayer(layer) { layers.set(layer.id, layer); },
      on(event, layer) { handlers.push([event, layer]); },
      getLayer: id => layers.get(id),
      getSource: id => sources.get(id),
      getLayoutProperty: (id, property) => layers.get(id)?.layout?.[property],
      setLayoutProperty(id, name, value) {
        const layer = layers.get(id);
        layer.layout ||= {};
        layer.layout[name] = value;
      },
      getZoom: () => 8,
      getMaxZoom: () => 15,
      stop() {},
      resize() {},
      flyTo(options) { flights.push(options); },
      fitBounds(bounds, options) { flights.push({ bounds, ...options }); }
    }
  });
  const boot = /\nstartClock\(\);\s*initMap\(\);\s*$/;
  assert.match(appSource, boot);
  vm.runInContext(appSource.replace(boot, '\n'), context);
  vm.runInContext(`
    map = mapMock;
    syncSelectedSuspectMarker = () => {};
    setOperationalWatchContent = () => {};
    updateTrackSelectionStatus = () => {};
    showMessage = () => {};
    floatingPanelManager = { hideAll: hidePanels };
    addOperationalLayers();
  `, context);
  return { context, layers, sources, handlers, flights, markers, elements, hiddenPanels: () => hiddenPanels };
}

test('only pollution areas, tracks and selected suspects are created', () => {
  const { sources, layers, handlers } = harness();
  assert.deepEqual([...sources.keys()], ['pollution', 'tracks', 'suspicious']);
  assert.deepEqual([...layers.keys()], [
    'pollution-fills', 'pollution-outlines', 'track-halo', 'track-lines', 'suspicious-ships'
  ]);
  assert.ok(handlers.every(([, layer]) => !/^(risk|warning)-/.test(layer)));
});

test('view switching and record location never restore removed areas', () => {
  const { context, layers, sources, flights } = harness();
  vm.runInContext(`
    activateView('vessels');
    activateView('tracks');
    activateView('pollution');
    locateFeature({ geometry: { type: 'Point', coordinates: [56.5, 26.1] } }, 'Located');
  `, context);
  assert.equal(layers.get('pollution-fills').layout.visibility, 'visible');
  assert.equal(flights.length, 1);
  assert.equal(flights[0].zoom, 12);
  assert.equal(flights[0].padding, 0);
  assert.equal(sources.size, 3);
  assert.equal(layers.size, 5);
});

test('automatic refresh retains warning records without drawing their areas', async () => {
  const { context, sources, layers } = harness();
  const paths = [];
  context.testFetch = async path => {
    paths.push(path);
    return path.includes('/catalog') ? { items: [{ mmsi: '470003707' }] }
      : { type: 'FeatureCollection', features: [{ properties: { test: path } }] };
  };
  vm.runInContext('fetchGeoJson = testFetch; mapLayersReady = true;', context);
  await vm.runInContext('loadOperationalLayers({ initial: true })', context);
  await vm.runInContext('loadOperationalLayers()', context);
  assert.ok(paths.some(path => path.startsWith('/api/pollution-events')));
  assert.ok(paths.some(path => path.startsWith('/api/warnings')));
  assert.ok(paths.every(path => !path.startsWith('/api/risk-areas')));
  assert.equal(sources.get('pollution').data.features.length, 1);
  assert.equal(vm.runInContext('warningData.features.length', context), 1);
  assert.equal(sources.size, 3);
  assert.equal(layers.size, 5);
});

test('removed controls have no remaining bindings; pollution control stays', () => {
  assert.doesNotMatch(html + appSource, /riskLayerToggle|warningLayerToggle/);
  assert.match(html, /id="pollutionLayerToggle"/);
  assert.match(html, /app\.js\?v=20260903-auto-alerts/);
});

test('the alert LOCATE button centers its polygon, closes the panel and replaces the pin', () => {
  const { context, elements, flights, markers, layers, hiddenPanels } = harness();
  vm.runInContext(`
    warningData.features = [
      { id: 5, properties: { warning_name: 'MS-005' }, geometry: {
        type: 'Polygon', coordinates: [[[56.4, 26], [56.6, 26], [56.6, 26.2], [56.4, 26.2], [56.4, 26]]]
      } },
      { properties: { id: 4, warning_name: 'MS-004' }, geometry: {
        type: 'Point', coordinates: [56.8, 26.3]
      } }
    ];
    bindControls();
  `, context);
  const locate = elements.get('#alertRecordList').listeners.click;
  const click = id => locate({ target: { closest: () => ({ dataset: { warningId: id } }) } });
  click('5');
  assert.ok(Math.abs(flights[0].center[0] - 56.5) < 1e-9);
  assert.ok(Math.abs(flights[0].center[1] - 26.1) < 1e-9);
  assert.equal(flights[0].zoom, 12);
  assert.match(markers[0].getElement().title, /MS-005/);
  assert.match(markers[0].getPopup().html, /56\.500000/);
  context.mapMock.getZoom = () => 14;
  click('4');
  assert.equal(flights[1].zoom, 14);
  assert.equal(flights[1].center[0], 56.8);
  assert.equal(markers[0].removed, true);
  assert.equal(markers[0].getPopup().removed, true);
  assert.equal(markers.filter(marker => !marker.removed).length, 1);
  assert.equal(hiddenPanels(), 2);
  assert.equal(layers.size, 5);
  click('not-found');
  assert.equal(flights.length, 2);
});

test('returning home clears the temporary location pin', () => {
  const { context, elements, markers } = harness();
  vm.runInContext(`
    bindControls();
    locateFeature({ geometry: { type: 'Point', coordinates: [56.5, 26.1] } }, 'Located');
  `, context);
  elements.get('#homeMap').listeners.click();
  assert.equal(markers[0].removed, true);
  assert.equal(vm.runInContext('locatedFeatureMarker', context), null);
});

test('candidate passage stays identified and time-bounded across automatic refresh', async () => {
  const { context, layers, markers, elements } = harness();
  const paths = [];
  context.testFetch = async path => {
    paths.push(path);
    return path.includes('/catalog') ? { items: [] } : { type: 'FeatureCollection', features: [] };
  };
  vm.runInContext(`
    fetchGeoJson = testFetch;
    mapLayersReady = true;
    var evidence = {
      eventId: 'MS-003', eventTime: '2026-08-31T14:00:00', mmsi: '470000789',
      ship_name: 'TANKER-0789', minutes_before_event: 10,
      start_time: '2026-08-31T13:48:00', end_time: '2026-08-31T13:53:00',
      match_time: '2026-08-31T13:50:00', point_count: 2, track_distance_nm: 0.3,
      evidence_geometry: { type: 'LineString', coordinates: [[56.4,26.1],[56.5,26.2]] }
    };
  `, context);
  await vm.runInContext("displaySingleTrack('470000789', { evidence })", context);
  assert.equal(layers.get('track-lines').paint['line-color'], '#9f1239');
  assert.match(markers.at(-1).element.innerHTML, /TANKER-0789/);
  assert.match(markers.at(-1).element.innerHTML, /470000789/);
  assert.match(markers.at(-1).element.title, /Historical segment end/);
  assert.equal(elements.get('#selectedTrackInfo').hidden, false);
  assert.match(elements.get('#selectedTrackBasis').textContent, /10.0 min before event/);
  await vm.runInContext('loadOperationalLayers()', context);
  assert.ok(paths.every(path => !path.startsWith('/api/tracks?')));
  assert.equal(vm.runInContext('trackData.features[0].properties.end_time', context), '2026-08-31T13:53:00');
  vm.runInContext('clearTrackSelection({ notify: false })', context);
  assert.equal(markers.at(-1).removed, true);
  assert.equal(elements.get('#selectedTrackInfo').hidden, true);
});

test('screening sends lookback hours and displays passage time', async () => {
  const { context, elements } = harness();
  const paths = [];
  context.testFetch = async path => {
    paths.push(path);
    return { event_time: '2026-08-31T14:00:00', items: [{
      mmsi: '123', ship_name: 'TEST', match_type: 'INTERSECTS',
      start_time: '2026-08-31T13:40:00', end_time: '2026-08-31T13:50:00',
      match_time: '2026-08-31T13:45:00', minutes_before_event: 15
    }] };
  };
  vm.runInContext('fetchGeoJson = testFetch;', context);
  await vm.runInContext("loadSourceCandidates('MS-003', 5, 6)", context);
  assert.match(paths[0], /lookback_hours=6/);
  assert.equal(vm.runInContext('sourceCandidateContext.lookbackHours', context), 6);
  assert.match(elements.get('#sourceCandidateList').innerHTML, /15.0 min before event/);
  assert.match(elements.get('#sourceCandidateList').innerHTML, /13:45:00 UTC/);
});
