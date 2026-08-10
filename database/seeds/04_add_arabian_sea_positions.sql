-- APPEND-ONLY: sparse AIS positions in the Arabian Sea east of Oman.
-- Adds 360 vessels; does not delete or modify any existing ship_position row.
-- The points use a diffuse curved shipping corridor plus irregular offshore
-- clouds, deliberately avoiding a rectangular or uniformly filled pattern.

WITH
base_mmsi AS (
  SELECT coalesce(max(mmsi::bigint), 470002999) AS last_mmsi
  FROM ship_position
),
-- A broad Arabian Sea route, well offshore of Oman and the Makran coast.
sea_route AS (
  SELECT ST_GeomFromText(
    'LINESTRING(60.28 22.36,61.05 22.16,61.84 21.91,62.62 21.66,63.43 21.39,64.28 21.06,65.12 20.67)',
    4326) AS route_geom
),
route_noise AS MATERIALIZED (
  SELECT generate_series(1, 140) AS local_id,
         random() AS u_t, random() AS u_width, random() AS u_z1,
         random() AS u_z2, random() AS u_type, random() AS u_speed,
         random() AS u_course
),
route_anchor AS (
  SELECT n.*, r.route_geom, 0.02 + 0.96 * n.u_t AS t,
         sign(cos(2.0 * pi() * n.u_z2))
           * least(sqrt(-2.0 * ln(greatest(n.u_z1, 0.000001))), 2.0)
           * (5.0 + 10.0 * n.u_width) AS cross_km
  FROM route_noise n CROSS JOIN sea_route r
),
route_tangent AS (
  SELECT *, ST_LineInterpolatePoint(route_geom, t) AS centre_pt,
         ST_LineInterpolatePoint(route_geom, greatest(0.0, t - 0.006)) AS prev_pt,
         ST_LineInterpolatePoint(route_geom, least(1.0, t + 0.006)) AS next_pt
  FROM route_anchor
),
route_points AS (
  SELECT local_id, 'Arabian Sea route'::text AS source,
         ST_X(centre_pt) - (ST_Y(next_pt) - ST_Y(prev_pt))
           / nullif(sqrt(power(ST_X(next_pt) - ST_X(prev_pt), 2)
                       + power(ST_Y(next_pt) - ST_Y(prev_pt), 2)), 0)
           * cross_km / (111.32 * cos(radians(ST_Y(centre_pt)))) AS longitude,
         ST_Y(centre_pt) + (ST_X(next_pt) - ST_X(prev_pt))
           / nullif(sqrt(power(ST_X(next_pt) - ST_X(prev_pt), 2)
                       + power(ST_Y(next_pt) - ST_Y(prev_pt), 2)), 0)
           * cross_km / 111.32 AS latitude,
         CASE WHEN u_type < 0.52 THEN 'Cargo'
              WHEN u_type < 0.86 THEN 'Tanker'
              WHEN u_type < 0.94 THEN 'Passenger'
              ELSE 'Fishing' END AS ship_type,
         u_speed,
         mod((degrees(ST_Azimuth(prev_pt, next_pt)) + (u_course - 0.5) * 18.0 + 360.0)::numeric,
             360::numeric)::double precision AS course
  FROM route_tangent
),
-- Four independent, sea-only point clouds create loose activity patterns
-- around the route instead of a large random longitude/latitude rectangle.
cloud_noise AS MATERIALIZED (
  SELECT generate_series(1, 220) AS local_id,
         random() AS pick_cloud, random() AS u1, random() AS u2,
         random() AS u_type, random() AS u_speed, random() AS u_course
),
cloud_points AS (
  SELECT local_id, 'Arabian Sea offshore'::text AS source,
         CASE WHEN pick_cloud < 0.28 THEN 61.05
              WHEN pick_cloud < 0.55 THEN 62.65
              WHEN pick_cloud < 0.79 THEN 64.25
              ELSE 65.20 END
           + CASE WHEN pick_cloud < 0.28 THEN 0.42
                  WHEN pick_cloud < 0.55 THEN 0.54
                  WHEN pick_cloud < 0.79 THEN 0.48
                  ELSE 0.38 END
             * sqrt(-2.0 * ln(greatest(u1, 0.000001))) * cos(2.0 * pi() * u2) AS longitude,
         CASE WHEN pick_cloud < 0.28 THEN 20.95
              WHEN pick_cloud < 0.55 THEN 20.55
              WHEN pick_cloud < 0.79 THEN 20.18
              ELSE 19.75 END
           + CASE WHEN pick_cloud < 0.28 THEN 0.32
                  WHEN pick_cloud < 0.55 THEN 0.38
                  WHEN pick_cloud < 0.79 THEN 0.34
                  ELSE 0.29 END
             * sqrt(-2.0 * ln(greatest(u1, 0.000001))) * sin(2.0 * pi() * u2) AS latitude,
         CASE WHEN u_type < 0.51 THEN 'Cargo'
              WHEN u_type < 0.79 THEN 'Tanker'
              WHEN u_type < 0.90 THEN 'Fishing'
              ELSE 'Passenger' END AS ship_type,
         u_speed, u_course * 360.0 AS course
  FROM cloud_noise
),
all_new_points AS (
  SELECT * FROM route_points
  UNION ALL SELECT * FROM cloud_points
),
numbered AS (
  SELECT row_number() OVER (ORDER BY source, local_id) AS vessel_no, *
  FROM all_new_points
)
INSERT INTO ship_position
  (mmsi, ship_name, ship_type, speed, course, update_time, longitude, latitude, geom)
SELECT
  base_mmsi.last_mmsi + vessel_no AS mmsi,
  'ARABIAN-' || upper(ship_type) || '-' || lpad(vessel_no::text, 3, '0') AS ship_name,
  ship_type,
  round(least(22.0, greatest(0.0,
    CASE ship_type
      WHEN 'Tanker' THEN 6.0 + 10.0 * u_speed
      WHEN 'Cargo' THEN 7.0 + 12.0 * u_speed
      WHEN 'Passenger' THEN 8.0 + 12.0 * u_speed
      ELSE 1.0 + 7.0 * u_speed
    END))::numeric, 1) AS speed,
  round(mod((course + 360.0)::numeric, 360::numeric), 1) AS course,
  now() - random() * interval '12 hours' AS update_time,
  round(longitude::numeric, 6) AS longitude,
  round(latitude::numeric, 6) AS latitude,
  ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
FROM numbered
CROSS JOIN base_mmsi;

-- Validation: SELECT count(*) FROM ship_position WHERE ship_name LIKE 'ARABIAN-%';
