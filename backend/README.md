# Oman Marine Monitoring API - read-only PostGIS service

This backend uses the existing `Oman_Oil_Monitor` PostgreSQL/PostGIS database. It does not modify database data.

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
