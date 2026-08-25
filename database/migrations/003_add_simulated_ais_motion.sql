BEGIN;

-- =========================================================
-- 1. 船舶航线表
-- 只供需要沿航道、港口路线或局部活动路线移动的船使用。
-- 不会把所有船舶强制移动到航线上。
-- =========================================================

CREATE TABLE IF NOT EXISTS public.shipping_route (
    route_id serial PRIMARY KEY,

    route_name varchar(120) NOT NULL,
    route_kind varchar(30) NOT NULL,

    allowed_ship_types varchar(30)[] NOT NULL,

    enabled boolean NOT NULL DEFAULT true,

    description text,

    geom geometry(LineString, 4326) NOT NULL,

    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT shipping_route_name_unique
        UNIQUE (route_name),

    CONSTRAINT shipping_route_kind_check
        CHECK (
            route_kind IN (
                'MAIN',
                'PORT',
                'FISHING',
                'PASSENGER',
                'OFFSHORE'
            )
        )
);

CREATE INDEX IF NOT EXISTS shipping_route_geom_gix
ON public.shipping_route
USING gist (geom);

CREATE INDEX IF NOT EXISTS shipping_route_kind_idx
ON public.shipping_route (route_kind);

CREATE INDEX IF NOT EXISTS shipping_route_enabled_idx
ON public.shipping_route (enabled);


-- =========================================================
-- 2. 插入阿曼海域已有安全航线
-- 这些航线来自项目原有历史轨迹脚本。
-- 后续可以继续补充波斯湾、霍尔木兹和港口路线。
-- =========================================================

INSERT INTO public.shipping_route (
    route_name,
    route_kind,
    allowed_ship_types,
    enabled,
    description,
    geom
)
VALUES

-- 阿曼湾—马斯喀特—阿曼南部商船主航线
(
    'Oman Coastal Main Route 01',
    'MAIN',
    ARRAY['Cargo', 'Tanker'],
    true,
    '阿曼湾至阿曼南部的商船和油轮主航线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                57.86 25.70,
                57.58 25.61,
                57.28 25.48,
                57.00 25.37,
                56.75 25.25,
                56.53 25.15,
                56.65 24.88,
                56.88 24.60,
                57.35 24.32,
                57.88 24.04,
                58.45 23.78,
                58.84 23.65,
                59.25 23.32,
                59.65 22.88,
                60.02 22.50,
                59.72 22.03,
                59.32 21.52,
                58.92 20.95,
                58.50 20.40,
                58.08 19.98,
                57.76 19.75
            )',
            4326
        ),
        3,
        true
    )
),

-- 阿曼湾北部至马斯喀特方向主航线
(
    'Oman Gulf Main Route 02',
    'MAIN',
    ARRAY['Cargo', 'Tanker'],
    true,
    '阿曼湾北部至马斯喀特方向主航线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                56.98 25.31,
                56.78 25.11,
                56.72 24.88,
                56.84 24.64,
                57.14 24.43,
                57.52 24.22,
                57.94 24.03,
                58.36 23.85,
                58.76 23.68,
                59.15 23.40,
                59.54 22.99,
                59.88 22.55
            )',
            4326
        ),
        3,
        true
    )
),

-- 马斯喀特至阿曼中南部航线
(
    'Muscat Southbound Main Route',
    'MAIN',
    ARRAY['Cargo', 'Tanker'],
    true,
    '马斯喀特至阿曼中南部海域航线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                60.05 22.52,
                59.82 22.18,
                59.60 21.83,
                59.37 21.47,
                59.14 21.12,
                58.91 20.78,
                58.67 20.45,
                58.41 20.16,
                58.10 19.92,
                57.78 19.75
            )',
            4326
        ),
        3,
        true
    )
),

-- 阿曼南部至阿拉伯海航线
(
    'Oman Arabian Sea Offshore Route',
    'OFFSHORE',
    ARRAY['Cargo', 'Tanker'],
    true,
    '阿曼南部至阿拉伯海远海航线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                57.82 19.72,
                57.48 19.30,
                57.08 18.95,
                56.66 18.60,
                56.22 18.25,
                55.78 17.91,
                55.32 17.55,
                54.86 17.20,
                54.38 16.92
            )',
            4326
        ),
        3,
        true
    )
),

-- 富查伊拉附近渔船局部活动路线
(
    'Fujairah Fishing Area Route',
    'FISHING',
    ARRAY['Fishing'],
    true,
    '富查伊拉附近渔船局部闭合活动路线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                56.98 24.52,
                56.91 24.44,
                56.89 24.33,
                56.98 24.26,
                57.11 24.28,
                57.17 24.37,
                57.13 24.47,
                56.98 24.52
            )',
            4326
        ),
        3,
        true
    )
),

-- 马斯喀特附近渔船局部活动路线
(
    'Muscat Fishing Area Route',
    'FISHING',
    ARRAY['Fishing'],
    true,
    '马斯喀特附近渔船闭合活动路线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                58.76 23.73,
                58.69 23.65,
                58.73 23.55,
                58.86 23.51,
                58.97 23.57,
                58.99 23.67,
                58.90 23.75,
                58.76 23.73
            )',
            4326
        ),
        3,
        true
    )
),

-- 杜库姆附近渔船局部活动路线
(
    'Duqm Fishing Area Route',
    'FISHING',
    ARRAY['Fishing'],
    true,
    '杜库姆附近渔船闭合活动路线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                57.95 19.82,
                57.88 19.75,
                57.91 19.65,
                58.04 19.60,
                58.16 19.65,
                58.19 19.75,
                58.10 19.83,
                57.95 19.82
            )',
            4326
        ),
        3,
        true
    )
),

-- 富查伊拉附近客船路线
(
    'Fujairah Passenger Route',
    'PASSENGER',
    ARRAY['Passenger'],
    true,
    '富查伊拉附近客船和港口交通闭合路线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                56.96 24.63,
                56.87 24.55,
                56.82 24.46,
                56.88 24.38,
                57.00 24.40,
                57.08 24.49,
                57.05 24.58,
                56.96 24.63
            )',
            4326
        ),
        3,
        true
    )
),

-- 马斯喀特附近客船路线
(
    'Muscat Passenger Route',
    'PASSENGER',
    ARRAY['Passenger'],
    true,
    '马斯喀特附近客船和沿岸交通闭合路线',
    ST_ChaikinSmoothing(
        ST_GeomFromText(
            'LINESTRING(
                58.84 23.77,
                58.73 23.70,
                58.63 23.63,
                58.67 23.55,
                58.79 23.51,
                58.91 23.57,
                58.96 23.68,
                58.84 23.77
            )',
            4326
        ),
        3,
        true
    )
)

ON CONFLICT (route_name)
DO UPDATE SET
    route_kind = EXCLUDED.route_kind,
    allowed_ship_types = EXCLUDED.allowed_ship_types,
    enabled = EXCLUDED.enabled,
    description = EXCLUDED.description,
    geom = EXCLUDED.geom,
    updated_at = CURRENT_TIMESTAMP;


-- =========================================================
-- 3. 船舶运动状态表
-- 保存每艘船采用哪种运动方式。
-- 不会替换ship_position。
-- =========================================================

CREATE TABLE IF NOT EXISTS public.ship_motion_state (
    mmsi varchar(20) PRIMARY KEY,

    motion_mode varchar(20) NOT NULL,

    route_id integer
        REFERENCES public.shipping_route(route_id)
        ON DELETE SET NULL,

    route_progress double precision NOT NULL DEFAULT 0,

    direction smallint NOT NULL DEFAULT 1,

    -- 保存船舶初始化时的原始位置
    anchor_geom geometry(Point, 4326) NOT NULL,

    -- 初始化时船舶与所选航线的距离
    route_distance_m double precision,

    -- 航线左右偏移，后续模拟程序使用
    lateral_offset_m double precision NOT NULL DEFAULT 0,

    simulated_speed double precision NOT NULL DEFAULT 0,

    simulated_course double precision NOT NULL DEFAULT 0,

    movement_enabled boolean NOT NULL DEFAULT true,

    track_enabled boolean NOT NULL DEFAULT false,

    needs_route_review boolean NOT NULL DEFAULT false,

    last_position_time timestamp,

    last_track_time timestamp,

    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT ship_motion_mode_check
        CHECK (
            motion_mode IN (
                'ROUTE',
                'PORT',
                'FISHING',
                'PASSENGER',
                'OFFSHORE',
                'ANCHORED'
            )
        ),

    CONSTRAINT ship_motion_direction_check
        CHECK (direction IN (-1, 1)),

    CONSTRAINT ship_motion_progress_check
        CHECK (
            route_progress >= 0
            AND route_progress <= 1
        ),

    CONSTRAINT ship_motion_speed_check
        CHECK (
            simulated_speed >= 0
            AND simulated_speed <= 30
        )
);

CREATE INDEX IF NOT EXISTS ship_motion_state_route_idx
ON public.ship_motion_state(route_id);

CREATE INDEX IF NOT EXISTS ship_motion_state_mode_idx
ON public.ship_motion_state(motion_mode);

CREATE INDEX IF NOT EXISTS ship_motion_state_enabled_idx
ON public.ship_motion_state(movement_enabled);

CREATE INDEX IF NOT EXISTS ship_motion_state_track_idx
ON public.ship_motion_state(track_enabled);

CREATE INDEX IF NOT EXISTS ship_motion_state_anchor_gix
ON public.ship_motion_state
USING gist(anchor_geom);


-- =========================================================
-- 4. 初始化现有船舶的运动状态
--
-- 重要：
-- 1. 不修改ship_position坐标；
-- 2. 不会立即让船移动；
-- 3. 只给距离适用航线较近的船分配航线；
-- 4. 其他船设置为ANCHORED或等待后续检查；
-- 5. 重复执行不会覆盖已经运行中的运动状态。
-- =========================================================

WITH vessel_source AS (
    SELECT
        p.mmsi,
        p.ship_name,
        p.ship_type,
        COALESCE(p.speed, 0) AS current_speed,
        COALESCE(p.course, 0) AS current_course,
        p.update_time,
        p.geom
    FROM public.ship_position p
    WHERE p.mmsi IS NOT NULL
      AND p.geom IS NOT NULL
),

nearest_compatible_route AS (
    SELECT
        v.*,

        nearest.route_id,
        nearest.route_kind,
        nearest.route_geom,
        nearest.route_distance_m

    FROM vessel_source v

    LEFT JOIN LATERAL (
        SELECT
            r.route_id,
            r.route_kind,
            r.geom AS route_geom,

            ST_Distance(
                v.geom::geography,
                ST_ClosestPoint(r.geom, v.geom)::geography
            ) AS route_distance_m

        FROM public.shipping_route r

        WHERE r.enabled = true
          AND v.ship_type = ANY(r.allowed_ship_types)

        ORDER BY v.geom <-> r.geom

        LIMIT 1
    ) nearest ON true
),

classified AS (
    SELECT
        n.*,

        -- 判断当前船是否可以使用找到的航线
        CASE
            WHEN n.current_speed <= 0.5
                THEN false

            WHEN n.ship_type IN ('Cargo', 'Tanker')
                 AND n.route_kind IN ('MAIN', 'OFFSHORE')
                 AND n.route_distance_m <= 15000
                THEN true

            WHEN n.ship_type = 'Fishing'
                 AND n.route_kind = 'FISHING'
                 AND n.route_distance_m <= 20000
                THEN true

            WHEN n.ship_type = 'Passenger'
                 AND n.route_kind IN ('PASSENGER', 'PORT')
                 AND n.route_distance_m <= 20000
                THEN true

            ELSE false
        END AS route_accepted

    FROM nearest_compatible_route n
),

motion_values AS (
    SELECT
        c.*,

        CASE
            WHEN c.current_speed <= 0.5
                THEN 'ANCHORED'

            WHEN c.route_accepted
                 AND c.ship_type IN ('Cargo', 'Tanker')
                THEN 'ROUTE'

            WHEN c.route_accepted
                 AND c.ship_type = 'Fishing'
                THEN 'FISHING'

            WHEN c.route_accepted
                 AND c.ship_type = 'Passenger'
                THEN 'PASSENGER'

            -- 离安全航线较远的移动船暂时不自动移动
            ELSE 'ANCHORED'
        END AS calculated_motion_mode,

        CASE
            WHEN c.current_speed <= 0.5
                THEN 0

            WHEN c.ship_type = 'Fishing'
                THEN LEAST(
                    GREATEST(c.current_speed, 1),
                    7
                )

            WHEN c.ship_type = 'Passenger'
                THEN LEAST(
                    GREATEST(c.current_speed, 4),
                    20
                )

            WHEN c.ship_type = 'Tanker'
                THEN LEAST(
                    GREATEST(c.current_speed, 2),
                    16
                )

            WHEN c.ship_type = 'Cargo'
                THEN LEAST(
                    GREATEST(c.current_speed, 3),
                    20
                )

            ELSE LEAST(
                GREATEST(c.current_speed, 0),
                22
            )
        END AS calculated_speed

    FROM classified c
)

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
    last_track_time
)

SELECT
    m.mmsi,

    m.calculated_motion_mode,

    CASE
        WHEN m.route_accepted
            THEN m.route_id
        ELSE NULL
    END,

    CASE
        WHEN m.route_accepted
            THEN ST_LineLocatePoint(
                m.route_geom,
                ST_ClosestPoint(m.route_geom, m.geom)
            )
        ELSE 0
    END,

    -- 使用MMSI生成稳定的正向或反向状态
    CASE
        WHEN mod(hashtext(m.mmsi), 2) = 0
            THEN 1
        ELSE -1
    END,

    m.geom,

    CASE
        WHEN m.route_accepted
            THEN m.route_distance_m
        ELSE NULL
    END,

    0,

    m.calculated_speed,

    CASE
        WHEN m.current_course >= 0
             AND m.current_course <= 360
            THEN m.current_course
        ELSE 0
    END,

    true,

    false,

    CASE
        WHEN m.current_speed > 0.5
             AND NOT m.route_accepted
            THEN true
        ELSE false
    END,

    m.update_time,

    NULL

FROM motion_values m

ON CONFLICT (mmsi)
DO NOTHING;


-- =========================================================
-- 5. 建立运动状态检查视图
-- 用于pgAdmin、QGIS和后续API检查。
-- =========================================================

CREATE OR REPLACE VIEW public.ship_motion_overview AS

SELECT
    p.mmsi,
    p.ship_name,
    p.ship_type,

    p.longitude,
    p.latitude,
    p.speed AS database_speed,
    p.course AS database_course,
    p.update_time,

    s.motion_mode,
    s.simulated_speed,
    s.simulated_course,
    s.direction,
    s.route_progress,
    s.route_distance_m,
    s.movement_enabled,
    s.track_enabled,
    s.needs_route_review,

    r.route_id,
    r.route_name,
    r.route_kind,

    p.geom

FROM public.ship_position p

LEFT JOIN public.ship_motion_state s
    ON s.mmsi = p.mmsi

LEFT JOIN public.shipping_route r
    ON r.route_id = s.route_id;


COMMIT;