from __future__ import annotations

from psycopg import Error as PsycopgError

from .database import get_connection


def main() -> int:
    try:
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT current_database() AS database, PostGIS_Version() AS postgis_version")
                server = cursor.fetchone()
                cursor.execute("SELECT COUNT(*) AS vessel_count FROM public.ship_position")
                count = cursor.fetchone()
                cursor.execute(
                    """
                    SELECT GeometryType(geom) AS geometry_type, ST_SRID(geom) AS srid
                    FROM public.ship_position
                    WHERE geom IS NOT NULL
                    LIMIT 1
                    """
                )
                geometry = cursor.fetchone()
    except (PsycopgError, RuntimeError) as exc:
        print("DATABASE CONNECTION FAILED")
        print(str(exc))
        return 1

    print("DATABASE CONNECTION SUCCESSFUL")
    print(f"Database: {server['database']}")
    print(f"PostGIS: {server['postgis_version']}")
    print(f"ship_position rows: {count['vessel_count']}")
    print(f"Geometry: {geometry['geometry_type']} / EPSG:{geometry['srid']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
