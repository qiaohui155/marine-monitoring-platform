from __future__ import annotations

from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, HTTPException, Query
from psycopg import Error as PsycopgError

from ..api_utils import add_bbox_filter, feature_collection, feature_from_row
from ..database import get_connection


router = APIRouter(tags=["Warning Areas"])


@router.get("/api/warnings")
def list_warnings(
    warning_level: str | None = None,
    start_time: datetime | None = None,
    end_time: datetime | None = None,
    min_lon: float | None = None,
    min_lat: float | None = None,
    max_lon: float | None = None,
    max_lat: float | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
) -> dict:
    if start_time and end_time and start_time > end_time:
        raise HTTPException(status_code=422, detail="start_time must be before end_time.")
    conditions: list[str] = []
    parameters: list[object] = []
    if warning_level:
        conditions.append("warning_level = %s")
        parameters.append(warning_level)
    if start_time:
        conditions.append("warning_time >= %s")
        parameters.append(start_time)
    if end_time:
        conditions.append("warning_time <= %s")
        parameters.append(end_time)
    add_bbox_filter(
        conditions, parameters, "geom", min_lon, min_lat, max_lon, max_lat
    )
    where_sql = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"""
        SELECT
            id,
            warning_name,
            warning_level,
            reason,
            warning_time,
            ST_AsGeoJSON(geom, 9)::json AS geometry
        FROM public.warning_area
        {where_sql}
        ORDER BY warning_time DESC NULLS LAST, id
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
    return feature_collection(rows)


@router.get("/api/warnings/{warning_id}")
def get_warning(warning_id: int) -> dict:
    sql = """
        SELECT id, warning_name, warning_level, reason, warning_time,
               ST_AsGeoJSON(geom, 9)::json AS geometry
        FROM public.warning_area
        WHERE id = %s
    """
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, (warning_id,))
                row = cursor.fetchone()
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if row is None:
        raise HTTPException(status_code=404, detail="Warning area not found")
    return feature_from_row(dict(row))
