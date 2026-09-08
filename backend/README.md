# Oman Marine Monitoring API and AIS services

This backend connects to the PostgreSQL/PostGIS database selected by `DB_NAME` in
the local `.env`. HTTP endpoints are read-only; the optional AIS collector writes
new reports only when live collection is enabled.

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
PostGIS. The optional ShipXY collector can update real vessel positions and append
historical track points when that table is available.

The simulator is implemented in `app/simulated_ais.py`. After database migrations
003, 004, 005 and 006 have been applied, set `SIMULATED_AIS_AUTO_START=true`
in the local `.env`. The main `start_platform.bat` shortcut then starts it
automatically. Reviewed route matches follow shipping routes; remaining vessels move
locally around their existing sea positions so that every simulated vessel receives
a fresh AIS timestamp. Do not enable simulated and live ShipXY collection at the same time.

## Optional real ShipXY AIS collection

1. Run `setup_backend.ps1` once after this update to install the `requests` package.
2. Double-click `configure_shipxy.bat`, then enter a ShipXY API key and one or more
   MMSI numbers separated by commas. Press Enter at the MMSI prompt to use `357867000`.
   The secret is stored only in the local `.env`.
3. Set `SHIPXY_AUTO_START=true` and `SHIPXY_TARGET_DB` to the live AIS database in
   the local `.env` file.
4. Start or restart the platform. The collector runs in the background and writes
   logs under `backend/logs/`.

For each queried MMSI, the collector updates a writable `ship_position` table or
appends the report to `ais_position` when `ship_position` is a compatibility view.
The target-database guard prevents real AIS collection from accidentally writing
into another configured database. Set `SHIPXY_AUTO_START=false` to stop automatic
collection and avoid consuming ShipXY API quota. When ShipXY rejects a request or
the network fails, the collector automatically increases the retry interval up to
`SHIPXY_MAX_BACKOFF_SECONDS` instead of repeatedly consuming requests every 15 seconds.
