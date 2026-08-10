from __future__ import annotations

from typing import Annotated

from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from psycopg import Error as PsycopgError

from .config import DB_CONFIG, database_ready
from .database import get_connection
from .routers import dashboard, pollution, risk, suspicious, tracks, warnings


app = FastAPI(
    title="Oman Marine Monitoring API",
    description="Backend service for the vessel and pollution monitoring desktop platform.",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["null"],
    allow_origin_regex=r"^https?://(127\.0\.0\.1|localhost)(:\d+)?$",
    allow_credentials=False,
    allow_methods=["GET"],
    allow_headers=["*"],
)

app.include_router(tracks.router)
app.include_router(pollution.router)
app.include_router(risk.router)
app.include_router(suspicious.router)
app.include_router(warnings.router)
app.include_router(dashboard.router)


def _feature(row: dict) -> dict:
    longitude = float(row.pop("longitude"))
    latitude = float(row.pop("latitude"))
    if row.get("update_time") is not None:
        row["update_time"] = row["update_time"].isoformat()
    return {
        "type": "Feature",
        "id": row.get("id"),
        "geometry": {"type": "Point", "coordinates": [longitude, latitude]},
        "properties": row,
    }


@app.get("/")
def root() -> dict:
    return {
        "service": "Oman Marine Monitoring API",
        "status": "running",
        "documentation": "/docs",
    }


@app.get("/api/health")
def health() -> dict:
    result = {
        "api": "ok",
        "database_configured": database_ready(),
        "database": DB_CONFIG["dbname"],
        "host": DB_CONFIG["host"],
    }
    if not database_ready():
        result["database"] = "not configured"
        return result

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT current_database() AS database, PostGIS_Version() AS postgis_version")
                database = cursor.fetchone()
        result["database_connection"] = "ok"
        result["postgis_version"] = database["postgis_version"]
    except (PsycopgError, RuntimeError) as exc:
        result["database_connection"] = "failed"
        result["error"] = str(exc)
    return result


@app.get("/api/ships")
def list_ships(
    search: str | None = None,
    ship_type: str | None = None,
    min_lon: float | None = None,
    min_lat: float | None = None,
    max_lon: float | None = None,
    max_lat: float | None = None,
    limit: Annotated[int, Query(ge=1, le=5000)] = 5000,
) -> dict:
    conditions: list[str] = []
    parameters: list[object] = []

    if search:
        conditions.append("(ship_name ILIKE %s OR mmsi ILIKE %s)")
        term = f"%{search.strip()}%"
        parameters.extend([term, term])
    if ship_type:
        conditions.append("ship_type = %s")
        parameters.append(ship_type)
    if None not in (min_lon, min_lat, max_lon, max_lat):
        conditions.append("geom && ST_MakeEnvelope(%s, %s, %s, %s, 4326)")
        parameters.extend([min_lon, min_lat, max_lon, max_lat])

    where_sql = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"""
        SELECT
            id,
            mmsi,
            ship_name,
            ship_type,
            speed,
            course,
            update_time,
            ST_X(geom) AS longitude,
            ST_Y(geom) AS latitude
        FROM public.ship_position
        {where_sql}
        ORDER BY update_time DESC NULLS LAST, id
        LIMIT %s
    """
    parameters.append(limit)

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, parameters)
                rows = cursor.fetchall()
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return {
        "type": "FeatureCollection",
        "count": len(rows),
        "features": [_feature(dict(row)) for row in rows],
    }


@app.get("/api/ships/{mmsi}")
def get_ship(mmsi: str) -> dict:
    sql = """
        SELECT
            id,
            mmsi,
            ship_name,
            ship_type,
            speed,
            course,
            update_time,
            ST_X(geom) AS longitude,
            ST_Y(geom) AS latitude
        FROM public.ship_position
        WHERE mmsi = %s
        ORDER BY update_time DESC NULLS LAST, id DESC
        LIMIT 1
    """

    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(sql, (mmsi,))
                row = cursor.fetchone()
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    if row is None:
        raise HTTPException(status_code=404, detail="Vessel not found")
    return _feature(dict(row))
