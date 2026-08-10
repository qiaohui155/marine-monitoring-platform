from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Any

from fastapi import HTTPException


def json_safe(value: Any) -> Any:
    """Convert PostgreSQL values into JSON-serializable Python values."""
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, dict):
        return {key: json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_safe(item) for item in value]
    return value


def feature_from_row(
    row: dict,
    *,
    geometry_field: str = "geometry",
    feature_id_field: str = "id",
) -> dict:
    data = dict(row)
    geometry = data.pop(geometry_field, None)
    feature_id = data.get(feature_id_field)
    return {
        "type": "Feature",
        "id": feature_id,
        "geometry": geometry,
        "properties": json_safe(data),
    }


def feature_collection(
    rows: list[dict],
    *,
    geometry_field: str = "geometry",
    feature_id_field: str = "id",
) -> dict:
    features = [
        feature_from_row(
            row,
            geometry_field=geometry_field,
            feature_id_field=feature_id_field,
        )
        for row in rows
    ]
    return {"type": "FeatureCollection", "count": len(features), "features": features}


def add_bbox_filter(
    conditions: list[str],
    parameters: list[object],
    geometry_expression: str,
    min_lon: float | None,
    min_lat: float | None,
    max_lon: float | None,
    max_lat: float | None,
) -> None:
    values = (min_lon, min_lat, max_lon, max_lat)
    if any(value is not None for value in values) and any(value is None for value in values):
        raise HTTPException(
            status_code=422,
            detail="A bounding box requires min_lon, min_lat, max_lon and max_lat.",
        )
    if all(value is not None for value in values):
        if min_lon >= max_lon or min_lat >= max_lat:
            raise HTTPException(status_code=422, detail="Invalid bounding box coordinates.")
        conditions.append(
            f"{geometry_expression} && ST_MakeEnvelope(%s, %s, %s, %s, 4326)"
        )
        parameters.extend(values)
