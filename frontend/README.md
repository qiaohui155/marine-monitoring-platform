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
- Automatic API refresh every 15 seconds
- Smooth movement from the previous real AIS coordinate to each newly received coordinate
- Full-screen map workspace with compact left and right toolbars
- Independent floating business panels with drag, minimize, hide, close, multi-window, and viewport-boundary support

## Main files

- `index.html` — dashboard structure, panels, controls, and labels
- `styles.css` — responsive business-screen layout, colors, and visual styling
- `app.js` — map rendering, API calls, statistics, filtering, and interaction
- `floating-panels.js` — reusable floating-panel state, drag, focus, window controls, and boundary management

To run the complete local platform, double-click `..\start_platform.bat` and open `http://127.0.0.1:5173/`.
