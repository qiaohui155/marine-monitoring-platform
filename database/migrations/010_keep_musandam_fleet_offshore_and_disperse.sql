BEGIN;

-- Use a simplified Natural Earth 1:10m land mask to keep every simulated
-- vessel offshore. Spread the fleet broadly across safe Musandam/Hormuz water
-- instead of concentrating most vessels around a few route centre-lines.

CREATE TABLE IF NOT EXISTS public.musandam_land_mask (
    area_code varchar(30) PRIMARY KEY,
    source_name varchar(120) NOT NULL,
    geom geometry(MultiPolygon, 4326) NOT NULL,
    updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS musandam_land_mask_geom_gix
ON public.musandam_land_mask USING gist (geom);

INSERT INTO public.musandam_land_mask (area_code, source_name, geom, updated_at)
VALUES (
    'MUSANDAM_HORMUZ',
    'Natural Earth 1:10m land, simplified for local simulation',
    ST_GeomFromText('MULTIPOLYGON(((55.3 25.25633424157358,55.318369988000086 25.22528717700004,55.301117384000065 25.19367096600007,55.328868035000085 25.20148346600007,55.33423912900008 25.219224351000037,55.30640709700003 25.275051174000055,55.309255405000044 25.29173411700009,55.33936608200008 25.321437893000052,55.363291863000086 25.324042059000078,55.359385613000086 25.348578192000048,55.36548912900008 25.358587958000044,55.376963738000086 25.364976304000038,55.387054884000065 25.357082424000055,55.43897545700008 25.41278717700004,55.45533287900008 25.39988841400009,55.46566816500007 25.419623114000046,55.47250410200007 25.41278717700004,55.48609459700003 25.44993724200009,55.506602410000085 25.47483958500004,55.494151238000086 25.48078034100007,55.53565514400003 25.56240469000005,55.55103600400008 25.578599351000037,55.56812584700003 25.58466217700004,55.54224694100009 25.54254791900007,55.54818769600007 25.52948639500005,55.56373131600009 25.52374909100007,55.62631269600007 25.536322333000044,55.656911655000044 25.597723700000074,55.68344160200007 25.623521226000037,55.73389733200008 25.64679596600007,55.770518425000034 25.687160549000055,55.842458530000044 25.713812567000048,55.87810306100005 25.740057684000078,55.959727410000085 25.82367584800005,55.93718509200005 25.776678778000075,55.95232181100005 25.77212148600006,55.96599368600005 25.83421458500004,56.014414910000085 25.878851630000042,56.03687584700003 25.91510651200008,56.041026238000086 25.933539130000042,56.00757897200003 25.90688711100006,56.055349155000044 25.988755601000037,56.09148196700005 26.10651276200008,56.18181399800005 26.24599844000005,56.20826256600009 26.26308828300006,56.20826256600009 26.24404531500005,56.21989993600005 26.227728583000044,56.21241295700008 26.207831122000073,56.25554446700005 26.218085028000075,56.26685631600009 26.227484442000048,56.29184004000007 26.211859442000048,56.294932488000086 26.194240627000056,56.30193118600005 26.20530833500004,56.329112175000034 26.20107656500005,56.36695397200003 26.221502997000073,56.40414472700007 26.21474844000005,56.406911655000044 26.223130601000037,56.394541863000086 26.239162502000056,56.367849155000044 26.244086005000042,56.34685306100005 26.23859284100007,56.31959069100009 26.217922268000052,56.30844160200007 26.221502997000073,56.31592858200008 26.29043203300006,56.358409050000034 26.264960028000075,56.36378014400003 26.27952708500004,56.34782962300005 26.297430731000077,56.322276238000086 26.30963776200008,56.35629316500007 26.337591864000046,56.36378014400003 26.385972398000035,56.38363691500007 26.358710028000075,56.40414472700007 26.372300523000035,56.41163170700008 26.364935614000046,56.40650475400008 26.354803778000075,56.41163170700008 26.345038153000075,56.42107181100005 26.352118231000077,56.43897545700008 26.337591864000046,56.46216881600009 26.331854559000078,56.487315300000034 26.331366278000075,56.47982832100007 26.35187409100007,56.500987175000034 26.358710028000075,56.50896243600005 26.32371653900009,56.45281009200005 26.31834544500009,56.406260613000086 26.284898179000038,56.39861087300005 26.268703518000052,56.432302280000044 26.239447333000044,56.44581139400003 26.235174872000073,56.47624759200005 26.249172268000052,56.487315300000034 26.235174872000073,56.459646030000044 26.202093817000048,56.45329837300005 26.221502997000073,56.431976759000065 26.221502997000073,56.431976759000065 26.194240627000056,56.47291100400008 26.164007880000042,56.47982832100007 26.145819403000075,56.43897545700008 26.160101630000042,56.424571160000085 26.15379466400009,56.412445509000065 26.15843333500004,56.40414472700007 26.186753648000035,56.37745201900003 26.17373281500005,56.378916863000086 26.192531643000052,56.39112389400003 26.20107656500005,56.36841881600009 26.20453522300005,56.34359785200007 26.19139232000009,56.328786655000044 26.17283763200004,56.335948113000086 26.160101630000042,56.32976321700005 26.137111721000053,56.335948113000086 26.11163971600007,56.35303795700008 26.142645575000074,56.36378014400003 26.145819403000075,56.371104363000086 26.127834377000056,56.36378014400003 26.10488515800006,56.38331139400003 26.097479559000078,56.472992384000065 26.09861888200004,56.449229363000086 26.073553778000075,56.38013756600009 26.038234768000052,56.38363691500007 26.022284247000073,56.408864780000044 26.034369208000044,56.422862175000034 26.023138739000046,56.42335045700008 26.00462474200009,56.400401238000086 25.99046458500004,56.42212975400008 25.95661041900007,56.45329837300005 25.94717031500005,56.43897545700008 25.92609284100007,56.40788821700005 25.93740469000005,56.38363691500007 25.92609284100007,56.399424675000034 25.90232982000009,56.36378014400003 25.837958075000074,56.36378014400003 25.80687083500004,56.31625410200007 25.74957916900007,56.301768425000034 25.74176666900007,56.301768425000034 25.762884833000044,56.273773634000065 25.709133205000057,56.266612175000034 25.67259349200009,56.27906334700003 25.627427476000037,56.34001712300005 25.60455963700008,56.36996504000007 25.52570221600007,56.36378014400003 25.433254299000055,56.36833743600005 25.396307684000078,56.35922285200007 25.37641022300005,56.38363691500007 25.31346263200004,56.365977410000085 25.20921458500004,56.361989780000044 25.05727773600006,56.404704040935876 24.9,55.3 24.9,55.3 25.25633424157358)),((57.59880618600005 25.74640534100007,57.52068118600005 25.74355703300006,57.45248457100007 25.762884833000044,57.459971550000034 25.76902903900009,57.326182488000086 25.777004299000055,57.311534050000034 25.784125067000048,57.29867597700007 25.84870026200008,57.25359134200005 25.95897044500009,57.219737175000034 25.995021877000056,57.19857832100007 25.995021877000056,57.166758660000085 26.08299388200004,57.170909050000034 26.115627346000053,57.212901238000086 26.16624583500004,57.199229363000086 26.198187567000048,57.13306725400008 26.263739325000074,57.13843834700003 26.29043203300006,57.13103274800005 26.296616929000038,57.118174675000034 26.36432526200008,57.08318118600005 26.40648021000004,57.07634524800005 26.44745514500005,57.09343509200005 26.572211005000042,57.09001712300005 26.618801174000055,57.02491295700008 26.85097890800006,56.97371964408276 26.9,57.6 26.9,57.59880618600005 25.74640534100007)),((55.3 26.9,55.584619923443576 26.9,55.580414259000065 26.859116929000038,55.56853274800005 26.83079661700009,55.52173912900008 26.78457265800006,55.48406009200005 26.767523505000042,55.44223066500007 26.759914455000057,55.39730879000007 26.762152411000045,55.3 26.789084345220576,55.3 26.9)),((55.320323113000086 26.278347072000088,55.322601759000065 26.254055080000057,55.3 26.249012219785154,55.3 26.277722482719657,55.320323113000086 26.278347072000088)),((55.85320071700005 26.621039130000042,55.855479363000086 26.64411041900007,55.86833743600005 26.666449286000045,55.89429772200003 26.679429429000038,55.90398196700005 26.64524974200009,55.889659050000034 26.62376536700009,55.86931399800005 26.613023179000038,55.85320071700005 26.621039130000042)),((56.08936608200008 26.793524481000077,56.04281660200007 26.768133856000077,55.97641035200007 26.71157461100006,55.94703209700003 26.69627513200004,55.92400149800005 26.705023505000042,55.87663821700005 26.74290599200009,55.77271569100009 26.688381252000056,55.685557488000086 26.69049713700008,55.502940300000034 26.594875393000052,55.44117272200003 26.58860911700009,55.369476759000065 26.564113674000055,55.33961022200003 26.56899648600006,55.330739780000044 26.553615627000056,55.3 26.543870831946723,55.3 26.65538952841395,55.33187910200007 26.645331122000073,55.351898634000065 26.64744700700004,55.40479576900003 26.67401764500005,55.574229363000086 26.72068919500009,55.64039147200003 26.760565497000073,55.705821160000085 26.783270575000074,55.75416100400008 26.786078192000048,55.774180535000085 26.796942450000074,55.76677493600005 26.81053294500009,55.78207441500007 26.82615794500009,55.78565514400003 26.844956773000035,55.776277960983656 26.9,56.167948105900706 26.9,56.13721764400003 26.844671942000048,56.08936608200008 26.793524481000077)),((56.37916100400008 26.838690497000073,56.34099368600005 26.82762278900009,56.322276238000086 26.834418036000045,56.326833530000044 26.861070054000038,56.34115644600007 26.879339911000045,56.40414472700007 26.893052476000037,56.409190300000034 26.862250067000048,56.37916100400008 26.838690497000073)))', 4326),
    CURRENT_TIMESTAMP
)
ON CONFLICT (area_code) DO UPDATE
SET source_name = EXCLUDED.source_name,
    geom = EXCLUDED.geom,
    updated_at = EXCLUDED.updated_at;

DO $$
BEGIN
    IF (SELECT count(*) FROM public.ship_position) <> 1000 THEN
        RAISE EXCEPTION 'This migration expects the current 1,000-vessel fleet.';
    END IF;
END
$$;

LOCK TABLE public.ship_position IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_track IN SHARE ROW EXCLUSIVE MODE;
LOCK TABLE public.ship_motion_state IN SHARE ROW EXCLUSIVE MODE;

TRUNCATE TABLE public.ship_motion_state;
TRUNCATE TABLE public.ship_track RESTART IDENTITY;

CREATE TEMP TABLE _safe_musandam_water ON COMMIT DROP AS
SELECT ST_Multi(
    ST_CollectionExtract(
        ST_Difference(
            area.geom,
            ST_Buffer(land.geom::geography, 4000.0)::geometry
        ),
        3
    )
)::geometry(MultiPolygon, 4326) AS geom
FROM public.monitoring_area area
JOIN public.musandam_land_mask land USING (area_code)
WHERE area.area_code = 'MUSANDAM_HORMUZ';

CREATE TEMP TABLE _random_safe_water_points ON COMMIT DROP AS
SELECT
    row_number() OVER () AS point_rank,
    dumped.geom::geometry(Point, 4326) AS geom
FROM _safe_musandam_water water
CROSS JOIN LATERAL ST_Dump(ST_GeneratePoints(water.geom, 900, 8312026)) dumped;

CREATE TEMP TABLE _musandam_dispersed_assignment ON COMMIT DROP AS
WITH ranked AS (
    SELECT
        position.*,
        row_number() OVER (ORDER BY md5(position.mmsi || ':dispersed-water')) AS fleet_rank
    FROM public.ship_position position
),
route_source AS (
    SELECT
        vessel.*,
        route.route_id,
        route.route_kind,
        route.geom AS route_geom,
        0.10 + mod(abs(hashtext(vessel.mmsi || ':route-progress-safe')::bigint), 8001) / 10000.0 AS route_progress,
        CASE
            WHEN mod(abs(hashtext(vessel.mmsi || ':direction-safe')::bigint), 2) = 0 THEN 1
            ELSE -1
        END::smallint AS direction,
        (mod(abs(hashtext(vessel.mmsi || ':safe-lane')::bigint), 1001) - 500)::double precision AS lane_offset_m
    FROM ranked vessel
    LEFT JOIN LATERAL (
        SELECT candidate.*
        FROM public.shipping_route candidate
        WHERE vessel.fleet_rank <= 100
          AND candidate.enabled = true
          AND vessel.ship_type = ANY(candidate.allowed_ship_types)
          AND NOT EXISTS (
              SELECT 1
              FROM public.musandam_land_mask land
              WHERE land.area_code = 'MUSANDAM_HORMUZ'
                AND ST_Intersects(candidate.geom, land.geom)
          )
        ORDER BY md5(vessel.mmsi || ':safe-route:' || candidate.route_name)
        LIMIT 1
    ) route ON true
),
route_geometry AS (
    SELECT
        source.*,
        CASE WHEN fleet_rank <= 100
            THEN ST_LineInterpolatePoint(route_geom, route_progress)::geometry(Point, 4326)
            ELSE NULL
        END AS route_point,
        CASE WHEN fleet_rank <= 100
            THEN ST_LineInterpolatePoint(
                route_geom,
                LEAST(0.9999, GREATEST(0.0001, route_progress + direction * 0.0005))
            )::geometry(Point, 4326)
            ELSE NULL
        END AS route_probe
    FROM route_source source
),
candidate_anchors AS (
    SELECT
        geometry.*,
        water.geom AS random_water_geom,
        CASE
            WHEN fleet_rank <= 100 THEN ST_Project(
                route_point::geography,
                abs(lane_offset_m),
                ST_Azimuth(route_point::geography, route_probe::geography)
                  + CASE WHEN lane_offset_m >= 0 THEN pi() / 2 ELSE -pi() / 2 END
            )::geometry(Point, 4326)
            ELSE water.geom
        END AS candidate_anchor
    FROM route_geometry geometry
    LEFT JOIN _random_safe_water_points water
      ON water.point_rank = geometry.fleet_rank - 100
),
safe_anchors AS (
    SELECT
        candidate.*,
        CASE
            WHEN ST_CoveredBy(candidate_anchor, safe.geom) THEN candidate_anchor
            ELSE ST_ClosestPoint(safe.geom, candidate_anchor)::geometry(Point, 4326)
        END AS activity_anchor,
        mod(abs(hashtext(mmsi || ':safe-local-phase')::bigint), 10000) / 10000.0 AS local_progress,
        CASE
            WHEN fleet_rank <= 100 THEN 150.0
            WHEN fleet_rank <= 950
                THEN 350.0 + mod(abs(hashtext(mmsi || ':safe-radius')::bigint), 1151)
            ELSE 80.0
        END::double precision AS local_radius_m,
        CASE
            WHEN fleet_rank > 950 THEN 0.0
            WHEN ship_type = 'Fishing' THEN 3.0 + mod(abs(hashtext(mmsi || ':safe-speed')::bigint), 45) / 10.0
            WHEN ship_type = 'Passenger' THEN 11.0 + mod(abs(hashtext(mmsi || ':safe-speed')::bigint), 80) / 10.0
            WHEN ship_type = 'Tanker' THEN 7.0 + mod(abs(hashtext(mmsi || ':safe-speed')::bigint), 65) / 10.0
            ELSE 9.0 + mod(abs(hashtext(mmsi || ':safe-speed')::bigint), 75) / 10.0
        END AS simulated_speed
    FROM candidate_anchors candidate
    CROSS JOIN _safe_musandam_water safe
)
SELECT
    anchors.*,
    activity_anchor AS position_geom,
    CASE
        WHEN fleet_rank > 950 THEN 0.0
        WHEN fleet_rank > 100
            THEN mod(abs(hashtext(mmsi || ':safe-course')::bigint), 36000) / 100.0
        ELSE degrees(ST_Azimuth(route_point::geography, route_probe::geography))
    END AS simulated_course
FROM safe_anchors anchors;

UPDATE public.ship_position position
SET longitude = ST_X(assignment.position_geom),
    latitude = ST_Y(assignment.position_geom),
    speed = assignment.simulated_speed,
    course = assignment.simulated_course,
    update_time = CURRENT_TIMESTAMP AT TIME ZONE 'UTC',
    geom = assignment.position_geom
FROM _musandam_dispersed_assignment assignment
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
        WHEN fleet_rank > 100 AND ship_type = 'Fishing' THEN 'FISHING'
        WHEN fleet_rank > 100 AND ship_type = 'Passenger' THEN 'PASSENGER'
        WHEN fleet_rank > 100 THEN 'OFFSHORE'
        WHEN route_kind = 'FISHING' THEN 'FISHING'
        WHEN route_kind = 'PASSENGER' THEN 'PASSENGER'
        WHEN route_kind = 'PORT' THEN 'PORT'
        WHEN route_kind = 'OFFSHORE' THEN 'OFFSHORE'
        ELSE 'ROUTE'
    END,
    CASE WHEN fleet_rank <= 100 THEN route_id ELSE NULL END,
    route_progress,
    direction,
    activity_anchor,
    CASE WHEN fleet_rank <= 100 THEN 0.0 ELSE NULL END,
    CASE WHEN fleet_rank <= 100 THEN lane_offset_m ELSE 0.0 END,
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
FROM _musandam_dispersed_assignment;

WITH time_steps AS (
    SELECT
        assignment.*,
        point_number,
        LEAST(
            0.9999,
            GREATEST(0.0001, route_progress - direction * ((11 - point_number) * 0.003))
        ) AS historical_progress,
        local_progress - direction * ((11 - point_number) * 0.024) AS historical_local_progress
    FROM _musandam_dispersed_assignment assignment
    CROSS JOIN generate_series(0, 11) AS series(point_number)
    WHERE fleet_rank <= 950
),
historical_geometry AS (
    SELECT
        steps.*,
        CASE
            WHEN fleet_rank <= 100 THEN ST_Project(
                ST_LineInterpolatePoint(route_geom, historical_progress)::geography,
                abs(lane_offset_m),
                ST_Azimuth(
                    ST_LineInterpolatePoint(route_geom, historical_progress)::geography,
                    ST_LineInterpolatePoint(
                        route_geom,
                        LEAST(0.9999, GREATEST(0.0001, historical_progress + direction * 0.0005))
                    )::geography
                ) + CASE WHEN lane_offset_m >= 0 THEN pi() / 2 ELSE -pi() / 2 END
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
    WHERE ST_DWithin(track.geom::geography, spill.geom::geography, 25000.0)
),
deduplicated AS (
    SELECT DISTINCT ON (mmsi)
        mmsi,
        ship_name,
        event_id,
        distance_m
    FROM candidates
    WHERE event_rank <= 20
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
    land_geometry geometry;
    on_land_count bigint;
BEGIN
    SELECT geom INTO land_geometry
    FROM public.musandam_land_mask
    WHERE area_code = 'MUSANDAM_HORMUZ';

    SELECT count(*) INTO on_land_count
    FROM public.ship_position
    WHERE ST_Intersects(geom, land_geometry);

    IF on_land_count > 0 THEN
        RAISE EXCEPTION '% active vessels still intersect the land mask.', on_land_count;
    END IF;

    IF (SELECT count(*) FROM public.ship_position) <> 1000 THEN
        RAISE EXCEPTION 'The active fleet must contain exactly 1,000 vessels.';
    END IF;

    IF (SELECT count(*) FROM public.ship_motion_state WHERE route_id IS NOT NULL) <> 100 THEN
        RAISE EXCEPTION 'The route-following fleet must contain exactly 100 vessels.';
    END IF;

    IF (
        SELECT count(*) FROM public.ship_motion_state
        WHERE route_id IS NULL AND motion_mode <> 'ANCHORED' AND simulated_speed > 0
    ) <> 850 THEN
        RAISE EXCEPTION 'The dispersed moving fleet must contain exactly 850 vessels.';
    END IF;

    IF (SELECT count(*) FROM public.ship_motion_state WHERE motion_mode = 'ANCHORED') <> 50 THEN
        RAISE EXCEPTION 'The anchored fleet must contain exactly 50 vessels.';
    END IF;
END
$$;

COMMIT;

SELECT
    (SELECT count(*) FROM public.ship_position) AS vessels,
    (SELECT count(*) FROM public.ship_motion_state WHERE route_id IS NOT NULL) AS route_following,
    (SELECT count(*) FROM public.ship_motion_state WHERE route_id IS NULL AND motion_mode <> 'ANCHORED') AS dispersed_movement,
    (SELECT count(*) FROM public.ship_motion_state WHERE motion_mode = 'ANCHORED') AS anchored,
    (SELECT count(DISTINCT mmsi) FROM public.ship_track) AS tracked_vessels,
    (SELECT count(*) FROM public.suspicious_ship) AS suspicious_vessels;
