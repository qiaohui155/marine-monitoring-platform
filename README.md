# Oman Marine Monitoring Platform

Local GIS monitoring prototype built with PostgreSQL/PostGIS, FastAPI, MapLibre GL JS,
and optional ShipXY AIS collection.

## Project structure

- `frontend/` - browser-based vessel and pollution map
- `backend/` - read-only HTTP API plus optional AIS collector
- `database/` - versioned schema, simulation seeds, and migrations
- `start_platform.bat` - starts the API, optional live AIS collector, and frontend
- `restart_platform.bat` - safely restarts all local platform services

## Local startup

1. Ensure PostgreSQL 16 is running and `backend/.env` is configured locally.
2. Double-click `start_platform.bat`.
3. Open `http://127.0.0.1:5173`.

To start real AIS collection with the platform, configure ShipXY locally and set
`SHIPXY_AUTO_START=true` plus `SHIPXY_TARGET_DB=<live database>` in `backend/.env`.
Only new coordinates received from the provider are animated on the map.

## Security

`backend/.env`, virtual environments, database backups, and large raster files are
ignored by Git. Never commit database passwords or API keys. PostgreSQL data is
backed up separately under `D:\oman\database-backup`.

See `database/README.md` before changing or regenerating database data.
