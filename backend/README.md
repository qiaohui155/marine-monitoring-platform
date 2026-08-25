# Oman Marine Monitoring API and AIS services

This backend uses the existing `Oman_Oil_Monitor` PostgreSQL/PostGIS database.
The HTTP API is read-only. Optional AIS services can update vessel positions and
append historical track points.

## Confirmed source

- Host: `localhost`
- Port: `5432`
- Database: `Oman_Oil_Monitor`
- Schema/table: `public.ship_position`
- Geometry: `Point`, EPSG:4326
- Primary key: `id`
- Current feature count observed in QGIS: 3,960

## First-time setup

1. Double-click `configure_database.bat` and type the local PostgreSQL password. It will configure and test the existing database without changing any data.
2. Double-click `start_backend.bat`.
3. Open `http://127.0.0.1:8000/docs`.

## Implemented endpoints

- `GET /api/health`
- `GET /api/ships`
- `GET /api/ships/{mmsi}`
- `GET /api/tracks`
- `GET /api/ships/{mmsi}/track`
- `GET /api/pollution-events`
- `GET /api/pollution-events/{event_id}`
- `GET /api/risk-areas`
- `GET /api/risk-areas/{risk_id}`
- `GET /api/suspicious-ships`
- `GET /api/suspicious-ships/{ship_id}`
- `GET /api/warnings`
- `GET /api/warnings/{warning_id}`
- `GET /api/dashboard/summary`

The HTTP API is read-only. Map layers are returned as GeoJSON and are sourced from
PostGIS. A separate optional ShipXY collector can update real vessel positions and
append their historical track points.

## Simulated AIS movement

After migrations `003_add_simulated_ais_motion.sql` and
`004_replace_shipping_routes_ocean_only.sql` are applied, run:

`python -m app.simulated_ais --once --dry-run`

This validates one cycle without changing PostgreSQL. Set the local `.env` values
`SIMULATED_AIS_AUTO_START=true` and `SIMULATED_AIS_TARGET_DB=Oman_Oil_Monitor` to
start the service with `start_platform.bat`. The default staged rollout moves the
100 routed vessels closest to a route, updates them every 15 seconds, and appends
history at a filtered interval. Increase `SIMULATED_AIS_MAX_VESSELS` only after the
first group has been checked on the map.

## Optional real ShipXY AIS collection

1. Run `setup_backend.ps1` once after this update to install the `requests` package.
2. Double-click `configure_shipxy.bat`, then enter a ShipXY API key and one or more
   MMSI numbers separated by commas. Press Enter at the MMSI prompt to use `357867000`.
   The secret is stored only in the local `.env`.
3. Double-click `start_shipxy_ingest.bat` and keep that window open while collecting.
4. Close the collector window or press Ctrl+C to stop it.

For each queried MMSI, the collector updates the latest row in `ship_position` and
adds filtered historical points to `ship_track`. The existing `ship_track_lines`
view and frontend will therefore reflect new database data automatically. The
collector is deliberately separate from `start_platform.bat` so opening the map
does not unexpectedly consume ShipXY API quota.
