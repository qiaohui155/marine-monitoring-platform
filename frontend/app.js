const API_BASE = 'http://127.0.0.1:8000';
const AUTO_REFRESH_MS = 15000;
const VESSEL_ANIMATION_MS = 12000;
const VESSEL_ANIMATION_FRAME_MS = 100;
const HOME = { center: [58.55, 23.95], zoom: 5.25 };
const TYPE_COLORS = {
  Cargo: '#e15d65',
  Tanker: '#16a3c1',
  Fishing: '#7759c7',
  Passenger: '#2aa56e',
  Other: '#7c8e9a'
};

let map;
let vesselData = { type: 'FeatureCollection', features: [] };
let displayedVesselData = { type: 'FeatureCollection', features: [] };
let trackData = { type: 'FeatureCollection', features: [] };
let pollutionData = { type: 'FeatureCollection', features: [] };
let riskData = { type: 'FeatureCollection', features: [] };
let suspiciousData = { type: 'FeatureCollection', features: [] };
let warningData = { type: 'FeatureCollection', features: [] };
let labelsVisible = true;
let selectedFeatureId = null;
let selectedMmsi = null;
let refreshTimer = null;
let vesselRefreshRunning = false;
let operationalRefreshRunning = false;
let vesselAnimationFrame = null;
let vesselAnimationGeneration = 0;

const LAYER_GROUPS = {
  vessels: ['vessel-selection', 'vessels', 'vessel-labels'],
  tracks: ['track-lines'],
  pollution: ['pollution-fills', 'pollution-outlines'],
  risk: ['risk-fills', 'risk-outlines'],
  suspicious: ['suspicious-ships'],
  warnings: ['warning-fills', 'warning-outlines']
};

const $ = selector => document.querySelector(selector);
const loadingScreen = $('#loadingScreen');
const connectionPill = $('#connectionPill');
const detailPanel = $('#detailPanel');

function rasterStyle() {
  return {
    version: 8,
    sources: {
      osm: {
        type: 'raster',
        tiles: ['https://tile.openstreetmap.org/{z}/{x}/{y}.png'],
        tileSize: 256,
        attribution: '© OpenStreetMap contributors'
      }
    },
    layers: [{ id: 'osm', type: 'raster', source: 'osm', minzoom: 0, maxzoom: 19 }]
  };
}

function createShipImage(color) {
  const canvas = document.createElement('canvas');
  canvas.width = 64;
  canvas.height = 64;
  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, 64, 64);
  ctx.translate(32, 32);
  ctx.beginPath();
  ctx.moveTo(0, -26);
  ctx.lineTo(17, 19);
  ctx.lineTo(0, 12);
  ctx.lineTo(-17, 19);
  ctx.closePath();
  ctx.fillStyle = color;
  ctx.fill();
  ctx.strokeStyle = '#ffffff';
  ctx.lineWidth = 4;
  ctx.stroke();
  ctx.beginPath();
  ctx.moveTo(0, -15);
  ctx.lineTo(0, 10);
  ctx.strokeStyle = 'rgba(16,54,75,.45)';
  ctx.lineWidth = 2;
  ctx.stroke();
  return ctx.getImageData(0, 0, 64, 64);
}

function registerShipImages() {
  Object.entries(TYPE_COLORS).forEach(([type, color]) => {
    const id = `ship-${type.toLowerCase()}`;
    if (!map.hasImage(id)) map.addImage(id, createShipImage(color), { pixelRatio: 2 });
  });
}

function shipImageExpression() {
  return [
    'match', ['get', 'ship_type'],
    'Cargo', 'ship-cargo',
    'Tanker', 'ship-tanker',
    'Fishing', 'ship-fishing',
    'Passenger', 'ship-passenger',
    'ship-other'
  ];
}

function escapeHtml(value) {
  return String(value ?? '—')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function popupHtml(category, title, rows) {
  const details = rows
    .filter(([, value]) => value !== null && value !== undefined && value !== '')
    .map(([label, value]) => `<div><dt>${escapeHtml(label)}</dt><dd>${escapeHtml(value)}</dd></div>`)
    .join('');
  return `<section class="feature-popup"><small>${escapeHtml(category)}</small><strong>${escapeHtml(title)}</strong><dl>${details}</dl></section>`;
}

function bindLayerPopup(layerId, contentBuilder) {
  map.on('click', layerId, event => {
    const feature = event.features?.[0];
    if (!feature) return;
    new maplibregl.Popup({ closeButton: true, maxWidth: '290px' })
      .setLngLat(event.lngLat)
      .setHTML(contentBuilder(feature.properties))
      .addTo(map);
  });
  map.on('mouseenter', layerId, () => { map.getCanvas().style.cursor = 'pointer'; });
  map.on('mouseleave', layerId, () => { map.getCanvas().style.cursor = ''; });
}

function addOperationalLayers() {
  map.addSource('risk-areas', { type: 'geojson', data: riskData });
  map.addLayer({
    id: 'risk-fills',
    type: 'fill',
    source: 'risk-areas',
    layout: { visibility: 'none' },
    paint: {
      'fill-color': ['coalesce', ['get', 'fill_hex'], '#e4b64b'],
      'fill-opacity': .22
    }
  });
  map.addLayer({
    id: 'risk-outlines',
    type: 'line',
    source: 'risk-areas',
    layout: { visibility: 'none' },
    paint: { 'line-color': ['coalesce', ['get', 'fill_hex'], '#b57c22'], 'line-width': 1.2, 'line-opacity': .8 }
  });

  map.addSource('warnings', { type: 'geojson', data: warningData });
  map.addLayer({
    id: 'warning-fills',
    type: 'fill',
    source: 'warnings',
    layout: { visibility: 'none' },
    paint: { 'fill-color': '#f39c32', 'fill-opacity': .12 }
  });
  map.addLayer({
    id: 'warning-outlines',
    type: 'line',
    source: 'warnings',
    layout: { visibility: 'none' },
    paint: { 'line-color': '#e67e22', 'line-width': 2, 'line-dasharray': [2, 1.5] }
  });

  map.addSource('pollution', { type: 'geojson', data: pollutionData });
  map.addLayer({
    id: 'pollution-fills',
    type: 'fill',
    source: 'pollution',
    paint: {
      'fill-color': ['match', ['get', 'level'], '高', '#d94841', '中', '#ed7d32', '低', '#f1bd4b', '#d95c45'],
      'fill-opacity': .42
    }
  });
  map.addLayer({
    id: 'pollution-outlines',
    type: 'line',
    source: 'pollution',
    paint: { 'line-color': '#c93831', 'line-width': 2.2, 'line-opacity': .95 }
  });

  map.addSource('tracks', { type: 'geojson', data: trackData, promoteId: 'mmsi' });
  map.addLayer({
    id: 'track-lines',
    type: 'line',
    source: 'tracks',
    layout: { visibility: 'none', 'line-cap': 'round', 'line-join': 'round' },
    paint: {
      'line-color': ['match', ['get', 'ship_type'], 'Tanker', '#16a3c1', 'Cargo', '#e15d65', 'Fishing', '#7759c7', 'Passenger', '#2aa56e', '#237bad'],
      'line-width': ['interpolate', ['linear'], ['zoom'], 4, 1.1, 8, 2.1, 11, 3],
      'line-opacity': .82
    }
  });

  map.addSource('suspicious', { type: 'geojson', data: suspiciousData });
  map.addLayer({
    id: 'suspicious-ships',
    type: 'circle',
    source: 'suspicious',
    paint: {
      'circle-radius': ['interpolate', ['linear'], ['zoom'], 4, 5, 9, 9],
      'circle-color': ['match', ['get', 'risk_level'], '高', '#d73027', '中', '#f39c32', '#f1c84b'],
      'circle-stroke-color': '#ffffff',
      'circle-stroke-width': 2,
      'circle-opacity': .95
    }
  });

  bindLayerPopup('track-lines', p => popupHtml('Historical track', p.ship_name || p.mmsi, [
    ['MMSI', p.mmsi], ['Type', p.ship_type], ['Points', p.point_count], ['Distance', p.distance_nm ? `${p.distance_nm} NM` : null]
  ]));
  bindLayerPopup('pollution-fills', p => popupHtml('Pollution event', p.event_id, [
    ['Level', p.level], ['Status', p.status], ['Area', p.area_km2 ? `${p.area_km2} km²` : null], ['Detected', formatDate(p.event_time)]
  ]));
  bindLayerPopup('risk-fills', p => popupHtml('Risk area', p.area_name, [
    ['Risk level', p.risk_level], ['Coefficient', p.coefficient], ['Basis', p.basis]
  ]));
  bindLayerPopup('suspicious-ships', p => popupHtml('Suspected vessel', p.ship_name || p.mmsi, [
    ['MMSI', p.mmsi], ['Risk level', p.risk_level], ['Reason', p.reason]
  ]));
  bindLayerPopup('warning-fills', p => popupHtml('Warning area', p.warning_name, [
    ['Level', p.warning_level], ['Reason', p.reason], ['Issued', formatDate(p.warning_time)]
  ]));
}

function addVesselLayers() {
  map.addSource('vessels', { type: 'geojson', data: vesselData, promoteId: 'id' });
  map.addLayer({
    id: 'vessel-selection',
    type: 'circle',
    source: 'vessels',
    paint: {
      'circle-radius': ['interpolate', ['linear'], ['zoom'], 4, 8, 9, 14],
      'circle-color': '#ffffff',
      'circle-opacity': ['case', ['boolean', ['feature-state', 'selected'], false], .9, 0],
      'circle-stroke-color': '#126c9d',
      'circle-stroke-width': ['case', ['boolean', ['feature-state', 'selected'], false], 3, 0]
    }
  });
  map.addLayer({
    id: 'vessels',
    type: 'symbol',
    source: 'vessels',
    layout: {
      'icon-image': shipImageExpression(),
      'icon-size': ['interpolate', ['linear'], ['zoom'], 4, .42, 7, .56, 10, .74],
      'icon-rotate': ['coalesce', ['to-number', ['get', 'course']], 0],
      'icon-rotation-alignment': 'map',
      'icon-allow-overlap': true,
      'icon-ignore-placement': true
    }
  });
  map.addLayer({
    id: 'vessel-labels',
    type: 'symbol',
    source: 'vessels',
    minzoom: 7.2,
    layout: {
      'text-field': ['coalesce', ['get', 'ship_name'], ['get', 'mmsi']],
      'text-font': ['Open Sans Semibold'],
      'text-size': 10,
      'text-offset': [0, 1.55],
      'text-anchor': 'top',
      'text-optional': true
    },
    paint: {
      'text-color': '#183d55',
      'text-halo-color': 'rgba(255,255,255,.95)',
      'text-halo-width': 1.5
    }
  });

  map.on('click', 'vessels', event => {
    const feature = event.features?.[0];
    if (feature) selectVessel(feature);
  });
  map.on('mouseenter', 'vessels', () => { map.getCanvas().style.cursor = 'pointer'; });
  map.on('mouseleave', 'vessels', () => { map.getCanvas().style.cursor = ''; });
}

function setConnection(status, label) {
  connectionPill.className = `connection-pill ${status}`;
  connectionPill.querySelector('span').textContent = label;
}

function showMessage(message) {
  const el = $('#mapMessage');
  el.textContent = message;
  el.classList.add('visible');
  clearTimeout(showMessage.timer);
  showMessage.timer = setTimeout(() => el.classList.remove('visible'), 2200);
}

function formatDate(value) {
  if (!value) return 'No timestamp';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString('en-GB', { month:'short', day:'2-digit', hour:'2-digit', minute:'2-digit' });
}

function updateSummary(data) {
  $('#totalShips').textContent = data.count.toLocaleString();
  $('#apiCount').textContent = `API records: ${data.count.toLocaleString()}`;
  const counts = { Cargo:0, Tanker:0, Fishing:0, Passenger:0 };
  let latest = null;
  data.features.forEach(feature => {
    const type = feature.properties.ship_type;
    if (type in counts) counts[type]++;
    const value = feature.properties.update_time;
    if (value && (!latest || value > latest)) latest = value;
  });
  Object.entries(counts).forEach(([type, count]) => {
    $(`#count${type}`).textContent = count.toLocaleString();
  });
  $('#latestUpdate').textContent = latest ? formatDate(latest) : 'Not available';
}

function updateRefreshStatus(message) {
  const status = $('#refreshStatus');
  if (status) status.textContent = message;
}

function vesselKey(feature) {
  return String(feature.properties?.mmsi ?? feature.id ?? feature.properties?.id ?? '');
}

function cloneVesselCollection(data) {
  return {
    type: 'FeatureCollection',
    features: data.features.map(feature => ({
      ...feature,
      geometry: {
        ...feature.geometry,
        coordinates: [...feature.geometry.coordinates]
      },
      properties: { ...feature.properties }
    }))
  };
}

function interpolateCourse(fromValue, toValue, progress) {
  const from = Number(fromValue);
  const to = Number(toValue);
  if (!Number.isFinite(from) || !Number.isFinite(to)) return toValue;
  const shortestTurn = ((to - from + 540) % 360) - 180;
  return (from + shortestTurn * progress + 360) % 360;
}

function displayVessels(nextData, { initial = false } = {}) {
  const source = map.getSource('vessels');
  if (!source) return;

  vesselAnimationGeneration += 1;
  const generation = vesselAnimationGeneration;
  if (vesselAnimationFrame !== null) {
    cancelAnimationFrame(vesselAnimationFrame);
    vesselAnimationFrame = null;
  }

  if (initial || displayedVesselData.features.length === 0) {
    displayedVesselData = cloneVesselCollection(nextData);
    source.setData(displayedVesselData);
    return;
  }

  const previousByKey = new Map(
    displayedVesselData.features.map(feature => [vesselKey(feature), feature])
  );
  const animated = cloneVesselCollection(nextData);
  const transitions = [];

  animated.features.forEach(feature => {
    const previous = previousByKey.get(vesselKey(feature));
    if (!previous) return;
    const from = previous.geometry.coordinates.map(Number);
    const to = feature.geometry.coordinates.map(Number);
    if (![...from, ...to].every(Number.isFinite)) return;

    const longitudeDelta = to[0] - from[0];
    const latitudeDelta = to[1] - from[1];
    const plausibleStep = Math.hypot(longitudeDelta, latitudeDelta) <= 0.08;
    if (!plausibleStep) return;

    const targetCourse = feature.properties.course;
    feature.geometry.coordinates = [...from];
    feature.properties.course = previous.properties?.course ?? feature.properties.course;
    transitions.push({
      feature,
      from,
      to,
      fromCourse: previous.properties?.course,
      toCourse: targetCourse
    });
  });

  if (transitions.length === 0) {
    displayedVesselData = cloneVesselCollection(nextData);
    source.setData(displayedVesselData);
    return;
  }

  displayedVesselData = animated;
  source.setData(displayedVesselData);
  const startedAt = performance.now();
  let lastPaintAt = 0;

  const animate = now => {
    if (generation !== vesselAnimationGeneration) return;
    const progress = Math.min(1, (now - startedAt) / VESSEL_ANIMATION_MS);

    if (progress >= 1 || now - lastPaintAt >= VESSEL_ANIMATION_FRAME_MS) {
      transitions.forEach(transition => {
        transition.feature.geometry.coordinates[0] =
          transition.from[0] + (transition.to[0] - transition.from[0]) * progress;
        transition.feature.geometry.coordinates[1] =
          transition.from[1] + (transition.to[1] - transition.from[1]) * progress;
        transition.feature.properties.course = interpolateCourse(
          transition.fromCourse,
          transition.toCourse,
          progress
        );
      });
      source.setData(displayedVesselData);
      lastPaintAt = now;
    }

    if (progress < 1) {
      vesselAnimationFrame = requestAnimationFrame(animate);
    } else {
      displayedVesselData = cloneVesselCollection(nextData);
      source.setData(displayedVesselData);
      vesselAnimationFrame = null;
    }
  };

  vesselAnimationFrame = requestAnimationFrame(animate);
}

function refreshSelectedVessel() {
  if (selectedFeatureId === null) return;
  const selected = vesselData.features.find(feature => {
    const featureId = feature.id ?? feature.properties.id;
    return String(featureId) === String(selectedFeatureId);
  });
  if (selected) {
    selectVessel(selected);
  } else {
    selectedFeatureId = null;
    detailPanel.classList.remove('visible');
  }
}

async function loadVessels({ initial = false } = {}) {
  if (vesselRefreshRunning) return;
  vesselRefreshRunning = true;
  try {
    const response = await fetch(`${API_BASE}/api/ships?limit=5000`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`API returned ${response.status}`);
    vesselData = await response.json();
    displayVessels(vesselData, { initial });
    updateSummary(vesselData);
    applyTypeFilter();
    refreshSelectedVessel();
    setConnection('connected', 'Live · 15 s');
    updateRefreshStatus(`Last refresh: ${new Date().toLocaleTimeString()} · every 15 s`);
    loadingScreen.classList.add('hidden');
  } catch (error) {
    setConnection('failed', 'API Offline');
    updateRefreshStatus(`Refresh failed: ${new Date().toLocaleTimeString()}`);
    if (initial) {
      loadingScreen.querySelector('strong').textContent = 'Unable to load vessel data';
      loadingScreen.querySelector('span').textContent = error.message;
    } else {
      showMessage('Automatic refresh failed · showing the last successful data');
    }
    console.error(error);
  } finally {
    vesselRefreshRunning = false;
  }
}

async function fetchGeoJson(path) {
  const response = await fetch(`${API_BASE}${path}`, { cache: 'no-store' });
  if (!response.ok) throw new Error(`${path} returned ${response.status}`);
  return response.json();
}

async function loadOperationalLayers({ initial = false } = {}) {
  if (operationalRefreshRunning) return;
  operationalRefreshRunning = true;
  try {
    [trackData, pollutionData, riskData, suspiciousData, warningData] = await Promise.all([
      fetchGeoJson('/api/tracks?limit=1000'),
      fetchGeoJson('/api/pollution-events?limit=1000'),
      fetchGeoJson('/api/risk-areas?limit=1000'),
      fetchGeoJson('/api/suspicious-ships?limit=1000'),
      fetchGeoJson('/api/warnings?limit=1000')
    ]);
    map.getSource('tracks').setData(trackData);
    map.getSource('pollution').setData(pollutionData);
    map.getSource('risk-areas').setData(riskData);
    map.getSource('suspicious').setData(suspiciousData);
    map.getSource('warnings').setData(warningData);
  } catch (error) {
    if (!initial) showMessage('One or more operational layers could not be refreshed');
    console.error(error);
  } finally {
    operationalRefreshRunning = false;
  }
}

async function loadDashboard() {
  try {
    const response = await fetch(`${API_BASE}/api/dashboard/summary`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`Dashboard returned ${response.status}`);
    const summary = await response.json();
    $('#statTrackVessels').textContent = Number(summary.tracks.vessels).toLocaleString();
    $('#statPollutionEvents').textContent = Number(summary.pollution_events.total).toLocaleString();
    $('#statSuspiciousShips').textContent = Number(summary.suspicious_ships.total).toLocaleString();
    $('#statWarnings').textContent = Number(summary.warnings.total).toLocaleString();
  } catch (error) {
    console.error(error);
  }
}

async function refreshPlatformData({ initial = false } = {}) {
  await Promise.allSettled([
    loadVessels({ initial }),
    loadOperationalLayers({ initial }),
    loadDashboard()
  ]);
}

function startAutoRefresh() {
  if (refreshTimer !== null) clearInterval(refreshTimer);
  refreshTimer = setInterval(() => {
    if (!document.hidden) refreshPlatformData();
  }, AUTO_REFRESH_MS);
}

function selectedTypes() {
  return [...document.querySelectorAll('.type-filters input:checked')].map(input => input.value);
}

function applyTypeFilter() {
  const types = selectedTypes();
  const filter = types.length ? ['in', ['get', 'ship_type'], ['literal', types]] : ['==', 1, 0];
  ['vessel-selection', 'vessels', 'vessel-labels'].forEach(id => map.setFilter(id, filter));
  const visible = vesselData.features.filter(feature => types.includes(feature.properties.ship_type)).length;
  $('#totalShips').textContent = visible.toLocaleString();
}

function setText(selector, value) {
  $(selector).textContent = value ?? '—';
}

function selectVessel(feature) {
  if (selectedFeatureId !== null) map.setFeatureState({ source:'vessels', id:selectedFeatureId }, { selected:false });
  selectedFeatureId = feature.id ?? feature.properties.id;
  map.setFeatureState({ source:'vessels', id:selectedFeatureId }, { selected:true });
  const p = feature.properties;
  selectedMmsi = p.mmsi || null;
  const [lng, lat] = feature.geometry.coordinates;
  setText('#detailName', p.ship_name || 'Unnamed vessel');
  setText('#detailIdentity', `${p.ship_type || 'Unknown type'} · ${p.mmsi || 'No MMSI'}`);
  setText('#detailTime', formatDate(p.update_time));
  setText('#detailSpeed', p.speed == null ? '—' : `${Number(p.speed).toFixed(1)} kn`);
  setText('#detailCourse', p.course == null ? '—' : `${Math.round(Number(p.course))}°`);
  setText('#detailLatitude', `${Number(lat).toFixed(5)}° N`);
  setText('#detailLongitude', `${Number(lng).toFixed(5)}° E`);
  setText('#detailType', p.ship_type);
  setText('#detailMmsi', p.mmsi);
  setText('#detailId', p.id);
  const color = TYPE_COLORS[p.ship_type] || TYPE_COLORS.Other;
  $('#detailShipIcon').style.color = color;
  detailPanel.classList.add('visible');
}

async function searchVessel(query) {
  const response = await fetch(`${API_BASE}/api/ships?search=${encodeURIComponent(query)}&limit=20`);
  if (!response.ok) throw new Error('Search failed');
  const result = await response.json();
  if (!result.features.length) return showMessage('No matching vessel found');
  const feature = result.features[0];
  map.flyTo({ center:feature.geometry.coordinates, zoom:9, speed:1.2 });
  selectVessel(feature);
  showMessage(`${result.count} matching vessel${result.count === 1 ? '' : 's'}`);
}

function setLayerGroupVisibility(group, visible) {
  const visibility = visible ? 'visible' : 'none';
  (LAYER_GROUPS[group] || []).forEach(id => {
    if (map.getLayer(id)) map.setLayoutProperty(id, 'visibility', visibility);
  });
}

function setLayerToggle(toggleId, group, visible) {
  const toggle = $(toggleId);
  if (toggle) toggle.checked = visible;
  setLayerGroupVisibility(group, visible);
}

function activateView(view) {
  document.querySelectorAll('.nav-tab[data-view]').forEach(tab => {
    tab.classList.toggle('active', tab.dataset.view === view);
  });
  if (view === 'vessels') {
    setLayerToggle('#vesselLayerToggle', 'vessels', true);
    setLayerToggle('#trackLayerToggle', 'tracks', false);
    setLayerToggle('#pollutionLayerToggle', 'pollution', false);
    setLayerToggle('#riskLayerToggle', 'risk', false);
    setLayerToggle('#suspiciousLayerToggle', 'suspicious', false);
    setLayerToggle('#warningLayerToggle', 'warnings', false);
  } else if (view === 'tracks') {
    map.setFilter('track-lines', null);
    setLayerToggle('#vesselLayerToggle', 'vessels', true);
    setLayerToggle('#trackLayerToggle', 'tracks', true);
    setLayerToggle('#pollutionLayerToggle', 'pollution', false);
    setLayerToggle('#riskLayerToggle', 'risk', false);
    setLayerToggle('#suspiciousLayerToggle', 'suspicious', false);
    setLayerToggle('#warningLayerToggle', 'warnings', false);
  } else if (view === 'pollution') {
    setLayerToggle('#vesselLayerToggle', 'vessels', true);
    setLayerToggle('#trackLayerToggle', 'tracks', false);
    setLayerToggle('#pollutionLayerToggle', 'pollution', true);
    setLayerToggle('#riskLayerToggle', 'risk', true);
    setLayerToggle('#suspiciousLayerToggle', 'suspicious', true);
    setLayerToggle('#warningLayerToggle', 'warnings', true);
  }
}

function showSelectedTrack() {
  if (!selectedMmsi) return showMessage('Select a vessel first');
  const track = trackData.features.find(feature => String(feature.properties.mmsi) === String(selectedMmsi));
  if (!track) return showMessage('No historical track is available for this vessel');

  document.querySelectorAll('.nav-tab[data-view]').forEach(tab => {
    tab.classList.toggle('active', tab.dataset.view === 'tracks');
  });
  setLayerToggle('#trackLayerToggle', 'tracks', true);
  map.setFilter('track-lines', ['==', ['get', 'mmsi'], selectedMmsi]);
  const bounds = new maplibregl.LngLatBounds();
  track.geometry.coordinates.forEach(coordinate => bounds.extend(coordinate));
  map.fitBounds(bounds, { padding: 80, maxZoom: 9, duration: 900 });
  showMessage(`Showing historical track for ${track.properties.ship_name || selectedMmsi}`);
}

function bindControls() {
  $('#homeMap').addEventListener('click', () => map.flyTo({ ...HOME, speed:1.1 }));
  $('#zoomIn').addEventListener('click', () => map.zoomIn());
  $('#zoomOut').addEventListener('click', () => map.zoomOut());
  $('#toggleLabels').addEventListener('click', event => {
    labelsVisible = !labelsVisible;
    map.setLayoutProperty('vessel-labels', 'visibility', labelsVisible ? 'visible' : 'none');
    event.currentTarget.classList.toggle('active', labelsVisible);
  });
  document.querySelectorAll('.type-filters input').forEach(input => input.addEventListener('change', applyTypeFilter));
  $('#resetFilters').addEventListener('click', () => {
    document.querySelectorAll('.type-filters input').forEach(input => { input.checked = true; });
    applyTypeFilter();
  });
  $('#vesselLayerToggle').addEventListener('change', event => {
    setLayerGroupVisibility('vessels', event.currentTarget.checked);
  });
  $('#trackLayerToggle').addEventListener('change', event => {
    if (event.currentTarget.checked) map.setFilter('track-lines', null);
    setLayerGroupVisibility('tracks', event.currentTarget.checked);
  });
  $('#pollutionLayerToggle').addEventListener('change', event => setLayerGroupVisibility('pollution', event.currentTarget.checked));
  $('#riskLayerToggle').addEventListener('change', event => setLayerGroupVisibility('risk', event.currentTarget.checked));
  $('#suspiciousLayerToggle').addEventListener('change', event => setLayerGroupVisibility('suspicious', event.currentTarget.checked));
  $('#warningLayerToggle').addEventListener('change', event => setLayerGroupVisibility('warnings', event.currentTarget.checked));
  document.querySelectorAll('.nav-tab[data-view]').forEach(tab => {
    tab.addEventListener('click', () => activateView(tab.dataset.view));
  });
  $('#collapseControl').addEventListener('click', () => {
    $('.control-panel').classList.add('collapsed');
    $('#openControl').classList.add('visible');
  });
  $('#openControl').addEventListener('click', () => {
    $('.control-panel').classList.remove('collapsed');
    $('#openControl').classList.remove('visible');
  });
  $('#detailClose').addEventListener('click', () => detailPanel.classList.remove('visible'));
  $('#showTrackButton').addEventListener('click', showSelectedTrack);
  $('#searchForm').addEventListener('submit', event => {
    event.preventDefault();
    const query = $('#shipSearch').value.trim();
    if (query) searchVessel(query).catch(error => showMessage(error.message));
  });
}

function initMap() {
  map = new maplibregl.Map({
    container: 'map',
    style: rasterStyle(),
    center: HOME.center,
    zoom: HOME.zoom,
    minZoom: 3.5,
    maxZoom: 15,
    attributionControl: true
  });
  map.addControl(new maplibregl.NavigationControl({ showCompass:true }), 'top-right');
  map.addControl(new maplibregl.ScaleControl({ maxWidth:120, unit:'nautical' }), 'bottom-right');
  map.on('mousemove', event => {
    $('#mouseCoordinates').textContent = `${event.lngLat.lat.toFixed(4)}° N, ${event.lngLat.lng.toFixed(4)}° E`;
  });
  map.on('load', async () => {
    registerShipImages();
    addOperationalLayers();
    addVesselLayers();
    bindControls();
    await refreshPlatformData({ initial: true });
    startAutoRefresh();
  });
}

document.addEventListener('visibilitychange', () => {
  if (!document.hidden && map?.loaded()) refreshPlatformData();
});

window.addEventListener('beforeunload', () => {
  if (refreshTimer !== null) clearInterval(refreshTimer);
  if (vesselAnimationFrame !== null) cancelAnimationFrame(vesselAnimationFrame);
});

initMap();
