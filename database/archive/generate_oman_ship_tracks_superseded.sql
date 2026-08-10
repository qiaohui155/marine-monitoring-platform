-- Synthetic historical AIS tracks for the Gulf of Oman.
-- PostgreSQL 12+ / PostGIS required.
--
-- Selects 50 existing vessels from ship_position:
--   Tanker 15, Cargo 20, Fishing 10, Passenger 5
-- Each vessel has 40 positions at 10-minute intervals: 2,000 rows in total.
-- Rerunning this script replaces only this simulation's 08:00--14:30 samples,
-- preventing duplicate timestamps from creating false long lines in QGIS.

BEGIN;

DELETE FROM ship_track
WHERE update_time BETWEEN timestamp '2026-07-30 08:00:00'
                      AND timestamp '2026-07-30 14:30:00';

-- Some existing track tables were created before vessel categories were needed.
-- Add the required attribute once; IF NOT EXISTS makes rerunning this safe.
ALTER TABLE ship_track
  ADD COLUMN IF NOT EXISTS ship_type varchar(20);

WITH
-- Pick named vessels already present in the current AIS layer.  Each type has
-- more than the required number in the generated ship_position dataset.
ranked_vessels AS (
  SELECT mmsi, ship_name, ship_type,
         row_number() OVER (PARTITION BY ship_type ORDER BY mmsi) AS type_no
  FROM ship_position
  WHERE ship_type IN ('Tanker', 'Cargo', 'Fishing', 'Passenger')
),
selected_vessels AS (
  SELECT mmsi, ship_name, ship_type, type_no
  FROM ranked_vessels
  WHERE (ship_type = 'Tanker'    AND type_no <= 15)
     OR (ship_type = 'Cargo'     AND type_no <= 20)
     OR (ship_type = 'Fishing'   AND type_no <= 10)
     OR (ship_type = 'Passenger' AND type_no <= 5)
),
vessels AS (
  SELECT *, row_number() OVER (ORDER BY ship_type, mmsi) AS vessel_no
  FROM selected_vessels
),

-- Commercial ships travel only between adjacent, named waypoints during this
-- 6 h 30 min window.  A full Hormuz-to-Duqm passage takes much longer and is
-- therefore represented by several consecutive legs, not an impossible leap.
-- Fishing routes are short, curved near-coast loops.
-- No route is a straight two-point line.
routes(route_id, route_kind, route_geom) AS (
  VALUES
    (1, 'merchant', ST_GeomFromText(
      'LINESTRING(57.82 25.68,57.58 25.61,57.30 25.48,57.02 25.37,56.75 25.25,56.50 25.15)', 4326)),
    (2, 'merchant', ST_GeomFromText(
      'LINESTRING(56.52 25.13,56.57 24.96,56.66 24.77,56.77 24.59,56.86 24.45)', 4326)),
    (3, 'merchant', ST_GeomFromText(
      'LINESTRING(56.90 24.46,57.18 24.34,57.48 24.19,57.76 24.04,58.05 23.93)', 4326)),
    (4, 'merchant', ST_GeomFromText(
      'LINESTRING(58.08 23.93,58.25 23.85,58.43 23.75,58.60 23.67,58.77 23.62)', 4326)),
    (5, 'port', ST_GeomFromText(
      'LINESTRING(56.94 24.72,56.91 24.63,56.86 24.55,56.80 24.46)', 4326)),
    (6, 'port', ST_GeomFromText(
      'LINESTRING(58.90 23.75,58.82 23.70,58.72 23.65,58.60 23.62)', 4326)),
    (7, 'merchant', ST_GeomFromText(
      'LINESTRING(60.05 22.55,59.85 22.25,59.66 21.95,59.47 21.68)', 4326)),
    (8, 'port', ST_GeomFromText(
      'LINESTRING(58.05 19.93,57.94 19.85,57.84 19.77,57.74 19.69)', 4326)),
    (9, 'fishing', ST_GeomFromText(
      'LINESTRING(56.72 24.47,56.64 24.42,56.62 24.34,56.70 24.28,56.82 24.27,56.90 24.33,56.88 24.41,56.78 24.47)', 4326)),
    (10, 'fishing', ST_GeomFromText(
      'LINESTRING(58.43 23.72,58.37 23.66,58.40 23.57,58.51 23.54,58.61 23.59,58.64 23.68,58.55 23.74)', 4326)),
    (11, 'fishing', ST_GeomFromText(
      'LINESTRING(57.62 19.83,57.55 19.77,57.58 19.68,57.70 19.62,57.81 19.66,57.85 19.75,57.77 19.83)', 4326)),
    (12, 'port', ST_GeomFromText(
      'LINESTRING(57.87 25.06,57.62 25.02,57.36 24.94,57.08 24.84,56.82 24.73)', 4326))
),

-- Assign each vessel a different route/direction pattern.  Reversal represents
-- a port arrival instead of an outward passage; this avoids fake parallel pairs.
plans AS (
  SELECT v.*,
         CASE
           WHEN ship_type = 'Tanker' AND type_no % 5 IN (1, 4) THEN 1
           WHEN ship_type = 'Tanker' AND type_no % 5 = 2 THEN 2
           WHEN ship_type = 'Tanker' AND type_no % 5 = 3 THEN 12
           WHEN ship_type = 'Tanker' THEN 6
           WHEN ship_type = 'Cargo' AND type_no % 6 IN (1, 5) THEN 2
           WHEN ship_type = 'Cargo' AND type_no % 6 = 2 THEN 3
           WHEN ship_type = 'Cargo' AND type_no % 6 = 3 THEN 4
           WHEN ship_type = 'Cargo' AND type_no % 6 = 4 THEN 7
           WHEN ship_type = 'Cargo' THEN 12
           WHEN ship_type = 'Fishing' AND type_no % 3 = 1 THEN 9
           WHEN ship_type = 'Fishing' AND type_no % 3 = 2 THEN 10
           WHEN ship_type = 'Fishing' THEN 11
           WHEN type_no % 3 = 1 THEN 5
           WHEN type_no % 3 = 2 THEN 6
           ELSE 8
         END AS route_id,
         CASE
           WHEN ship_type = 'Fishing' THEN 1
           WHEN (vessel_no + type_no) % 2 = 0 THEN 1
           ELSE -1
         END AS direction,
         -- Per-vessel, deterministic phase/bias gives a smooth unique track,
         -- rather than 50 perfectly coincident copies of one centre-line.
         (0.17 + 0.48 * abs(sin(vessel_no * 2.731))) AS width_km,
         0.55 * sin(vessel_no * 1.913) AS lane_bias_km,
         abs(sin(vessel_no * 0.731)) AS phase
  FROM vessels v
),
planned_routes AS (
  SELECT p.*,
         r.route_kind,
         CASE WHEN p.direction = 1 THEN r.route_geom ELSE ST_Reverse(r.route_geom) END AS line_geom
  FROM plans p
  JOIN routes r ON r.route_id = p.route_id
),
time_steps AS (
  SELECT p.*, g.point_no,
         g.point_no / 39.0 AS t,
         timestamp '2026-07-30 08:00:00' + g.point_no * interval '10 minutes' AS update_time
  FROM planned_routes p
  CROSS JOIN generate_series(0, 39) AS g(point_no)
),
centre_points AS (
  SELECT *,
         ST_LineInterpolatePoint(line_geom, t) AS centre_pt,
         ST_LineInterpolatePoint(line_geom, greatest(0.0, t - 0.012)) AS prev_centre,
         ST_LineInterpolatePoint(line_geom, least(1.0, t + 0.012)) AS next_centre
  FROM time_steps
),
offset_points AS (
  SELECT *,
         -- Smooth lateral movement: ships have a stable lane preference plus
         -- gentle helm/current drift. Fishing vessels use a slightly livelier
         -- oscillation while staying in their small coastal grounds.
         lane_bias_km
           + width_km * CASE WHEN route_kind = 'fishing'
                              THEN 0.68 * sin(2.0 * pi() * (2.7 * t + phase))
                                 + 0.20 * sin(2.0 * pi() * (5.1 * t + phase))
                              ELSE 0.43 * sin(2.0 * pi() * (1.35 * t + phase))
                                 + 0.15 * sin(2.0 * pi() * (3.10 * t + phase))
                         END AS cross_km
  FROM centre_points
),
track_xy AS (
  SELECT mmsi, ship_name, ship_type, point_no, update_time,
         ST_X(centre_pt)
           + (-1.0 * (ST_Y(next_centre) - ST_Y(prev_centre))
              / nullif(sqrt(power(ST_X(next_centre) - ST_X(prev_centre), 2)
                          + power(ST_Y(next_centre) - ST_Y(prev_centre), 2)), 0))
             * cross_km / (111.32 * cos(radians(ST_Y(centre_pt)))) AS longitude,
         ST_Y(centre_pt)
           + ((ST_X(next_centre) - ST_X(prev_centre))
              / nullif(sqrt(power(ST_X(next_centre) - ST_X(prev_centre), 2)
                          + power(ST_Y(next_centre) - ST_Y(prev_centre), 2)), 0))
             * cross_km / 111.32 AS latitude
  FROM offset_points
),
track_geom AS (
  SELECT *, ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
  FROM track_xy
),
motion AS (
  SELECT *,
         lead(geom) OVER vessel_window AS next_geom,
         lag(geom)  OVER vessel_window AS prev_geom
  FROM track_geom
  WINDOW vessel_window AS (PARTITION BY mmsi ORDER BY point_no)
)
INSERT INTO ship_track
  (mmsi, ship_name, ship_type, longitude, latitude, speed, course, update_time, geom)
SELECT
  mmsi,
  ship_name,
  ship_type,
  round(longitude::numeric, 6) AS longitude,
  round(latitude::numeric, 6) AS latitude,
  round(least(22.0, greatest(0.0,
    CASE WHEN next_geom IS NOT NULL
         THEN ST_DistanceSphere(geom, next_geom) / 1852.0 * 6.0
         ELSE ST_DistanceSphere(prev_geom, geom) / 1852.0 * 6.0
    END))::numeric, 1) AS speed,
  round(mod((degrees(CASE WHEN next_geom IS NOT NULL
                           THEN ST_Azimuth(geom, next_geom)
                           ELSE ST_Azimuth(prev_geom, geom)
                      END) + 360.0)::numeric, 360::numeric), 1) AS course,
  update_time,
  -- Required WGS 84 geometry expression, ready for QGIS.
  ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
FROM motion
ORDER BY mmsi, point_no;

COMMIT;

-- Validation (should return 50 vessels and 2,000 points):
-- SELECT ship_type, count(DISTINCT mmsi) AS ships, count(*) AS track_points
-- FROM ship_track
-- WHERE update_time BETWEEN timestamp '2026-07-30 08:00:00'
--                       AND timestamp '2026-07-30 14:30:00'
-- GROUP BY ship_type ORDER BY ship_type;
