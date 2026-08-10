# Database migrations

Create one ordered SQL file for each future database change. Use a timestamp and a
short description, for example:

`20260810_001_add_data_source.sql`

Apply migrations with `database/apply_migration.ps1`. That launcher creates a verified
backup first and accepts only files from this directory. Never put passwords, API keys,
or real AIS records in a migration.
