-- Create five oil-spill events whose footprints are spatially anchored to
-- existing historical AIS tracks.  Re-running this file replaces only the
-- OS-101 ... OS-105 records created here.

BEGIN;

DELETE FROM public.oil_spill_area
WHERE event_id IN ('OS-101', 'OS-102', 'OS-103', 'OS-104', 'OS-105');

DELETE FROM public.oil_spill_event
WHERE event_id IN ('OS-101', 'OS-102', 'OS-103', 'OS-104', 'OS-105');

CREATE TEMP TABLE _track_matched_events ON COMMIT DROP AS
WITH definitions(event_id, reference_lon, reference_lat, radius_m, level, status, event_time) AS (
    VALUES
        ('OS-101', 56.55::double precision, 25.45::double precision,  9000::double precision, '高', '监测中', CURRENT_TIMESTAMP - INTERVAL '10 hours'),
        ('OS-102', 56.75::double precision, 24.55::double precision,  7000::double precision, '中', '待核实', CURRENT_TIMESTAMP - INTERVAL '8 hours'),
        ('OS-103', 58.75::double precision, 23.75::double precision,  8000::double precision, '高', '处置中', CURRENT_TIMESTAMP - INTERVAL '6 hours'),
        ('OS-104', 57.75::double precision, 19.55::double precision, 10000::double precision, '中', '监测中', CURRENT_TIMESTAMP - INTERVAL '4 hours'),
        ('OS-105', 60.10::double precision, 22.10::double precision, 12000::double precision, '低', '待核实', CURRENT_TIMESTAMP - INTERVAL '2 hours')
),
centers AS (
    SELECT
        d.*,
        nearest.mmsi AS matched_mmsi,
        nearest.ship_name AS matched_ship_name,
        ST_ClosestPoint(
            nearest.geom,
            ST_SetSRID(ST_MakePoint(d.reference_lon, d.reference_lat), 4326)
        )::geometry(Point, 4326) AS center_geom
    FROM definitions d
    CROSS JOIN LATERAL (
        SELECT t.mmsi, t.ship_name, t.geom
        FROM public.ship_track_lines t
        WHERE t.geom IS NOT NULL AND NOT ST_IsEmpty(t.geom)
        ORDER BY t.geom <-> ST_SetSRID(ST_MakePoint(d.reference_lon, d.reference_lat), 4326)
        LIMIT 1
    ) nearest
),
vertices AS (
    SELECT
        c.*,
        vertex_number,
        ST_Project(
            c.center_geom::geography,
            c.radius_m * radius_factor,
            radians(vertex_number * 30.0)
        )::geometry(Point, 4326) AS vertex_geom
    FROM centers c
    CROSS JOIN LATERAL unnest(
        ARRAY[0.82, 1.18, 0.91, 1.25, 0.76, 1.08, 0.88, 1.22, 0.79, 1.12, 0.86, 1.16]::double precision[]
    ) WITH ORDINALITY AS radii(radius_factor, ordinal)
    CROSS JOIN LATERAL (SELECT (ordinal - 1)::integer AS vertex_number) numbered
),
open_rings AS (
    SELECT
        event_id,
        level,
        status,
        event_time,
        matched_mmsi,
        matched_ship_name,
        center_geom,
        ST_MakeLine(vertex_geom ORDER BY vertex_number) AS open_ring
    FROM vertices
    GROUP BY event_id, level, status, event_time, matched_mmsi, matched_ship_name, center_geom
)
SELECT
    event_id,
    level,
    status,
    event_time,
    matched_mmsi,
    matched_ship_name,
    center_geom,
    ST_MakePolygon(ST_AddPoint(open_ring, ST_StartPoint(open_ring)))::geometry(Polygon, 4326) AS area_geom
FROM open_rings;

INSERT INTO public.oil_spill_event (event_id, event_time, source, status, geom)
SELECT
    event_id,
    event_time,
    'SAR imagery interpretation',
    status,
    center_geom
FROM _track_matched_events
ORDER BY event_id;

INSERT INTO public.oil_spill_area (event_id, event_time, area_km2, level, status, geom)
SELECT
    event_id,
    event_time,
    ROUND((ST_Area(area_geom::geography) / 1000000.0)::numeric, 2),
    level,
    status,
    area_geom
FROM _track_matched_events
ORDER BY event_id;

-- Verification: every event should have at least the matched track crossing
-- its footprint, while nearby tracks are determined by the API distance.
SELECT
    e.event_id,
    e.event_time,
    a.area_km2,
    seeded.matched_mmsi,
    seeded.matched_ship_name,
    COUNT(t.mmsi) FILTER (WHERE ST_Intersects(t.geom, a.geom)) AS intersecting_tracks
FROM public.oil_spill_event e
JOIN public.oil_spill_area a USING (event_id)
JOIN _track_matched_events seeded USING (event_id)
LEFT JOIN public.ship_track_lines t ON ST_Intersects(t.geom, a.geom)
WHERE e.event_id IN ('OS-101', 'OS-102', 'OS-103', 'OS-104', 'OS-105')
GROUP BY e.event_id, e.event_time, a.area_km2, seeded.matched_mmsi, seeded.matched_ship_name
ORDER BY e.event_id;

COMMIT;
