# Database source and change workflow

The live local database is `Oman_Oil_Monitor`. The SQL files in this directory are
the version-controlled source for its structure and simulated content. The database
itself and real AIS observations are not stored in GitHub.

## Files

- `schema.sql` - schema-only export of the current PostGIS database
- `seeds/` - ordered simulation scripts and an exact snapshot of current operational layers
- `reset_simulation.sql` - runs all seed scripts in the required order
- `reset_simulation.ps1` - guarded launcher that backs up before resetting simulation data
- `migrations/` - one reviewed SQL file for every future schema or data change
- `archive/` - superseded historical scripts retained for reference only
- `backup_database.ps1` - creates and validates an external custom-format backup
- `apply_migration.ps1` - backs up, then applies one migration with stop-on-error

The simulated AIS runtime uses migrations `003`, `004`, and `005` in order:

- `003_add_simulated_ais_motion.sql` creates routes and per-vessel motion state.
- `004_replace_shipping_routes_ocean_only.sql` installs the reviewed offshore routes.
- `005_prepare_simulated_ais_runtime.sql` preserves the pre-movement position snapshot
  and adds indexes used by real-time track updates.

## Safe workflow for every database change

1. Create a new file in `migrations/`, for example
   `20260810_001_add_data_source.sql`.
2. Put the change inside `BEGIN; ... COMMIT;` and make it idempotent when practical.
3. Apply it with:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\database\apply_migration.ps1 `
     -File .\database\migrations\20260810_001_add_data_source.sql
   ```

4. Verify the API and frontend, then commit the SQL and code together.

## Backup

Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\database\backup_database.ps1
```

Backups are written to `D:\oman\database-backup`, outside the Git repository.

## Rebuilding simulation data

`reset_simulation.ps1` deletes and recreates simulated vessel positions and tracks.
It can also remove real AIS rows stored in the same tables. Do not run it against a
production or irreplaceable database. It requires the explicit `-ConfirmReset` flag:

```powershell
powershell -ExecutionPolicy Bypass -File .\database\reset_simulation.ps1 -ConfirmReset
```

The script creates a verified backup before executing any destructive seed SQL.
It has not been run automatically on the current database.

## Fresh local database

For a newly created empty database with PostGIS available, apply `schema.sql`, then
run the seed scripts in `reset_simulation.sql`. The schema export is a baseline, not
a migration to re-run on an existing populated database.
