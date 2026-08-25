from __future__ import annotations

import argparse
import logging
import math
import os
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any

import psycopg

from .config import DB_CONFIG


LOGGER = logging.getLogger("simulated_ais")
LOCK_NAME = "oman_marine_monitoring_simulated_ais"


NEXT_POSITIONS_SQL = """
WITH selected AS (
    SELECT
        state.mmsi,
        state.route_id,
        state.route_progress,
        state.direction,
        state.route_distance_m,
        state.lateral_offset_m,
        state.simulated_speed,
        state.last_track_time,
        position.geom AS current_geom,
        route.geom AS route_geom,
        ST_Length(route.geom::geography) AS route_length_m,
        ST_IsClosed(route.geom) AS route_is_closed,
        CASE
            WHEN abs(state.lateral_offset_m) > 0.01 THEN state.lateral_offset_m
            ELSE (
                CASE position.ship_type
                    WHEN 'Fishing' THEN 80.0
                    WHEN 'Passenger' THEN 120.0
                    WHEN 'Tanker' THEN 350.0
                    ELSE 260.0
                END
                * ((abs(hashtext(state.mmsi)) %% 2001) / 1000.0 - 1.0)
            )
        END AS effective_offset_m
    FROM public.ship_motion_state AS state
    JOIN public.ship_position AS position
      ON position.mmsi = state.mmsi
    JOIN public.shipping_route AS route
      ON route.route_id = state.route_id
     AND route.enabled = true
    WHERE state.movement_enabled = true
      AND state.route_id IS NOT NULL
      AND state.motion_mode <> 'ANCHORED'
      AND state.simulated_speed > 0
      AND COALESCE(state.route_distance_m, 0) <= %s
    ORDER BY COALESCE(state.route_distance_m, 0), state.mmsi
    LIMIT %s
),
current_route_geometry AS (
    SELECT
        selected.*,
        GREATEST(selected.simulated_speed, 0.1) * 0.514444 * %s AS movement_m,
        ST_LineInterpolatePoint(
            selected.route_geom,
            selected.route_progress
        ) AS current_route_point,
        ST_LineInterpolatePoint(
            selected.route_geom,
            LEAST(
                1.0,
                GREATEST(
                    0.0,
                    selected.route_progress + selected.direction * 0.0005
                )
            )
        ) AS current_route_probe
    FROM selected
),
current_target AS (
    SELECT
        current_route_geometry.*,
        CASE
            WHEN ST_Equals(current_route_point, current_route_probe)
                THEN radians(0.0)
            ELSE ST_Azimuth(
                current_route_point::geography,
                current_route_probe::geography
            )
        END AS current_route_bearing
    FROM current_route_geometry
),
advance_decision AS (
    SELECT
        current_target.*,
        ST_Project(
            current_route_point::geography,
            abs(effective_offset_m),
            current_route_bearing
              + CASE WHEN effective_offset_m >= 0 THEN pi() / 2 ELSE -pi() / 2 END
        )::geometry AS current_target_geom
    FROM current_target
),
raw_progress AS (
    SELECT
        advance_decision.*,
        route_progress
        + CASE
            WHEN ST_Distance(
                    current_geom::geography,
                    current_target_geom::geography
                 ) <= GREATEST(movement_m * 1.5, 50.0)
                THEN direction * movement_m / NULLIF(route_length_m, 0)
            ELSE 0.0
          END AS proposed_progress
    FROM advance_decision
),
normalised_progress AS (
    SELECT
        raw_progress.*,
        CASE
            WHEN route_is_closed
                THEN proposed_progress - floor(proposed_progress)
            WHEN proposed_progress > 1.0
                THEN GREATEST(0.0, 2.0 - proposed_progress)
            WHEN proposed_progress < 0.0
                THEN LEAST(1.0, -proposed_progress)
            ELSE proposed_progress
        END AS next_progress,
        CASE
            WHEN NOT route_is_closed
                 AND (proposed_progress > 1.0 OR proposed_progress < 0.0)
                THEN (-1 * direction)::smallint
            ELSE direction
        END AS next_direction
    FROM raw_progress
),
next_route_geometry AS (
    SELECT
        normalised_progress.*,
        ST_LineInterpolatePoint(route_geom, next_progress) AS next_route_point,
        ST_LineInterpolatePoint(
            route_geom,
            LEAST(
                1.0,
                GREATEST(0.0, next_progress + next_direction * 0.0005)
            )
        ) AS next_route_probe
    FROM normalised_progress
),
next_target AS (
    SELECT
        next_route_geometry.*,
        CASE
            WHEN ST_Equals(next_route_point, next_route_probe)
                THEN current_route_bearing
            ELSE ST_Azimuth(
                next_route_point::geography,
                next_route_probe::geography
            )
        END AS next_route_bearing
    FROM next_route_geometry
),
offset_target AS (
    SELECT
        next_target.*,
        ST_Project(
            next_route_point::geography,
            abs(effective_offset_m),
            next_route_bearing
              + CASE WHEN effective_offset_m >= 0 THEN pi() / 2 ELSE -pi() / 2 END
        )::geometry AS target_geom
    FROM next_target
),
new_geometry AS (
    SELECT
        offset_target.*,
        CASE
            WHEN ST_Distance(current_geom::geography, target_geom::geography) <= movement_m
                THEN target_geom
            ELSE ST_Project(
                current_geom::geography,
                movement_m,
                ST_Azimuth(current_geom::geography, target_geom::geography)
            )::geometry
        END AS new_geom
    FROM offset_target
)
SELECT
    mmsi,
    next_progress,
    next_direction,
    effective_offset_m,
    simulated_speed,
    last_track_time,
    ST_X(new_geom) AS longitude,
    ST_Y(new_geom) AS latitude,
    CASE
        WHEN ST_DWithin(current_geom::geography, new_geom::geography, 0.05)
            THEN degrees(next_route_bearing) + 360.0
                 - floor((degrees(next_route_bearing) + 360.0) / 360.0) * 360.0
        ELSE degrees(ST_Azimuth(current_geom::geography, new_geom::geography)) + 360.0
             - floor(
                 (degrees(ST_Azimuth(current_geom::geography, new_geom::geography)) + 360.0)
                 / 360.0
             ) * 360.0
    END AS course
FROM new_geometry
ORDER BY mmsi
"""


UPDATE_POSITION_SQL = """
UPDATE public.ship_position
SET longitude = %s,
    latitude = %s,
    speed = %s,
    course = %s,
    update_time = %s,
    geom = ST_SetSRID(ST_MakePoint(%s, %s), 4326)
WHERE mmsi = %s
"""


UPDATE_STATE_SQL = """
UPDATE public.ship_motion_state
SET route_progress = %s,
    direction = %s,
    lateral_offset_m = %s,
    simulated_course = %s,
    track_enabled = true,
    last_position_time = %s,
    updated_at = %s
WHERE mmsi = %s
"""


APPEND_TRACK_SQL = """
WITH candidates AS (
    SELECT
        position.*,
        state.last_track_time,
        latest.geom AS previous_track_geom
    FROM public.ship_position AS position
    JOIN public.ship_motion_state AS state
      ON state.mmsi = position.mmsi
    LEFT JOIN LATERAL (
        SELECT track.geom
        FROM public.ship_track AS track
        WHERE track.mmsi = position.mmsi
        ORDER BY track.update_time DESC NULLS LAST, track.id DESC
        LIMIT 1
    ) AS latest ON true
    WHERE position.mmsi = ANY(%s)
      AND state.track_enabled = true
      AND (
          state.last_track_time IS NULL
          OR state.last_track_time <= %s - make_interval(secs => %s)
      )
      AND (
          latest.geom IS NULL
          OR ST_Distance(
              latest.geom::geography,
              position.geom::geography
          ) >= %s
      )
),
inserted AS (
    INSERT INTO public.ship_track (
        mmsi,
        ship_name,
        ship_type,
        longitude,
        latitude,
        speed,
        course,
        update_time,
        geom
    )
    SELECT
        mmsi,
        ship_name,
        ship_type,
        longitude,
        latitude,
        speed,
        course,
        update_time,
        geom
    FROM candidates
    RETURNING mmsi
)
UPDATE public.ship_motion_state AS state
SET last_track_time = %s,
    updated_at = %s
FROM inserted
WHERE state.mmsi = inserted.mmsi
RETURNING state.mmsi
"""


def _int_setting(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be an integer.") from exc
    return min(max(value, minimum), maximum)


def _float_setting(name: str, default: float, minimum: float, maximum: float) -> float:
    try:
        value = float(os.getenv(name, str(default)))
    except ValueError as exc:
        raise RuntimeError(f"{name} must be a number.") from exc
    if not math.isfinite(value):
        raise RuntimeError(f"{name} must be a finite number.")
    return min(max(value, minimum), maximum)


def _settings() -> dict[str, Any]:
    target_database = os.getenv("SIMULATED_AIS_TARGET_DB", DB_CONFIG["dbname"]).strip()
    if target_database != DB_CONFIG["dbname"]:
        raise RuntimeError(
            "SIMULATED_AIS_TARGET_DB does not match DB_NAME. "
            "The simulator refused to write to an unexpected database."
        )
    return {
        "target_database": target_database,
        "update_seconds": _int_setting("SIMULATED_AIS_UPDATE_SECONDS", 15, 5, 3600),
        "track_seconds": _int_setting("SIMULATED_TRACK_SECONDS", 120, 30, 86400),
        "track_min_metres": _float_setting("SIMULATED_TRACK_MIN_METERS", 200.0, 0.0, 100000.0),
        "max_vessels": _int_setting("SIMULATED_AIS_MAX_VESSELS", 100, 1, 5000),
        "max_join_metres": _float_setting("SIMULATED_AIS_MAX_JOIN_METERS", 5000.0, 100.0, 50000.0),
    }


def _configure_logging() -> None:
    log_directory = Path(__file__).resolve().parents[1] / "logs"
    log_directory.mkdir(parents=True, exist_ok=True)
    formatter = logging.Formatter("%(asctime)s | %(levelname)s | %(message)s")

    stream_handler = logging.StreamHandler()
    stream_handler.setFormatter(formatter)
    file_handler = RotatingFileHandler(
        log_directory / "simulated_ais.log",
        maxBytes=2_000_000,
        backupCount=3,
        encoding="utf-8",
    )
    file_handler.setFormatter(formatter)

    LOGGER.setLevel(logging.INFO)
    LOGGER.handlers.clear()
    LOGGER.addHandler(stream_handler)
    LOGGER.addHandler(file_handler)


def _verify_schema(cursor: Any) -> None:
    cursor.execute(
        """
        SELECT
            to_regclass('public.ship_position') IS NOT NULL AS has_positions,
            to_regclass('public.ship_track') IS NOT NULL AS has_tracks,
            to_regclass('public.shipping_route') IS NOT NULL AS has_routes,
            to_regclass('public.ship_motion_state') IS NOT NULL AS has_states
        """
    )
    row = cursor.fetchone()
    missing = [
        name
        for name, present in (
            ("ship_position", row["has_positions"]),
            ("ship_track", row["has_tracks"]),
            ("shipping_route", row["has_routes"]),
            ("ship_motion_state", row["has_states"]),
        )
        if not present
    ]
    if missing:
        raise RuntimeError(
            "Missing database objects: " + ", ".join(missing) + ". Run migrations 003 and 004 first."
        )


def _calculate_positions(cursor: Any, settings: dict[str, Any]) -> list[dict[str, Any]]:
    cursor.execute(
        NEXT_POSITIONS_SQL,
        (
            settings["max_join_metres"],
            settings["max_vessels"],
            settings["update_seconds"],
        ),
    )
    return [dict(row) for row in cursor.fetchall()]


def _save_cycle(cursor: Any, positions: list[dict[str, Any]], settings: dict[str, Any]) -> int:
    if not positions:
        return 0

    cursor.execute("SELECT CURRENT_TIMESTAMP AT TIME ZONE 'UTC' AS cycle_time")
    cycle_time = cursor.fetchone()["cycle_time"]

    cursor.executemany(
        UPDATE_POSITION_SQL,
        [
            (
                row["longitude"],
                row["latitude"],
                row["simulated_speed"],
                row["course"],
                cycle_time,
                row["longitude"],
                row["latitude"],
                row["mmsi"],
            )
            for row in positions
        ],
    )
    cursor.executemany(
        UPDATE_STATE_SQL,
        [
            (
                row["next_progress"],
                row["next_direction"],
                row["effective_offset_m"],
                row["course"],
                cycle_time,
                cycle_time,
                row["mmsi"],
            )
            for row in positions
        ],
    )

    cursor.execute(
        APPEND_TRACK_SQL,
        (
            [row["mmsi"] for row in positions],
            cycle_time,
            settings["track_seconds"],
            settings["track_min_metres"],
            cycle_time,
            cycle_time,
        ),
    )
    return len(cursor.fetchall())


def run_cycle(connection: Any, settings: dict[str, Any], dry_run: bool = False) -> tuple[int, int]:
    try:
        with connection.cursor() as cursor:
            _verify_schema(cursor)
            positions = _calculate_positions(cursor, settings)
            if dry_run:
                connection.rollback()
                return len(positions), 0
            track_count = _save_cycle(cursor, positions, settings)
        connection.commit()
        return len(positions), track_count
    except Exception:
        connection.rollback()
        raise


def _open_locked_connection() -> psycopg.Connection:
    connection = psycopg.connect(**DB_CONFIG, row_factory=psycopg.rows.dict_row)
    with connection.cursor() as cursor:
        cursor.execute("SELECT pg_try_advisory_lock(hashtext(%s)) AS acquired", (LOCK_NAME,))
        acquired = cursor.fetchone()["acquired"]
    if not acquired:
        connection.close()
        raise RuntimeError("Another simulated AIS service is already running.")
    return connection


def main() -> None:
    parser = argparse.ArgumentParser(description="Move simulated AIS vessels along PostGIS shipping routes.")
    parser.add_argument("--once", action="store_true", help="Run one update cycle and exit.")
    parser.add_argument("--dry-run", action="store_true", help="Calculate a cycle without changing the database.")
    args = parser.parse_args()

    _configure_logging()
    settings = _settings()
    LOGGER.info(
        "Simulated AIS service starting for database %s; interval=%ss; maximum vessels=%s.",
        settings["target_database"],
        settings["update_seconds"],
        settings["max_vessels"],
    )

    while True:
        try:
            with _open_locked_connection() as connection:
                while True:
                    started = time.monotonic()
                    position_count, track_count = run_cycle(connection, settings, dry_run=args.dry_run)
                    LOGGER.info(
                        "Updated %s vessel position(s); appended %s track point(s)%s.",
                        position_count,
                        track_count,
                        " [dry-run]" if args.dry_run else "",
                    )
                    if args.once:
                        return
                    time.sleep(max(0.0, settings["update_seconds"] - (time.monotonic() - started)))
        except KeyboardInterrupt:
            LOGGER.info("Simulated AIS service stopped.")
            return
        except RuntimeError as exc:
            LOGGER.error("%s", exc)
            if args.once or "already running" in str(exc):
                return
        except (psycopg.Error, OSError) as exc:
            LOGGER.error("Database cycle failed: %s", exc)
            if args.once:
                raise

        LOGGER.info("Retrying the simulated AIS database connection in 10 seconds.")
        time.sleep(10)


if __name__ == "__main__":
    main()
