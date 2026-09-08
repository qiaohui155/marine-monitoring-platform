BEGIN;

-- Reduce the dense 2,916-vessel Musandam simulation to a representative fleet
-- of 500. The retained fleet keeps the original vessel-type proportions while
-- using three visual behaviours: route-following, local offshore movement and
-- stationary anchorage.

DO $$
BEGIN
    IF to_regclass('public.monitoring_area') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM public.monitoring_area
           WHERE area_code = 'MUSANDAM_HORMUZ'
       ) THEN
        RAISE EXCEPTION 'Run 007_focus_simulation_on_musandam.sql first.';
    END IF;
END
$$;

LOCK TABLE public.ship_position IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_track IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_motion_state IN SHARE ROW EXCLUSIVE MODE;

-- Preserve a proportional selection: 190 cargo, 189 tanker, 63 passenger and
-- 58 fishing vessels. Hash ordering makes the selection stable and repeatable.
CREATE TEMP TABLE _musandam_retained_vessels (
    mmsi varchar(20) PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO _musandam_retained_vessels (mmsi)
WITH ranked AS (
    SELECT
        mmsi,
        ship_type,
        row_number() OVER (
            PARTITION BY ship_type
            ORDER BY md5(mmsi || ':musandam-500')
        ) AS type_rank
    FROM public.ship_position
    WHERE mmsi IS NOT NULL
)
SELECT mmsi
FROM ranked
WHERE type_rank <= CASE ship_type
    WHEN 'Cargo' THEN 190
    WHEN 'Tanker' THEN 189
    WHEN 'Passenger' THEN 63
    WHEN 'Fishing' THEN 58
    ELSE 0
END;

DO $$
BEGIN
    IF (SELECT count(*) FROM _musandam_retained_vessels) <> 500 THEN
        RAISE EXCEPTION 'The proportional fleet selection did not produce exactly 500 vessels.';
    END IF;
END
$$;

TRUNCATE TABLE public.ship_motion_state;
TRUNCATE TABLE public.ship_track RESTART IDENTITY;

DELETE FROM public.ship_position position
WHERE NOT EXISTS (
    SELECT 1
    FROM _musandam_retained_vessels retained
    WHERE retained.mmsi = position.mmsi
);

-- Build an organic-looking operating picture:
--   1-420   follow one of six compatible routes with varied offsets;
--   421-480 move around local offshore activity centres;
--   481-500 remain anchored while their timestamps continue to refresh.
CREATE TEMP TABLE _musandam_fleet_assignment ON COMMIT DROP AS
WITH ranked AS (
    SELECT
        position.*,
        row_number() OVER (ORDER BY md5(position.mmsi || ':layout')) AS fleet_rank
    FROM public.ship_position position
),
route_source AS (
    SELECT
        vessel.*,
        route.route_id,
        route.route_kind,
        route.geom AS route_geom,
        0.07 + mod(abs(hashtext(vessel.mmsi || ':progress')::bigint), 8600) / 10000.0 AS route_progress,
        CASE
            WHEN mod(abs(hashtext(vessel.mmsi || ':direction')::bigint), 2) = 0 THEN 1
            ELSE -1
        END::smallint AS direction,
        CASE
            WHEN vessel.fleet_rank <= 420
                THEN mod(abs(hashtext(vessel.mmsi || ':lane-offset')::bigint), 1401) - 700
            WHEN vessel.fleet_rank <= 480
                THEN mod(abs(hashtext(vessel.mmsi || ':local-offset')::bigint), 3001) - 1500
            ELSE mod(abs(hashtext(vessel.mmsi || ':anchor-offset')::bigint), 401) - 200
        END::double precision AS placement_offset_m
    FROM ranked vessel
    CROSS JOIN LATERAL (
        SELECT candidate.*
        FROM public.shipping_route candidate
        WHERE candidate.enabled = true
          AND vessel.ship_type = ANY(candidate.allowed_ship_types)
        ORDER BY md5(vessel.mmsi || ':route:' || candidate.route_name)
        LIMIT 1
    ) route
),
route_geometry AS (
    SELECT
        source.*,
        ST_LineInterpolatePoint(source.route_geom, source.route_progress)::geometry(Point, 4326) AS route_point,
        ST_LineInterpolatePoint(
            source.route_geom,
            LEAST(0.9999, GREATEST(0.0001, source.route_progress + source.direction * 0.0005))
        )::geometry(Point, 4326) AS route_probe
    FROM route_source source
),
placed AS (
    SELECT
        route_geometry.*,
        CASE
            WHEN abs(placement_offset_m) < 0.01 THEN route_point
            ELSE ST_Project(
                route_point::geography,
                abs(placement_offset_m),
                ST_Azimuth(route_point::geography, route_probe::geography)
                  + CASE WHEN placement_offset_m >= 0 THEN pi() / 2 ELSE -pi() / 2 END
            )::geometry(Point, 4326)
        END AS activity_anchor,
        mod(abs(hashtext(mmsi || ':local-progress')::bigint), 10000) / 10000.0 AS local_progress,
        350.0 + mod(abs(hashtext(mmsi || ':local-radius')::bigint), 1051) AS local_radius_m,
        CASE
            WHEN fleet_rank > 480 THEN 0.0
            WHEN ship_type = 'Fishing' THEN 4.0 + mod(abs(hashtext(mmsi || ':speed')::bigint), 35) / 10.0
            WHEN ship_type = 'Passenger' THEN 12.0 + mod(abs(hashtext(mmsi || ':speed')::bigint), 65) / 10.0
            WHEN ship_type = 'Tanker' THEN 8.0 + mod(abs(hashtext(mmsi || ':speed')::bigint), 50) / 10.0
            ELSE 10.0 + mod(abs(hashtext(mmsi || ':speed')::bigint), 60) / 10.0
        END AS simulated_speed
    FROM route_geometry
),
final_geometry AS (
    SELECT
        placed.*,
        CASE
            WHEN fleet_rank BETWEEN 421 AND 480 THEN ST_Project(
                activity_anchor::geography,
                local_radius_m,
                2.0 * pi() * local_progress
            )::geometry(Point, 4326)
            ELSE activity_anchor
        END AS position_geom
    FROM placed
)
SELECT
    final_geometry.*,
    CASE
        WHEN fleet_rank > 480 THEN 0.0
        WHEN fleet_rank BETWEEN 421 AND 480
            THEN degrees(2.0 * pi() * local_progress + pi() / 2)
              - floor(degrees(2.0 * pi() * local_progress + pi() / 2) / 360.0) * 360.0
        ELSE degrees(ST_Azimuth(route_point::geography, route_probe::geography))
    END AS simulated_course
FROM final_geometry;

UPDATE public.ship_position position
SET longitude = ST_X(assignment.position_geom),
    latitude = ST_Y(assignment.position_geom),
    speed = assignment.simulated_speed,
    course = assignment.simulated_course,
    update_time = CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    geom = assignment.position_geom
FROM _musandam_fleet_assignment assignment
WHERE position.mmsi = assignment.mmsi;

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
        WHEN fleet_rank > 480 THEN 'ANCHORED'
        WHEN fleet_rank BETWEEN 421 AND 480 AND ship_type = 'Fishing' THEN 'FISHING'
        WHEN fleet_rank BETWEEN 421 AND 480 AND ship_type = 'Passenger' THEN 'PASSENGER'
        WHEN fleet_rank BETWEEN 421 AND 480 THEN 'OFFSHORE'
        WHEN route_kind = 'FISHING' THEN 'FISHING'
        WHEN route_kind = 'PASSENGER' THEN 'PASSENGER'
        WHEN route_kind = 'PORT' THEN 'PORT'
        WHEN route_kind = 'OFFSHORE' THEN 'OFFSHORE'
        ELSE 'ROUTE'
    END,
    CASE WHEN fleet_rank <= 420 THEN route_id ELSE NULL END,
    route_progress,
    direction,
    CASE WHEN fleet_rank BETWEEN 421 AND 480 THEN activity_anchor ELSE position_geom END,
    CASE WHEN fleet_rank <= 420 THEN 0.0 ELSE NULL END,
    CASE WHEN fleet_rank <= 420 THEN placement_offset_m ELSE 0.0 END,
    simulated_speed,
    simulated_course,
    true,
    fleet_rank <= 480,
    false,
    CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    NULL,
    local_progress,
    CASE WHEN fleet_rank BETWEEN 421 AND 480 THEN local_radius_m ELSE 250.0 END,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM _musandam_fleet_assignment;

-- Generate a compact 90-minute history for all 480 moving vessels. Route
-- followers use their assigned lane; local vessels use short offshore arcs.
WITH time_steps AS (
    SELECT
        assignment.*,
        point_number,
        LEAST(
            0.9999,
            GREATEST(
                0.0001,
                route_progress - direction * ((17 - point_number) * 0.0035)
            )
        ) AS historical_progress,
        local_progress - direction * ((17 - point_number) * 0.018) AS historical_local_progress
    FROM _musandam_fleet_assignment assignment
    CROSS JOIN generate_series(0, 17) AS series(point_number)
    WHERE fleet_rank <= 480
),
historical_geometry AS (
    SELECT
        time_steps.*,
        CASE
            WHEN fleet_rank <= 420 THEN ST_Project(
                ST_LineInterpolatePoint(route_geom, historical_progress)::geography,
                abs(placement_offset_m),
                ST_Azimuth(
                    ST_LineInterpolatePoint(route_geom, historical_progress)::geography,
                    ST_LineInterpolatePoint(
                        route_geom,
                        LEAST(0.9999, GREATEST(0.0001, historical_progress + direction * 0.0005))
                    )::geography
                ) + CASE WHEN placement_offset_m >= 0 THEN pi() / 2 ELSE -pi() / 2 END
            )::geometry(Point, 4326)
            ELSE ST_Project(
                activity_anchor::geography,
                local_radius_m,
                2.0 * pi() * (historical_local_progress - floor(historical_local_progress))
            )::geometry(Point, 4326)
        END AS track_geom
    FROM time_steps
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
    simulated_course,
    (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') - ((17 - point_number) * INTERVAL '5 minutes'),
    track_geom
FROM historical_geometry
ORDER BY mmsi, point_number;

UPDATE public.ship_motion_state
SET last_track_time = CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    updated_at = CURRENT_TIMESTAMP
WHERE track_enabled = true;

-- Recalculate the suspicious-vessel layer from the retained track catalogue.
TRUNCATE TABLE public.suspicious_ship RESTART IDENTITY;

WITH candidates AS (
    SELECT
        track.mmsi,
        track.ship_name,
        spill.event_id,
        ST_Distance(track.geom::geography, spill.geom::geography) AS distance_m,
        row_number() OVER (
            PARTITION BY spill.event_id
            ORDER BY ST_Distance(track.geom::geography, spill.geom::geography), track.mmsi
        ) AS event_rank
    FROM public.ship_track_lines track
    CROSS JOIN public.oil_spill_area spill
    WHERE ST_DWithin(track.geom::geography, spill.geom::geography, 10000.0)
),
deduplicated AS (
    SELECT DISTINCT ON (mmsi)
        mmsi,
        ship_name,
        event_id,
        distance_m
    FROM candidates
    WHERE event_rank <= 12
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
INSERT INTO public.suspicious_ship (mmsi, ship_name, reason, risk_level, geom)
SELECT
    selected.mmsi,
    selected.ship_name,
    selected.event_id || ' 历史轨迹穿过或接近模拟油污范围',
    CASE WHEN risk_rank <= 6 THEN '高' WHEN risk_rank <= 14 THEN '中' ELSE '低' END,
    position.geom
FROM selected
JOIN public.ship_position position USING (mmsi)
ORDER BY risk_rank;

DO $$
DECLARE
    aoi geometry;
    outside_count bigint;
BEGIN
    SELECT geom INTO aoi
    FROM public.monitoring_area
    WHERE area_code = 'MUSANDAM_HORMUZ';

    SELECT count(*) INTO outside_count
    FROM (
        SELECT geom FROM public.ship_position
        UNION ALL SELECT geom FROM public.ship_track
        UNION ALL SELECT geom FROM public.suspicious_ship
    ) retained_geometry
    WHERE geom IS NULL OR NOT ST_CoveredBy(geom, aoi);

    IF outside_count > 0 THEN
        RAISE EXCEPTION '% retained fleet geometries fall outside the Musandam monitoring envelope.', outside_count;
    END IF;

    IF (SELECT count(*) FROM public.ship_position) <> 500 THEN
        RAISE EXCEPTION 'The active simulated fleet must contain exactly 500 vessels.';
    END IF;

    IF (SELECT count(*) FROM public.ship_motion_state WHERE route_id IS NOT NULL) <> 420 THEN
        RAISE EXCEPTION 'The route-following fleet must contain exactly 420 vessels.';
    END IF;

    IF (
        SELECT count(*) FROM public.ship_motion_state
        WHERE route_id IS NULL AND motion_mode <> 'ANCHORED' AND simulated_speed > 0
    ) <> 60 THEN
        RAISE EXCEPTION 'The local offshore fleet must contain exactly 60 vessels.';
    END IF;

    IF (SELECT count(*) FROM public.ship_motion_state WHERE motion_mode = 'ANCHORED') <> 20 THEN
        RAISE EXCEPTION 'The anchored fleet must contain exactly 20 vessels.';
    END IF;

    IF (SELECT count(DISTINCT mmsi) FROM public.ship_track) <> 480 THEN
        RAISE EXCEPTION 'All 480 moving vessels must have a historical track.';
    END IF;
END
$$;

COMMIT;

SELECT
    (SELECT count(*) FROM public.ship_position) AS vessels,
    (SELECT count(*) FROM public.ship_motion_state WHERE route_id IS NOT NULL) AS route_following,
    (SELECT count(*) FROM public.ship_motion_state WHERE route_id IS NULL AND motion_mode <> 'ANCHORED') AS local_movement,
    (SELECT count(*) FROM public.ship_motion_state WHERE motion_mode = 'ANCHORED') AS anchored,
    (SELECT count(DISTINCT mmsi) FROM public.ship_track) AS tracked_vessels,
    (SELECT count(*) FROM public.suspicious_ship) AS suspicious_vessels;
