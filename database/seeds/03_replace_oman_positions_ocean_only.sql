-- Replace ONLY the previously appended OMAN-* positions.
-- The original 3,000 ship_position records are preserved.
-- This version keeps all new positions on the offshore side of Oman's coast,
-- from the Strait of Hormuz / Muscat to Duqm and Salalah.

BEGIN;

DELETE FROM ship_position
WHERE ship_name LIKE 'OMAN-%';

WITH
base_mmsi AS (
  SELECT coalesce(max(mmsi::bigint), 470002999) AS last_mmsi
  FROM ship_position
),
-- 240 sea-facing port/anchorage points: Duqm and Salalah centres are placed
-- offshore first, then spread only toward the open sea (never inland).
anchorages(name, lon0, lat0, mean_km, sea_bearing, fan_degrees, range_lo, range_hi) AS (
  VALUES
    ('Duqm offshore anchorage',    57.90, 19.70, 7.0, 100.0,  90.0, 0.00, 0.60),
    ('Salalah offshore anchorage', 54.20, 16.84, 7.5, 185.0, 100.0, 0.60, 1.01)
),
anchorage_noise AS MATERIALIZED (
  SELECT generate_series(1, 240) AS local_id,
         random() AS pick_anchor, random() AS u_radius, random() AS u_angle,
         random() AS u_type, random() AS u_speed, random() AS u_course
),
anchorage_points AS (
  SELECT n.local_id, 'Oman anchorage'::text AS source,
         a.lon0 + (1.2 - ln(greatest(1.0 - n.u_radius, 0.000001)) * a.mean_km)
                    * sin(radians(a.sea_bearing + (n.u_angle - 0.5) * a.fan_degrees))
                    / (111.32 * cos(radians(a.lat0))) AS longitude,
         a.lat0 + (1.2 - ln(greatest(1.0 - n.u_radius, 0.000001)) * a.mean_km)
                    * cos(radians(a.sea_bearing + (n.u_angle - 0.5) * a.fan_degrees))
                    / 111.32 AS latitude,
         CASE WHEN n.u_type < 0.39 THEN 'Tanker'
              WHEN n.u_type < 0.70 THEN 'Cargo'
              WHEN n.u_type < 0.89 THEN 'Fishing'
              ELSE 'Passenger' END AS ship_type,
         n.u_speed, n.u_course * 360.0 AS course
  FROM anchorage_noise n
  JOIN anchorages a ON n.pick_anchor >= a.range_lo AND n.pick_anchor < a.range_hi
),

-- These centre-lines are already 15--40 km offshore.  Their small (2--7 km)
-- lateral drift is deliberately much narrower than their distance from land.
-- They cover the complete Omani coastline: north coast, Masirah/Duqm, Salalah.
offshore_routes(route_id, range_lo, range_hi, route_geom) AS (
  VALUES
    (1, 0.00, 0.37, ST_GeomFromText(
      'LINESTRING(57.15 24.86,57.63 24.55,58.15 24.19,58.70 23.82,59.22 23.42,59.72 22.98,60.12 22.62)', 4326)),
    (2, 0.37, 0.72, ST_GeomFromText(
      'LINESTRING(60.18 22.50,59.86 22.02,59.55 21.55,59.26 21.10,58.98 20.66,58.66 20.22,58.24 19.86)', 4326)),
    (3, 0.72, 1.01, ST_GeomFromText(
      'LINESTRING(58.05 19.67,57.48 19.12,56.82 18.57,56.08 18.03,55.32 17.45,54.45 16.88)', 4326))
),
corridor_noise AS MATERIALIZED (
  SELECT generate_series(1, 270) AS local_id,
         random() AS pick_route, random() AS u_t, random() AS u_width,
         random() AS u_z1, random() AS u_z2, random() AS u_type,
         random() AS u_speed, random() AS u_course
),
corridor_anchor AS (
  SELECT n.*, r.route_geom, 0.02 + 0.96 * n.u_t AS t,
         sign(cos(2.0 * pi() * n.u_z2))
           * least(sqrt(-2.0 * ln(greatest(n.u_z1, 0.000001))), 1.8)
           * (2.0 + 5.0 * n.u_width) AS cross_km
  FROM corridor_noise n
  JOIN offshore_routes r ON n.pick_route >= r.range_lo AND n.pick_route < r.range_hi
),
corridor_tangent AS (
  SELECT *, ST_LineInterpolatePoint(route_geom, t) AS centre_pt,
         ST_LineInterpolatePoint(route_geom, greatest(0.0, t - 0.007)) AS prev_pt,
         ST_LineInterpolatePoint(route_geom, least(1.0, t + 0.007)) AS next_pt
  FROM corridor_anchor
),
corridor_points AS (
  SELECT local_id, 'Oman offshore corridor'::text AS source,
         ST_X(centre_pt) - (ST_Y(next_pt) - ST_Y(prev_pt))
           / nullif(sqrt(power(ST_X(next_pt) - ST_X(prev_pt), 2)
                       + power(ST_Y(next_pt) - ST_Y(prev_pt), 2)), 0)
           * cross_km / (111.32 * cos(radians(ST_Y(centre_pt)))) AS longitude,
         ST_Y(centre_pt) + (ST_X(next_pt) - ST_X(prev_pt))
           / nullif(sqrt(power(ST_X(next_pt) - ST_X(prev_pt), 2)
                       + power(ST_Y(next_pt) - ST_Y(prev_pt), 2)), 0)
           * cross_km / 111.32 AS latitude,
         CASE WHEN u_type < 0.50 THEN 'Cargo'
              WHEN u_type < 0.82 THEN 'Tanker'
              WHEN u_type < 0.91 THEN 'Passenger'
              ELSE 'Fishing' END AS ship_type,
         u_speed,
         mod((degrees(ST_Azimuth(prev_pt, next_pt)) + (u_course - 0.5) * 14.0 + 360.0)::numeric,
             360::numeric)::double precision AS course
  FROM corridor_tangent
),

-- Curved, local offshore activity clouds.  Each fan opens seaward, which gives
-- port/approach density without spilling onto the Omani mainland.
activity_centres(lon0, lat0, mean_km, sea_bearing, fan_degrees, range_lo, range_hi) AS (
  VALUES
    (58.82, 23.67, 10.0,  70.0,  85.0, 0.00, 0.22), -- Muscat offshore
    (60.08, 22.52, 11.0,  90.0,  95.0, 0.22, 0.42), -- Ras al Hadd offshore
    (59.22, 20.55, 12.0, 100.0, 100.0, 0.42, 0.65), -- Masirah offshore
    (57.96, 19.75, 11.0, 100.0,  90.0, 0.65, 0.84), -- Duqm offshore
    (54.25, 16.82, 11.0, 185.0, 100.0, 0.84, 1.01)  -- Salalah offshore
),
activity_noise AS MATERIALIZED (
  SELECT generate_series(1, 140) AS local_id,
         random() AS pick_centre, random() AS u_radius, random() AS u_angle,
         random() AS u_type, random() AS u_speed, random() AS u_course
),
activity_points AS (
  SELECT n.local_id, 'Oman local activity'::text AS source,
         c.lon0 + (2.0 - ln(greatest(1.0 - n.u_radius, 0.000001)) * c.mean_km)
                    * sin(radians(c.sea_bearing + (n.u_angle - 0.5) * c.fan_degrees))
                    / (111.32 * cos(radians(c.lat0))) AS longitude,
         c.lat0 + (2.0 - ln(greatest(1.0 - n.u_radius, 0.000001)) * c.mean_km)
                    * cos(radians(c.sea_bearing + (n.u_angle - 0.5) * c.fan_degrees))
                    / 111.32 AS latitude,
         CASE WHEN n.u_type < 0.44 THEN 'Tanker'
              WHEN n.u_type < 0.75 THEN 'Cargo'
              WHEN n.u_type < 0.91 THEN 'Fishing'
              ELSE 'Passenger' END AS ship_type,
         n.u_speed, n.u_course * 360.0 AS course
  FROM activity_noise n
  JOIN activity_centres c ON n.pick_centre >= c.range_lo AND n.pick_centre < c.range_hi
),

-- A few genuinely sparse points in the Arabian Sea, still well seaward of land.
offshore_noise AS MATERIALIZED (
  SELECT generate_series(1, 50) AS local_id,
         random() AS pick_cloud, random() AS u1, random() AS u2,
         random() AS u_type, random() AS u_speed, random() AS u_course
),
offshore_points AS (
  SELECT local_id, 'Arabian Sea sparse'::text AS source,
         CASE WHEN pick_cloud < 0.50 THEN 59.15 ELSE 56.15 END
           + CASE WHEN pick_cloud < 0.50 THEN 0.38 ELSE 0.42 END
             * sqrt(-2.0 * ln(greatest(u1, 0.000001))) * cos(2.0 * pi() * u2) AS longitude,
         CASE WHEN pick_cloud < 0.50 THEN 20.55 ELSE 17.65 END
           + CASE WHEN pick_cloud < 0.50 THEN 0.30 ELSE 0.22 END
             * sqrt(-2.0 * ln(greatest(u1, 0.000001))) * sin(2.0 * pi() * u2) AS latitude,
         CASE WHEN u_type < 0.50 THEN 'Cargo'
              WHEN u_type < 0.77 THEN 'Tanker'
              WHEN u_type < 0.91 THEN 'Fishing'
              ELSE 'Passenger' END AS ship_type,
         u_speed, u_course * 360.0 AS course
  FROM offshore_noise
),
all_new_points AS (
  SELECT * FROM anchorage_points
  UNION ALL SELECT * FROM corridor_points
  UNION ALL SELECT * FROM activity_points
  UNION ALL SELECT * FROM offshore_points
),
numbered AS (
  SELECT row_number() OVER (ORDER BY source, local_id) AS vessel_no, *
  FROM all_new_points
)
INSERT INTO ship_position
  (mmsi, ship_name, ship_type, speed, course, update_time, longitude, latitude, geom)
SELECT
  base_mmsi.last_mmsi + vessel_no AS mmsi,
  'OMAN-' || upper(ship_type) || '-' || lpad(vessel_no::text, 3, '0') AS ship_name,
  ship_type,
  round(least(22.0, greatest(0.0,
    CASE ship_type
      WHEN 'Tanker' THEN 1.0 + 14.0 * u_speed
      WHEN 'Cargo' THEN 3.0 + 16.0 * u_speed
      WHEN 'Passenger' THEN 4.0 + 17.0 * u_speed
      ELSE 0.2 + 8.0 * u_speed
    END))::numeric, 1) AS speed,
  round(mod((course + 360.0)::numeric, 360::numeric), 1) AS course,
  now() - random() * interval '12 hours' AS update_time,
  round(longitude::numeric, 6) AS longitude,
  round(latitude::numeric, 6) AS latitude,
  ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
FROM numbered
CROSS JOIN base_mmsi;

COMMIT;

-- Validation: 700 OMAN-* positions, all newly placed on the seaward side.
-- SELECT count(*) FROM ship_position WHERE ship_name LIKE 'OMAN-%';
