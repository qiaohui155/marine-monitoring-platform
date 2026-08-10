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
