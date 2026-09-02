const API_BASE = 'http://127.0.0.1:8000';
const AUTO_REFRESH_MS = 5000;
// PostgreSQL receives a new AIS position every five seconds. Interpolate most
// of that interval so successive coordinates appear as continuous movement.
const VESSEL_ANIMATION_MS = 4200;
const TRACK_CATALOG_REFRESH_MS = 30000;
const AIS_FRESHNESS_MS = 5 * 60 * 1000;
// Musandam Governorate and the adjacent Strait of Hormuz monitoring waters.
const HOME = { center: [56.45, 25.92], zoom: 7.15 };
const DETAILED_VESSEL_ZOOM = 9;
const MAP_CLICK_TOLERANCE_PX = 12;
const BASEMAP_LAYERS = {
  operations: ['osm'],
  street: ['osm-color'],
  satellite: ['satellite'],
  'satellite-hybrid': ['satellite', 'satellite-reference']
};

function automaticBasemapForZoom(zoom) {
  return Number(zoom) >= DETAILED_VESSEL_ZOOM ? 'satellite-hybrid' : 'street';
}
const TYPE_COLORS = {
  Overview: '#ffd84d',
  Cargo: '#e15d65',
  Tanker: '#16a3c1',
  Fishing: '#7759c7',
  Passenger: '#2aa56e',
  Other: '#7c8e9a'
};

let map;
let locatedFeatureMarker = null;
let vesselData = { type: 'FeatureCollection', features: [] };
let renderedVesselData = { type: 'FeatureCollection', features: [] };
let trackData = { type: 'FeatureCollection', features: [] };
let trackCatalogData = [];
let trackCatalogLoadedAt = 0;
let pollutionData = { type: 'FeatureCollection', features: [] };
let suspiciousData = { type: 'FeatureCollection', features: [] };
let warningData = { type: 'FeatureCollection', features: [] };
let recentPollutionEvents = [];
let labelsVisible = true;
let selectedFeatureId = null;
let selectedMmsi = null;
let selectedTrackMmsi = null;
let selectedTrackCenterTime = null;
let selectedTrackStartTime = null;
let selectedTrackEndTime = null;
let selectedTrackRequest = 0;
let sourceCandidateData = [];
let sourceCandidateEventId = null;
let sourceCandidateRadiusNm = null;
let sourceCandidateRequest = 0;
let refreshTimer = null;
let clockTimer = null;
let vesselRefreshRunning = false;
let operationalRefreshRunning = false;
let vesselAnimationFrame = null;
let mapLayersReady = false;
let mapLayersInitializing = false;
let controlsBound = false;
let floatingPanelManager = null;
const requestedBasemap = new URLSearchParams(window.location.search).get('basemap');
const hasRequestedBasemap = Boolean(requestedBasemap && BASEMAP_LAYERS[requestedBasemap]);
let basemapAutoMode = !hasRequestedBasemap;
let activeBasemap = hasRequestedBasemap ? requestedBasemap : automaticBasemapForZoom(HOME.zoom);

const LAYER_GROUPS = {
  vessels: ['vessel-selection', 'vessels-overview', 'vessels', 'vessel-labels'],
  tracks: ['track-lines'],
  pollution: ['pollution-fills', 'pollution-outlines'],
  suspicious: ['suspicious-ships']
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
      },
      satellite: {
        type: 'raster',
        tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
        tileSize: 256,
        attribution: 'Tiles © Esri, Maxar, Earthstar Geographics'
      },
      'satellite-reference': {
        type: 'raster',
        tiles: ['https://services.arcgisonline.com/ArcGIS/rest/services/Reference/World_Boundaries_and_Places/MapServer/tile/{z}/{y}/{x}'],
        tileSize: 256,
        attribution: 'Reference tiles © Esri'
      }
    },
    layers: [
      {
        id: 'osm',
        type: 'raster',
        source: 'osm',
        minzoom: 0,
        maxzoom: 19,
        layout: { visibility: activeBasemap === 'operations' ? 'visible' : 'none' },
        paint: {
          'raster-saturation': -1,
          'raster-contrast': .18,
          'raster-brightness-min': .03,
          'raster-brightness-max': .56
        }
      },
      {
        id: 'osm-color',
        type: 'raster',
        source: 'osm',
        minzoom: 0,
        maxzoom: 19,
        layout: { visibility: activeBasemap === 'street' ? 'visible' : 'none' },
        paint: {
          'raster-saturation': -.08,
          'raster-contrast': .05,
          'raster-brightness-max': .88
        }
      },
      {
        id: 'satellite',
        type: 'raster',
        source: 'satellite',
        minzoom: 0,
        maxzoom: 19,
        layout: { visibility: ['satellite', 'satellite-hybrid'].includes(activeBasemap) ? 'visible' : 'none' },
        paint: {
          'raster-saturation': -.15,
          'raster-contrast': .12,
          'raster-brightness-max': .78
        }
      },
      {
        id: 'satellite-reference',
        type: 'raster',
        source: 'satellite-reference',
        minzoom: 0,
        maxzoom: 19,
        layout: { visibility: activeBasemap === 'satellite-hybrid' ? 'visible' : 'none' },
        paint: { 'raster-opacity': .96 }
      }
    ]
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
  // 仅绘制油污业务区域；预警记录仍可供信息窗口使用，但不绘制预警/风险范围。
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
    filter: ['==', ['get', 'mmsi'], '__no_selected_suspect__'],
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
  bindLayerPopup('suspicious-ships', p => popupHtml('Suspected vessel', p.ship_name || p.mmsi, [
    ['MMSI', p.mmsi], ['Risk level', p.risk_level], ['Reason', p.reason], ['Map action', 'Displaying this vessel’s historical track']
  ]));
  map.on('click', 'suspicious-ships', event => {
    const mmsi = event.features?.[0]?.properties?.mmsi;
    if (!mmsi) return;
    displaySingleTrack(mmsi).catch(error => showMessage(error.message));
  });
}

function addVesselLayers() {
  map.addSource('vessels', { type: 'geojson', data: vesselData, promoteId: 'mmsi' });
  map.addLayer({
    id: 'vessel-selection',
    type: 'circle',
    source: 'vessels',
    minzoom: DETAILED_VESSEL_ZOOM,
    paint: {
      'circle-radius': ['interpolate', ['linear'], ['zoom'], 4, 8, 9, 14],
      'circle-color': '#ffffff',
      'circle-opacity': ['case', ['boolean', ['feature-state', 'selected'], false], .9, 0],
      'circle-stroke-color': '#126c9d',
      'circle-stroke-width': ['case', ['boolean', ['feature-state', 'selected'], false], 3, 0]
    }
  });
  map.addLayer({
    id: 'vessels-overview',
    type: 'symbol',
    source: 'vessels',
    maxzoom: DETAILED_VESSEL_ZOOM,
    layout: {
      'icon-image': 'ship-overview',
      'icon-size': ['interpolate', ['linear'], ['zoom'], 4, .30, 6, .38, 8.9, .52],
      'icon-rotate': ['coalesce', ['to-number', ['get', 'course']], 0],
      'icon-rotation-alignment': 'map',
      'icon-allow-overlap': true,
      'icon-ignore-placement': true
    }
  });
  map.addLayer({
    id: 'vessels',
    type: 'symbol',
    source: 'vessels',
    minzoom: DETAILED_VESSEL_ZOOM,
    layout: {
      'icon-image': shipImageExpression(),
      'icon-size': ['interpolate', ['linear'], ['zoom'], 9, .54, 12, .72],
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
    minzoom: 10.5,
    layout: {
      'text-field': ['coalesce', ['get', 'ship_name'], ['get', 'mmsi']],
      'text-font': ['Open Sans Semibold'],
      'text-size': 9,
      'text-offset': [0, 1.55],
      'text-anchor': 'top',
      'text-optional': true
    },
    paint: {
      'text-color': '#c8f8fa',
      'text-halo-color': 'rgba(2,18,29,.92)',
      'text-halo-width': 1.7
    }
  });

  ['vessels-overview', 'vessels'].forEach(layerId => {
    map.on('click', layerId, event => {
      const feature = event.features?.[0];
      if (feature) selectVessel(feature);
    });
    map.on('mouseenter', layerId, () => { map.getCanvas().style.cursor = 'pointer'; });
    map.on('mouseleave', layerId, () => { map.getCanvas().style.cursor = ''; });
  });

  map.on('click', event => {
    const vesselLayers = ['vessels-overview', 'vessels'].filter(layerId => map.getLayer(layerId));
    const vesselFeatures = vesselLayers.length
      ? map.queryRenderedFeatures(event.point, { layers: vesselLayers })
      : [];
    if (!vesselFeatures.length) clearSelectedVessel();
  });
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

async function fetchWithTimeout(url, options = {}, timeoutMs = 12000) {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } catch (error) {
    if (error.name === 'AbortError') throw new Error('API request timed out');
    throw error;
  } finally {
    clearTimeout(timeoutId);
  }
}

function numberValue(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function highRiskCount(counts = {}) {
  return Object.entries(counts).reduce((total, [label, value]) => {
    const normalized = String(label).toLowerCase();
    const isHigh = /高|一级|核心|high|critical|level\s*1|red/.test(normalized);
    return total + (isHigh ? numberValue(value) : 0);
  }, 0);
}

function isHighLevel(value) {
  return /高|一级|核心|high|critical|level\s*1|red/i.test(String(value || ''));
}

function featureCenter(feature) {
  const properties = feature?.properties || {};
  const propertyLng = Number(properties.center_longitude);
  const propertyLat = Number(properties.center_latitude);
  if (Number.isFinite(propertyLng) && Number.isFinite(propertyLat)) return [propertyLng, propertyLat];

  const geometry = feature?.geometry;
  if (!geometry) return null;
  if (geometry.type === 'Point' && geometry.coordinates?.length >= 2) {
    const point = geometry.coordinates.map(Number);
    return point.every(Number.isFinite) ? point.slice(0, 2) : null;
  }

  const points = [];
  const collect = coordinates => {
    if (!Array.isArray(coordinates)) return;
    if (coordinates.length >= 2 && Number.isFinite(Number(coordinates[0])) && Number.isFinite(Number(coordinates[1]))) {
      points.push([Number(coordinates[0]), Number(coordinates[1])]);
      return;
    }
    coordinates.forEach(collect);
  };
  collect(geometry.coordinates);
  if (!points.length) return null;
  const bounds = points.reduce((value, point) => ({
    west: Math.min(value.west, point[0]),
    east: Math.max(value.east, point[0]),
    south: Math.min(value.south, point[1]),
    north: Math.max(value.north, point[1])
  }), { west: Infinity, east: -Infinity, south: Infinity, north: -Infinity });
  return [(bounds.west + bounds.east) / 2, (bounds.south + bounds.north) / 2];
}

function distanceNm(first, second) {
  if (!first || !second) return Infinity;
  const radians = value => value * Math.PI / 180;
  const latitudeDelta = radians(second[1] - first[1]);
  const longitudeDelta = radians(second[0] - first[0]);
  const a = Math.sin(latitudeDelta / 2) ** 2
    + Math.cos(radians(first[1])) * Math.cos(radians(second[1])) * Math.sin(longitudeDelta / 2) ** 2;
  return 3440.065 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function pollutionFeatures() {
  return [...(pollutionData.features || [])].sort((a, b) => {
    return Date.parse(b.properties?.event_time || 0) - Date.parse(a.properties?.event_time || 0);
  });
}

function pollutionFeatureById(eventId) {
  return pollutionFeatures().find(feature => String(feature.properties?.event_id ?? feature.id) === String(eventId)) || null;
}

function syncEventSelect(selector) {
  const select = $(selector);
  if (!select) return null;
  const current = select.value;
  const events = pollutionFeatures();
  if (!events.length) {
    select.innerHTML = '<option value="">No event records available</option>';
    return null;
  }
  select.innerHTML = events.map(feature => {
    const properties = feature.properties || {};
    const id = properties.event_id ?? feature.id;
    return `<option value="${escapeHtml(id)}">${escapeHtml(id)} · ${escapeHtml(formatDate(properties.event_time))}</option>`;
  }).join('');
  if (events.some(feature => String(feature.properties?.event_id ?? feature.id) === current)) select.value = current;
  return pollutionFeatureById(select.value);
}

function nearbyVessels(feature, limit = 6) {
  const center = featureCenter(feature);
  if (!center) return [];
  const suspectedMmsi = new Set((suspiciousData.features || []).map(item => String(item.properties?.mmsi || '')));
  return (vesselData.features || []).map(vessel => ({
    vessel,
    distance: distanceNm(center, featureCenter(vessel)),
    suspected: suspectedMmsi.has(String(vessel.properties?.mmsi || ''))
  })).filter(item => Number.isFinite(item.distance)).sort((a, b) => a.distance - b.distance).slice(0, limit);
}

function renderSatelliteReadiness() {
  const events = pollutionFeatures();
  setText('#satelliteEventCount', events.length.toLocaleString());
  setText('#satelliteReadinessLabel', events.length ? `${events.length} mapped events` : 'Data readiness');
}

function renderSourceCandidateRows() {
  const container = $('#sourceCandidateList');
  if (!container) return;
  setText('#sourceCandidateCount', `${sourceCandidateData.length} candidates`);
  container.innerHTML = sourceCandidateData.length ? sourceCandidateData.map(item => {
    const crossed = item.match_type === 'INTERSECTS' || item.intersects_event === true;
    const start = formatDate(item.start_time);
    const end = formatDate(item.end_time);
    const distance = crossed ? 'Crossed area' : `${numberValue(item.distance_nm).toFixed(1)} NM`;
    return `<div class="candidate-row"><strong>${escapeHtml(item.ship_name || item.mmsi || 'Unknown vessel')}<small>MMSI ${escapeHtml(item.mmsi || '—')} · ${escapeHtml(start)} to ${escapeHtml(end)}</small></strong><span>${escapeHtml(item.ship_type || 'Other')}</span><span>${escapeHtml(distance)}</span><em class="${crossed ? 'priority' : ''}">${crossed ? 'Track intersects' : 'Track nearby'}</em><button type="button" data-source-track-mmsi="${escapeHtml(item.mmsi || '')}">SHOW TRACK</button></div>`;
  }).join('') : '<div class="empty-row">No historical vessel track crosses or approaches this event area within the selected distance.</div>';
}

async function loadSourceCandidates(eventId, nearbyNm) {
  const requestId = ++sourceCandidateRequest;
  const container = $('#sourceCandidateList');
  if (container) container.innerHTML = '<div class="empty-row">Screening historical tracks against the pollution area…</div>';
  setText('#sourceCandidateCount', 'Screening…');
  try {
    const result = await fetchGeoJson(`/api/pollution-events/${encodeURIComponent(eventId)}/candidate-vessels?nearby_nm=${encodeURIComponent(nearbyNm)}&limit=500`);
    if (requestId !== sourceCandidateRequest) return;
    sourceCandidateEventId = String(eventId);
    sourceCandidateRadiusNm = Number(nearbyNm);
    sourceCandidateData = Array.isArray(result.items) ? result.items : [];
    renderSourceCandidateRows();
  } catch (error) {
    if (requestId !== sourceCandidateRequest) return;
    sourceCandidateData = [];
    setText('#sourceCandidateCount', 'Unavailable');
    if (container) container.innerHTML = `<div class="empty-row">Historical-track screening failed: ${escapeHtml(error.message)}</div>`;
    console.error(error);
  }
}

function renderSourceAnalysis(options = {}) {
  const force = options?.force === true;
  const feature = syncEventSelect('#sourceEventSelect');
  const container = $('#sourceCandidateList');
  if (!feature || !container) {
    sourceCandidateData = [];
    sourceCandidateEventId = null;
    setText('#sourceCandidateCount', '0 candidates');
    if (container) container.innerHTML = '<div class="empty-row">No event record is available for screening</div>';
    return;
  }
  const properties = feature.properties || {};
  const center = featureCenter(feature);
  const eventId = String(properties.event_id ?? feature.id);
  const nearbyNm = Number($('#sourceNearbyNm')?.value || 10);
  setText('#sourceEventTime', formatDate(properties.event_time));
  setText('#sourceEventArea', properties.area_km2 == null ? '—' : `${numberValue(properties.area_km2).toFixed(2)} km²`);
  setText('#sourceEventCoordinates', center ? `${center[1].toFixed(4)}° N, ${center[0].toFixed(4)}° E` : '—');
  if (!force && sourceCandidateEventId === eventId && sourceCandidateRadiusNm === nearbyNm) {
    renderSourceCandidateRows();
    return;
  }
  loadSourceCandidates(eventId, nearbyNm);
}

function renderAlertCenter() {
  const features = warningData.features || [];
  const sorted = [...features].sort((a, b) => Date.parse(b.properties?.warning_time || 0) - Date.parse(a.properties?.warning_time || 0));
  setText('#alertTotal', features.length.toLocaleString());
  setText('#alertHighCount', features.filter(feature => isHighLevel(feature.properties?.warning_level)).length.toLocaleString());
  setText('#alertLatestTime', sorted.length ? formatDate(sorted[0].properties?.warning_time) : '—');
  const container = $('#alertRecordList');
  if (!container) return;
  container.innerHTML = sorted.length ? sorted.slice(0, 8).map(feature => {
    const properties = feature.properties || {};
    return `<div class="alert-record-row"><div><strong>${escapeHtml(properties.warning_name || `Warning ${feature.id ?? ''}`)}</strong><small>${escapeHtml(properties.warning_level || 'Recorded')} · ${escapeHtml(formatDate(properties.warning_time))}</small></div><button type="button" data-warning-id="${escapeHtml(feature.id ?? properties.id)}">LOCATE</button></div>`;
  }).join('') : '<div class="empty-row">No warning records are available</div>';
}

function warningNearFeature(feature) {
  const center = featureCenter(feature);
  if (!center) return null;
  return (warningData.features || []).map(warning => ({ warning, distance: distanceNm(center, featureCenter(warning)) }))
    .filter(item => Number.isFinite(item.distance)).sort((a, b) => a.distance - b.distance)[0] || null;
}

function evidenceItems(feature) {
  const properties = feature?.properties || {};
  const center = featureCenter(feature);
  const candidates = feature ? nearbyVessels(feature) : [];
  const warning = feature ? warningNearFeature(feature) : null;
  return [
    ['Incident identity', Boolean(properties.event_id ?? feature?.id), 'Event number in the archive'],
    ['Observation time', Boolean(properties.event_time), 'Recorded incident timestamp'],
    ['Pollution geometry', Boolean(feature?.geometry), 'Mapped boundary or point'],
    ['Affected-area estimate', properties.area_km2 != null, 'Reported area in square kilometres'],
    ['Center coordinates', Boolean(center), 'Derived event center'],
    ['Response status', Boolean(properties.status), 'Current processing state'],
    ['Nearby vessel screening', candidates.length > 0, `${candidates.length} current positions ranked`],
    ['Related warning record', Boolean(warning && warning.distance <= 100), warning ? `${warning.distance.toFixed(1)} NM from event center` : 'No nearby warning record'],
    ['Original satellite product', false, 'Dedicated product not connected'],
    ['Analyst-approved report', false, 'Approval workflow not configured']
  ];
}

function renderEvidenceReadiness() {
  const feature = syncEventSelect('#evidenceEventSelect');
  const container = $('#evidenceChecklist');
  const items = feature ? evidenceItems(feature) : [];
  const available = items.filter(([, ready]) => ready).length;
  const percent = items.length ? Math.round(available / items.length * 100) : 0;
  setText('#evidenceReadyCount', `${available} / ${items.length} available`);
  setText('#evidenceProgressText', `${percent}%`);
  if ($('#evidenceProgressBar')) $('#evidenceProgressBar').style.width = `${percent}%`;
  if (!container) return;
  container.innerHTML = items.length ? items.map(([label, ready, description]) => `<div class="evidence-item ${ready ? '' : 'missing'}"><i>${ready ? '✓' : '!'}</i><div><strong>${escapeHtml(label)}</strong><small>${escapeHtml(description)}</small></div></div>`).join('') : '<div class="empty-row">No event record is available for review</div>';
}

function refreshRequirementModules() {
  renderSatelliteReadiness();
  renderSourceAnalysis();
  renderAlertCenter();
  renderEvidenceReadiness();
  renderTrackCatalog();
}

function clearLocatedFeature() {
  if (!locatedFeatureMarker) return;
  locatedFeatureMarker.getPopup()?.remove();
  locatedFeatureMarker.remove();
  locatedFeatureMarker = null;
}

function locateFeature(feature, message) {
  const center = featureCenter(feature);
  if (!center || !map) return showMessage('This record has no valid map location');
  activateView('pollution');
  floatingPanelManager?.hideAll();
  clearLocatedFeature();
  const properties = feature.properties || {};
  const title = properties.warning_name || properties.event_id || 'Selected location';
  const popup = new maplibregl.Popup({ closeButton: true, maxWidth: '310px', offset: 28 })
    .setHTML(popupHtml('Located record', title, [
      ['Longitude', center[0].toFixed(6)],
      ['Latitude', center[1].toFixed(6)],
      ['Record time', formatDate(properties.warning_time || properties.event_time)]
    ]));
  // 只标出当前点击记录的位置，不恢复预警圈或风险区域。
  locatedFeatureMarker = new maplibregl.Marker({ color: '#2f76d2', scale: 1.15 })
    .setLngLat(center)
    .setPopup(popup)
    .addTo(map);
  locatedFeatureMarker.getElement().title = `${title} · ${center[0].toFixed(5)}, ${center[1].toFixed(5)}`;
  map.stop();
  map.resize();
  map.flyTo({
    center,
    zoom: Math.min(map.getMaxZoom(), Math.max(map.getZoom(), 12)),
    padding: 0,
    duration: 1000
  });
  showMessage(message);
}

function downloadDraftSummary() {
  const feature = pollutionFeatureById($('#evidenceEventSelect')?.value);
  if (!feature) return showMessage('Select an event before creating a draft summary');
  const properties = feature.properties || {};
  const center = featureCenter(feature);
  const candidates = nearbyVessels(feature).map(({ vessel, distance, suspected }) => ({
    mmsi: vessel.properties?.mmsi,
    ship_name: vessel.properties?.ship_name,
    ship_type: vessel.properties?.ship_type,
    distance_nm: Number(distance.toFixed(2)),
    priority_list: suspected
  }));
  const documentData = {
    document_type: 'EVENT_REVIEW_DRAFT',
    generated_at: new Date().toISOString(),
    event: {
      event_id: properties.event_id ?? feature.id,
      event_time: properties.event_time,
      status: properties.status,
      level: properties.level,
      area_km2: properties.area_km2,
      center_longitude: center?.[0] ?? null,
      center_latitude: center?.[1] ?? null
    },
    nearby_vessel_screening: candidates,
    completeness: evidenceItems(feature).map(([item, available, note]) => ({ item, available, note })),
    note: 'Draft for operational review. Original satellite products, analysis records and approval are required for a formal evidence package.'
  };
  const blob = new Blob([JSON.stringify(documentData, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `${properties.event_id || feature.id || 'event'}_review_draft.json`;
  document.body.appendChild(link);
  link.click();
  link.remove();
  URL.revokeObjectURL(url);
  showMessage('Draft event summary downloaded');
}

function updateVesselMixBars(counts) {
  const total = Math.max(1, Object.values(counts).reduce((sum, value) => sum + value, 0));
  Object.entries(counts).forEach(([type, count]) => {
    const bar = $(`#bar${type}`);
    if (bar) bar.style.width = `${Math.max(2, count / total * 100)}%`;
  });
}

function renderStatusBars(statusCounts = {}) {
  const container = $('#eventStatusBars');
  if (!container) return;
  const entries = Object.entries(statusCounts);
  if (!entries.length) {
    container.innerHTML = '<div class="empty-row">No incident status records</div>';
    return;
  }
  const maximum = Math.max(1, ...entries.map(([, value]) => numberValue(value)));
  container.innerHTML = entries.slice(0, 5).map(([label, value]) => {
    const count = numberValue(value);
    return `<div class="status-bar-row"><span>${escapeHtml(label)}</span><em><u style="width:${Math.max(4, count / maximum * 100)}%"></u></em><b>${count.toLocaleString()}</b></div>`;
  }).join('');
}

function incidentStatusGroup(value) {
  const status = String(value || '').toLowerCase();
  if (/closed|close|completed|resolved|关闭|完成|结束/.test(status)) return 'closed';
  if (/process|review|pending|处理中|待审核|审核/.test(status)) return 'processing';
  return 'active';
}

function applyIncidentFilters() {
  const container = $('#recentEventsList');
  if (!container) return;
  const statusFilter = $('#incidentStatusFilter')?.value || 'all';
  const riskFilter = $('#incidentRiskFilter')?.value || 'all';
  const searchFilter = ($('#incidentSearchFilter')?.value || '').trim().toLowerCase();

  const filtered = recentPollutionEvents.filter(event => {
    const status = incidentStatusGroup(event.status);
    const risk = String(event.risk_level || event.level || '').toLowerCase();
    const searchable = `${event.event_id || ''} ${event.status || ''} ${event.level || ''}`.toLowerCase();
    return (statusFilter === 'all' || status === statusFilter)
      && (riskFilter === 'all' || risk.includes(riskFilter))
      && (!searchFilter || searchable.includes(searchFilter));
  });

  const activeCount = recentPollutionEvents.filter(event => incidentStatusGroup(event.status) !== 'closed').length;
  const visibleArea = filtered.reduce((sum, event) => sum + numberValue(event.area_km2), 0);
  setText('#incidentRecordCount', recentPollutionEvents.length.toLocaleString());
  setText('#incidentActiveCount', activeCount.toLocaleString());
  setText('#incidentAreaTotal', `${visibleArea.toFixed(2)} km²`);
  setText('#incidentFilterSummary', `Showing ${filtered.length} of ${recentPollutionEvents.length} archive records`);

  if (!filtered.length) {
    container.innerHTML = '<div class="empty-row">No pollution incidents match the selected filters</div>';
    return;
  }

  container.innerHTML = filtered.slice(0, 8).map(event => {
    const area = numberValue(event.area_km2);
    const areaLabel = area ? `${area.toFixed(2)} km²` : '—';
    const risk = event.risk_level || event.level || 'Recorded';
    const status = event.status || 'Recorded';
    return `<div class="incident-table-row" role="row"><strong>${escapeHtml(event.event_id || 'Event')}</strong><span>${escapeHtml(formatDate(event.event_time))}</span><b>${escapeHtml(areaLabel)}</b><em>${escapeHtml(risk)}</em><u>${escapeHtml(status)}</u><button type="button" class="incident-row-action" data-event-action="locate" data-event-id="${escapeHtml(event.event_id || '')}">Locate</button></div>`;
  }).join('');
}

function renderRecentEvents(events = []) {
  recentPollutionEvents = events.slice(0, 50);
  applyIncidentFilters();
}

function renderFootprintChart(events = []) {
  const line = $('#trendLine');
  const area = $('#trendArea');
  const dots = $('#trendDots');
  if (!line || !area || !dots) return;
  const values = events.slice(0, 8).reverse().map(event => numberValue(event.area_km2));
  if (!values.length) values.push(0, 0);
  if (values.length === 1) values.unshift(0);
  const maximum = Math.max(1, ...values);
  const left = 12;
  const right = 508;
  const top = 12;
  const bottom = 108;
  const points = values.map((value, index) => {
    const x = left + (right - left) * index / Math.max(1, values.length - 1);
    const y = bottom - (bottom - top) * value / maximum;
    return [x, y];
  });
  const pointString = points.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ');
  line.setAttribute('points', pointString);
  area.setAttribute('d', `M${left} ${bottom} L${pointString.replaceAll(' ', ' L')} L${right} ${bottom} Z`);
  dots.innerHTML = points.map(([x, y]) => `<circle class="trend-dot" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="3"/>`).join('');
}

function updateDashboardVisuals(summary) {
  const tracks = summary.tracks || {};
  const pollution = summary.pollution_events || {};
  const riskAreas = summary.risk_areas || {};
  const suspicious = summary.suspicious_ships || {};
  const warnings = summary.warnings || {};

  setText('#trackedPoints', numberValue(tracks.points).toLocaleString());
  setText('#affectedArea', `${numberValue(pollution.total_area_km2).toFixed(2)} km²`);
  setText('#statRiskAreas', numberValue(riskAreas.total).toLocaleString());
  setText('#highRiskShips', highRiskCount(suspicious.by_level).toLocaleString());

  const warningTotal = numberValue(warnings.total);
  const suspectTotal = numberValue(suspicious.total);
  const pollutionTotal = numberValue(pollution.total);
  const highSignals = highRiskCount(warnings.by_level) + highRiskCount(suspicious.by_level) + highRiskCount(pollution.by_level);
  const signalTotal = Math.max(1, warningTotal + suspectTotal + pollutionTotal);
  const gaugeAngle = Math.min(270, highSignals / signalTotal * 270);
  const gauge = $('#riskGauge');
  if (gauge) gauge.style.setProperty('--gauge-angle', `${gaugeAngle.toFixed(1)}deg`);
  setText('#riskGaugeValue', highSignals.toLocaleString());
  setText('#gaugeWarnings', warningTotal.toLocaleString());
  setText('#gaugeSuspects', suspectTotal.toLocaleString());
  setText('#gaugePollution', pollutionTotal.toLocaleString());

  renderStatusBars(pollution.by_status);
  renderRecentEvents(summary.recent_pollution_events);
  renderFootprintChart(summary.recent_pollution_events);
}

function updateAisMotionStatus(motion = {}) {
  const total = numberValue(motion.total_vessels);
  const refreshed = numberValue(motion.recently_refreshed);
  const moving = numberValue(motion.moving_vessels);
  const stationary = numberValue(motion.stationary_vessels);
  const route = numberValue(motion.route_following);
  const local = numberValue(motion.local_movement);
  const interval = numberValue(motion.refresh_seconds) || Math.round(AUTO_REFRESH_MS / 1000);
  const isLive = motion.status === 'live' && total > 0 && refreshed === total;

  setText('#motionRefreshed', `${refreshed.toLocaleString()} / ${total.toLocaleString()}`);
  setText('#motionRefreshedNote', isLive ? 'All vessel timestamps are current' : 'Some vessel updates are delayed');
  setText('#motionMoving', moving.toLocaleString());
  setText('#motionStationary', stationary.toLocaleString());
  setText('#motionInterval', `${interval} s`);
  setText('#motionRoute', route.toLocaleString());
  setText('#motionLocal', local.toLocaleString());
  setText('#motionStationaryMode', stationary.toLocaleString());
  setText('#motionLatestUpdate', `Latest AIS update: ${formatDate(motion.latest_update)}`);
  setText('#motionFooterStatus', `Moving: ${moving.toLocaleString()} · Stationary: ${stationary.toLocaleString()}`);

  const badge = $('#motionStatusBadge');
  if (badge) {
    badge.textContent = isLive ? `LIVE · ${interval} s` : 'UPDATE DELAYED';
    badge.classList.toggle('motion-delayed', !isLive);
  }
  if (isLive) setConnection('connected', `Live AIS · ${total.toLocaleString()} · ${interval} s`);
}

function updateSummary(data) {
  const totalCount = numberValue(data.count || data.features.length);
  $('#totalShips').textContent = totalCount.toLocaleString();
  $('#apiCount').textContent = `API records: ${totalCount.toLocaleString()}`;
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
  updateVesselMixBars(counts);
  $('#latestUpdate').textContent = latest ? formatDate(latest) : 'Not available';
}

function updateRefreshStatus(message) {
  const status = $('#refreshStatus');
  if (status) status.textContent = message;
}

function refreshSelectedVessel() {
  if (selectedMmsi === null) return;
  const selected = vesselData.features.find(
    feature => String(feature.properties.mmsi) === String(selectedMmsi)
  );
  if (selected) {
    selectVessel(selected, { openPanel: false });
  } else {
    selectedFeatureId = null;
    floatingPanelManager?.hide('ship-details');
  }
}

function latestVesselUpdateMs(collection) {
  const timestamps = (collection.features || [])
    .map(feature => Date.parse(feature.properties?.update_time))
    .filter(Number.isFinite);
  return timestamps.length ? Math.max(...timestamps) : null;
}

function cloneVesselCollection(collection) {
  return {
    ...collection,
    features: (collection.features || []).map(feature => ({
      ...feature,
      properties: { ...feature.properties },
      geometry: {
        ...feature.geometry,
        coordinates: [...feature.geometry.coordinates]
      }
    }))
  };
}

function vesselKey(feature) {
  return String(feature.properties?.mmsi ?? feature.id ?? feature.properties?.id ?? '');
}

function setRenderedVessels(collection) {
  renderedVesselData = cloneVesselCollection(collection);
  map?.getSource('vessels')?.setData(renderedVesselData);
}

function animateVesselUpdate(nextCollection, { initial = false } = {}) {
  if (vesselAnimationFrame !== null) {
    cancelAnimationFrame(vesselAnimationFrame);
    vesselAnimationFrame = null;
  }

  const vesselSource = map?.getSource('vessels');
  if (initial || !vesselSource || renderedVesselData.features.length === 0) {
    setRenderedVessels(nextCollection);
    return;
  }

  const previousByKey = new Map(
    renderedVesselData.features.map(feature => [vesselKey(feature), feature])
  );
  const animatedCollection = cloneVesselCollection(nextCollection);
  const movements = [];

  animatedCollection.features.forEach((feature, index) => {
    const previous = previousByKey.get(vesselKey(feature));
    if (!previous) return;
    const start = previous.geometry?.coordinates;
    const target = feature.geometry?.coordinates;
    if (
      !Array.isArray(start) || !Array.isArray(target) ||
      !start.every(Number.isFinite) || !target.every(Number.isFinite) ||
      (start[0] === target[0] && start[1] === target[1])
    ) return;
    movements.push({ index, start: [...start], target: [...target] });
    feature.geometry.coordinates = [...start];
  });

  if (movements.length === 0) {
    setRenderedVessels(nextCollection);
    return;
  }

  const startedAt = performance.now();
  const renderFrame = now => {
    const progress = Math.min(1, (now - startedAt) / VESSEL_ANIMATION_MS);
    const eased = progress < .5
      ? 2 * progress * progress
      : 1 - Math.pow(-2 * progress + 2, 2) / 2;

    movements.forEach(({ index, start, target }) => {
      animatedCollection.features[index].geometry.coordinates = [
        start[0] + (target[0] - start[0]) * eased,
        start[1] + (target[1] - start[1]) * eased
      ];
    });
    renderedVesselData = animatedCollection;
    vesselSource.setData(animatedCollection);

    if (progress < 1) {
      vesselAnimationFrame = requestAnimationFrame(renderFrame);
    } else {
      vesselAnimationFrame = null;
      setRenderedVessels(nextCollection);
    }
  };
  vesselAnimationFrame = requestAnimationFrame(renderFrame);
}

async function loadVessels({ initial = false } = {}) {
  if (vesselRefreshRunning) return;
  vesselRefreshRunning = true;
  try {
    const response = await fetchWithTimeout(`${API_BASE}/api/ships?limit=5000`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`API returned ${response.status}`);
    const nextVesselData = await response.json();
    vesselData = nextVesselData;
    animateVesselUpdate(nextVesselData, { initial });
    updateSummary(vesselData);
    if (mapLayersReady) {
      applyTypeFilter();
      refreshSelectedVessel();
    }
    const latestUpdateMs = latestVesselUpdateMs(vesselData);
    const dataIsFresh = latestUpdateMs !== null
      && Math.abs(Date.now() - latestUpdateMs) <= AIS_FRESHNESS_MS;
    const refreshSeconds = Math.round(AUTO_REFRESH_MS / 1000);
    setConnection(dataIsFresh ? 'connected' : 'stale', dataIsFresh ? `Live AIS · ${refreshSeconds} s` : `AIS stale · ${refreshSeconds} s`);
    updateRefreshStatus(`Last refresh: ${new Date().toLocaleTimeString()} · every ${refreshSeconds} s`);
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
  const response = await fetchWithTimeout(`${API_BASE}${path}`, { cache: 'no-store' });
  if (!response.ok) throw new Error(`${path} returned ${response.status}`);
  return response.json();
}

async function loadOperationalLayers({ initial = false } = {}) {
  if (operationalRefreshRunning) return;
  operationalRefreshRunning = true;
  const requestedTrackMmsi = selectedTrackMmsi;
  const refreshCatalog = initial || !trackCatalogData.length || Date.now() - trackCatalogLoadedAt >= TRACK_CATALOG_REFRESH_MS;
  try {
    const [catalogResult, selectedTrackResult, nextPollution, nextSuspicious, nextWarnings] = await Promise.all([
      refreshCatalog ? fetchGeoJson('/api/tracks/catalog?limit=5000') : Promise.resolve(null),
      requestedTrackMmsi
        ? fetchGeoJson(selectedTrackUrl(requestedTrackMmsi, {
          centerTime: selectedTrackCenterTime,
          startTime: selectedTrackStartTime,
          endTime: selectedTrackEndTime
        }))
        : Promise.resolve({ type: 'FeatureCollection', features: [] }),
      fetchGeoJson('/api/pollution-events?limit=1000'),
      fetchGeoJson('/api/suspicious-ships?limit=1000'),
      fetchGeoJson('/api/warnings?limit=1000')
    ]);
    if (catalogResult) {
      trackCatalogData = Array.isArray(catalogResult.items) ? catalogResult.items : [];
      trackCatalogLoadedAt = Date.now();
    }
    if (requestedTrackMmsi === selectedTrackMmsi) {
      trackData = selectedTrackResult;
    }
    pollutionData = nextPollution;
    suspiciousData = nextSuspicious;
    warningData = nextWarnings;
    if (mapLayersReady) {
      map.getSource('tracks')?.setData(trackData);
      map.getSource('pollution')?.setData(pollutionData);
      map.getSource('suspicious')?.setData(suspiciousData);
    }
    syncSelectedSuspectMarker();
    updateTrackSelectionStatus();
  } catch (error) {
    if (!initial) showMessage('One or more operational layers could not be refreshed');
    console.error(error);
  } finally {
    operationalRefreshRunning = false;
  }
}

async function loadDashboard() {
  try {
    const response = await fetchWithTimeout(`${API_BASE}/api/dashboard/summary`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`Dashboard returned ${response.status}`);
    const summary = await response.json();
    $('#statTrackVessels').textContent = Number(summary.tracks.vessels).toLocaleString();
    $('#statPollutionEvents').textContent = Number(summary.pollution_events.total).toLocaleString();
    $('#statSuspiciousShips').textContent = Number(summary.suspicious_ships.total).toLocaleString();
    $('#statWarnings').textContent = Number(summary.warnings.total).toLocaleString();
    updateDashboardVisuals(summary);
    updateAisMotionStatus(summary.ais_motion);
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
  refreshRequirementModules();
}

function startAutoRefresh() {
  if (refreshTimer !== null) clearInterval(refreshTimer);
  refreshTimer = setInterval(() => {
    if (!document.hidden) refreshPlatformData();
  }, AUTO_REFRESH_MS);
}

function updateClock() {
  const now = new Date();
  setText('#dashboardClock', now.toLocaleTimeString('en-GB', { hour12:false }));
  setText('#dashboardDate', now.toLocaleDateString('en-GB', { day:'2-digit', month:'short', year:'numeric' }).toUpperCase());
  setText('#omanClock', now.toLocaleTimeString('en-GB', { hour12:false, timeZone:'Asia/Muscat' }));
  setText('#omanDate', now.toLocaleDateString('en-GB', {
    day:'2-digit',
    month:'short',
    year:'numeric',
    timeZone:'Asia/Muscat'
  }).toUpperCase());
}

function startClock() {
  updateClock();
  if (clockTimer !== null) clearInterval(clockTimer);
  clockTimer = setInterval(updateClock, 1000);
}

function selectedTypes() {
  return [...document.querySelectorAll('.type-filters input:checked')].map(input => input.value);
}

function applyTypeFilter() {
  const types = selectedTypes();
  const filter = types.length ? ['in', ['get', 'ship_type'], ['literal', types]] : ['==', 1, 0];
  ['vessel-selection', 'vessels-overview', 'vessels', 'vessel-labels'].forEach(id => {
    if (!map?.getLayer(id)) return;
    map.setFilter(id, filter);
  });
  const visible = vesselData.features.filter(feature => types.includes(feature.properties.ship_type)).length;
  $('#totalShips').textContent = visible.toLocaleString();
}

function setText(selector, value) {
  $(selector).textContent = value ?? '—';
}

function vesselOperationalStatus(properties = {}) {
  const speed = Number(properties.speed);
  const type = String(properties.ship_type || '').toLowerCase();
  if (!Number.isFinite(speed)) {
    return { key: 'unknown', label: 'Status unavailable', badge: 'UNKNOWN', note: 'No valid speed value is available' };
  }
  if (speed <= 0.5) {
    return { key: 'stationary', label: 'Stationary / Anchored', badge: 'STATIONARY', note: `Speed ${speed.toFixed(1)} kn · position is being refreshed` };
  }
  if (type === 'fishing' && speed <= 6) {
    return { key: 'fishing', label: 'Fishing activity', badge: 'ACTIVE', note: `Moving at ${speed.toFixed(1)} kn in a fishing-speed range` };
  }
  if (speed < 3) {
    return { key: 'manoeuvring', label: 'Slow movement / Manoeuvring', badge: 'MOVING', note: `Low-speed movement at ${speed.toFixed(1)} kn` };
  }
  return { key: 'underway', label: 'Under way', badge: 'MOVING', note: `Navigating at ${speed.toFixed(1)} kn` };
}

function selectVessel(feature, { openPanel = true } = {}) {
  const p = feature.properties;
  if (selectedFeatureId !== null && map?.getSource('vessels')) {
    map.setFeatureState({ source:'vessels', id:selectedFeatureId }, { selected:false });
  }
  selectedMmsi = p.mmsi || null;
  selectedFeatureId = selectedMmsi === null
    ? feature.id ?? p.id
    : String(selectedMmsi);
  if (map?.getSource('vessels')) {
    map.setFeatureState({ source:'vessels', id:selectedFeatureId }, { selected:true });
  }
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
  const operationalStatus = vesselOperationalStatus(p);
  setText('#detailStatus', operationalStatus.label);
  setText('#detailStatusBadge', operationalStatus.badge);
  setText('#detailStatusNote', operationalStatus.note);
  $('#detailStatusCard').dataset.status = operationalStatus.key;
  const color = TYPE_COLORS[p.ship_type] || TYPE_COLORS.Other;
  $('#detailShipIcon').style.color = color;
  if (openPanel) {
    if (floatingPanelManager) floatingPanelManager.open('ship-details');
    else detailPanel.classList.add('is-visible');
  }
}

function clearSelectedVessel() {
  if (selectedFeatureId !== null && map?.getSource('vessels')) {
    map.setFeatureState({ source: 'vessels', id: selectedFeatureId }, { selected: false });
  }
  selectedFeatureId = null;
  selectedMmsi = null;
  if (floatingPanelManager) floatingPanelManager.hide('ship-details');
  else detailPanel.classList.remove('is-visible');
}

async function searchVessel(query) {
  const response = await fetchWithTimeout(`${API_BASE}/api/ships?search=${encodeURIComponent(query)}&limit=20`);
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

function syncSelectedSuspectMarker() {
  if (!map?.getLayer('suspicious-ships')) return;
  const selected = String(selectedTrackMmsi || '');
  const isSuspected = Boolean(selected && (suspiciousData.features || []).some(feature => {
    return String(feature.properties?.mmsi || '') === selected;
  }));
  const trackVisible = Boolean(
    map.getLayer('track-lines') &&
    map.getLayoutProperty('track-lines', 'visibility') !== 'none'
  );
  const showSelectedSuspect = isSuspected && trackVisible;
  map.setFilter(
    'suspicious-ships',
    showSelectedSuspect
      ? ['==', ['get', 'mmsi'], selected]
      : ['==', ['get', 'mmsi'], '__no_selected_suspect__']
  );
  map.setLayoutProperty('suspicious-ships', 'visibility', showSelectedSuspect ? 'visible' : 'none');
  const toggle = $('#suspiciousLayerToggle');
  if (toggle) toggle.checked = showSelectedSuspect;
}

function clearTrackSelection({ notify = true } = {}) {
  selectedTrackRequest += 1;
  selectedTrackMmsi = null;
  selectedTrackCenterTime = null;
  selectedTrackStartTime = null;
  selectedTrackEndTime = null;
  trackData = { type: 'FeatureCollection', features: [] };
  map?.getSource('tracks')?.setData(trackData);
  setLayerToggle('#trackLayerToggle', 'tracks', false);
  syncSelectedSuspectMarker();
  updateTrackSelectionStatus();
  renderTrackCatalog();
  if (notify) showMessage('Historical track cleared');
}

function setOperationalWatchContent() {
  renderTrackCatalog();
}

function trackQueryFilters() {
  const startDate = $('#trackQueryStartDate')?.value || '';
  const startClock = $('#trackQueryStartClock')?.value || '';
  const endDate = $('#trackQueryEndDate')?.value || '';
  const endClock = $('#trackQueryEndClock')?.value || '';
  const withSeconds = value => value && value.length === 5 ? `${value}:00` : value;
  return {
    vessel: ($('#trackCatalogSearch')?.value || '').trim(),
    startTime: startDate && startClock ? `${startDate}T${withSeconds(startClock)}` : '',
    endTime: endDate && endClock ? `${endDate}T${withSeconds(endClock)}` : ''
  };
}

function renderTrackCatalog() {
  const container = $('#trackCatalogList');
  if (!container) return;
  const filters = trackQueryFilters();
  const query = filters.vessel.toLowerCase();
  const requestedStart = filters.startTime ? new Date(filters.startTime).getTime() : null;
  const requestedEnd = filters.endTime ? new Date(filters.endTime).getTime() : null;
  const tracks = trackCatalogData
    .filter(properties => {
      const matchesVessel = !query || `${properties.ship_name || ''} ${properties.mmsi || ''} ${properties.ship_type || ''}`.toLowerCase().includes(query);
      const trackStart = properties.start_time ? new Date(properties.start_time).getTime() : null;
      const trackEnd = properties.end_time ? new Date(properties.end_time).getTime() : null;
      const overlapsStart = requestedStart === null || trackEnd === null || trackEnd >= requestedStart;
      const overlapsEnd = requestedEnd === null || trackStart === null || trackStart <= requestedEnd;
      return matchesVessel && overlapsStart && overlapsEnd;
    })
    .sort((left, right) => String(left.ship_name || left.mmsi || '').localeCompare(String(right.ship_name || right.mmsi || '')));
  const total = trackCatalogData.length;
  const filtered = Boolean(query || filters.startTime || filters.endTime);
  setText('#trackCatalogCount', filtered ? `${tracks.length} of ${total} vessels` : `${total} vessels with tracks`);
  container.innerHTML = tracks.length ? tracks.map(properties => {
    const name = properties.ship_name || `MMSI ${properties.mmsi || 'Unknown'}`;
    const start = formatDate(properties.start_time);
    const end = formatDate(properties.end_time);
    const isSelected = String(properties.mmsi) === String(selectedTrackMmsi || '');
    const suspected = (suspiciousData.features || []).find(feature => String(feature.properties?.mmsi || '') === String(properties.mmsi || ''));
    const suspectLabel = suspected ? ` · Suspected ${suspected.properties?.risk_level || ''} risk` : '';
    return `<div class="track-catalog-row ${isSelected ? 'is-selected' : ''}" role="row"><div class="track-catalog-identity"><strong>${escapeHtml(name)}</strong><small>MMSI ${escapeHtml(properties.mmsi)}${escapeHtml(suspectLabel)}</small></div><span class="track-catalog-type">${escapeHtml(properties.ship_type || 'Unknown')}</span><span class="track-catalog-period">${escapeHtml(start)}<small>to ${escapeHtml(end)}</small></span><strong class="track-catalog-points">${numberValue(properties.point_count).toLocaleString()}</strong><button type="button" data-track-mmsi="${escapeHtml(properties.mmsi)}">${isSelected ? 'DISPLAYED' : 'SHOW TRACK'}</button></div>`;
  }).join('') : '<div class="empty-row">No vessels match this search.</div>';
}

function updateTrackSelectionStatus(track = trackData.features?.[0]) {
  const status = $('#trackSelectionStatus');
  const clearButton = $('#clearTrackSelection');
  if (!status) return;
  const properties = track?.properties || {};
  const active = Boolean(selectedTrackMmsi && track);
  status.dataset.active = String(active);
  status.querySelector('strong').textContent = active
    ? properties.ship_name || `MMSI ${selectedTrackMmsi}`
    : 'No vessel selected';
  status.querySelector('small').textContent = active
    ? `MMSI ${selectedTrackMmsi} · ${numberValue(properties.point_count).toLocaleString()} unique points · ${formatDate(properties.start_time)} to ${formatDate(properties.end_time)} · ${properties.distance_nm ?? '—'} NM`
    : 'Enter a vessel number/name and time range, or choose a vessel from the list below.';
  if (clearButton) clearButton.disabled = !active;
}

function selectedTrackUrl(mmsi, { centerTime = null, startTime = null, endTime = null } = {}) {
  const hasTimeRange = Boolean(startTime || endTime);
  const parameters = new URLSearchParams({
    mmsi: String(mmsi),
    limit: '1',
    max_points: hasTimeRange ? '2000' : centerTime ? '240' : '120'
  });
  if (centerTime) {
    parameters.set('center_time', centerTime);
    parameters.set('window_minutes', '120');
  } else {
    if (startTime) parameters.set('start_time', startTime);
    if (endTime) parameters.set('end_time', endTime);
  }
  return `/api/tracks?${parameters.toString()}`;
}

async function displaySingleTrack(mmsi, { closeCatalog = false, centerTime = null, startTime = null, endTime = null } = {}) {
  const requestedMmsi = String(mmsi || '').trim();
  if (!requestedMmsi) return showMessage('This vessel has no valid MMSI');
  if (!map.getLayer('track-lines')) return showMessage('The map layers are still loading');
  const requestId = ++selectedTrackRequest;
  showMessage(`Loading historical track for MMSI ${requestedMmsi}…`);
  const collection = await fetchGeoJson(selectedTrackUrl(requestedMmsi, { centerTime, startTime, endTime }));
  if (requestId !== selectedTrackRequest) return;
  const track = collection.features?.[0];
  if (!track?.geometry?.coordinates?.length) return showMessage('This vessel does not yet have enough historical points to form a line');
  const properties = track.properties || {};
  selectedTrackMmsi = String(properties.mmsi || requestedMmsi);
  selectedTrackCenterTime = centerTime || null;
  selectedTrackStartTime = startTime || null;
  selectedTrackEndTime = endTime || null;
  trackData = collection;
  map.getSource('tracks')?.setData(trackData);
  setLayerToggle('#trackLayerToggle', 'tracks', true);
  syncSelectedSuspectMarker();
  setOperationalWatchContent();
  const bounds = new maplibregl.LngLatBounds();
  track.geometry.coordinates.forEach(coordinate => bounds.extend(coordinate));
  clearLocatedFeature();
  map.fitBounds(bounds, { padding: 110, maxZoom: 14.5, duration: 900 });
  updateTrackSelectionStatus(track);
  renderTrackCatalog();
  if (closeCatalog) floatingPanelManager?.hide('operational-watch');
  showMessage(`Showing ${properties.ship_name || selectedTrackMmsi}'s filtered historical track`);
}

async function submitTrackQuery(event) {
  event.preventDefault();
  const filters = trackQueryFilters();
  if (!filters.vessel || !filters.startTime || !filters.endTime) {
    return showMessage('Enter the vessel number/name, start time and end time');
  }
  if (new Date(filters.startTime).getTime() >= new Date(filters.endTime).getTime()) {
    return showMessage('The end time must be later than the start time');
  }

  const requested = filters.vessel.toLowerCase();
  const exact = trackCatalogData.find(item =>
    String(item.mmsi || '').toLowerCase() === requested ||
    String(item.ship_name || '').trim().toLowerCase() === requested
  );
  const partialMatches = trackCatalogData.filter(item =>
    `${item.ship_name || ''} ${item.mmsi || ''}`.toLowerCase().includes(requested)
  );
  const vessel = exact || (partialMatches.length === 1 ? partialMatches[0] : null);
  if (!vessel) {
    return showMessage(partialMatches.length > 1
      ? 'More than one vessel matches. Enter an exact ship name or MMSI.'
      : 'No vessel with historical-track data matches this query.');
  }

  const startTime = filters.startTime.length === 16 ? `${filters.startTime}:00` : filters.startTime;
  const endTime = filters.endTime.length === 16 ? `${filters.endTime}:00` : filters.endTime;
  await displaySingleTrack(vessel.mmsi, { closeCatalog: true, startTime, endTime });
}

function activateView(view) {
  document.querySelectorAll('[data-view]').forEach(tab => {
    tab.classList.toggle('active', tab.dataset.view === view);
  });
  if (view === 'vessels') {
    setOperationalWatchContent('vessels');
    setLayerToggle('#vesselLayerToggle', 'vessels', true);
    setLayerToggle('#trackLayerToggle', 'tracks', false);
    setLayerToggle('#pollutionLayerToggle', 'pollution', false);
    setLayerToggle('#suspiciousLayerToggle', 'suspicious', false);
  } else if (view === 'tracks') {
    setOperationalWatchContent('tracks');
    setLayerToggle('#vesselLayerToggle', 'vessels', true);
    setLayerToggle('#trackLayerToggle', 'tracks', Boolean(selectedTrackMmsi && trackData.features?.length));
    setLayerToggle('#pollutionLayerToggle', 'pollution', false);
    setLayerToggle('#suspiciousLayerToggle', 'suspicious', false);
  } else if (view === 'pollution') {
    setLayerToggle('#vesselLayerToggle', 'vessels', true);
    setLayerToggle('#trackLayerToggle', 'tracks', false);
    setLayerToggle('#pollutionLayerToggle', 'pollution', true);
    setLayerToggle('#suspiciousLayerToggle', 'suspicious', true);
  }
  syncSelectedSuspectMarker();
}

function syncBasemapControls() {
  document.querySelectorAll('.basemap-option').forEach(button => {
    button.classList.toggle('active', button.dataset.basemap === activeBasemap);
  });
}

function closeBasemapMenu() {
  $('#basemapMenu').classList.remove('visible');
  $('#basemapButton').classList.remove('active');
  $('#basemapButton').setAttribute('aria-expanded', 'false');
}

function setBasemap(name, { manual = true, notify = true } = {}) {
  if (!BASEMAP_LAYERS[name]) return;
  if (manual) basemapAutoMode = false;
  activeBasemap = name;
  const visibleLayerIds = new Set(BASEMAP_LAYERS[name]);
  const allLayerIds = new Set(Object.values(BASEMAP_LAYERS).flat());
  allLayerIds.forEach(layerId => {
    if (map.getLayer(layerId)) {
      map.setLayoutProperty(layerId, 'visibility', visibleLayerIds.has(layerId) ? 'visible' : 'none');
    }
  });
  syncBasemapControls();
  closeBasemapMenu();
  const label = document.querySelector(`.basemap-option[data-basemap="${name}"] b`)?.textContent || name;
  if (notify) showMessage(`${label} basemap selected`);
}

function syncAutomaticBasemap() {
  if (!basemapAutoMode || !map) return;
  const desiredBasemap = automaticBasemapForZoom(map.getZoom());
  if (desiredBasemap !== activeBasemap) {
    setBasemap(desiredBasemap, { manual: false, notify: false });
  }
}

function bindControls() {
  if (controlsBound) return;
  controlsBound = true;
  if (window.FloatingPanelManager) {
    floatingPanelManager = new window.FloatingPanelManager({
      headerHeight: 60,
      margin: 12,
      startingZIndex: 1100
    }).init();
  }
  $('#homeMap').addEventListener('click', () => {
    clearLocatedFeature();
    map.flyTo({ ...HOME, padding: 0, speed:1.1 });
  });
  $('#liveMapTool').addEventListener('click', () => {
    floatingPanelManager?.hideAll();
    clearLocatedFeature();
    clearSelectedVessel();
    activateView('vessels');
    map.flyTo({ ...HOME, speed:1.1 });
    showMessage('Live maritime situation map');
  });
  $('#zoomIn').addEventListener('click', () => map.zoomIn());
  $('#zoomOut').addEventListener('click', () => map.zoomOut());
  $('#toggleLabels').addEventListener('click', event => {
    labelsVisible = !labelsVisible;
    if (map.getLayer('vessel-labels')) {
      map.setLayoutProperty('vessel-labels', 'visibility', labelsVisible ? 'visible' : 'none');
    }
    event.currentTarget.classList.toggle('active', labelsVisible);
  });
  syncBasemapControls();
  $('#basemapButton').addEventListener('click', event => {
    event.stopPropagation();
    const menu = $('#basemapMenu');
    const isOpen = menu.classList.toggle('visible');
    event.currentTarget.classList.toggle('active', isOpen);
    event.currentTarget.setAttribute('aria-expanded', String(isOpen));
  });
  document.querySelectorAll('.basemap-option').forEach(button => {
    button.addEventListener('click', () => setBasemap(button.dataset.basemap));
  });
  document.addEventListener('click', event => {
    if (!event.target.closest('#basemapMenu') && !event.target.closest('#basemapButton')) closeBasemapMenu();
  });
  document.querySelectorAll('.type-filters input').forEach(input => input.addEventListener('change', applyTypeFilter));
  $('#resetFilters').addEventListener('click', () => {
    document.querySelectorAll('.type-filters input').forEach(input => { input.checked = true; });
    applyTypeFilter();
  });
  $('#vesselLayerToggle').addEventListener('change', event => {
    setLayerGroupVisibility('vessels', event.currentTarget.checked);
  });
  $('#pollutionLayerToggle').addEventListener('change', event => setLayerGroupVisibility('pollution', event.currentTarget.checked));
  $('#suspiciousLayerToggle').addEventListener('change', event => {
    const requestedVisible = event.currentTarget.checked;
    syncSelectedSuspectMarker();
    if (requestedVisible && !event.currentTarget.checked) {
      showMessage('Select a suspected vessel track in Historical Track Query first');
    }
  });
  document.querySelectorAll('[data-view]').forEach(tab => {
    tab.addEventListener('click', () => activateView(tab.dataset.view));
  });
  $('#trackCatalogSearch')?.addEventListener('input', renderTrackCatalog);
  ['#trackQueryStartDate', '#trackQueryStartClock', '#trackQueryEndDate', '#trackQueryEndClock'].forEach(selector => {
    $(selector)?.addEventListener('input', renderTrackCatalog);
  });
  $('#trackCatalogQuery')?.addEventListener('submit', event => {
    submitTrackQuery(event).catch(error => showMessage(error.message));
  });
  $('#trackCatalogQuery')?.addEventListener('reset', () => {
    window.setTimeout(() => {
      clearTrackSelection({ notify: false });
      renderTrackCatalog();
      showMessage('Historical-track query cleared');
    }, 0);
  });
  $('#clearTrackSelection')?.addEventListener('click', () => clearTrackSelection());
  $('#trackCatalogList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-track-mmsi]');
    if (!button) return;
    const filters = trackQueryFilters();
    if (!filters.startTime || !filters.endTime) {
      return showMessage('Select the start time and end time before querying this vessel');
    }
    const startTime = filters.startTime ? (filters.startTime.length === 16 ? `${filters.startTime}:00` : filters.startTime) : null;
    const endTime = filters.endTime ? (filters.endTime.length === 16 ? `${filters.endTime}:00` : filters.endTime) : null;
    if (startTime && new Date(startTime).getTime() >= new Date(endTime).getTime()) {
      return showMessage('The end time must be later than the start time');
    }
    displaySingleTrack(button.dataset.trackMmsi, { closeCatalog: true, startTime, endTime }).catch(error => showMessage(error.message));
  });
  $('#incidentStatusFilter')?.addEventListener('change', applyIncidentFilters);
  $('#incidentRiskFilter')?.addEventListener('change', applyIncidentFilters);
  $('#incidentSearchFilter')?.addEventListener('input', applyIncidentFilters);
  $('#incidentFilterReset')?.addEventListener('click', () => {
    $('#incidentStatusFilter').value = 'all';
    $('#incidentRiskFilter').value = 'all';
    $('#incidentSearchFilter').value = '';
    applyIncidentFilters();
  });
  $('#recentEventsList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-event-action="locate"]');
    if (!button) return;
    const feature = pollutionFeatureById(button.dataset.eventId);
    if (feature) locateFeature(feature, `${feature.properties?.event_id || 'Pollution event'} located on the map`);
  });
  $('#satelliteShowEvents')?.addEventListener('click', () => {
    activateView('pollution');
    floatingPanelManager?.hide('satellite-products');
    showMessage('Pollution event footprints enabled');
  });
  $('#sourceEventSelect')?.addEventListener('change', () => renderSourceAnalysis({ force: true }));
  $('#sourceNearbyNm')?.addEventListener('change', () => renderSourceAnalysis({ force: true }));
  $('#sourceCandidateList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-source-track-mmsi]');
    if (!button) return;
    const requestedMmsi = String(button.dataset.sourceTrackMmsi || '');
    const candidate = sourceCandidateData.find(item => String(item.mmsi || '') === requestedMmsi);
    displaySingleTrack(requestedMmsi, { centerTime: candidate?.match_time || null })
      .then(() => {
        if (selectedTrackMmsi === requestedMmsi) floatingPanelManager?.hide('source-analysis');
      })
      .catch(error => showMessage(error.message));
  });
  $('#sourceLocateEvent')?.addEventListener('click', () => {
    const feature = pollutionFeatureById($('#sourceEventSelect')?.value);
    if (feature) locateFeature(feature, `${feature.properties?.event_id || 'Event'} screening area located`);
  });
  $('#alertRecordList')?.addEventListener('click', event => {
    const button = event.target.closest('[data-warning-id]');
    if (!button) return;
    const feature = (warningData.features || []).find(item => String(item.id ?? item.properties?.id) === String(button.dataset.warningId));
    if (!feature) return showMessage('This warning record is no longer available. Refresh the list and try again.');
    locateFeature(feature, `${feature.properties?.warning_name || 'Warning record'} located — blue pin marks the selected position`);
  });
  $('#evidenceEventSelect')?.addEventListener('change', renderEvidenceReadiness);
  $('#evidenceLocateEvent')?.addEventListener('click', () => {
    const feature = pollutionFeatureById($('#evidenceEventSelect')?.value);
    if (feature) locateFeature(feature, `${feature.properties?.event_id || 'Event'} located for record review`);
  });
  $('#downloadDraftSummary')?.addEventListener('click', downloadDraftSummary);
  $('#detailClose').addEventListener('click', clearSelectedVessel);
  $('#searchForm').addEventListener('submit', event => {
    event.preventDefault();
    const query = $('#shipSearch').value.trim();
    if (query) searchVessel(query).catch(error => showMessage(error.message));
  });
}

function initializeMapLayers() {
  if (mapLayersReady || mapLayersInitializing) return;
  const style = map.getStyle();
  if (!style?.layers?.some(layer => layer.id === 'osm')) return;

  mapLayersInitializing = true;
  try {
    registerShipImages();
    addOperationalLayers();
    addVesselLayers();
    mapLayersReady = true;
    applyTypeFilter();
    updateTrackSelectionStatus();
  } catch (error) {
    console.error('Unable to initialize business map layers', error);
  } finally {
    mapLayersInitializing = false;
  }
}

function initMap() {
  map = new maplibregl.Map({
    container: 'map',
    style: rasterStyle(),
    center: HOME.center,
    zoom: HOME.zoom,
    minZoom: 3.5,
    maxZoom: 15,
    // Ignore small hand movements during a normal left click. Intentional
    // dragging still works after the pointer moves beyond this threshold.
    clickTolerance: MAP_CLICK_TOLERANCE_PX,
    attributionControl: true
  });
  // A double click on a dense vessel symbol used to zoom around the pointer,
  // which looked like the basemap moved after selecting a vessel.
  map.doubleClickZoom.disable();
  map.addControl(new maplibregl.NavigationControl({ showCompass:true }), 'top-right');
  map.addControl(new maplibregl.ScaleControl({ maxWidth:120, unit:'nautical' }), 'bottom-right');
  map.on('mousemove', event => {
    $('#mouseCoordinates').textContent = `${event.lngLat.lat.toFixed(4)}° N, ${event.lngLat.lng.toFixed(4)}° E`;
  });
  map.on('zoom', () => {
    setText('#mapZoom', `Z ${map.getZoom().toFixed(1)}`);
    syncAutomaticBasemap();
  });
  bindControls();

  map.on('styledata', initializeMapLayers);
  map.once('style.load', initializeMapLayers);

  // Business data is local and must not wait for external basemap tiles.
  refreshPlatformData({ initial: true });
  startAutoRefresh();
}

document.addEventListener('visibilitychange', () => {
  if (!document.hidden && map?.loaded()) refreshPlatformData();
});

window.addEventListener('beforeunload', () => {
  if (refreshTimer !== null) clearInterval(refreshTimer);
  if (clockTimer !== null) clearInterval(clockTimer);
});

startClock();
initMap();
