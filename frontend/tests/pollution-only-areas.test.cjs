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
        constructor() { this.element = {}; markers.push(this); }
        setLngLat(coordinates) { this.coordinates = coordinates; return this; }
        setPopup(popup) { this.popup = popup; return this; }
        addTo() { return this; }
        getPopup() { return this.popup; }
        getElement() { return this.element; }
        remove() { this.removed = true; }
      }
    },
    window: { location: { search: '' }, addEventListener() {} },
    document: {
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
      setLayoutProperty(id, name, value) {
        const layer = layers.get(id);
        layer.layout ||= {};
        layer.layout[name] = value;
      },
      getZoom: () => 8,
      getMaxZoom: () => 15,
      stop() {},
      resize() {},
      flyTo(options) { flights.push(options); }
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
    'pollution-fills', 'pollution-outlines', 'track-lines', 'suspicious-ships'
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
  assert.equal(layers.size, 4);
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
  assert.equal(layers.size, 4);
});

test('removed controls have no remaining bindings; pollution control stays', () => {
  assert.doesNotMatch(html + appSource, /riskLayerToggle|warningLayerToggle/);
  assert.match(html, /id="pollutionLayerToggle"/);
  assert.match(html, /app\.js\?v=20260902-alert-locate-focus/);
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
  assert.equal(layers.size, 4);
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
