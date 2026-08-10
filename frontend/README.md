# Formal Frontend — Stage 1

This is a new frontend built for the real `Oman_Oil_Monitor` database. It does not reuse the earlier static demonstration interface.

Implemented in stage 1:

- Real OpenStreetMap basemap
- Live loading from `GET /api/ships`
- All `ship_position` records rendered as directional vessel symbols
- Vessel type colors and filters
- Ship name / MMSI search through the API
- Click-to-open vessel details
- API and record status display

Historical tracks, pollution events, risk areas, and the incident archive are intentionally disabled until their database structures are verified.

To open the current development platform, double-click `..\start_platform.bat`.
