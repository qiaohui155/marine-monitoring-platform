# Oman Marine Monitoring Dashboard

This frontend is the browser-based operational screen for the local Oman marine monitoring platform. It uses MapLibre GL JS and reads all business data from the local FastAPI service at `http://127.0.0.1:8000`.

## Current functions

- Live AIS vessel positions with course-oriented symbols
- Overview vessel symbols below zoom 9 and type colors at detailed zoom levels
- Vessel name and MMSI search
- Vessel type filters and layer controls
- Historical vessel tracks
- Pollution events, sea-risk areas, suspected vessels, and warning areas
- Dynamic dashboard statistics, risk signals, incident status, and recent events
- Automatic API refresh every 5 seconds
- Stable map selection: small pointer movement during a click no longer pans the map, and double-click zoom is disabled
- Smooth movement from the previous real AIS coordinate to each newly received coordinate
- Centered, light vessel-detail windows with draggable headers and automatic navigation-status classification
- Four switchable basemaps, including pure satellite imagery and a satellite hybrid with boundaries and place labels
- Automatic default basemap by vessel-detail zoom: Standard Map below zoom 9 and Satellite Hybrid from zoom 9, aligned with the switch from overview vessels to type-coloured vessel symbols
- Full-screen map workspace with compact left and right toolbars
- Independent floating business panels with drag, minimize, hide, close, multi-window, and viewport-boundary support
- Unified medium-large blue-and-white business dialogs for modules 01–03, 05–09, and the live statistics summary, with enlarged readable typography
- Satellite data-readiness panel for reference imagery, pollution footprints, SAR/optical product access, and observation-target status
- Event-based nearby-vessel screening that ranks current positions by distance and highlights vessels already on the suspected-vessel list
- Alert and response center with warning totals, priority levels, map location, and external-channel configuration status
- Evidence and report workspace with record-completeness checks, event location, and downloadable review-draft summaries

Modules 10–13 use the records currently returned by the local API. Functions that require dedicated satellite products, external message gateways, or an analyst approval workflow are shown as pending until those services are configured.

## Main files

- `index.html` — dashboard structure, panels, controls, and labels
- `styles.css` — responsive business-screen layout, colors, and visual styling
- `app.js` — map rendering, API calls, statistics, filtering, and interaction
- `floating-panels.js` — reusable floating-panel state, drag, focus, window controls, and boundary management

To run the complete local platform, double-click `..\start_platform.bat` and open `http://127.0.0.1:5173/`.
