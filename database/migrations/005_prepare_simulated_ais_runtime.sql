BEGIN;

-- Preserve the original current-position snapshot before the first simulated
-- real-time update.  The table is created only once and is not refreshed on
-- later runs, so it remains a stable recovery point.
CREATE TABLE IF NOT EXISTS public.ship_position_before_simulated_realtime
(LIKE public.ship_position INCLUDING ALL);

INSERT INTO public.ship_position_before_simulated_realtime
SELECT position.*
FROM public.ship_position AS position
WHERE NOT EXISTS (
    SELECT 1
    FROM public.ship_position_before_simulated_realtime AS backup
    WHERE backup.id = position.id
);

-- These indexes keep repeated history checks and per-vessel track queries fast.
CREATE INDEX IF NOT EXISTS ship_track_mmsi_time_idx
ON public.ship_track (mmsi, update_time DESC);

CREATE INDEX IF NOT EXISTS ship_position_mmsi_idx
ON public.ship_position (mmsi);

COMMIT;

SELECT
    count(*) AS preserved_position_count
FROM public.ship_position_before_simulated_realtime;
