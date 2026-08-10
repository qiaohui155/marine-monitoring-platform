-- 3,000 synthetic AIS positions for the Persian Gulf / Strait of Hormuz / Gulf of Oman.
-- Requires PostgreSQL 12+ and PostGIS.  The target table is assumed to contain:
-- mmsi, ship_name, ship_type, speed, course, update_time, longitude, latitude, geom.
--
-- Distribution is deliberately non-rectangular:
--   1,350 port-centred, sea-facing exponential clusters (45%)
--   1,200 route-associated points (40%): 780 in broad curved corridors and
--     420 in irregular strait / port-approach activity clouds
--     450 sparse, irregular offshore clouds (15%)
-- Rerun the statement to obtain a fresh, plausible AIS snapshot.

BEGIN;

-- The request is to replace the currently displayed synthetic AIS snapshot.
-- Keep this DELETE only if ship_position is dedicated to this generated layer.
DELETE FROM ship_position;

WITH
-- sea_bearing is measured clockwise from north.  It keeps port clusters on the
-- water side of the coast rather than spreading equally over land and sea.
ports(port_name, lon0, lat0, mean_km, sea_bearing, fan_degrees, range_lo, range_hi) AS (
  VALUES
    ('Jebel Ali / Dubai',       55.027, 25.011, 4.5, 300.0, 150.0, 0.00, 0.20),
    ('Abu Dhabi offshore',      54.350, 24.550, 5.5,  20.0, 160.0, 0.20, 0.33),
    ('Sharjah / Ras Al Khaimah',55.550, 25.500, 4.0, 285.0, 135.0, 0.33, 0.45),
    ('Fujairah',                56.360, 25.120, 3.3,  85.0, 125.0, 0.45, 0.57),
    ('Sohar',                   56.740, 24.350, 4.0,  20.0, 135.0, 0.57, 0.68),
    ('Muscat',                  58.550, 23.620, 4.6,  25.0, 145.0, 0.68, 0.79),
    ('Duqm',                    57.705, 19.676, 4.8, 120.0, 170.0, 0.79, 0.90),
    ('Bandar Abbas',            56.270, 27.170, 4.0, 185.0, 130.0, 0.90, 1.01)
),
port_noise AS MATERIALIZED (
  SELECT generate_series(1, 1350) AS local_id,
         random() AS pick_port, random() AS u_radius, random() AS u_angle,
         random() AS cluster_width, random() AS pick_type,
         random() AS pick_speed, random() AS pick_course
),
port_z AS (
  SELECT n.*, p.*,
         -- Exponential distance: dense berths/anchorages near the port, with
         -- only a small, non-uniform tail extending into the approach channel.
         -ln(greatest(1.0 - n.u_radius, 0.000001))
           * p.mean_km * CASE WHEN n.cluster_width < 0.82 THEN 0.62
                              ELSE 1.15 + n.cluster_width END AS radius_km,
         radians(p.sea_bearing + (n.u_angle - 0.5) * p.fan_degrees) AS heading_rad
  FROM port_noise n
  JOIN ports p ON n.pick_port >= p.range_lo AND n.pick_port < p.range_hi
),
port_typed AS (
  SELECT local_id, 'port'::text AS source,
         lon0 + radius_km * sin(heading_rad) / (111.32 * cos(radians(lat0))) AS longitude,
         lat0 + radius_km * cos(heading_rad) / 111.32 AS latitude,
         CASE WHEN pick_type < 0.45 THEN 'Tanker'
              WHEN pick_type < 0.70 THEN 'Cargo'
              WHEN pick_type < 0.88 THEN 'Passenger'
              ELSE 'Fishing' END AS ship_type,
         pick_speed, pick_course * 360.0 AS course
  FROM port_z
),
port_points AS (
  SELECT local_id, source, longitude, latitude, ship_type, course,
         CASE ship_type
           WHEN 'Tanker'    THEN 0.2 + 9.0  * pick_speed
           WHEN 'Cargo'     THEN 0.5 + 11.0 * pick_speed
           WHEN 'Passenger' THEN 1.0 + 14.0 * pick_speed
           ELSE                  0.0 + 8.0  * pick_speed
         END AS speed
  FROM port_typed
),

-- These are centre-lines, not parallel strips.  The offset is calculated
-- perpendicular to each line's local tangent, with a different random width
-- for every vessel.
routes(route_name, route_class, range_lo, range_hi, route_geom) AS (
  VALUES
    ('Persian Gulf trunk west-east', 'cargo', 0.00, 0.23,
      ST_GeomFromText('LINESTRING(50.15 26.88,51.10 26.73,52.45 26.57,53.82 26.36,55.00 26.05,56.08 25.76)', 4326)),
    ('Southern Gulf oil route', 'oil', 0.23, 0.37,
      ST_GeomFromText('LINESTRING(53.20 24.92,53.62 25.14,54.22 25.43,54.94 25.63,55.62 25.71,56.18 25.78)', 4326)),
    ('Hormuz inbound lane', 'oil', 0.37, 0.59,
      ST_GeomFromText('LINESTRING(55.55 25.49,56.18 25.76,56.68 26.02,57.12 26.34,57.58 26.53,57.93 26.39)', 4326)),
    ('Hormuz outbound lane', 'oil', 0.59, 0.72,
      ST_GeomFromText('LINESTRING(57.98 26.12,57.62 26.22,57.18 25.99,56.77 25.70,56.30 25.45,55.78 25.22)', 4326)),
    ('Gulf of Oman coastal route', 'cargo', 0.72, 0.89,
      ST_GeomFromText('LINESTRING(57.43 25.47,57.75 25.10,58.05 24.66,58.38 24.12,58.62 23.65,59.08 23.23,59.80 22.76,60.55 22.59)', 4326)),
    ('Muscat to Duqm coastal route', 'cargo', 0.89, 1.01,
      ST_GeomFromText('LINESTRING(58.66 23.56,58.38 23.15,58.10 22.70,57.90 22.18,57.73 21.60,57.62 20.92,57.64 20.20,57.70 19.75)', 4326))
),
route_noise AS MATERIALIZED (
  SELECT generate_series(1, 780) AS local_id,
         random() AS pick_route, random() AS u_t, random() AS u_width,
         random() AS u_z1, random() AS u_z2, random() AS pick_type,
         random() AS pick_speed, random() AS course_jitter
),
route_anchor AS (
  SELECT n.*, r.*, 0.015 + 0.970 * n.u_t AS t,
         sqrt(-2.0 * ln(greatest(n.u_z1, 0.000001))) * cos(2.0 * pi() * n.u_z2) AS z_offset
  FROM route_noise n
  JOIN routes r ON n.pick_route >= r.range_lo AND n.pick_route < r.range_hi
),
route_tangent AS (
  SELECT *,
         ST_LineInterpolatePoint(route_geom, t) AS centre_pt,
         ST_LineInterpolatePoint(route_geom, greatest(0.0, t - 0.004)) AS prev_pt,
         ST_LineInterpolatePoint(route_geom, least(1.0, t + 0.004)) AS next_pt,
         -- AIS traffic does not sit on a one-pixel centre-line.  These are
         -- 4--22 km navigable corridors, with occasional wider diversion / wait
         -- areas.  Capping the normal tail avoids artificial, isolated outliers.
         sign(z_offset) * least(abs(z_offset), 2.2)
           * CASE WHEN u_width < 0.34 THEN 4.0 + 8.0 * u_width
                  WHEN u_width < 0.86 THEN 9.0 + 13.0 * u_width
                  ELSE 18.0 + 10.0 * u_width END AS cross_km
  FROM route_anchor
),
route_typed AS (
  SELECT *,
         CASE
           WHEN route_class = 'oil' AND pick_type < 0.62 THEN 'Tanker'
           WHEN route_class = 'oil' AND pick_type < 0.90 THEN 'Cargo'
           WHEN route_class = 'oil' THEN 'Passenger'
           -- The only fishing vessels on a route are on the Oman coast; their
           -- main concentration remains at the coastal port clusters above.
           WHEN route_name = 'Gulf of Oman coastal route' AND pick_type < 0.52 THEN 'Cargo'
           WHEN route_name = 'Gulf of Oman coastal route' AND pick_type < 0.77 THEN 'Tanker'
           WHEN route_name = 'Gulf of Oman coastal route' AND pick_type < 0.90 THEN 'Passenger'
           WHEN route_name = 'Gulf of Oman coastal route' THEN 'Fishing'
           WHEN route_class = 'cargo' AND pick_type < 0.58 THEN 'Cargo'
           WHEN route_class = 'cargo' AND pick_type < 0.82 THEN 'Tanker'
           ELSE 'Passenger'
         END AS ship_type
  FROM route_tangent
),
route_points AS (
  SELECT local_id, 'route'::text AS source,
         ST_X(centre_pt)
           + (-1.0 * (ST_Y(next_pt) - ST_Y(prev_pt))
              / nullif(sqrt(power(ST_X(next_pt) - ST_X(prev_pt), 2)
                          + power(ST_Y(next_pt) - ST_Y(prev_pt), 2)), 0))
             * cross_km / (111.32 * cos(radians(ST_Y(centre_pt)))) AS longitude,
         ST_Y(centre_pt)
           + ((ST_X(next_pt) - ST_X(prev_pt))
              / nullif(sqrt(power(ST_X(next_pt) - ST_X(prev_pt), 2)
                          + power(ST_Y(next_pt) - ST_Y(prev_pt), 2)), 0))
             * cross_km / 111.32 AS latitude,
         ship_type,
         mod((degrees(ST_Azimuth(prev_pt, next_pt))
              + (course_jitter - 0.5) * 16.0 + 360.0)::numeric, 360::numeric)::double precision AS course,
         CASE ship_type
           WHEN 'Tanker'    THEN 7.0 + 10.0 * pick_speed
           WHEN 'Cargo'     THEN 8.0 + 12.0 * pick_speed
           WHEN 'Passenger' THEN 10.0 + 12.0 * pick_speed
           ELSE                  3.0 + 7.0 * pick_speed
         END AS speed
  FROM route_typed
),

-- A sizeable part of traffic slows, queues, merges, or changes course around
-- port approaches and the Strait of Hormuz.  Modelling this separately removes
-- the unrealistic "single unbroken rail" appearance of a one-line route model.
approaches(name, lon0, lat0, mean_km, sea_bearing, fan_degrees, range_lo, range_hi) AS (
  VALUES
    ('Dubai approach',       54.92, 25.10, 10.0, 310.0, 185.0, 0.00, 0.14),
    ('Abu Dhabi approach',   53.98, 24.76, 13.0,  25.0, 200.0, 0.14, 0.25),
    ('Hormuz west',          56.12, 25.70, 13.0,  55.0, 225.0, 0.25, 0.46),
    ('Fujairah roadstead',   56.53, 25.18, 10.0,  85.0, 175.0, 0.46, 0.59),
    ('Sohar approach',       56.82, 24.47, 12.0,  25.0, 190.0, 0.59, 0.70),
    ('Muscat approach',      58.78, 23.78, 13.0,  30.0, 185.0, 0.70, 0.81),
    ('Duqm approach',        57.82, 19.86, 14.0, 120.0, 190.0, 0.81, 0.91),
    ('Bandar Abbas approach',56.13, 27.03, 10.0, 185.0, 160.0, 0.91, 1.01)
),
approach_noise AS MATERIALIZED (
  SELECT generate_series(1, 420) AS local_id,
         random() AS pick_approach, random() AS u_radius, random() AS u_angle,
         random() AS pick_type, random() AS pick_speed, random() AS pick_course
),
approach_typed AS (
  SELECT n.local_id, 'approach'::text AS source,
         a.lon0 + (2.0 - ln(greatest(1.0 - n.u_radius, 0.000001)) * a.mean_km)
                    * sin(radians(a.sea_bearing + (n.u_angle - 0.5) * a.fan_degrees))
                    / (111.32 * cos(radians(a.lat0))) AS longitude,
         a.lat0 + (2.0 - ln(greatest(1.0 - n.u_radius, 0.000001)) * a.mean_km)
                    * cos(radians(a.sea_bearing + (n.u_angle - 0.5) * a.fan_degrees))
                    / 111.32 AS latitude,
         CASE WHEN n.pick_type < 0.57 THEN 'Tanker'
              WHEN n.pick_type < 0.84 THEN 'Cargo'
              WHEN n.pick_type < 0.93 THEN 'Passenger'
              ELSE 'Fishing' END AS ship_type,
         n.pick_speed, n.pick_course * 360.0 AS course
  FROM approach_noise n
  JOIN approaches a ON n.pick_approach >= a.range_lo AND n.pick_approach < a.range_hi
),
approach_points AS (
  SELECT local_id, source, longitude, latitude, ship_type, course,
         CASE ship_type
           WHEN 'Tanker'    THEN 1.0 + 10.0 * pick_speed
           WHEN 'Cargo'     THEN 2.0 + 12.0 * pick_speed
           WHEN 'Passenger' THEN 3.0 + 13.0 * pick_speed
           ELSE                  0.5 + 7.0 * pick_speed
         END AS speed
  FROM approach_typed
),

-- A Gaussian mixture produces sparse, irregular open-water observations.
-- It intentionally avoids a longitude/latitude rectangle and a uniform grid.
background_noise AS MATERIALIZED (
  SELECT generate_series(1, 450) AS local_id,
         random() AS pick_cloud, random() AS u1, random() AS u2,
         random() AS pick_type, random() AS pick_speed, random() AS pick_course
),
background_z AS (
  SELECT *,
         sqrt(-2.0 * ln(greatest(u1, 0.000001))) * cos(2.0 * pi() * u2) AS z_lon,
         sqrt(-2.0 * ln(greatest(u1, 0.000001))) * sin(2.0 * pi() * u2) AS z_lat
  FROM background_noise
),
background_typed AS (
  SELECT local_id, 'background'::text AS source,
         CASE WHEN pick_type >= 0.72 AND pick_type < 0.91 AND pick_cloud < 0.55
                   THEN 56.86 + 0.24 * z_lon
              WHEN pick_type >= 0.72 AND pick_type < 0.91
                   THEN 58.42 + 0.28 * z_lon
              WHEN pick_cloud < 0.32 THEN 52.25 + 0.62 * z_lon
              WHEN pick_cloud < 0.57 THEN 54.18 + 0.48 * z_lon
              WHEN pick_cloud < 0.75 THEN 55.58 + 0.28 * z_lon
              ELSE                         59.75 + 0.72 * z_lon END AS longitude,
         CASE WHEN pick_type >= 0.72 AND pick_type < 0.91 AND pick_cloud < 0.55
                   THEN 24.48 + 0.11 * z_lat
              WHEN pick_type >= 0.72 AND pick_type < 0.91
                   THEN 23.77 + 0.12 * z_lat
              WHEN pick_cloud < 0.32 THEN 26.30 + 0.24 * z_lat
              WHEN pick_cloud < 0.57 THEN 25.90 + 0.19 * z_lat
              WHEN pick_cloud < 0.75 THEN 25.42 + 0.13 * z_lat
              ELSE                         24.08 + 0.34 * z_lat END AS latitude,
         CASE WHEN pick_type < 0.47 THEN 'Cargo'
              WHEN pick_type < 0.72 THEN 'Tanker'
              WHEN pick_type < 0.91 THEN 'Fishing'
              ELSE 'Passenger' END AS ship_type,
         pick_speed, pick_course * 360.0 AS course
  FROM background_z
),
background_points AS (
  SELECT local_id, source, longitude, latitude, ship_type, course,
         CASE ship_type
           WHEN 'Tanker'    THEN 6.0 + 9.0  * pick_speed
           WHEN 'Cargo'     THEN 7.0 + 11.0 * pick_speed
           WHEN 'Passenger' THEN 8.0 + 10.0 * pick_speed
           ELSE                  1.0 + 7.0  * pick_speed
         END AS speed
  FROM background_typed
),
all_points AS (
  SELECT * FROM port_points
  UNION ALL SELECT * FROM route_points
  UNION ALL SELECT * FROM approach_points
  UNION ALL SELECT * FROM background_points
),
numbered AS (
  SELECT row_number() OVER (ORDER BY source, local_id) AS vessel_no, *
  FROM all_points
)
INSERT INTO ship_position
  (mmsi, ship_name, ship_type, speed, course, update_time, longitude, latitude, geom)
SELECT
  470000000 + vessel_no AS mmsi,
  upper(ship_type) || '-' || lpad(vessel_no::text, 4, '0') AS ship_name,
  ship_type,
  round(least(22.0, greatest(0.0, speed))::numeric, 1) AS speed,
  round(mod((course + 360.0)::numeric, 360::numeric), 1) AS course,
  now() - (random() * interval '12 hours') AS update_time,
  round(longitude::numeric, 6) AS longitude,
  round(latitude::numeric, 6) AS latitude,
  ST_SetSRID(ST_MakePoint(longitude, latitude), 4326) AS geom
FROM numbered;

COMMIT;

-- Optional quick validation after insertion:
-- SELECT count(*) AS total, ship_type, count(*)
-- FROM ship_position GROUP BY ship_type ORDER BY ship_type;
