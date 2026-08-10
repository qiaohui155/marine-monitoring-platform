-- APPEND-ONLY Omani Sea AIS positions.
-- Keeps the existing 3,000 rows in ship_position and adds 600 new positions:
--   180 Duqm port / roadstead cluster
--   220 broad, curved Muscat--Duqm / Masirah traffic corridors
--   120 port-approach / waiting-area clouds
--    80 sparse Omani offshore observations
-- No DELETE or TRUNCATE is performed by this script.

WITH
base_mmsi AS (
  SELECT coalesce(max(mmsi::bigint), 470002999) AS last_mmsi
  FROM ship_position
),
-- Dense Duqm anchorage / port activity, constrained to the sea side of shore.
duqm_noise AS MATERIALIZED (
  SELECT generate_series(1, 180) AS local_id,
         random() AS u_radius, random() AS u_angle, random() AS u_type,
         random() AS u_speed, random() AS u_course
),
duqm_points AS (
  SELECT local_id, 'Duqm'::text AS source,
         57.705 + (-ln(greatest(1.0 - u_radius, 0.000001)) * 4.8)
                    * sin(radians(120.0 + (u_angle - 0.5) * 170.0))
                    / (111.32 * cos(radians(19.676))) AS longitude,
         19.676 + (-ln(greatest(1.0 - u_radius, 0.000001)) * 4.8)
                    * cos(radians(120.0 + (u_angle - 0.5) * 170.0))
                    / 111.32 AS latitude,
         CASE WHEN u_type < 0.38 THEN 'Tanker'
              WHEN u_type < 0.69 THEN 'Cargo'
              WHEN u_type < 0.89 THEN 'Fishing'
              ELSE 'Passenger' END AS ship_type,
         u_speed, u_course * 360.0 AS course
  FROM duqm_noise
),

-- Three non-straight corridor centre-lines.  Each sample has a broad random
-- cross-corridor offset, so this forms a shipping activity zone, not rail lines.
oman_routes(route_id, range_lo, range_hi, route_geom) AS (
  VALUES
    (1, 0.00, 0.45, ST_GeomFromText(
      'LINESTRING(58.70 23.54,58.42 23.15,58.12 22.70,57.91 22.18,57.74 21.60,57.62 20.92,57.64 20.20,57.70 19.75)', 4326)),
    (2, 0.45, 0.75, ST_GeomFromText(
      'LINESTRING(59.52 22.52,59.25 22.12,58.98 21.67,58.75 21.21,58.46 20.78,58.12 20.34)', 4326)),
    (3, 0.75, 1.01, ST_GeomFromText(
      'LINESTRING(57.98 20.46,58.19 20.28,58.22 20.06,58.05 19.88,57.82 19.74)', 4326))
),
corridor_noise AS MATERIALIZED (
  SELECT generate_series(1, 220) AS local_id,
         random() AS pick_route, random() AS u_t, random() AS u_width,
         random() AS u_z1, random() AS u_z2, random() AS u_type,
         random() AS u_speed, random() AS u_course
),
corridor_anchor AS (
  SELECT n.*, r.route_geom, 0.02 + 0.96 * n.u_t AS t,
         sign(cos(2.0 * pi() * n.u_z2))
           * least(sqrt(-2.0 * ln(greatest(n.u_z1, 0.000001))), 2.1)
           * CASE WHEN n.u_width < 0.35 THEN 5.0 + 8.0 * n.u_width
                  WHEN n.u_width < 0.85 THEN 10.0 + 12.0 * n.u_width
                  ELSE 18.0 + 8.0 * n.u_width END AS cross_km
  FROM corridor_noise n
  JOIN oman_routes r ON n.pick_route >= r.range_lo AND n.pick_route < r.range_hi
),
corridor_tangent AS (
  SELECT *, ST_LineInterpolatePoint(route_geom, t) AS centre_pt,
         ST_LineInterpolatePoint(route_geom, greatest(0.0, t - 0.006)) AS prev_pt,
         ST_LineInterpolatePoint(route_geom, least(1.0, t + 0.006)) AS next_pt
  FROM corridor_anchor
),
corridor_points AS (
  SELECT local_id, 'Oman coastal corridor'::text AS source,
         ST_X(centre_pt) - (ST_Y(next_pt) - ST_Y(prev_pt))
           / nullif(sqrt(power(ST_X(next_pt) - ST_X(prev_pt), 2)
                       + power(ST_Y(next_pt) - ST_Y(prev_pt), 2)), 0)
           * cross_km / (111.32 * cos(radians(ST_Y(centre_pt)))) AS longitude,
         ST_Y(centre_pt) + (ST_X(next_pt) - ST_X(prev_pt))
           / nullif(sqrt(power(ST_X(next_pt) - ST_X(prev_pt), 2)
                       + power(ST_Y(next_pt) - ST_Y(prev_pt), 2)), 0)
           * cross_km / 111.32 AS latitude,
         CASE WHEN u_type < 0.48 THEN 'Cargo'
              WHEN u_type < 0.82 THEN 'Tanker'
              WHEN u_type < 0.91 THEN 'Passenger'
              ELSE 'Fishing' END AS ship_type,
         u_speed,
         mod((degrees(ST_Azimuth(prev_pt, next_pt)) + (u_course - 0.5) * 18.0 + 360.0)::numeric,
             360::numeric)::double precision AS course
  FROM corridor_tangent
),

-- Queuing, pilotage and local fishing create scattered activity clouds around
-- Duqm, Masirah and Ras al Hadd rather than a uniformly filled sea rectangle.
activity_centres(name, lon0, lat0, mean_km, sea_bearing, fan_degrees, range_lo, range_hi) AS (
  VALUES
    ('Duqm roadstead', 57.82, 19.86, 13.0, 120.0, 190.0, 0.00, 0.50),
    ('Masirah offshore',58.87,20.62, 16.0, 100.0, 210.0, 0.50, 0.78),
    ('Ras al Hadd offshore',59.72,22.47, 14.0, 105.0, 195.0, 0.78, 1.01)
),
activity_noise AS MATERIALIZED (
  SELECT generate_series(1, 120) AS local_id,
         random() AS pick_centre, random() AS u_radius, random() AS u_angle,
         random() AS u_type, random() AS u_speed, random() AS u_course
),
activity_points AS (
  SELECT n.local_id, 'Oman approach activity'::text AS source,
         c.lon0 + (2.0 - ln(greatest(1.0 - n.u_radius, 0.000001)) * c.mean_km)
                    * sin(radians(c.sea_bearing + (n.u_angle - 0.5) * c.fan_degrees))
                    / (111.32 * cos(radians(c.lat0))) AS longitude,
         c.lat0 + (2.0 - ln(greatest(1.0 - n.u_radius, 0.000001)) * c.mean_km)
                    * cos(radians(c.sea_bearing + (n.u_angle - 0.5) * c.fan_degrees))
                    / 111.32 AS latitude,
         CASE WHEN n.u_type < 0.46 THEN 'Tanker'
              WHEN n.u_type < 0.76 THEN 'Cargo'
              WHEN n.u_type < 0.91 THEN 'Fishing'
              ELSE 'Passenger' END AS ship_type,
         n.u_speed, n.u_course * 360.0 AS course
  FROM activity_noise n
  JOIN activity_centres c ON n.pick_centre >= c.range_lo AND n.pick_centre < c.range_hi
),
offshore_noise AS MATERIALIZED (
  SELECT generate_series(1, 80) AS local_id,
         random() AS pick_cloud, random() AS u1, random() AS u2,
         random() AS u_type, random() AS u_speed, random() AS u_course
),
offshore_points AS (
  SELECT local_id, 'Oman offshore'::text AS source,
         CASE WHEN pick_cloud < 0.52 THEN 58.30 ELSE 59.18 END
           + CASE WHEN pick_cloud < 0.52 THEN 0.58 ELSE 0.46 END
             * sqrt(-2.0 * ln(greatest(u1, 0.000001))) * cos(2.0 * pi() * u2) AS longitude,
         CASE WHEN pick_cloud < 0.52 THEN 21.25 ELSE 22.20 END
           + CASE WHEN pick_cloud < 0.52 THEN 0.34 ELSE 0.28 END
             * sqrt(-2.0 * ln(greatest(u1, 0.000001))) * sin(2.0 * pi() * u2) AS latitude,
         CASE WHEN u_type < 0.49 THEN 'Cargo'
              WHEN u_type < 0.75 THEN 'Tanker'
              WHEN u_type < 0.91 THEN 'Fishing'
              ELSE 'Passenger' END AS ship_type,
         u_speed, u_course * 360.0 AS course
  FROM offshore_noise
),
all_new_points AS (
  SELECT * FROM duqm_points
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

-- Validation: this returns 600 appended Omani positions.
-- SELECT count(*) FROM ship_position WHERE ship_name LIKE 'OMAN-%';
