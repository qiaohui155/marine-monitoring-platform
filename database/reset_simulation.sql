\set ON_ERROR_STOP on

\echo Rebuilding the simulated Oman marine monitoring dataset...
\ir seeds/01_ais_3000_realistic_postgis.sql
\ir seeds/02_add_oman_ship_positions.sql
\ir seeds/03_replace_oman_positions_ocean_only.sql
\ir seeds/04_add_arabian_sea_positions.sql
\ir seeds/05_replace_arabian_with_sparse_sea_points.sql
\ir seeds/06_regenerate_long_oman_ship_tracks.sql
\ir seeds/07_create_ship_track_lines_view.sql
\ir seeds/08_create_oman_sea_risk_index_layer.sql
\ir seeds/09_replace_oman_sea_risk_index_irregular.sql

TRUNCATE TABLE
    public.sea_risk_index,
    public.oil_spill_area,
    public.oil_spill_event,
    public.suspicious_ship,
    public.warning_area
RESTART IDENTITY CASCADE;

\ir seeds/10_operational_layers_snapshot.sql
\echo Simulation rebuild completed.
