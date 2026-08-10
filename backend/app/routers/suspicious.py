from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, HTTPException, Query
from psycopg import Error as PsycopgError

from ..api_utils import add_bbox_filter, feature_collection, feature_from_row
from ..database import get_connection


router = APIRouter(tags=["Suspected Vessels"])


@router.get("/api/suspicious-ships")
def list_suspicious_ships(
    search: str | None = None,
    risk_level: str | None = None,
    min_lon: float | None = None,
    min_lat: float | None = None,
    max_lon: float | None = None,
    max_lat: float | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
) -> dict:
    conditions: list[str] = []
    parameters: list[object] = []
    if search:
        conditions.append("(ship_name ILIKE %s OR mmsi ILIKE %s)")
        term = f"%{search.strip()}%"
        parameters.extend([term, term])
    if risk_level:
        conditions.append("risk_level = %s")
        parameters.append(risk_level)
    add_bbox_filter(
        conditions, parameters, "geom", min_lon, min_lat, max_lon, max_lat
    )
    where_sql = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"""
        SELECT
            id,
            mmsi,
            ship_name,
            reason,
            risk_level,
            ST_AsGeoJSON(geom, 9)::json AS geometry
        FROM public.suspicious_ship
        {where_sql}
        ORDER BY
            CASE risk_level WHEN '高' THEN 1 WHEN '中' THEN 2 WHEN '低' THEN 3 ELSE 4 END,
            id
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


@router.get("/api/suspicious-ships/{ship_id}")
def get_suspicious_ship(ship_id: int) -> dict:
    sql = """
        SELECT id, mmsi, ship_name, reason, risk_level,
               ST_AsGeoJSON(geom, 9)::json AS geometry
        FROM public.suspicious_ship
        WHERE id = %s
    """
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, (ship_id,))
                row = cursor.fetchone()
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if row is None:
        raise HTTPException(status_code=404, detail="Suspected vessel not found")
    return feature_from_row(dict(row))
