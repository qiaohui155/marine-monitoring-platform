# Oman Marine Monitoring Platform

Local GIS monitoring prototype built with PostgreSQL/PostGIS, FastAPI, MapLibre GL JS,
and optional ShipXY AIS collection.

## Project structure

- `frontend/` - browser-based vessel and pollution map
- `backend/` - HTTP API plus real and simulated AIS services
- `database/` - versioned schema, simulation seeds, and migrations
- `start_platform.bat` - starts the API and frontend locally

## Local startup

1. Ensure PostgreSQL 16 is running and `backend/.env` is configured locally.
2. Double-click `start_platform.bat`.
3. Open `http://127.0.0.1:5173`.

When `SIMULATED_AIS_AUTO_START=true`, the same shortcut also starts the local
simulated AIS movement service. It updates routed vessels every 15 seconds and
builds filtered history in `ship_track`. Runtime details are written to
`backend/logs/simulated_ais.log`.

Real AIS collection is separate. Configure it with
`backend/configure_shipxy.bat`, then run `backend/start_shipxy_ingest.bat`.

## Security

`backend/.env`, virtual environments, database backups, and large raster files are
ignored by Git. Never commit database passwords or API keys. PostgreSQL data is
backed up separately under `D:\oman\database-backup`.

See `database/README.md` before changing or regenerating database data.
