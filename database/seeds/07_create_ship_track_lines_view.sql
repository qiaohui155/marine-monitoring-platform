-- Convert the historical AIS samples into one displayable line per ship.
-- Run once after regenerate_long_oman_ship_tracks.sql, then add this VIEW to QGIS as
-- a PostGIS layer.  mmsi is a unique identifier for the resulting line layer.

-- DROP is required because PostgreSQL does not allow CREATE OR REPLACE VIEW
-- to change an existing result column from generic geometry to LineString.
-- It removes only the view definition, never the underlying ship_track rows.
DROP VIEW IF EXISTS ship_track_lines;

CREATE VIEW ship_track_lines AS
SELECT
  mmsi,
  max(ship_name) AS ship_name,
  max(ship_type) AS ship_type,
  min(update_time) AS start_time,
  max(update_time) AS end_time,
  count(*) AS point_count,
  ST_MakeLine(geom ORDER BY update_time)::geometry(LineString, 4326) AS geom
FROM ship_track
GROUP BY mmsi
HAVING count(*) >= 2;

-- Optional: create a spatial index only if ship_track is large.
-- CREATE INDEX IF NOT EXISTS ship_track_geom_gix ON ship_track USING gist (geom);
