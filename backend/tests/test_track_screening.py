"""Integration cases use temporary tables only; production records are untouched."""
import unittest
from datetime import datetime

from app.database import get_connection
from app.track_screening import SCREENING_SQL


class PreEventScreeningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manager = get_connection()
        cls.connection = cls.manager.__enter__()
        cls.sql = SCREENING_SQL.replace('public.oil_spill_event', 'pg_temp.screen_event').replace(
            'public.oil_spill_area', 'pg_temp.screen_area'
        ).replace('public.ship_track', 'pg_temp.screen_track')
        with cls.connection.cursor() as cursor:
            cursor.execute('CREATE TEMP TABLE screen_event (event_id text, event_time timestamp, geom geometry)')
            cursor.execute('CREATE TEMP TABLE screen_area (id integer, event_id text, geom geometry)')
            cursor.execute('CREATE TEMP TABLE screen_track (id serial, mmsi text, ship_name text, ship_type text, update_time timestamp, geom geometry)')
            cursor.execute("INSERT INTO screen_event VALUES ('TEST', '2026-09-01 12:00', ST_SetSRID(ST_Point(56.5,26.1),4326))")
            cursor.execute("INSERT INTO screen_area SELECT 1, event_id, ST_Buffer(geom::geography, 200)::geometry FROM screen_event")
            fixtures = [
                ('BEFORE', '2026-09-01 11:40', '2026-09-01 11:50', 26.1),
                ('AFTER', '2026-09-01 12:01', '2026-09-01 12:10', 26.1),
                ('AT_EVENT', '2026-09-01 11:50', '2026-09-01 12:00', 26.1),
                ('STRADDLES', '2026-09-01 11:59', '2026-09-01 12:01', 26.1),
                ('OLD', '2026-08-30 11:40', '2026-08-30 11:50', 26.1),
                ('GAP', '2026-09-01 09:00', '2026-09-01 11:50', 26.1),
                ('NEAR', '2026-09-01 11:40', '2026-09-01 11:50', 26.104),
                ('FAR', '2026-09-01 11:40', '2026-09-01 11:50', 26.5),
                ('TWO_HOURS', '2026-09-01 10:40', '2026-09-01 10:50', 26.1),
            ]
            for name, start, end, latitude in fixtures:
                for time, longitude in [(start, 56.48), (end, 56.52)]:
                    cursor.execute('INSERT INTO screen_track (mmsi,ship_name,ship_type,update_time,geom) VALUES (%s,%s,%s,%s,ST_SetSRID(ST_Point(%s,%s),4326))',
                                   (name, name, 'Cargo', time, longitude, latitude))
            cursor.execute("INSERT INTO screen_track (mmsi,ship_name,ship_type,update_time,geom) SELECT mmsi,ship_name,ship_type,update_time,geom FROM screen_track WHERE mmsi='BEFORE'")

    @classmethod
    def tearDownClass(cls):
        cls.connection.rollback()
        cls.manager.__exit__(None, None, None)

    def query(self, hours=24):
        with self.connection.cursor() as cursor:
            cursor.execute(self.sql, dict(event_id='TEST', nearby_nm=0.2, lookback_hours=hours, max_gap_minutes=30, limit=500))
            return {row['mmsi']: row for row in cursor.fetchall()}

    def test_only_pre_event_passages_with_valid_continuity(self):
        self.assertEqual(set(self.query()), {'BEFORE', 'NEAR', 'TWO_HOURS'})

    def test_crossing_detected_even_when_both_endpoints_are_outside(self):
        row = self.query()['BEFORE']
        self.assertTrue(row['intersects_event'])
        self.assertEqual(row['evidence_geometry']['type'], 'LineString')
        self.assertEqual(len(row['evidence_geometry']['coordinates']), 2)
        self.assertLess(row['start_time'], row['match_time'])
        self.assertLess(row['match_time'], row['end_time'])
        self.assertLess(row['end_time'], datetime(2026, 9, 1, 12))
        self.assertGreater(row['minutes_before_event'], 0)

    def test_nearby_is_not_mislabelled_as_crossing(self):
        row = self.query()['NEAR']
        self.assertEqual(row['match_type'], 'NEARBY')
        self.assertGreater(row['distance_nm'], 0)

    def test_lookback_window_and_no_duplicates(self):
        rows = self.query(hours=1)
        self.assertEqual(set(rows), {'BEFORE', 'NEAR'})
        self.assertEqual(rows['BEFORE']['point_count'], 2)


if __name__ == '__main__':
    unittest.main()
