"""Time-bounded passage evidence; never join observations across large gaps."""

SCREENING_SQL = """
    WITH event_context AS (
        SELECT e.event_id, e.event_time, COALESCE(a.geom, e.geom) AS geom
        FROM public.oil_spill_event e
        LEFT JOIN public.oil_spill_area a ON a.event_id = e.event_id
        WHERE e.event_id = %(event_id)s
        ORDER BY a.id NULLS LAST
        LIMIT 1
    ),
    ordered_points AS MATERIALIZED (
        SELECT t.*,
            lag(t.geom) OVER vessel_order AS previous_geom,
            lag(t.update_time) OVER vessel_order AS previous_time
        FROM public.ship_track t
        CROSS JOIN event_context e
        WHERE t.update_time >= e.event_time - make_interval(hours => %(lookback_hours)s)
          AND t.update_time < e.event_time
          AND t.geom IS NOT NULL
        WINDOW vessel_order AS (PARTITION BY t.mmsi ORDER BY t.update_time, t.id)
    ),
    segments AS MATERIALIZED (
        SELECT mmsi, ship_name, ship_type,
            previous_time AS start_time, update_time AS end_time,
            previous_geom,
            ST_MakeLine(previous_geom, geom) AS geom
        FROM ordered_points
        WHERE previous_time IS NOT NULL
          AND update_time > previous_time
          AND update_time - previous_time <= make_interval(mins => %(max_gap_minutes)s)
          AND NOT ST_Equals(previous_geom, geom)
    ),
    spatial_matches AS (
        SELECT s.*, e.event_time,
            ST_Intersects(s.geom, e.geom) AS intersects_event,
            ST_Distance(s.geom::geography, e.geom::geography) / 1852.0 AS distance_nm,
            CASE WHEN ST_Intersects(s.geom, e.geom)
                THEN ST_ClosestPoint(ST_Intersection(s.geom, e.geom), s.previous_geom)
                ELSE ST_ClosestPoint(s.geom, e.geom)
            END AS match_geom
        FROM segments s
        CROSS JOIN event_context e
        WHERE ST_DWithin(s.geom::geography, e.geom::geography, %(nearby_nm)s * 1852.0)
    ),
    timed_matches AS (
        SELECT *, start_time + (end_time - start_time)
            * ST_LineLocatePoint(geom, match_geom) AS match_time
        FROM spatial_matches
    ),
    best_matches AS (
        SELECT DISTINCT ON (mmsi) *
        FROM timed_matches
        ORDER BY mmsi, intersects_event DESC, distance_nm, match_time DESC
    )
    SELECT mmsi, ship_name, ship_type, start_time, end_time,
        2 AS point_count, match_time, event_time, intersects_event,
        CASE WHEN intersects_event THEN 'INTERSECTS' ELSE 'NEARBY' END AS match_type,
        'INTERPOLATED_BETWEEN_AIS_POINTS' AS time_basis,
        ROUND((EXTRACT(EPOCH FROM (event_time - match_time)) / 60)::numeric, 2) AS minutes_before_event,
        ROUND(distance_nm::numeric, 2) AS distance_nm,
        ROUND((ST_Length(geom::geography) / 1852.0)::numeric, 2) AS track_distance_nm,
        ST_X(match_geom) AS match_longitude, ST_Y(match_geom) AS match_latitude,
        ST_AsGeoJSON(geom, 9)::json AS evidence_geometry
    FROM best_matches
    ORDER BY intersects_event DESC, distance_nm, match_time DESC, mmsi
    LIMIT %(limit)s
"""
