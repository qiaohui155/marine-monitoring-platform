from __future__ import annotations

import argparse
import logging
import math
import os
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

import requests

from .database import get_connection


SHIPXY_URL = "https://api.shipxy.com/apicall/v3/GetManyShip"
LOGGER = logging.getLogger("shipxy_ingest")


@dataclass(frozen=True)
class AisPosition:
    mmsi: str
    ship_name: str
    ship_type: str
    longitude: float
    latitude: float
    speed: float | None
    course: float | None
    update_time: datetime


def _float(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _ship_type(value: Any) -> str:
    text = str(value or "").strip()
    lowered = text.lower()
    if "tanker" in lowered or "油轮" in text:
        return "Tanker"
    if "cargo" in lowered or "货" in text:
        return "Cargo"
    if "fishing" in lowered or "渔" in text:
        return "Fishing"
    if "passenger" in lowered or "客" in text:
        return "Passenger"

    try:
        code = int(float(text))
    except (TypeError, ValueError):
        return "Other"
    if code == 30:
        return "Fishing"
    if 60 <= code <= 69:
        return "Passenger"
    if 70 <= code <= 79:
        return "Cargo"
    if 80 <= code <= 89:
        return "Tanker"
    return "Other"


def _source_time(ship: dict[str, Any]) -> datetime:
    value = next(
        (
            ship.get(key)
            for key in (
                "last_time",
                "lasttime",
                "update_time",
                "base_date_time",
                "utc",
                "timestamp",
                "time",
            )
            if ship.get(key) not in (None, "")
        ),
        None,
    )
    if value is None:
        return datetime.now(UTC).replace(tzinfo=None)

    if isinstance(value, (int, float)) or str(value).strip().isdigit():
        timestamp = float(value)
        if timestamp > 10_000_000_000:
            timestamp /= 1000
        try:
            return datetime.fromtimestamp(timestamp, UTC).replace(tzinfo=None)
        except (OverflowError, OSError, ValueError):
            pass

    text = str(value).strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(text)
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone(UTC).replace(tzinfo=None)
        return parsed
    except ValueError:
        return datetime.now(UTC).replace(tzinfo=None)


def normalize_ship(ship: dict[str, Any]) -> AisPosition | None:
    mmsi = str(ship.get("mmsi") or "").strip()
    longitude = _float(ship.get("lng", ship.get("longitude")))
    latitude = _float(ship.get("lat", ship.get("latitude")))
    if not mmsi or longitude is None or latitude is None:
        return None
    if not (-180 <= longitude <= 180 and -90 <= latitude <= 90):
        return None

    speed = _float(ship.get("sog", ship.get("speed")))
    if speed is not None and not (0 <= speed <= 80):
        speed = None
    course = _float(ship.get("cog", ship.get("course")))
    if course is not None:
        course %= 360

    return AisPosition(
        mmsi=mmsi,
        ship_name=str(ship.get("ship_name") or ship.get("name") or f"AIS-{mmsi}").strip(),
        ship_type=_ship_type(ship.get("ship_type")),
        longitude=longitude,
        latitude=latitude,
        speed=speed,
        course=course,
        update_time=_source_time(ship),
    )


def fetch_positions(session: requests.Session, api_key: str, mmsis: str) -> list[AisPosition]:
    response = session.get(
        SHIPXY_URL,
        params={"key": api_key, "mmsis": mmsis, "output": 1},
        timeout=15,
    )
    response.raise_for_status()
    result = response.json()
    if str(result.get("status")) != "0":
        raise RuntimeError(f"ShipXY query failed: {result.get('msg') or 'unknown error'}")

    raw_data = result.get("data") or []
    if not isinstance(raw_data, list):
        raise RuntimeError("ShipXY returned an unexpected data structure.")
    return [position for item in raw_data if (position := normalize_ship(item))]


def _distance_metres(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
    radius = 6_371_008.8
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lon2 - lon1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return radius * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _upsert_current(cursor: Any, position: AisPosition) -> None:
    cursor.execute(
        """
        WITH target AS (
            SELECT id
            FROM public.ship_position
            WHERE mmsi = %s
            ORDER BY update_time DESC NULLS LAST, id DESC
            LIMIT 1
        )
        UPDATE public.ship_position AS p
        SET ship_name = %s,
            ship_type = %s,
            longitude = %s,
            latitude = %s,
            speed = %s,
            course = %s,
            update_time = %s,
            geom = ST_SetSRID(ST_MakePoint(%s, %s), 4326)
        FROM target
        WHERE p.id = target.id
        """,
        (
            position.mmsi,
            position.ship_name,
            position.ship_type,
            position.longitude,
            position.latitude,
            position.speed,
            position.course,
            position.update_time,
            position.longitude,
            position.latitude,
        ),
    )
    if cursor.rowcount:
        return

    cursor.execute(
        """
        INSERT INTO public.ship_position
            (mmsi, ship_name, ship_type, longitude, latitude, speed, course, update_time, geom)
        VALUES
            (%s, %s, %s, %s, %s, %s, %s, %s,
             ST_SetSRID(ST_MakePoint(%s, %s), 4326))
        """,
        (
            position.mmsi,
            position.ship_name,
            position.ship_type,
            position.longitude,
            position.latitude,
            position.speed,
            position.course,
            position.update_time,
            position.longitude,
            position.latitude,
        ),
    )


def _append_track_if_needed(
    cursor: Any,
    position: AisPosition,
    minimum_seconds: int,
    minimum_metres: float,
) -> bool:
    cursor.execute(
        """
        SELECT longitude, latitude, update_time
        FROM public.ship_track
        WHERE mmsi = %s
        ORDER BY update_time DESC NULLS LAST, id DESC
        LIMIT 1
        """,
        (position.mmsi,),
    )
    previous = cursor.fetchone()
    if previous:
        distance = _distance_metres(
            float(previous["longitude"]),
            float(previous["latitude"]),
            position.longitude,
            position.latitude,
        )
        previous_time = previous["update_time"]
        elapsed = (position.update_time - previous_time).total_seconds() if previous_time else minimum_seconds
        if distance < minimum_metres and elapsed < minimum_seconds:
            return False

    cursor.execute(
        """
        INSERT INTO public.ship_track
            (mmsi, ship_name, ship_type, longitude, latitude, speed, course, update_time, geom)
        VALUES
            (%s, %s, %s, %s, %s, %s, %s, %s,
             ST_SetSRID(ST_MakePoint(%s, %s), 4326))
        """,
        (
            position.mmsi,
            position.ship_name,
            position.ship_type,
            position.longitude,
            position.latitude,
            position.speed,
            position.course,
            position.update_time,
            position.longitude,
            position.latitude,
        ),
    )
    return True


def save_positions(positions: list[AisPosition], minimum_seconds: int, minimum_metres: float) -> int:
    track_count = 0
    with get_connection() as connection:
        try:
            with connection.cursor() as cursor:
                for position in positions:
                    _upsert_current(cursor, position)
                    if _append_track_if_needed(cursor, position, minimum_seconds, minimum_metres):
                        track_count += 1
            connection.commit()
        except Exception:
            connection.rollback()
            raise
    return track_count


def _settings() -> tuple[str, str, int, int, float]:
    api_key = os.getenv("SHIPXY_API_KEY", "").strip()
    mmsis = ",".join(part.strip() for part in os.getenv("SHIPXY_MMSI_LIST", "").split(",") if part.strip())
    if not api_key:
        raise RuntimeError("SHIPXY_API_KEY is missing. Run configure_shipxy.bat first.")
    if not mmsis:
        raise RuntimeError("SHIPXY_MMSI_LIST is missing. Run configure_shipxy.bat first.")
    poll_seconds = max(5, int(os.getenv("SHIPXY_POLL_SECONDS", "15")))
    track_seconds = max(10, int(os.getenv("SHIPXY_TRACK_MIN_SECONDS", "60")))
    track_metres = max(0.0, float(os.getenv("SHIPXY_TRACK_MIN_METERS", "20")))
    return api_key, mmsis, poll_seconds, track_seconds, track_metres


def main() -> None:
    parser = argparse.ArgumentParser(description="Collect ShipXY AIS data into the local PostGIS database.")
    parser.add_argument("--once", action="store_true", help="Query and save one cycle, then exit.")
    parser.add_argument("--dry-run", action="store_true", help="Query ShipXY but do not write to PostgreSQL.")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")

    api_key, mmsis, poll_seconds, track_seconds, track_metres = _settings()
    LOGGER.info("ShipXY collector started for %s MMSI number(s).", len(mmsis.split(",")))
    LOGGER.info("Current positions update every %s seconds; track filtering is enabled.", poll_seconds)

    with requests.Session() as session:
        while True:
            cycle_started = time.monotonic()
            try:
                positions = fetch_positions(session, api_key, mmsis)
                if args.dry_run:
                    LOGGER.info("Received %s valid position(s); dry-run skipped database writes.", len(positions))
                else:
                    track_count = save_positions(positions, track_seconds, track_metres)
                    LOGGER.info(
                        "Saved %s current position(s) and %s new track point(s).",
                        len(positions),
                        track_count,
                    )
            except Exception as exc:
                LOGGER.error("Collection cycle failed: %s", exc)

            if args.once:
                break
            wait_seconds = max(0.0, poll_seconds - (time.monotonic() - cycle_started))
            try:
                time.sleep(wait_seconds)
            except KeyboardInterrupt:
                LOGGER.info("Collector stopped.")
                break


if __name__ == "__main__":
    main()
