from __future__ import annotations

from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query
from psycopg import Error as PsycopgError

from ..api_utils import add_bbox_filter, feature_collection, feature_from_row
from ..database import get_connection


router = APIRouter(tags=["Pollution Events"])


def _base_select() -> str:
    return """
        SELECT
            e.id,
            e.event_id,
            e.event_time,
            e.source,
            COALESCE(a.status, e.status) AS status,
            a.area_km2,
            a.level,
            ST_X(e.geom) AS center_longitude,
            ST_Y(e.geom) AS center_latitude,
            ST_AsGeoJSON(COALESCE(a.geom, e.geom), 9)::json AS geometry
        FROM public.oil_spill_event e
        LEFT JOIN public.oil_spill_area a ON a.event_id = e.event_id
    """


@router.get("/api/pollution-events")
def list_pollution_events(
    status: str | None = None,
    level: str | None = None,
    start_time: datetime | None = None,
    end_time: datetime | None = None,
    min_lon: float | None = None,
    min_lat: float | None = None,
    max_lon: float | None = None,
    max_lat: float | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
) -> dict:
    """Return pollution footprints with event metadata and center coordinates."""
    if start_time and end_time and start_time > end_time:
        raise HTTPException(status_code=422, detail="start_time must be before end_time.")

    conditions: list[str] = []
    parameters: list[object] = []
    if status:
        conditions.append("COALESCE(a.status, e.status) = %s")
        parameters.append(status)
    if level:
        conditions.append("a.level = %s")
        parameters.append(level)
    if start_time:
        conditions.append("e.event_time >= %s")
        parameters.append(start_time)
    if end_time:
        conditions.append("e.event_time <= %s")
        parameters.append(end_time)
    add_bbox_filter(
        conditions,
        parameters,
        "COALESCE(a.geom, e.geom)",
        min_lon,
        min_lat,
        max_lon,
        max_lat,
    )

    where_sql = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"{_base_select()} {where_sql} ORDER BY e.event_time DESC, e.id LIMIT %s"
    parameters.append(limit)

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, parameters)
                rows = [dict(row) for row in cursor.fetchall()]
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return feature_collection(rows, feature_id_field="event_id")


@router.get("/api/pollution-events/{event_id}")
def get_pollution_event(event_id: str) -> dict:
    sql = f"{_base_select()} WHERE e.event_id = %s LIMIT 1"
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, (event_id,))
                row = cursor.fetchone()
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    if row is None:
        raise HTTPException(status_code=404, detail="Pollution event not found")
    return feature_from_row(dict(row), feature_id_field="event_id")


@router.get("/api/pollution-events/{event_id}/candidate-vessels")
def list_pollution_candidate_vessels(
    event_id: str,
    nearby_nm: Annotated[float, Query(gt=0, le=100)] = 10.0,
    limit: Annotated[int, Query(ge=1, le=1000)] = 200,
) -> dict:
    """Screen historical vessel tracks against a pollution footprint.

    A vessel is returned only when its stored track intersects the mapped
    pollution geometry or comes within ``nearby_nm`` nautical miles of it.
    The endpoint deliberately uses historical track lines rather than current
    vessel positions, so a vessel that has already left the incident area can
    still be reviewed.
    """
    sql = """
        WITH event_context AS (
            SELECT
                e.event_id,
                e.event_time,
                COALESCE(a.geom, e.geom) AS geom
            FROM public.oil_spill_event e
            LEFT JOIN public.oil_spill_area a ON a.event_id = e.event_id
            WHERE e.event_id = %s
            ORDER BY a.id NULLS LAST
            LIMIT 1
        ),
        candidate_mmsi AS MATERIALIZED (
            SELECT DISTINCT ON (t.mmsi)
                t.mmsi,
                t.update_time AS match_time
            FROM public.ship_track t
            CROSS JOIN event_context e
            WHERE t.geom && ST_Expand(e.geom, %s / 45.0)
              AND ST_DWithin(t.geom::geography, e.geom::geography, %s * 1852.0)
            ORDER BY
                t.mmsi,
                ST_Distance(t.geom::geography, e.geom::geography),
                abs(EXTRACT(EPOCH FROM (t.update_time - e.event_time)))
        ),
        candidate_tracks AS MATERIALIZED (
            SELECT
                t.mmsi,
                max(t.ship_name::text) AS ship_name,
                max(t.ship_type::text) AS ship_type,
                min(t.update_time) AS start_time,
                max(t.update_time) AS end_time,
                count(*) AS point_count,
                candidate.match_time,
                ST_MakeLine(t.geom ORDER BY t.update_time)::geometry(LineString, 4326) AS geom
            FROM public.ship_track t
            JOIN candidate_mmsi candidate USING (mmsi)
            GROUP BY t.mmsi, candidate.match_time
            HAVING count(*) >= 2
        ),
        matches AS (
            SELECT
                t.mmsi,
                t.ship_name,
                t.ship_type,
                t.start_time,
                t.end_time,
                t.point_count,
                t.match_time,
                ST_Intersects(t.geom, e.geom) AS intersects_event,
                ST_Distance(t.geom::geography, e.geom::geography) / 1852.0 AS distance_nm,
                ST_Length(t.geom::geography) / 1852.0 AS track_distance_nm
            FROM candidate_tracks t
            CROSS JOIN event_context e
            WHERE ST_DWithin(t.geom::geography, e.geom::geography, %s * 1852.0)
        )
        SELECT
            mmsi,
            ship_name,
            ship_type,
            start_time,
            end_time,
            point_count,
            match_time,
            intersects_event,
            CASE WHEN intersects_event THEN 'INTERSECTS' ELSE 'NEARBY' END AS match_type,
            ROUND(distance_nm::numeric, 2) AS distance_nm,
            ROUND(track_distance_nm::numeric, 2) AS track_distance_nm
        FROM matches
        ORDER BY intersects_event DESC, distance_nm, end_time DESC NULLS LAST, mmsi
        LIMIT %s
    """
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT event_id, event_time FROM public.oil_spill_event WHERE event_id = %s LIMIT 1",
                    (event_id,),
                )
                event_row = cursor.fetchone()
                if event_row is None:
                    raise HTTPException(status_code=404, detail="Pollution event not found")
                cursor.execute(sql, (event_id, nearby_nm, nearby_nm, nearby_nm, limit))
                rows = [dict(row) for row in cursor.fetchall()]
    except HTTPException:
        raise
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    intersects_count = sum(1 for row in rows if row["intersects_event"])
    return {
        "event_id": event_id,
        "event_time": event_row["event_time"],
        "nearby_nm": nearby_nm,
        "count": len(rows),
        "intersects_count": intersects_count,
        "nearby_count": len(rows) - intersects_count,
        "items": rows,
    }
