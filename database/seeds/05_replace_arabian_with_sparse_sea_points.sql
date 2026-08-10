-- Replace the previous ARABIAN-* route/cloud proposal with sparse, unstructured
-- offshore AIS points.  The original 3,000 records and OMAN-* records remain.
-- If the earlier Arabian Sea script was not run, the DELETE simply removes 0 rows.

BEGIN;

DELETE FROM ship_position
WHERE ship_name LIKE 'ARABIAN-%';

WITH
base_mmsi AS (
  SELECT coalesce(max(mmsi::bigint), 470002999) AS last_mmsi
  FROM ship_position
),
-- These polygons follow only open water.  They are intentionally irregular;
-- ST_GeneratePoints therefore does not create a longitude/latitude rectangle.
sea_zones(zone_name, point_count, sea_geom) AS (
  VALUES
    ('Gulf of Oman open sea', 70,
      ST_GeomFromText('POLYGON((57.10 24.92,58.20 25.02,59.45 24.42,60.70 23.82,61.35 22.95,61.10 22.25,60.25 22.08,59.30 22.48,58.40 23.15,57.65 24.05,57.10 24.92))', 4326)),
    ('Arabian Sea east', 120,
      ST_GeomFromText('POLYGON((60.35 22.55,62.15 22.72,64.55 22.30,66.35 21.25,66.70 19.60,65.80 18.35,63.85 17.65,61.65 18.10,59.55 19.35,59.30 20.65,60.35 22.55))', 4326)),
    ('Arabian Sea south of Oman', 70,
      ST_GeomFromText('POLYGON((58.25 19.15,57.45 18.62,56.40 17.92,55.25 17.25,54.20 16.45,53.55 15.58,54.85 15.15,56.65 15.50,58.45 16.22,59.65 17.55,59.25 18.55,58.25 19.15))', 4326))
),
random_sea_points AS MATERIALIZED (
  SELECT z.zone_name, dumped.geom AS point_geom,
         random() AS u_type, random() AS u_speed, random() AS u_course
  FROM sea_zones z
  CROSS JOIN LATERAL ST_Dump(ST_GeneratePoints(z.sea_geom, z.point_count)) AS dumped(path, geom)
),
numbered AS (
  SELECT row_number() OVER (ORDER BY zone_name, ST_X(point_geom), ST_Y(point_geom)) AS vessel_no, *
  FROM random_sea_points
)
INSERT INTO ship_position
  (mmsi, ship_name, ship_type, speed, course, update_time, longitude, latitude, geom)
SELECT
  base_mmsi.last_mmsi + vessel_no AS mmsi,
  'ARABIAN-' || lpad(vessel_no::text, 3, '0') AS ship_name,
  CASE WHEN u_type < 0.50 THEN 'Cargo'
       WHEN u_type < 0.76 THEN 'Tanker'
       WHEN u_type < 0.89 THEN 'Fishing'
       ELSE 'Passenger' END AS ship_type,
  round((CASE WHEN u_type < 0.50 THEN 7.0 + 11.0 * u_speed
              WHEN u_type < 0.76 THEN 6.0 + 10.0 * u_speed
              WHEN u_type < 0.89 THEN 1.0 + 7.0 * u_speed
              ELSE 8.0 + 11.0 * u_speed END)::numeric, 1) AS speed,
  round((u_course * 360.0)::numeric, 1) AS course,
  now() - random() * interval '12 hours' AS update_time,
  round(ST_X(point_geom)::numeric, 6) AS longitude,
  round(ST_Y(point_geom)::numeric, 6) AS latitude,
  ST_SetSRID(ST_MakePoint(ST_X(point_geom), ST_Y(point_geom)), 4326) AS geom
FROM numbered
CROSS JOIN base_mmsi;

COMMIT;

-- Validation: this returns 260 sparse open-sea records.
-- SELECT count(*) FROM ship_position WHERE ship_name LIKE 'ARABIAN-%';
