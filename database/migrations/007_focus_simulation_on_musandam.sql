BEGIN;

-- Move the complete simulated operating picture into the Musandam Governorate
-- monitoring area and the adjacent Strait of Hormuz waters. This migration is
-- intentionally comprehensive: positions, routes, historical tracks, spill
-- events, warnings, risk zones and suspicious-vessel records are regenerated
-- together so that every displayed business record refers to the same area.

DO $$
DECLARE
    required_table text;
BEGIN
    FOREACH required_table IN ARRAY ARRAY[
        'ship_position',
        'ship_track',
        'shipping_route',
        'ship_motion_state',
        'oil_spill_event',
        'oil_spill_area',
        'suspicious_ship',
        'warning_area',
        'sea_risk_index'
    ]
    LOOP
        IF to_regclass('public.' || required_table) IS NULL THEN
            RAISE EXCEPTION 'Required table public.% is missing.', required_table;
        END IF;
    END LOOP;
END
$$;

LOCK TABLE public.ship_position IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_track IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_motion_state IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.shipping_route IN SHARE ROW EXCLUSIVE MODE;

-- Keep the agreed area in the database so later APIs and GIS projects can use
-- one authoritative monitoring envelope rather than repeating coordinates.
CREATE TABLE IF NOT EXISTS public.monitoring_area (
    area_code varchar(30) PRIMARY KEY,
    area_name varchar(160) NOT NULL,
    description text,
    geom geometry(Polygon, 4326) NOT NULL,
    updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS monitoring_area_geom_gix
ON public.monitoring_area USING gist (geom);

INSERT INTO public.monitoring_area (
    area_code,
    area_name,
    description,
    geom,
    updated_at
)
VALUES (
    'MUSANDAM_HORMUZ',
    'Musandam Governorate and adjacent Strait of Hormuz waters',
    'Operational simulation envelope for satellite, AIS and marine-pollution monitoring.',
    ST_GeomFromText(
        'POLYGON((55.45 25.05,57.45 25.05,57.45 26.75,55.45 26.75,55.45 25.05))',
        4326
    ),
    CURRENT_TIMESTAMP
)
ON CONFLICT (area_code) DO UPDATE
SET area_name = EXCLUDED.area_name,
    description = EXCLUDED.description,
    geom = EXCLUDED.geom,
    updated_at = EXCLUDED.updated_at;

-- Replace the Oman-wide routes only after removing their motion-state links.
TRUNCATE TABLE public.ship_motion_state;
DELETE FROM public.shipping_route;

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
    'Musandam Hormuz Eastbound Lane',
    'MAIN',
    ARRAY['Cargo', 'Tanker', 'Passenger', 'Other'],
    true,
    'Reviewed simulated eastbound transit through the Strait of Hormuz and past Musandam.',
    ST_GeomFromText(
        'LINESTRING(55.55 26.40,55.85 26.38,56.12 26.48,56.38 26.52,56.58 26.30,56.62 26.02,56.58 25.80,56.72 25.60,57.05 25.35,57.35 25.22)',
        4326
    )
),
(
    'Musandam Hormuz Westbound Lane',
    'MAIN',
    ARRAY['Cargo', 'Tanker', 'Passenger', 'Other'],
    true,
    'Separated simulated westbound transit through the Strait of Hormuz.',
    ST_GeomFromText(
        'LINESTRING(57.32 25.30,57.02 25.46,56.70 25.68,56.56 25.90,56.52 26.13,56.35 26.40,56.12 26.44,55.84 26.33,55.55 26.31)',
        4326
    )
),
(
    'Musandam East Coast Offshore Lane',
    'OFFSHORE',
    ARRAY['Cargo', 'Tanker', 'Passenger', 'Other'],
    true,
    'Offshore operating route along the eastern Musandam monitoring waters.',
    ST_GeomFromText(
        'LINESTRING(56.62 26.18,56.70 26.02,56.82 25.86,56.94 25.68,57.08 25.50,57.24 25.34)',
        4326
    )
),
(
    'Khasab Kumzar Passenger Circuit',
    'PASSENGER',
    ARRAY['Passenger'],
    true,
    'Closed passenger-service circuit in the northern Musandam coastal waters.',
    ST_GeomFromText(
        'LINESTRING(56.43 26.27,56.55 26.38,56.45 26.53,56.27 26.57,56.16 26.48,56.23 26.34,56.43 26.27)',
        4326
    )
),
(
    'Musandam Coastal Fishing Circuit',
    'FISHING',
    ARRAY['Fishing'],
    true,
    'Closed fishing circuit east of Musandam for the simulated small-vessel fleet.',
    ST_GeomFromText(
        'LINESTRING(56.69 26.08,56.84 25.93,56.94 25.73,56.87 25.55,56.71 25.62,56.61 25.82,56.69 26.08)',
        4326
    )
),
(
    'Musandam Hormuz Anchorage Circuit',
    'PORT',
    ARRAY['Cargo', 'Tanker', 'Passenger', 'Fishing', 'Other'],
    true,
    'Closed offshore holding and service circuit west of the Musandam approaches.',
    ST_GeomFromText(
        'LINESTRING(55.76 26.34,55.98 26.45,56.18 26.50,56.08 26.34,55.88 26.29,55.76 26.34)',
        4326
    )
);

-- Deterministically distribute every existing simulated vessel across the new
-- routes. Thirty vessels remain stationary to represent anchored traffic.
CREATE TEMP TABLE _musandam_vessel_assignment ON COMMIT DROP AS
WITH ranked_vessels AS (
    SELECT
        p.*,
        row_number() OVER (ORDER BY p.mmsi, p.id) AS vessel_rank
    FROM public.ship_position p
    WHERE p.mmsi IS NOT NULL
),
route_assignment AS (
    SELECT
        p.*,
        r.route_id,
        r.route_kind,
        r.geom AS route_geom,
        p.vessel_rank <= 30 AS is_anchored,
        0.08 + (mod(abs(hashtext(p.mmsi)::bigint), 8400) / 10000.0) AS route_progress,
        CASE WHEN mod(abs(hashtext(p.mmsi || ':direction')::bigint), 2) = 0 THEN 1 ELSE -1 END::smallint AS direction
    FROM ranked_vessels p
    CROSS JOIN LATERAL (
        SELECT candidate.*
        FROM public.shipping_route candidate
        WHERE candidate.enabled = true
          AND COALESCE(p.ship_type, 'Other') = ANY(candidate.allowed_ship_types)
        ORDER BY md5(p.mmsi || candidate.route_name)
        LIMIT 1
    ) r
),
route_points AS (
    SELECT
        a.*,
        ST_LineInterpolatePoint(a.route_geom, a.route_progress)::geometry(Point, 4326) AS position_geom,
        ST_LineInterpolatePoint(
            a.route_geom,
            LEAST(0.9999, GREATEST(0.0001, a.route_progress + a.direction * 0.0005))
        )::geometry(Point, 4326) AS probe_geom
    FROM route_assignment a
)
SELECT
    route_points.*,
    CASE
        WHEN is_anchored THEN 0.0
        WHEN ship_type = 'Fishing' THEN 4.0 + mod(abs(hashtext(mmsi || ':speed')::bigint), 40) / 10.0
        WHEN ship_type = 'Passenger' THEN 12.0 + mod(abs(hashtext(mmsi || ':speed')::bigint), 70) / 10.0
        WHEN ship_type = 'Tanker' THEN 8.0 + mod(abs(hashtext(mmsi || ':speed')::bigint), 55) / 10.0
        ELSE 10.0 + mod(abs(hashtext(mmsi || ':speed')::bigint), 65) / 10.0
    END AS simulated_speed,
    CASE
        WHEN ST_Equals(position_geom, probe_geom) THEN 0.0
        ELSE degrees(ST_Azimuth(position_geom::geography, probe_geom::geography))
    END AS simulated_course
FROM route_points;

UPDATE public.ship_position p
SET longitude = ST_X(a.position_geom),
    latitude = ST_Y(a.position_geom),
    speed = a.simulated_speed,
    course = a.simulated_course,
    update_time = CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    geom = a.position_geom
FROM _musandam_vessel_assignment a
WHERE p.id = a.id;

INSERT INTO public.ship_motion_state (
    mmsi,
    motion_mode,
    route_id,
    route_progress,
    direction,
    anchor_geom,
    route_distance_m,
    lateral_offset_m,
    simulated_speed,
    simulated_course,
    movement_enabled,
    track_enabled,
    needs_route_review,
    last_position_time,
    last_track_time,
    local_progress,
    local_radius_m,
    created_at,
    updated_at
)
SELECT
    mmsi,
    CASE
        WHEN is_anchored THEN 'ANCHORED'
        WHEN route_kind = 'FISHING' THEN 'FISHING'
        WHEN route_kind = 'PASSENGER' THEN 'PASSENGER'
        WHEN route_kind = 'PORT' THEN 'PORT'
        WHEN route_kind = 'OFFSHORE' THEN 'OFFSHORE'
        ELSE 'ROUTE'
    END,
    CASE WHEN is_anchored THEN NULL ELSE route_id END,
    route_progress,
    direction,
    position_geom,
    CASE WHEN is_anchored THEN NULL ELSE 0.0 END,
    CASE
        WHEN is_anchored THEN 0.0
        WHEN ship_type = 'Fishing' THEN 60.0
        WHEN ship_type = 'Passenger' THEN 100.0
        WHEN ship_type = 'Tanker' THEN 220.0
        ELSE 180.0
    END * (mod(abs(hashtext(mmsi || ':offset')::bigint), 2001) / 1000.0 - 1.0),
    simulated_speed,
    simulated_course,
    true,
    NOT is_anchored,
    false,
    CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    NULL,
    mod(abs(hashtext(mmsi || ':local')::bigint), 10000) / 10000.0,
    CASE
        WHEN ship_type = 'Fishing' THEN 120.0
        WHEN ship_type = 'Passenger' THEN 180.0
        ELSE 250.0
    END,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM _musandam_vessel_assignment;

-- Replace all Oman-wide history with a coherent 90-minute Musandam history.
TRUNCATE TABLE public.ship_track RESTART IDENTITY;

WITH track_points AS (
    SELECT
        a.*,
        point_number,
        LEAST(
            0.9999,
            GREATEST(
                0.0001,
                a.route_progress - a.direction * ((17 - point_number) * 0.0035)
            )
        ) AS historical_progress
    FROM _musandam_vessel_assignment a
    CROSS JOIN generate_series(0, 17) AS series(point_number)
    WHERE NOT a.is_anchored
),
geometries AS (
    SELECT
        track_points.*,
        ST_LineInterpolatePoint(route_geom, historical_progress)::geometry(Point, 4326) AS track_geom,
        ST_LineInterpolatePoint(
            route_geom,
            LEAST(0.9999, GREATEST(0.0001, historical_progress + direction * 0.0005))
        )::geometry(Point, 4326) AS track_probe
    FROM track_points
)
INSERT INTO public.ship_track (
    mmsi,
    ship_name,
    ship_type,
    longitude,
    latitude,
    speed,
    course,
    update_time,
    geom
)
SELECT
    mmsi,
    ship_name,
    ship_type,
    ST_X(track_geom),
    ST_Y(track_geom),
    simulated_speed,
    CASE
        WHEN ST_Equals(track_geom, track_probe) THEN simulated_course
        ELSE degrees(ST_Azimuth(track_geom::geography, track_probe::geography))
    END,
    (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') - ((17 - point_number) * INTERVAL '5 minutes'),
    track_geom
FROM geometries
ORDER BY mmsi, point_number;

UPDATE public.ship_motion_state
SET last_track_time = CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    updated_at = CURRENT_TIMESTAMP
WHERE track_enabled = true;

-- Rebuild every simulated pollution-related business table in the same area.
TRUNCATE TABLE
    public.oil_spill_area,
    public.oil_spill_event,
    public.suspicious_ship,
    public.warning_area,
    public.sea_risk_index
RESTART IDENTITY;

CREATE TEMP TABLE _musandam_event_definitions ON COMMIT DROP AS
WITH definitions(event_id, route_name, route_progress, radius_m, level, status, event_time) AS (
    VALUES
        ('MS-001', 'Musandam Hormuz Eastbound Lane', 0.46::double precision, 5500.0, '高', '监测中', CURRENT_TIMESTAMP - INTERVAL '10 hours'),
        ('MS-002', 'Musandam Hormuz Westbound Lane', 0.58::double precision, 4200.0, '中', '待核实', CURRENT_TIMESTAMP - INTERVAL '8 hours'),
        ('MS-003', 'Khasab Kumzar Passenger Circuit', 0.24::double precision, 3000.0, '高', '处置中', CURRENT_TIMESTAMP - INTERVAL '6 hours'),
        ('MS-004', 'Musandam East Coast Offshore Lane', 0.55::double precision, 4800.0, '中', '监测中', CURRENT_TIMESTAMP - INTERVAL '4 hours'),
        ('MS-005', 'Musandam Hormuz Anchorage Circuit', 0.64::double precision, 3500.0, '低', '待核实', CURRENT_TIMESTAMP - INTERVAL '2 hours')
),
centers AS (
    SELECT
        d.*,
        ST_LineInterpolatePoint(r.geom, d.route_progress)::geometry(Point, 4326) AS center_geom
    FROM definitions d
    JOIN public.shipping_route r USING (route_name)
),
vertices AS (
    SELECT
        c.*,
        vertex_number,
        ST_Project(
            c.center_geom::geography,
            c.radius_m * (ARRAY[0.86,1.18,0.94,1.24,0.79,1.10,0.91,1.21,0.83,1.14,0.89,1.17]::double precision[])[vertex_number + 1],
            radians(vertex_number * 30.0)
        )::geometry(Point, 4326) AS vertex_geom
    FROM centers c
    CROSS JOIN generate_series(0, 11) AS series(vertex_number)
),
rings AS (
    SELECT
        event_id,
        route_name,
        route_progress,
        radius_m,
        level,
        status,
        event_time,
        center_geom,
        ST_MakeLine(vertex_geom ORDER BY vertex_number) AS open_ring
    FROM vertices
    GROUP BY event_id, route_name, route_progress, radius_m, level, status, event_time, center_geom
)
SELECT
    event_id,
    route_name,
    route_progress,
    radius_m,
    level,
    status,
    event_time,
    center_geom,
    ST_MakePolygon(ST_AddPoint(open_ring, ST_StartPoint(open_ring)))::geometry(Polygon, 4326) AS area_geom
FROM rings;

INSERT INTO public.oil_spill_event (event_id, event_time, source, status, geom)
SELECT
    event_id,
    event_time,
    'SAR imagery interpretation',
    status,
    center_geom
FROM _musandam_event_definitions
ORDER BY event_id;

INSERT INTO public.oil_spill_area (event_id, event_time, area_km2, level, status, geom)
SELECT
    event_id,
    event_time,
    ROUND((ST_Area(area_geom::geography) / 1000000.0)::numeric, 2),
    level,
    status,
    area_geom
FROM _musandam_event_definitions
ORDER BY event_id;

INSERT INTO public.warning_area (
    warning_name,
    warning_level,
    reason,
    warning_time,
    geom
)
SELECT
    event_id || ' 穆桑达姆油污扩散预警区',
    level,
    '根据浮油范围、附近船舶活动及霍尔木兹海峡水域建立的模拟扩散监测范围',
    event_time + INTERVAL '35 minutes',
    ST_Buffer(center_geom::geography, radius_m * 2.1)::geometry(Polygon, 4326)
FROM _musandam_event_definitions
ORDER BY event_id;

INSERT INTO public.sea_risk_index (
    risk_level,
    coefficient,
    area_name,
    basis,
    draw_order,
    geom,
    fill_hex,
    display_opacity
)
SELECT
    risk_level,
    coefficient,
    area_name,
    basis,
    draw_order,
    ST_Multi(ST_Buffer(center_geom::geography, radius_m)::geometry)::geometry(MultiPolygon, 4326),
    fill_hex,
    display_opacity
FROM (
    SELECT '高'::text AS risk_level, 0.9::numeric AS coefficient,
           '霍尔木兹海峡重点监测区'::text AS area_name,
           '船流密度、油污事件与航道交汇分析'::text AS basis,
           3 AS draw_order, center_geom, 18000.0 AS radius_m,
           '#e85d5d'::varchar(7) AS fill_hex, 42::smallint AS display_opacity
    FROM _musandam_event_definitions WHERE event_id = 'MS-001'
    UNION ALL
    SELECT '中', 0.6, '穆桑达姆东岸扩散关注区', '东岸污染足迹与海上活动综合分析',
           2, center_geom, 14000.0, '#f0ad3d', 34::smallint
    FROM _musandam_event_definitions WHERE event_id = 'MS-004'
    UNION ALL
    SELECT '低', 0.3, '哈萨卜北部常规观察区', '港口及沿岸船舶活动背景监测',
           1, center_geom, 11000.0, '#4caf7a', 26::smallint
    FROM _musandam_event_definitions WHERE event_id = 'MS-003'
) risk_seed;

-- Select 22 vessels whose stored tracks intersect or closely approach one of
-- the five spill footprints. Their current points remain clickable on the map.
WITH candidates AS (
    SELECT
        t.mmsi,
        t.ship_name,
        t.ship_type,
        e.event_id,
        ST_Distance(t.geom::geography, e.area_geom::geography) AS distance_m,
        row_number() OVER (
            PARTITION BY e.event_id
            ORDER BY ST_Distance(t.geom::geography, e.area_geom::geography), t.mmsi
        ) AS event_rank
    FROM public.ship_track_lines t
    CROSS JOIN _musandam_event_definitions e
    WHERE ST_DWithin(t.geom::geography, e.area_geom::geography, 10000.0)
),
deduplicated AS (
    SELECT DISTINCT ON (mmsi)
        mmsi,
        ship_name,
        ship_type,
        event_id,
        distance_m
    FROM candidates
    WHERE event_rank <= 8
    ORDER BY mmsi, distance_m
),
selected AS (
    SELECT
        deduplicated.*,
        row_number() OVER (ORDER BY distance_m, mmsi) AS risk_rank
    FROM deduplicated
    ORDER BY distance_m, mmsi
    LIMIT 22
)
INSERT INTO public.suspicious_ship (
    mmsi,
    ship_name,
    reason,
    risk_level,
    geom
)
SELECT
    selected.mmsi,
    selected.ship_name,
    selected.event_id || ' 历史轨迹穿过或接近模拟油污范围',
    CASE WHEN risk_rank <= 6 THEN '高' WHEN risk_rank <= 14 THEN '中' ELSE '低' END,
    position.geom
FROM selected
JOIN public.ship_position position USING (mmsi)
ORDER BY risk_rank;

-- The migration should fail as one transaction if any business layer escapes
-- the agreed monitoring envelope or if an event has no matching vessel track.
DO $$
DECLARE
    aoi geometry := ST_GeomFromText(
        'POLYGON((55.45 25.05,57.45 25.05,57.45 26.75,55.45 26.75,55.45 25.05))',
        4326
    );
    outside_count bigint;
    unmatched_count bigint;
BEGIN
    SELECT count(*) INTO outside_count
    FROM (
        SELECT geom FROM public.ship_position
        UNION ALL SELECT geom FROM public.ship_track
        UNION ALL SELECT geom FROM public.oil_spill_event
        UNION ALL SELECT geom FROM public.oil_spill_area
        UNION ALL SELECT geom FROM public.suspicious_ship
        UNION ALL SELECT geom FROM public.warning_area
        UNION ALL SELECT geom FROM public.sea_risk_index
        UNION ALL SELECT geom FROM public.shipping_route
    ) business_geometry
    WHERE geom IS NULL OR NOT ST_CoveredBy(geom, aoi);

    IF outside_count > 0 THEN
        RAISE EXCEPTION '% generated business geometries fall outside the Musandam monitoring envelope.', outside_count;
    END IF;

    SELECT count(*) INTO unmatched_count
    FROM public.oil_spill_area spill
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.ship_track_lines track
        WHERE ST_Intersects(track.geom, spill.geom)
    );

    IF unmatched_count > 0 THEN
        RAISE EXCEPTION '% pollution events do not intersect a stored vessel track.', unmatched_count;
    END IF;

    IF (SELECT count(*) FROM public.ship_position) <> (SELECT count(*) FROM public.ship_motion_state) THEN
        RAISE EXCEPTION 'Every simulated vessel must have one motion-state record.';
    END IF;
END
$$;

COMMIT;

SELECT
    (SELECT count(*) FROM public.ship_position) AS vessels,
    (SELECT count(*) FROM public.ship_motion_state WHERE motion_mode <> 'ANCHORED') AS moving_vessels,
    (SELECT count(*) FROM public.ship_motion_state WHERE motion_mode = 'ANCHORED') AS anchored_vessels,
    (SELECT count(DISTINCT mmsi) FROM public.ship_track) AS tracked_vessels,
    (SELECT count(*) FROM public.oil_spill_event) AS pollution_events,
    (SELECT count(*) FROM public.suspicious_ship) AS suspicious_vessels,
    (SELECT count(*) FROM public.warning_area) AS warning_areas,
    (SELECT count(*) FROM public.sea_risk_index) AS risk_areas;
