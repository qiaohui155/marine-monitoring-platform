BEGIN;

-- Expand the Musandam operating picture from 500 to 1,000 vessels and replace
-- the strongly linear arrangement with a broad, deterministic maritime cloud.
-- The distribution remains reproducible while looking irregular on the map:
--   180 route followers, 770 locally moving vessels and 50 anchored vessels.

DO $$
BEGIN
    IF to_regclass('public.monitoring_area') IS NULL
       OR NOT EXISTS (
           SELECT 1
           FROM public.monitoring_area
           WHERE area_code = 'MUSANDAM_HORMUZ'
       ) THEN
        RAISE EXCEPTION 'Run 007_focus_simulation_on_musandam.sql first.';
    END IF;

    IF (SELECT count(*) FROM public.ship_position) <> 500 THEN
        RAISE EXCEPTION 'This migration expects the current 500-vessel fleet.';
    END IF;
END
$$;

LOCK TABLE public.ship_position IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_track IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_motion_state IN SHARE ROW EXCLUSIVE MODE;

-- Add another proportional set of 500 vessels. New MMSIs use a separate local
-- simulation range, so they cannot collide with the retained vessel records.
INSERT INTO public.ship_position (
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
    (471000000 + source.source_rank)::varchar(20),
    upper(source.ship_type) || '-' || lpad((5000 + source.source_rank)::text, 4, '0'),
    source.ship_type,
    source.longitude,
    source.latitude,
    source.speed,
    source.course,
    CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    source.geom
FROM (
    SELECT
        position.*,
        row_number() OVER (ORDER BY position.ship_type, md5(position.mmsi || ':expand-1000')) AS source_rank
    FROM public.ship_position position
) source;

DO $$
BEGIN
    IF (SELECT count(*) FROM public.ship_position) <> 1000 THEN
        RAISE EXCEPTION 'Fleet expansion did not produce exactly 1,000 vessels.';
    END IF;
END
$$;

TRUNCATE TABLE public.ship_motion_state;
TRUNCATE TABLE public.ship_track RESTART IDENTITY;

-- Select a compatible water corridor for every vessel, then spread most
-- vessels around those corridors with broad lateral offsets and independent
-- local phases. The corridors are placement guides, not visible grid lines.
CREATE TEMP TABLE _musandam_1000_assignment ON COMMIT DROP AS
WITH ranked AS (
    SELECT
        position.*,
        row_number() OVER (ORDER BY md5(position.mmsi || ':organic-1000')) AS fleet_rank
    FROM public.ship_position position
),
route_source AS (
    SELECT
        vessel.*,
        route.route_id,
        route.route_kind,
        route.geom AS route_geom,
        0.10 + mod(abs(hashtext(vessel.mmsi || ':progress-1000')::bigint), 8001) / 10000.0 AS route_progress,
        CASE
            WHEN mod(abs(hashtext(vessel.mmsi || ':direction-1000')::bigint), 2) = 0 THEN 1
            ELSE -1
        END::smallint AS direction,
        CASE
            WHEN vessel.fleet_rank <= 180 THEN
                mod(abs(hashtext(vessel.mmsi || ':route-lane-1000')::bigint), 4001) - 2000
            WHEN vessel.fleet_rank <= 950 THEN
                mod(abs(hashtext(vessel.mmsi || ':scatter-band-1000')::bigint), 18001) - 9000
            ELSE
                mod(abs(hashtext(vessel.mmsi || ':anchor-band-1000')::bigint), 9001) - 4500
        END::double precision AS placement_offset_m
    FROM ranked vessel
    CROSS JOIN LATERAL (
        SELECT candidate.*
        FROM public.shipping_route candidate
        WHERE candidate.enabled = true
          AND vessel.ship_type = ANY(candidate.allowed_ship_types)
        ORDER BY md5(vessel.mmsi || ':organic-route:' || candidate.route_name)
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
activity_centres AS (
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
        mod(abs(hashtext(mmsi || ':local-phase-1000')::bigint), 10000) / 10000.0 AS local_progress,
        CASE
            WHEN fleet_rank <= 180 THEN 180.0
            WHEN fleet_rank <= 950
                THEN 450.0 + mod(abs(hashtext(mmsi || ':local-radius-1000')::bigint), 2751)
            ELSE 120.0 + mod(abs(hashtext(mmsi || ':anchor-radius-1000')::bigint), 281)
        END::double precision AS local_radius_m,
        CASE
            WHEN fleet_rank > 950 THEN 0.0
            WHEN ship_type = 'Fishing' THEN 3.0 + mod(abs(hashtext(mmsi || ':speed-1000')::bigint), 45) / 10.0
            WHEN ship_type = 'Passenger' THEN 11.0 + mod(abs(hashtext(mmsi || ':speed-1000')::bigint), 80) / 10.0
            WHEN ship_type = 'Tanker' THEN 7.0 + mod(abs(hashtext(mmsi || ':speed-1000')::bigint), 65) / 10.0
            ELSE 9.0 + mod(abs(hashtext(mmsi || ':speed-1000')::bigint), 75) / 10.0
        END AS simulated_speed
    FROM route_geometry
),
placed AS (
    SELECT
        centres.*,
        CASE
            WHEN fleet_rank BETWEEN 181 AND 950 THEN ST_Project(
                activity_anchor::geography,
                local_radius_m,
                2.0 * pi() * local_progress
            )::geometry(Point, 4326)
            ELSE activity_anchor
        END AS position_geom
    FROM activity_centres centres
)
SELECT
    placed.*,
    CASE
        WHEN fleet_rank > 950 THEN 0.0
        WHEN fleet_rank BETWEEN 181 AND 950 THEN
            degrees(2.0 * pi() * local_progress + pi() / 2)
              - floor(degrees(2.0 * pi() * local_progress + pi() / 2) / 360.0) * 360.0
        ELSE degrees(ST_Azimuth(route_point::geography, route_probe::geography))
    END AS simulated_course
FROM placed;

UPDATE public.ship_position position
SET longitude = ST_X(assignment.position_geom),
    latitude = ST_Y(assignment.position_geom),
    speed = assignment.simulated_speed,
    course = assignment.simulated_course,
    update_time = CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    geom = assignment.position_geom
FROM _musandam_1000_assignment assignment
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
        WHEN fleet_rank > 950 THEN 'ANCHORED'
        WHEN fleet_rank > 180 AND ship_type = 'Fishing' THEN 'FISHING'
        WHEN fleet_rank > 180 AND ship_type = 'Passenger' THEN 'PASSENGER'
        WHEN fleet_rank > 180 THEN 'OFFSHORE'
        WHEN route_kind = 'FISHING' THEN 'FISHING'
        WHEN route_kind = 'PASSENGER' THEN 'PASSENGER'
        WHEN route_kind = 'PORT' THEN 'PORT'
        WHEN route_kind = 'OFFSHORE' THEN 'OFFSHORE'
        ELSE 'ROUTE'
    END,
    CASE WHEN fleet_rank <= 180 THEN route_id ELSE NULL END,
    route_progress,
    direction,
    CASE WHEN fleet_rank > 180 THEN activity_anchor ELSE position_geom END,
    CASE WHEN fleet_rank <= 180 THEN 0.0 ELSE NULL END,
    CASE WHEN fleet_rank <= 180 THEN placement_offset_m ELSE 0.0 END,
    simulated_speed,
    simulated_course,
    true,
    fleet_rank <= 950,
    false,
    CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    NULL,
    local_progress,
    local_radius_m,
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
FROM _musandam_1000_assignment;

-- Seed a short history for every moving vessel. Local vessels use different
-- activity centres, radii and phases, preventing a single shared track line.
WITH time_steps AS (
    SELECT
        assignment.*,
        point_number,
        LEAST(
            0.9999,
            GREATEST(0.0001, route_progress - direction * ((11 - point_number) * 0.0035))
        ) AS historical_progress,
        local_progress - direction * ((11 - point_number) * 0.021) AS historical_local_progress
    FROM _musandam_1000_assignment assignment
    CROSS JOIN generate_series(0, 11) AS series(point_number)
    WHERE fleet_rank <= 950
),
historical_geometry AS (
    SELECT
        steps.*,
        CASE
            WHEN fleet_rank <= 180 THEN ST_Project(
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
    FROM time_steps steps
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
    (CURRENT_TIMESTAMP AT TIME ZONE 'UTC') - ((11 - point_number) * INTERVAL '5 minutes'),
    track_geom
FROM historical_geometry
ORDER BY mmsi, point_number;

UPDATE public.ship_motion_state
SET last_track_time = CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    updated_at = CURRENT_TIMESTAMP
WHERE track_enabled = true;

-- Rebuild the suspect layer so every selected suspect still belongs to the
-- active 1,000-vessel fleet and has a track near a pollution event.
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
    WHERE ST_DWithin(track.geom::geography, spill.geom::geography, 12000.0)
),
deduplicated AS (
    SELECT DISTINCT ON (mmsi)
        mmsi,
        ship_name,
        event_id,
        distance_m
    FROM candidates
    WHERE event_rank <= 16
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
    ) fleet_geometry
    WHERE geom IS NULL OR NOT ST_CoveredBy(geom, aoi);

    IF outside_count > 0 THEN
        RAISE EXCEPTION '% fleet geometries fall outside the Musandam monitoring envelope.', outside_count;
    END IF;

    IF (SELECT count(*) FROM public.ship_position) <> 1000 THEN
        RAISE EXCEPTION 'The active fleet must contain exactly 1,000 vessels.';
    END IF;

    IF (SELECT count(*) FROM public.ship_motion_state WHERE route_id IS NOT NULL) <> 180 THEN
        RAISE EXCEPTION 'The route-following fleet must contain exactly 180 vessels.';
    END IF;

    IF (
        SELECT count(*) FROM public.ship_motion_state
        WHERE route_id IS NULL AND motion_mode <> 'ANCHORED' AND simulated_speed > 0
    ) <> 770 THEN
        RAISE EXCEPTION 'The local moving fleet must contain exactly 770 vessels.';
    END IF;

    IF (SELECT count(*) FROM public.ship_motion_state WHERE motion_mode = 'ANCHORED') <> 50 THEN
        RAISE EXCEPTION 'The anchored fleet must contain exactly 50 vessels.';
    END IF;

    IF (SELECT count(DISTINCT mmsi) FROM public.ship_track) <> 950 THEN
        RAISE EXCEPTION 'All 950 moving vessels must have a historical track.';
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
