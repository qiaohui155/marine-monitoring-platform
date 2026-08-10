-- Long, smooth, sea-only AIS history simulation for Oman.
-- Replaces ship_track with 50 vessels x 217 observations = 10,850 records.
-- Time range: 2026-07-28 20:00 through 2026-07-30 08:00, every 10 minutes.
--
-- IMPORTANT: This intentionally clears ship_track because it regenerates the
-- complete simulated history layer.  It does not modify ship_position.

BEGIN;

DELETE FROM ship_track;

ALTER TABLE ship_track
  ADD COLUMN IF NOT EXISTS ship_type varchar(20);

WITH
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
-- All merchant paths are safely offshore and connect successive meaningful
-- waypoints.  ST_ChaikinSmoothing removes sharp polyline corners.
-- Routes 6--10 are closed near-coast circuits for fishing / passenger traffic.
route_templates(route_id, route_kind, route_geom) AS (
  VALUES
    (1, 'merchant', ST_GeomFromText(
      'LINESTRING(57.86 25.70,57.58 25.61,57.28 25.48,57.00 25.37,56.75 25.25,56.53 25.15,56.65 24.88,56.88 24.60,57.35 24.32,57.88 24.04,58.45 23.78,58.84 23.65,59.25 23.32,59.65 22.88,60.02 22.50,59.72 22.03,59.32 21.52,58.92 20.95,58.50 20.40,58.08 19.98,57.76 19.75)', 4326)),
    (2, 'merchant', ST_GeomFromText(
      'LINESTRING(57.76 19.75,58.08 19.98,58.50 20.40,58.92 20.95,59.32 21.52,59.72 22.03,60.02 22.50,59.65 22.88,59.25 23.32,58.84 23.65,58.45 23.78,57.88 24.04,57.35 24.32,56.88 24.60,56.65 24.88,56.53 25.15,56.75 25.25,57.00 25.37,57.28 25.48,57.58 25.61,57.86 25.70)', 4326)),
    (3, 'merchant', ST_GeomFromText(
      'LINESTRING(56.98 25.31,56.78 25.11,56.72 24.88,56.84 24.64,57.14 24.43,57.52 24.22,57.94 24.03,58.36 23.85,58.76 23.68,59.15 23.40,59.54 22.99,59.88 22.55)', 4326)),
    (4, 'merchant', ST_GeomFromText(
      'LINESTRING(60.05 22.52,59.82 22.18,59.60 21.83,59.37 21.47,59.14 21.12,58.91 20.78,58.67 20.45,58.41 20.16,58.10 19.92,57.78 19.75)', 4326)),
    (5, 'merchant', ST_GeomFromText(
      'LINESTRING(57.82 19.72,57.48 19.30,57.08 18.95,56.66 18.60,56.22 18.25,55.78 17.91,55.32 17.55,54.86 17.20,54.38 16.92)', 4326)),
    (6, 'fishing', ST_GeomFromText(
      'LINESTRING(56.98 24.52,56.91 24.44,56.89 24.33,56.98 24.26,57.11 24.28,57.17 24.37,57.13 24.47,56.98 24.52)', 4326)),
    (7, 'fishing', ST_GeomFromText(
      'LINESTRING(58.76 23.73,58.69 23.65,58.73 23.55,58.86 23.51,58.97 23.57,58.99 23.67,58.90 23.75,58.76 23.73)', 4326)),
    (8, 'fishing', ST_GeomFromText(
      'LINESTRING(57.95 19.82,57.88 19.75,57.91 19.65,58.04 19.60,58.16 19.65,58.19 19.75,58.10 19.83,57.95 19.82)', 4326)),
    (9, 'passenger', ST_GeomFromText(
      'LINESTRING(56.96 24.63,56.87 24.55,56.82 24.46,56.88 24.38,57.00 24.40,57.08 24.49,57.05 24.58,56.96 24.63)', 4326)),
    (10, 'passenger', ST_GeomFromText(
      'LINESTRING(58.84 23.77,58.73 23.70,58.63 23.63,58.67 23.55,58.79 23.51,58.91 23.57,58.96 23.68,58.84 23.77)', 4326))
),
plans AS (
  SELECT v.*,
         CASE
           WHEN ship_type = 'Tanker' AND type_no % 5 IN (1, 4) THEN 1
           WHEN ship_type = 'Tanker' AND type_no % 5 = 2 THEN 2
           WHEN ship_type = 'Tanker' AND type_no % 5 = 3 THEN 3
           WHEN ship_type = 'Tanker' THEN 4
           WHEN ship_type = 'Cargo' AND type_no % 5 IN (1, 4) THEN 1
           WHEN ship_type = 'Cargo' AND type_no % 5 = 2 THEN 2
           WHEN ship_type = 'Cargo' AND type_no % 5 = 3 THEN 3
           WHEN ship_type = 'Cargo' THEN 5
           WHEN ship_type = 'Fishing' AND type_no % 3 = 1 THEN 6
           WHEN ship_type = 'Fishing' AND type_no % 3 = 2 THEN 7
           WHEN ship_type = 'Fishing' THEN 8
           WHEN type_no % 2 = 1 THEN 9
           ELSE 10
         END AS route_id,
         -- Each vessel holds a small, smooth, persistent lane offset.  It is
         -- far smaller than the route's offshore clearance from the coastline.
         0.10 + 0.22 * abs(sin(vessel_no * 2.731)) AS width_km,
         0.16 * sin(vessel_no * 1.913) AS lane_bias_km,
         abs(sin(vessel_no * 0.731)) AS phase
  FROM vessels v
),
smooth_routes AS (
  SELECT p.*, r.route_kind,
         ST_ChaikinSmoothing(r.route_geom, 3, true) AS line_geom
  FROM plans p
  JOIN route_templates r ON r.route_id = p.route_id
),
time_steps AS (
  SELECT p.*, g.point_no,
         CASE WHEN p.route_kind IN ('fishing', 'passenger')
              THEN mod(g.point_no / 216.0 * CASE WHEN p.route_kind = 'fishing' THEN 3.0 ELSE 2.0 END, 1.0)
              ELSE g.point_no / 216.0 END AS t,
         timestamp '2026-07-28 20:00:00' + g.point_no * interval '10 minutes' AS update_time
  FROM smooth_routes p
  CROSS JOIN generate_series(0, 216) AS g(point_no)
),
centre_points AS (
  SELECT *,
         ST_LineInterpolatePoint(line_geom, t) AS centre_pt,
         ST_LineInterpolatePoint(line_geom, greatest(0.0, t - 0.003)) AS prev_centre,
         ST_LineInterpolatePoint(line_geom, least(1.0, t + 0.003)) AS next_centre
  FROM time_steps
),
offset_points AS (
  SELECT *, lane_bias_km
           + width_km * CASE WHEN route_kind = 'fishing'
                              THEN 0.72 * sin(2.0 * pi() * (2.4 * t + phase))
                                 + 0.16 * sin(2.0 * pi() * (5.0 * t + phase))
                              WHEN route_kind = 'passenger'
                              THEN 0.30 * sin(2.0 * pi() * (1.5 * t + phase))
                              ELSE 0.32 * sin(2.0 * pi() * (1.1 * t + phase))
                                 + 0.10 * sin(2.0 * pi() * (2.7 * t + phase))
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
  SELECT *, lead(geom) OVER vessel_window AS next_geom,
         lag(geom) OVER vessel_window AS prev_geom
  FROM track_geom
  WINDOW vessel_window AS (PARTITION BY mmsi ORDER BY point_no)
)
INSERT INTO ship_track
  (mmsi, ship_name, ship_type, longitude, latitude, speed, course, update_time, geom)
SELECT
  mmsi, ship_name, ship_type,
  round(longitude::numeric, 6),
  round(latitude::numeric, 6),
  round(least(22.0, greatest(0.0,
    CASE WHEN next_geom IS NOT NULL
         THEN ST_DistanceSphere(geom, next_geom) / 1852.0 * 6.0
         ELSE ST_DistanceSphere(prev_geom, geom) / 1852.0 * 6.0 END))::numeric, 1) AS speed,
  round(mod((degrees(CASE WHEN next_geom IS NOT NULL
                           THEN ST_Azimuth(geom, next_geom)
                           ELSE ST_Azimuth(prev_geom, geom) END) + 360.0)::numeric,
            360::numeric), 1) AS course,
  update_time,
  ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
FROM motion
ORDER BY mmsi, point_no;

COMMIT;

-- Validation: 50 vessels, 10,850 points, 217 points/vessel.
-- SELECT ship_type, count(DISTINCT mmsi) AS ships, count(*) AS positions
-- FROM ship_track GROUP BY ship_type ORDER BY ship_type;
