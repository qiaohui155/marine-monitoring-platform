BEGIN;

-- Vessels that are not close enough to a reviewed shipping route use a small
-- local operating circuit around their existing sea position.  These fields
-- keep that movement continuous without changing route_progress.
ALTER TABLE public.ship_motion_state
    ADD COLUMN IF NOT EXISTS local_progress double precision NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS local_radius_m double precision NOT NULL DEFAULT 0;

UPDATE public.ship_motion_state AS state
SET local_progress = (abs(hashtext(state.mmsi)) % 10000) / 10000.0,
    local_radius_m = CASE position.ship_type
        WHEN 'Fishing' THEN 120.0
        WHEN 'Passenger' THEN 180.0
        WHEN 'Tanker' THEN 250.0
        WHEN 'Cargo' THEN 250.0
        ELSE 150.0
    END,
    updated_at = CURRENT_TIMESTAMP
FROM public.ship_position AS position
WHERE position.mmsi = state.mmsi
  AND state.local_radius_m = 0;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'ship_motion_local_progress_check'
          AND conrelid = 'public.ship_motion_state'::regclass
    ) THEN
        ALTER TABLE public.ship_motion_state
            ADD CONSTRAINT ship_motion_local_progress_check
            CHECK (local_progress >= 0 AND local_progress <= 1);
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'ship_motion_local_radius_check'
          AND conrelid = 'public.ship_motion_state'::regclass
    ) THEN
        ALTER TABLE public.ship_motion_state
            ADD CONSTRAINT ship_motion_local_radius_check
            CHECK (local_radius_m >= 0 AND local_radius_m <= 5000);
    END IF;
END
$$;

COMMIT;

SELECT
    count(*) AS vessel_states,
    count(*) FILTER (WHERE local_radius_m > 0) AS local_motion_ready
FROM public.ship_motion_state;
