#!/bin/sh
# Once, when the database is first made. The app connects as lims_app, which can read and write rows but owns nothing,
# so it cannot disable the audit log's append-only triggers.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -v pw="$(cat /run/lims/app-password)" <<'SQL'
CREATE ROLE lims_app LOGIN PASSWORD :'pw';
GRANT CONNECT ON DATABASE lims TO lims_app;
GRANT USAGE ON SCHEMA public TO lims_app;
ALTER DEFAULT PRIVILEGES FOR ROLE lims_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lims_app;
ALTER DEFAULT PRIVILEGES FOR ROLE lims_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO lims_app;
SQL
