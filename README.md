# Oman Marine Monitoring Platform

Local GIS monitoring prototype built with PostgreSQL/PostGIS, FastAPI, MapLibre GL JS,
and optional ShipXY AIS collection.

## Project structure

- `frontend/` - browser-based vessel and pollution map
- `backend/` - read-only HTTP API plus optional live and simulated AIS services
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

For the local demonstration database, set `SIMULATED_AIS_AUTO_START=true` and
`SIMULATED_AIS_TARGET_DB=Oman_Oil_Monitor`. The same platform shortcut then refreshes
all simulated vessels every 15 seconds. Vessels close to reviewed routes follow those
routes; the others use small local sea-position circuits. Filtered history is written
only for route-reviewed vessels. Double-click `stop_simulated_ais.bat` before changing
routes or switching branches.

## Security

`backend/.env`, virtual environments, database backups, and large raster files are
ignored by Git. Never commit database passwords or API keys. PostgreSQL data is
backed up separately under `D:\oman\database-backup`.

See `database/README.md` before changing or regenerating database data.
