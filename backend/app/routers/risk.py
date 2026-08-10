from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, HTTPException, Query
from psycopg import Error as PsycopgError

from ..api_utils import add_bbox_filter, feature_collection, feature_from_row
from ..database import get_connection


router = APIRouter(tags=["Risk Areas"])


@router.get("/api/risk-areas")
def list_risk_areas(
    risk_level: str | None = None,
    min_lon: float | None = None,
    min_lat: float | None = None,
    max_lon: float | None = None,
    max_lat: float | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 500,
) -> dict:
    conditions: list[str] = []
    parameters: list[object] = []
    if risk_level:
        conditions.append("risk_level = %s")
        parameters.append(risk_level)
    add_bbox_filter(
        conditions, parameters, "geom", min_lon, min_lat, max_lon, max_lat
    )
    where_sql = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"""
        SELECT
            risk_id,
            risk_level,
            coefficient,
            area_name,
            basis,
            draw_order,
            fill_hex,
            display_opacity,
            ST_AsGeoJSON(geom, 9)::json AS geometry
        FROM public.sea_risk_index
        {where_sql}
        ORDER BY draw_order, risk_id
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
    return feature_collection(rows, feature_id_field="risk_id")


@router.get("/api/risk-areas/{risk_id}")
def get_risk_area(risk_id: int) -> dict:
    sql = """
        SELECT
            risk_id, risk_level, coefficient, area_name, basis, draw_order,
            fill_hex, display_opacity,
            ST_AsGeoJSON(geom, 9)::json AS geometry
        FROM public.sea_risk_index
        WHERE risk_id = %s
    """
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, (risk_id,))
                row = cursor.fetchone()
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    if row is None:
        raise HTTPException(status_code=404, detail="Risk area not found")
    return feature_from_row(dict(row), feature_id_field="risk_id")
