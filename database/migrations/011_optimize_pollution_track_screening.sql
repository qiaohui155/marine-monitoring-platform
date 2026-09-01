BEGIN;

-- The pollution-source screening endpoint first narrows historical AIS points
-- spatially, then builds exact lines only for matching vessels. These indexes
-- keep that lookup responsive as the five-second simulator accumulates data.

CREATE INDEX IF NOT EXISTS ship_track_geom_gix
ON public.ship_track USING gist (geom);

CREATE INDEX IF NOT EXISTS ship_track_update_time_idx
ON public.ship_track (update_time);

ANALYZE public.ship_track;

COMMIT;
