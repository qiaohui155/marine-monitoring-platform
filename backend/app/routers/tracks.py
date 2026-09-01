from __future__ import annotations

from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query
from psycopg import Error as PsycopgError

from ..api_utils import add_bbox_filter, feature_collection
from ..database import get_connection


router = APIRouter(tags=["Vessel Tracks"])


@router.get("/api/tracks/catalog")
def list_track_catalog(
    search: str | None = None,
    limit: Annotated[int, Query(ge=1, le=5000)] = 5000,
) -> dict:
    """Return lightweight vessel metadata for the historical-track selector."""
    conditions: list[str] = []
    parameters: list[object] = []
    if search:
        conditions.append("(ship_name ILIKE %s OR mmsi ILIKE %s)")
        term = f"%{search.strip()}%"
        parameters.extend([term, term])

    where_sql = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"""
        SELECT
            mmsi,
            ship_name,
            ship_type,
            start_time,
            end_time,
            point_count,
            ROUND((ST_Length(geom::geography) / 1852.0)::numeric, 2) AS distance_nm
        FROM public.ship_track_lines
        {where_sql}
        ORDER BY ship_name NULLS LAST, mmsi
        LIMIT %s
    """
    parameters.append(limit)

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, parameters)
                rows = [dict(row) for row in cursor.fetchall()]
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return {"count": len(rows), "items": rows}


@router.get("/api/tracks")
def list_track_lines(
    search: str | None = None,
    mmsi: str | None = None,
    ship_type: str | None = None,
    min_lon: float | None = None,
    min_lat: float | None = None,
    max_lon: float | None = None,
    max_lat: float | None = None,
    center_time: datetime | None = None,
    start_time: datetime | None = None,
    end_time: datetime | None = None,
    window_minutes: Annotated[int, Query(ge=15, le=1440)] = 120,
    max_points: Annotated[int, Query(ge=10, le=2000)] = 120,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
) -> dict:
    """Return vessel track lines as a GeoJSON FeatureCollection."""
    if start_time and end_time and start_time > end_time:
        raise HTTPException(status_code=422, detail="start_time must be before end_time.")
    if center_time and (start_time or end_time):
        raise HTTPException(
            status_code=422,
            detail="center_time cannot be combined with start_time or end_time.",
        )

    if mmsi:
        requested_mmsi = mmsi.strip()
        if center_time:
            point_sql = """
                SELECT *
                FROM public.ship_track
                WHERE mmsi = %s
                  AND update_time BETWEEN
                      %s - make_interval(mins => %s)
                      AND %s + make_interval(mins => %s)
                ORDER BY abs(EXTRACT(EPOCH FROM (update_time - %s))), id
                LIMIT %s
            """
            point_parameters: list[object] = [
                requested_mmsi,
                center_time,
                window_minutes,
                center_time,
                window_minutes,
                center_time,
                max_points,
            ]
        elif start_time or end_time:
            time_conditions = ["mmsi = %s"]
            point_parameters = [requested_mmsi]
            if start_time:
                time_conditions.append("update_time >= %s")
                point_parameters.append(start_time)
            if end_time:
                time_conditions.append("update_time <= %s")
                point_parameters.append(end_time)
            point_sql = f"""
                SELECT *
                FROM public.ship_track
                WHERE {' AND '.join(time_conditions)}
                ORDER BY update_time, id
                LIMIT %s
            """
            point_parameters.append(max_points)
        else:
            point_sql = """
                SELECT *
                FROM public.ship_track
                WHERE mmsi = %s
                ORDER BY update_time DESC, id DESC
                LIMIT %s
            """
            point_parameters = [requested_mmsi, max_points]

        sql = f"""
            WITH queried_points AS MATERIALIZED (
                {point_sql}
            ),
            selected_points AS MATERIALIZED (
                SELECT DISTINCT ON (
                    mmsi,
                    update_time,
                    ST_X(geom),
                    ST_Y(geom)
                ) *
                FROM queried_points
                ORDER BY
                    mmsi,
                    update_time,
                    ST_X(geom),
                    ST_Y(geom),
                    id
            )
            SELECT
                mmsi,
                max(ship_name::text) AS ship_name,
                max(ship_type::text) AS ship_type,
                min(update_time) AS start_time,
                max(update_time) AS end_time,
                count(*) AS point_count,
                ROUND((ST_Length(ST_MakeLine(geom ORDER BY update_time)::geography) / 1852.0)::numeric, 2) AS distance_nm,
                ST_AsGeoJSON(
                    ST_MakeLine(geom ORDER BY update_time)::geometry(LineString, 4326),
                    9
                )::json AS geometry
            FROM selected_points
            GROUP BY mmsi
            HAVING count(*) >= 2
        """
        try:
            with get_connection() as connection:
                with connection.cursor() as cursor:
                    cursor.execute(sql, point_parameters)
                    rows = [dict(row) for row in cursor.fetchall()]
        except (PsycopgError, RuntimeError) as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc

        return feature_collection(rows, feature_id_field="mmsi")

    conditions: list[str] = []
    parameters: list[object] = []

    if search:
        conditions.append("(ship_name ILIKE %s OR mmsi ILIKE %s)")
        term = f"%{search.strip()}%"
        parameters.extend([term, term])
    if ship_type:
        conditions.append("ship_type = %s")
        parameters.append(ship_type)
    add_bbox_filter(
        conditions,
        parameters,
        "geom",
        min_lon,
        min_lat,
        max_lon,
        max_lat,
    )

    where_sql = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"""
        SELECT
            mmsi,
            ship_name,
            ship_type,
            start_time,
            end_time,
            point_count,
            ROUND((ST_Length(geom::geography) / 1852.0)::numeric, 2) AS distance_nm,
            ST_AsGeoJSON(geom, 9)::json AS geometry
        FROM public.ship_track_lines
        {where_sql}
        ORDER BY start_time DESC NULLS LAST, mmsi
        LIMIT %s
    """
    parameters.append(limit)

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, parameters)
                rows = [dict(row) for row in cursor.fetchall()]
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return feature_collection(rows, feature_id_field="mmsi")


@router.get("/api/ships/{mmsi}/track")
def get_ship_track(
    mmsi: str,
    start_time: datetime | None = None,
    end_time: datetime | None = None,
    limit: Annotated[int, Query(ge=1, le=20000)] = 5000,
) -> dict:
    """Return time-ordered historical AIS points for route playback."""
    if start_time and end_time and start_time > end_time:
        raise HTTPException(status_code=422, detail="start_time must be before end_time.")

    conditions = ["mmsi = %s"]
    parameters: list[object] = [mmsi]
    if start_time:
        conditions.append("update_time >= %s")
        parameters.append(start_time)
    if end_time:
        conditions.append("update_time <= %s")
        parameters.append(end_time)

    sql = f"""
        SELECT
            id,
            mmsi,
            ship_name,
            ship_type,
            speed,
            course,
            update_time,
            ST_AsGeoJSON(geom, 9)::json AS geometry
        FROM public.ship_track
        WHERE {' AND '.join(conditions)}
        ORDER BY update_time, id
        LIMIT %s
    """
    parameters.append(limit)

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, parameters)
                rows = [dict(row) for row in cursor.fetchall()]
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    result = feature_collection(rows)
    result["mmsi"] = mmsi
    result["start_time"] = rows[0]["update_time"].isoformat() if rows else None
    result["end_time"] = rows[-1]["update_time"].isoformat() if rows else None
    return result
