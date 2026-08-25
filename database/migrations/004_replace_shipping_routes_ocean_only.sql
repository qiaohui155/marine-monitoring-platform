BEGIN;

-- Replace the first draft routes with routes that were checked against the
-- Natural Earth 1:10m land polygons on 2026-08-25.  This migration changes
-- route geometry and route assignments only.  It does not move, insert, or
-- delete rows in ship_position.

DO $$
BEGIN
    IF to_regclass('public.shipping_route') IS NULL THEN
        RAISE EXCEPTION
            'public.shipping_route is missing. Run 003_add_simulated_ais_motion.sql first.';
    END IF;

    IF to_regclass('public.ship_motion_state') IS NULL THEN
        RAISE EXCEPTION
            'public.ship_motion_state is missing. Run 003_add_simulated_ais_motion.sql first.';
    END IF;
END
$$;

LOCK TABLE public.shipping_route IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_motion_state IN SHARE ROW EXCLUSIVE MODE;

-- Keep one recoverable copy of the route records that are about to be
-- replaced.  Re-running this migration refreshes the copy first.
CREATE TABLE IF NOT EXISTS public.shipping_route_before_ocean_fix
(LIKE public.shipping_route INCLUDING ALL);

TRUNCATE TABLE public.shipping_route_before_ocean_fix;

INSERT INTO public.shipping_route_before_ocean_fix
SELECT *
FROM public.shipping_route;

-- Remove route links before replacing route records.  Existing vessel
-- positions remain unchanged and are placed in a safe, non-moving state.
UPDATE public.ship_motion_state
SET route_id = NULL,
    route_progress = 0,
    route_distance_m = NULL,
    lateral_offset_m = 0,
    motion_mode = 'ANCHORED',
    needs_route_review = true,
    updated_at = CURRENT_TIMESTAMP;

DELETE FROM public.shipping_route;

-- Do not smooth these geometries automatically.  Extra vertices are used
-- around Hormuz and the Oman coastline so that straight segments remain at
-- sea.  PORT routes are closed local operating circuits, not land-side port
-- centre lines.
INSERT INTO public.shipping_route (
    route_name,
    route_kind,
    allowed_ship_types,
    enabled,
    description,
    geom
)
VALUES
(
    'Persian Gulf Central Lane',
    'MAIN',
    ARRAY['Cargo', 'Tanker'],
    true,
    'Central Persian Gulf lane approaching the Strait of Hormuz from the west.',
    ST_GeomFromText(
        'LINESTRING(50.30 27.10,51.20 26.85,52.20 26.70,53.20 26.55,54.20 26.45,55.10 26.40,55.85 26.38,56.12 26.48,56.38 26.52,56.58 26.30,56.62 26.02,56.58 25.80)',
        4326
    )
),
(
    'Hormuz and Gulf of Oman Eastbound Lane',
    'MAIN',
    ARRAY['Cargo', 'Tanker'],
    true,
    'Eastbound lane from Hormuz through the Gulf of Oman into the Arabian Sea.',
    ST_GeomFromText(
        'LINESTRING(56.58 25.80,56.72 25.60,57.05 25.35,57.50 25.12,58.10 24.88,58.80 24.58,59.55 24.18,60.30 23.78,61.20 23.35,62.20 22.85,63.20 22.35,64.30 21.75,65.40 21.15,66.20 20.70)',
        4326
    )
),
(
    'Hormuz and Gulf of Oman Westbound Lane',
    'MAIN',
    ARRAY['Cargo', 'Tanker'],
    true,
    'Separated westbound lane from the Arabian Sea toward Hormuz.',
    ST_GeomFromText(
        'LINESTRING(66.20 20.82,65.35 21.28,64.25 21.88,63.15 22.48,62.15 22.98,61.15 23.48,60.22 23.90,59.48 24.30,58.75 24.70,58.05 25.00,57.45 25.22,57.00 25.46,56.70 25.70,56.58 25.90)',
        4326
    )
),
(
    'Oman Offshore Coastal Lane',
    'OFFSHORE',
    ARRAY['Cargo', 'Tanker', 'Passenger'],
    true,
    'Offshore lane following the Oman coast without cutting across headlands.',
    ST_GeomFromText(
        'LINESTRING(56.80 25.25,57.20 24.92,57.72 24.58,58.32 24.25,58.95 23.90,59.48 23.48,59.95 23.00,60.25 22.48,60.05 21.90,59.82 21.25,59.52 20.60,59.10 20.00,58.65 19.42,58.10 18.85,57.45 18.28,56.78 17.72,56.05 17.20,55.30 16.72,54.55 16.40)',
        4326
    )
),
(
    'Fujairah Offshore Local Circuit',
    'PORT',
    ARRAY['Cargo', 'Tanker', 'Fishing', 'Passenger'],
    true,
    'Offshore operating circuit east of Fujairah for local and port traffic.',
    ST_GeomFromText(
        'LINESTRING(56.78 25.30,56.92 25.08,57.10 24.85,57.18 24.62,57.08 24.43,56.94 24.56,56.88 24.80,56.78 25.05,56.78 25.30)',
        4326
    )
),
(
    'Sohar Offshore Local Circuit',
    'PORT',
    ARRAY['Cargo', 'Tanker', 'Fishing', 'Passenger'],
    true,
    'Offshore operating circuit east of Sohar for port and coastal traffic.',
    ST_GeomFromText(
        'LINESTRING(57.25 24.62,57.38 24.48,57.45 24.30,57.43 24.12,57.32 23.98,57.22 24.12,57.20 24.32,57.22 24.50,57.25 24.62)',
        4326
    )
),
(
    'Muscat Offshore Local Circuit',
    'PORT',
    ARRAY['Cargo', 'Tanker', 'Fishing', 'Passenger'],
    true,
    'Offshore operating circuit east of Muscat for local and port traffic.',
    ST_GeomFromText(
        'LINESTRING(59.00 23.88,59.20 23.84,59.38 23.70,59.42 23.52,59.28 23.42,59.08 23.47,58.95 23.60,58.92 23.75,59.00 23.88)',
        4326
    )
),
(
    'Duqm Offshore Local Circuit',
    'PORT',
    ARRAY['Cargo', 'Tanker', 'Fishing', 'Passenger'],
    true,
    'Offshore operating circuit east of Duqm for local and port traffic.',
    ST_GeomFromText(
        'LINESTRING(58.15 20.10,58.35 20.02,58.52 19.86,58.60 19.68,58.47 19.55,58.27 19.60,58.12 19.75,58.05 19.92,58.15 20.10)',
        4326
    )
),
(
    'Salalah Offshore Local Circuit',
    'PORT',
    ARRAY['Cargo', 'Tanker', 'Fishing', 'Passenger'],
    true,
    'Offshore operating circuit south of Salalah for local and port traffic.',
    ST_GeomFromText(
        'LINESTRING(54.05 16.58,54.30 16.48,54.58 16.47,54.82 16.55,54.90 16.68,54.72 16.78,54.43 16.77,54.17 16.70,54.05 16.58)',
        4326
    )
);

-- Assign a route only when the vessel is moving, the ship type is allowed,
-- and the nearest compatible route is close enough.  Vessels that do not
-- meet these rules remain at their existing coordinates as ANCHORED and are
-- marked for later route review.
WITH nearest AS (
    SELECT
        p.mmsi,
        p.ship_type,
        COALESCE(p.speed, 0) AS current_speed,
        r.route_id,
        r.route_kind,
        r.geom AS route_geom,
        ST_Distance(
            p.geom::geography,
            ST_ClosestPoint(r.geom, p.geom)::geography
        ) AS route_distance_m
    FROM public.ship_position p
    LEFT JOIN LATERAL (
        SELECT candidate.*
        FROM public.shipping_route candidate
        WHERE candidate.enabled = true
          AND p.ship_type = ANY(candidate.allowed_ship_types)
        ORDER BY p.geom <-> candidate.geom
        LIMIT 1
    ) r ON true
    WHERE p.mmsi IS NOT NULL
      AND p.geom IS NOT NULL
),
classified AS (
    SELECT
        n.*,
        CASE
            WHEN n.current_speed <= 0.5 THEN false
            WHEN n.ship_type IN ('Cargo', 'Tanker')
                 AND n.route_kind IN ('MAIN', 'OFFSHORE')
                 AND n.route_distance_m <= 50000 THEN true
            WHEN n.ship_type IN ('Cargo', 'Tanker')
                 AND n.route_kind = 'PORT'
                 AND n.route_distance_m <= 30000 THEN true
            WHEN n.ship_type = 'Fishing'
                 AND n.route_kind = 'PORT'
                 AND n.route_distance_m <= 50000 THEN true
            WHEN n.ship_type = 'Passenger'
                 AND n.route_kind IN ('PORT', 'OFFSHORE')
                 AND n.route_distance_m <= 50000 THEN true
            ELSE false
        END AS route_accepted
    FROM nearest n
)
UPDATE public.ship_motion_state state
SET route_id = CASE
        WHEN c.route_accepted THEN c.route_id
        ELSE NULL
    END,
    route_progress = CASE
        WHEN c.route_accepted THEN ST_LineLocatePoint(
            c.route_geom,
            ST_ClosestPoint(c.route_geom, position.geom)
        )
        ELSE 0
    END,
    route_distance_m = CASE
        WHEN c.route_accepted THEN c.route_distance_m
        ELSE NULL
    END,
    motion_mode = CASE
        WHEN c.current_speed <= 0.5 THEN 'ANCHORED'
        WHEN NOT c.route_accepted THEN 'ANCHORED'
        WHEN position.ship_type = 'Fishing' THEN 'FISHING'
        WHEN position.ship_type = 'Passenger' THEN 'PASSENGER'
        WHEN c.route_kind = 'PORT' THEN 'PORT'
        WHEN c.route_kind = 'OFFSHORE' THEN 'OFFSHORE'
        ELSE 'ROUTE'
    END,
    needs_route_review = CASE
        WHEN c.current_speed > 0.5 AND NOT c.route_accepted THEN true
        ELSE false
    END,
    updated_at = CURRENT_TIMESTAMP
FROM classified c
JOIN public.ship_position position
  ON position.mmsi = c.mmsi
WHERE state.mmsi = c.mmsi;

COMMIT;

-- Verification output.  Every route must be a valid, simple LineString.
SELECT
    route_id,
    route_name,
    route_kind,
    ST_IsValid(geom) AS geometry_valid,
    ST_IsSimple(geom) AS geometry_simple,
    round((ST_Length(geom::geography) / 1000.0)::numeric, 1) AS length_km
FROM public.shipping_route
ORDER BY route_id;

SELECT
    motion_mode,
    count(*) AS vessel_count,
    count(*) FILTER (WHERE route_id IS NOT NULL) AS assigned_to_route,
    count(*) FILTER (WHERE needs_route_review) AS needs_route_review
FROM public.ship_motion_state
GROUP BY motion_mode
ORDER BY motion_mode;
