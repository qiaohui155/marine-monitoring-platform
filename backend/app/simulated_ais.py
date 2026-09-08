from __future__ import annotations

import argparse
import logging
import math
import os
import time
from datetime import timedelta
from logging.handlers import RotatingFileHandler
from pathlib import Path
from typing import Any

import psycopg
from psycopg.types.json import Jsonb

from .config import DB_CONFIG


LOGGER = logging.getLogger("simulated_ais")
LOCK_NAME = "oman_marine_monitoring_simulated_ais"


NEXT_POSITIONS_SQL = """
WITH route_stats AS MATERIALIZED (
    SELECT
        route.route_id,
        route.geom AS route_geom,
        ST_Length(route.geom::geography) AS route_length_m,
        ST_IsClosed(route.geom) AS route_is_closed
    FROM public.shipping_route AS route
    WHERE route.enabled = true
),
selected AS (
    SELECT
        state.mmsi,
        state.route_id,
        state.route_progress,
        state.direction,
        state.route_distance_m,
        state.lateral_offset_m,
        state.simulated_speed,
        state.last_track_time,
        route.route_geom,
        route.route_length_m,
        route.route_is_closed,
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
    JOIN route_stats AS route
      ON route.route_id = state.route_id
    WHERE state.movement_enabled = true
      AND state.route_id IS NOT NULL
      AND state.motion_mode <> 'ANCHORED'
      AND state.simulated_speed > 0
      AND COALESCE(state.route_distance_m, 0) <= %s
    ORDER BY COALESCE(state.route_distance_m, 0), state.mmsi
    LIMIT %s
),
raw_progress AS (
    SELECT
        selected.*,
        GREATEST(selected.simulated_speed, 0.1) * 0.514444 * %s AS movement_m,
        route_progress
          + direction
          * (GREATEST(selected.simulated_speed, 0.1) * 0.514444 * %s)
          / NULLIF(route_length_m, 0) AS proposed_progress
    FROM selected
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
route_geometry AS (
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
route_target AS (
    SELECT
        route_geometry.*,
        CASE
            WHEN ST_Equals(next_route_point, next_route_probe)
                THEN radians(0.0)
            ELSE ST_Azimuth(next_route_point, next_route_probe)
        END AS next_route_bearing
    FROM route_geometry
),
offset_target AS (
    SELECT
        route_target.*,
        ST_Translate(
            next_route_point,
            abs(effective_offset_m)
              * sin(
                  next_route_bearing
                  + CASE WHEN effective_offset_m >= 0 THEN pi() / 2 ELSE -pi() / 2 END
                )
              / NULLIF(111320.0 * cos(radians(ST_Y(next_route_point))), 0),
            abs(effective_offset_m)
              * cos(
                  next_route_bearing
                  + CASE WHEN effective_offset_m >= 0 THEN pi() / 2 ELSE -pi() / 2 END
                )
              / 111320.0
        )::geometry(Point, 4326) AS new_geom
    FROM route_target
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
    degrees(next_route_bearing) + 360.0
      - floor((degrees(next_route_bearing) + 360.0) / 360.0) * 360.0 AS course
FROM offset_target
ORDER BY mmsi
"""


LOCAL_POSITIONS_SQL = """
WITH selected AS (
    SELECT
        state.mmsi,
        state.direction,
        state.local_progress,
        state.local_radius_m,
        state.anchor_geom,
        state.last_track_time,
        state.simulated_speed AS state_speed,
        position.ship_type,
        COALESCE(position.speed, 0) AS current_speed,
        COALESCE(position.course, state.simulated_course, 0) AS current_course,
        position.geom AS current_geom
    FROM public.ship_motion_state AS state
    JOIN public.ship_position AS position
      ON position.mmsi = state.mmsi
    WHERE state.movement_enabled = true
      AND NOT (
          state.route_id IS NOT NULL
          AND state.motion_mode <> 'ANCHORED'
          AND state.simulated_speed > 0
          AND COALESCE(state.route_distance_m, 0) <= %s
      )
    ORDER BY state.mmsi
),
motion_values AS (
    SELECT
        selected.*,
        CASE
            WHEN current_speed <= 0.5 THEN 0.0
            WHEN ship_type = 'Fishing' THEN LEAST(GREATEST(state_speed, 1.0), 3.5)
            WHEN ship_type = 'Passenger' THEN LEAST(GREATEST(state_speed, 1.5), 5.0)
            WHEN ship_type IN ('Cargo', 'Tanker') THEN LEAST(GREATEST(state_speed, 1.0), 4.0)
            ELSE LEAST(GREATEST(state_speed, 1.0), 3.0)
        END AS local_speed,
        CASE
            WHEN local_radius_m > 0 THEN local_radius_m
            WHEN ship_type = 'Fishing' THEN 120.0
            WHEN ship_type = 'Passenger' THEN 180.0
            WHEN ship_type IN ('Cargo', 'Tanker') THEN 250.0
            ELSE 150.0
        END AS effective_radius_m
    FROM selected
),
current_target AS (
    SELECT
        motion_values.*,
        local_speed * 0.514444 * %s AS movement_m,
        CASE
            WHEN local_speed <= 0 THEN current_geom
            ELSE ST_Project(
                anchor_geom::geography,
                effective_radius_m,
                2.0 * pi() * local_progress
            )::geometry
        END AS current_target_geom
    FROM motion_values
),
next_progress AS (
    SELECT
        current_target.*,
        CASE
            WHEN local_speed <= 0 THEN local_progress
            WHEN ST_Distance(
                    current_geom::geography,
                    current_target_geom::geography
                 ) > GREATEST(movement_m * 1.5, 15.0)
                THEN local_progress
            ELSE (
                local_progress
                + direction * movement_m / NULLIF(2.0 * pi() * effective_radius_m, 0)
            )
        END AS proposed_progress
    FROM current_target
),
normalised AS (
    SELECT
        next_progress.*,
        proposed_progress - floor(proposed_progress) AS next_local_progress
    FROM next_progress
),
target_geometry AS (
    SELECT
        normalised.*,
        CASE
            WHEN local_speed <= 0 THEN current_geom
            ELSE ST_Project(
                anchor_geom::geography,
                effective_radius_m,
                2.0 * pi() * next_local_progress
            )::geometry
        END AS target_geom
    FROM normalised
),
new_geometry AS (
    SELECT
        target_geometry.*,
        CASE
            WHEN local_speed <= 0 THEN current_geom
            WHEN ST_Distance(current_geom::geography, target_geom::geography) <= movement_m
                THEN target_geom
            ELSE ST_Project(
                current_geom::geography,
                movement_m,
                ST_Azimuth(current_geom::geography, target_geom::geography)
            )::geometry
        END AS new_geom
    FROM target_geometry
)
SELECT
    mmsi,
    next_local_progress,
    effective_radius_m,
    local_speed AS simulated_speed,
    last_track_time,
    ST_X(new_geom) AS longitude,
    ST_Y(new_geom) AS latitude,
    CASE
        WHEN local_speed <= 0
             OR ST_DWithin(current_geom::geography, new_geom::geography, 0.05)
            THEN current_course
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
WITH updates AS (
    SELECT *
    FROM jsonb_to_recordset(%s::jsonb) AS value(
        mmsi text,
        longitude double precision,
        latitude double precision,
        simulated_speed double precision,
        course double precision
    )
)
UPDATE public.ship_position AS position
SET longitude = updates.longitude,
    latitude = updates.latitude,
    speed = updates.simulated_speed,
    course = updates.course,
    update_time = %s,
    geom = ST_SetSRID(ST_MakePoint(updates.longitude, updates.latitude), 4326)
FROM updates
WHERE position.mmsi = updates.mmsi
"""


UPDATE_STATE_SQL = """
WITH updates AS (
    SELECT *
    FROM jsonb_to_recordset(%s::jsonb) AS value(
        mmsi text,
        next_progress double precision,
        next_direction smallint,
        effective_offset_m double precision,
        course double precision
    )
)
UPDATE public.ship_motion_state AS state
SET route_progress = updates.next_progress,
    direction = updates.next_direction,
    lateral_offset_m = updates.effective_offset_m,
    simulated_course = updates.course,
    track_enabled = true,
    last_position_time = %s,
    updated_at = %s
FROM updates
WHERE state.mmsi = updates.mmsi
"""


UPDATE_LOCAL_STATE_SQL = """
WITH updates AS (
    SELECT *
    FROM jsonb_to_recordset(%s::jsonb) AS value(
        mmsi text,
        next_local_progress double precision,
        effective_radius_m double precision,
        course double precision
    )
)
UPDATE public.ship_motion_state AS state
SET local_progress = updates.next_local_progress,
    local_radius_m = updates.effective_radius_m,
    simulated_course = updates.course,
    last_position_time = %s,
    updated_at = %s
FROM updates
WHERE state.mmsi = updates.mmsi
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
        "update_seconds": _int_setting("SIMULATED_AIS_UPDATE_SECONDS", 5, 5, 3600),
        "movement_scale": _float_setting("SIMULATED_AIS_MOVEMENT_SCALE", 1.0, 0.1, 20.0),
        "track_seconds": _int_setting("SIMULATED_TRACK_SECONDS", 120, 30, 86400),
        "track_min_metres": _float_setting("SIMULATED_TRACK_MIN_METERS", 200.0, 0.0, 100000.0),
        "max_vessels": _int_setting("SIMULATED_AIS_MAX_VESSELS", 5000, 1, 5000),
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

    cursor.execute(
        """
        SELECT count(*) = 2 AS local_motion_ready
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'ship_motion_state'
          AND column_name IN ('local_progress', 'local_radius_m')
        """
    )
    if not cursor.fetchone()["local_motion_ready"]:
        raise RuntimeError(
            "Local vessel motion fields are missing. Run migration 006_add_local_vessel_motion.sql first."
        )


def _calculate_route_positions(cursor: Any, settings: dict[str, Any]) -> list[dict[str, Any]]:
    cursor.execute(
        NEXT_POSITIONS_SQL,
        (
            settings["max_join_metres"],
            settings["max_vessels"],
            settings["update_seconds"] * settings["movement_scale"],
            settings["update_seconds"] * settings["movement_scale"],
        ),
    )
    return [dict(row) for row in cursor.fetchall()]


def _calculate_local_positions(cursor: Any, settings: dict[str, Any]) -> list[dict[str, Any]]:
    cursor.execute(
        LOCAL_POSITIONS_SQL,
        (
            settings["max_join_metres"],
            settings["update_seconds"] * settings["movement_scale"],
        ),
    )
    return [dict(row) for row in cursor.fetchall()]


def _save_cycle(
    cursor: Any,
    route_positions: list[dict[str, Any]],
    local_positions: list[dict[str, Any]],
    settings: dict[str, Any],
) -> int:
    positions = route_positions + local_positions
    if not positions:
        return 0

    cursor.execute("SELECT CURRENT_TIMESTAMP AT TIME ZONE 'UTC' AS cycle_time")
    cycle_time = cursor.fetchone()["cycle_time"]

    cursor.execute(
        UPDATE_POSITION_SQL,
        (
            Jsonb(
                [
                    {
                        "mmsi": row["mmsi"],
                        "longitude": row["longitude"],
                        "latitude": row["latitude"],
                        "simulated_speed": row["simulated_speed"],
                        "course": row["course"],
                    }
                    for row in positions
                ]
            ),
            cycle_time,
        ),
    )
    if route_positions:
        cursor.execute(
            UPDATE_STATE_SQL,
            (
                Jsonb(
                    [
                        {
                            "mmsi": row["mmsi"],
                            "next_progress": row["next_progress"],
                            "next_direction": row["next_direction"],
                            "effective_offset_m": row["effective_offset_m"],
                            "course": row["course"],
                        }
                        for row in route_positions
                    ]
                ),
                cycle_time,
                cycle_time,
            ),
        )

    if local_positions:
        cursor.execute(
            UPDATE_LOCAL_STATE_SQL,
            (
                Jsonb(
                    [
                        {
                            "mmsi": row["mmsi"],
                            "next_local_progress": row["next_local_progress"],
                            "effective_radius_m": row["effective_radius_m"],
                            "course": row["course"],
                        }
                        for row in local_positions
                    ]
                ),
                cycle_time,
                cycle_time,
            ),
        )

    due_cutoff = cycle_time - timedelta(seconds=settings["track_seconds"])
    trackable_positions = route_positions + [
        row for row in local_positions if row["simulated_speed"] > 0
    ]
    track_mmsis = [
        row["mmsi"]
        for row in trackable_positions
        if row["last_track_time"] is None or row["last_track_time"] <= due_cutoff
    ]
    if track_mmsis:
        cursor.execute(
            APPEND_TRACK_SQL,
            (
                track_mmsis,
                cycle_time,
                settings["track_seconds"],
                settings["track_min_metres"],
                cycle_time,
                cycle_time,
            ),
        )
        return len(cursor.fetchall())
    return 0


def run_cycle(connection: Any, settings: dict[str, Any], dry_run: bool = False) -> tuple[int, int]:
    try:
        with connection.cursor() as cursor:
            _verify_schema(cursor)
            route_positions = _calculate_route_positions(cursor, settings)
            local_positions = _calculate_local_positions(cursor, settings)
            position_count = len(route_positions) + len(local_positions)
            if dry_run:
                connection.rollback()
                return position_count, 0
            track_count = _save_cycle(cursor, route_positions, local_positions, settings)
        connection.commit()
        return position_count, track_count
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
        "Simulated AIS service starting for database %s; interval=%ss; movement scale=%.2fx; maximum vessels=%s.",
        settings["target_database"],
        settings["update_seconds"],
        settings["movement_scale"],
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
