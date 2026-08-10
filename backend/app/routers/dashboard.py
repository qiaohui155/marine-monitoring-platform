from __future__ import annotations

from fastapi import APIRouter, HTTPException
from psycopg import Error as PsycopgError

from ..api_utils import json_safe
from ..database import get_connection


router = APIRouter(tags=["Dashboard"])


def _grouped_counts(cursor, table: str, field: str) -> dict[str, int]:
    cursor.execute(
        f"SELECT COALESCE({field}, 'Unknown') AS label, count(*) AS count "
        f"FROM public.{table} GROUP BY {field} ORDER BY count DESC"
    )
    return {str(row["label"]): row["count"] for row in cursor.fetchall()}


@router.get("/api/dashboard/summary")
def dashboard_summary() -> dict:
    """Return the headline counts and recent events used by the home screen."""
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT count(*) AS total, max(update_time) AS latest_update "
                    "FROM public.ship_position"
                )
                ships = dict(cursor.fetchone())
                ship_types = _grouped_counts(cursor, "ship_position", "ship_type")

                cursor.execute(
                    "SELECT count(DISTINCT mmsi) AS vessels, count(*) AS points "
                    "FROM public.ship_track"
                )
                tracks = dict(cursor.fetchone())

                cursor.execute(
                    """
                    SELECT count(*) AS total,
                           COALESCE(sum(area_km2), 0) AS total_area_km2
                    FROM public.oil_spill_area
                    """
                )
                pollution = dict(cursor.fetchone())
                pollution["by_status"] = _grouped_counts(
                    cursor, "oil_spill_event", "status"
                )
                pollution["by_level"] = _grouped_counts(
                    cursor, "oil_spill_area", "level"
                )

                risk_by_level = _grouped_counts(
                    cursor, "sea_risk_index", "risk_level"
                )
                risk_areas = {
                    "total": sum(risk_by_level.values()),
                    "by_level": risk_by_level,
                }
                suspicious_by_level = _grouped_counts(
                    cursor, "suspicious_ship", "risk_level"
                )
                warnings_by_level = _grouped_counts(
                    cursor, "warning_area", "warning_level"
                )

                cursor.execute(
                    """
                    SELECT e.event_id, e.event_time, e.source,
                           COALESCE(a.status, e.status) AS status,
                           a.level, a.area_km2,
                           ST_X(e.geom) AS longitude,
                           ST_Y(e.geom) AS latitude
                    FROM public.oil_spill_event e
                    LEFT JOIN public.oil_spill_area a ON a.event_id = e.event_id
                    ORDER BY e.event_time DESC, e.id DESC
                    LIMIT 5
                    """
                )
                recent_events = [dict(row) for row in cursor.fetchall()]
    except (PsycopgError, RuntimeError) as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc

    return json_safe(
        {
            "ships": {**ships, "by_type": ship_types},
            "tracks": tracks,
            "pollution_events": pollution,
            "risk_areas": risk_areas,
            "suspicious_ships": {
                "total": sum(suspicious_by_level.values()),
                "by_level": suspicious_by_level,
            },
            "warnings": {
                "total": sum(warnings_by_level.values()),
                "by_level": warnings_by_level,
            },
            "recent_pollution_events": recent_events,
        }
    )
