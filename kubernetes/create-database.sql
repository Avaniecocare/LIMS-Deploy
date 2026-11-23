-- One company's database: the owner runs migrations, the app reads and writes rows and owns nothing, so it cannot disable
-- the audit log's protections. Roles carry the company's name because one instance serves every company.
SELECT format('CREATE ROLE %I LOGIN', :'db' || '_owner') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db' || '_owner') \gexec
SELECT format('CREATE ROLE %I LOGIN', :'db' || '_app') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'db' || '_app') \gexec
\set owner :db _owner
\set app :db _app
-- Verifiers, not passwords: what is sent and logged cannot be used to sign in.
ALTER ROLE :"owner" PASSWORD :'owner_verifier';
ALTER ROLE :"app" PASSWORD :'app_verifier';
-- On RDS the master may only make databases for roles it is in.
GRANT :"owner" TO CURRENT_USER;
SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'owner') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'db') \gexec
REVOKE CONNECT ON DATABASE :"db" FROM PUBLIC;
GRANT CONNECT ON DATABASE :"db" TO :"app";
\connect :"db"
SET ROLE :"owner";
GRANT USAGE ON SCHEMA public TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app";
ALTER DEFAULT PRIVILEGES FOR ROLE :"owner" IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"app";
