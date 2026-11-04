#!/bin/sh
# Runs once, when the database is first created. The app connects as lims_app, which can read and
# write rows but owns nothing, so it can't disable the audit log's append-only triggers.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE lims_app LOGIN PASSWORD '${LIMS_APP_PASSWORD}';
GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO lims_app;
GRANT USAGE ON SCHEMA public TO lims_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lims_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ${POSTGRES_USER} IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO lims_app;
SQL
