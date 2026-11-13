# Companies on the AWS production setup

How to put the first company on production, add each one after it, and take one off. Each company (lab) gets its
own database, its own file bucket with a copy in Hyderabad, its own settings, its own address and certificate, and
its own alarms; they share the servers, the database instance and the cache. Built with the Terraform in
[`terraform/`](../../terraform/README.md).

**Before the first company:** the shared setup is applied (`terraform/README.md`, "First time"), and the runbook's
eight app changes are released. Until then a company can be prepared (steps 1–4) but not started.

## Names used below

| Name | Example | Rule |
| --- | --- | --- |
| `<slug>` | `acme` | Lower-case letters, digits and hyphens, 2–20 characters. Never changed later |
| `<n>` | `1` | 1–15, unique, **never reused**, even after a company leaves. It is the company's Redis database, its ports (UI `8100+n`, API `3100+n`) and its routing priority |
| `<domain>` | `lims.acme.example` | The app's address. The API is `api.<domain>` |

What Terraform makes from those: bucket `lims-<slug>-files-<account-id>` (and `-dr-` in Hyderabad), settings under
`/lims/prod/<slug>/`, database `lims_<slug>` with roles `lims_<slug>_owner` and `lims_<slug>_app` (hyphens become
underscores). The roles carry the company's name because one RDS instance serves every company and role names are
shared across it.

## Add the first company

The first company also creates the load balancer's HTTPS listener (its certificate becomes the default), so its
certificate must be issued before the apply can finish.

### 1. Add it to Terraform

In `terraform/prod/terraform.tfvars`:

```hcl
labs = {
  acme = {
    number      = 1
    domain      = "lims.acme.example"
    dns_zone_id = null          # or its Route 53 hosted zone id
    image_tag   = "1.0.0"       # the release it runs
  }
}
```

### 2. Prove the domain

- **DNS in Route 53** (`dns_zone_id` set): nothing to do; Terraform adds the proof records and the two address
  records itself.
- **DNS elsewhere:** request the certificate first, add its two proof records at the DNS provider, then go on:

```bash
terraform apply -target='aws_acm_certificate.lab["acme"]'
terraform output -json certificate_validation      # two CNAME records: add both at the DNS provider
```

### 3. Apply

```bash
terraform plan -out=tfplan     # read it: only acme's resources and the HTTPS listener should be new
terraform apply tfplan
```

With DNS elsewhere, the apply waits at `aws_acm_certificate_validation` until the certificate is issued (usually
a few minutes after the records appear). Then add two CNAME records at the DNS provider: `<domain>` and
`api.<domain>`, both to the `load_balancer_dns` output.

### 4. Add its integration secrets

Only what the company uses; they stay out of the Terraform state:

```bash
P=/lims/prod/acme
aws ssm put-parameter --type String       --name $P/SMTP_HOST     --value email-smtp.ap-south-1.amazonaws.com
aws ssm put-parameter --type String       --name $P/SMTP_PORT     --value 587
aws ssm put-parameter --type String       --name $P/SMTP_USER     --value <ses-smtp-user>
aws ssm put-parameter --type SecureString --name $P/SMTP_PASSWORD --value '<ses-smtp-password>'
aws ssm put-parameter --type String       --name $P/SMTP_FROM     --value 'Acme Labs <lab@acme.example>'
# WhatsApp and GST e-invoicing, if used: the WHATSAPP_* and EINVOICE_* names from .env.example
```

### 5. Create its database

From an app server in Session Manager (the database is private: a laptop cannot reach it). Read the passwords
Terraform generated, then connect as the master user, whose password is in Secrets Manager
(`rds_master_secret_arn` output):

```bash
P=/lims/prod/acme
OWNER_PW=$(aws ssm get-parameter --with-decryption --name $P/DB_OWNER_PASSWORD --query Parameter.Value --output text)
APP_PW=$(aws ssm get-parameter --with-decryption --name $P/DB_APP_PASSWORD --query Parameter.Value --output text)
docker run --rm -it postgres:18 psql "host=<rds_endpoint output> user=lims_master dbname=postgres sslmode=require"
```

```sql
CREATE ROLE lims_acme_owner LOGIN PASSWORD '<OWNER_PW>';
CREATE ROLE lims_acme_app   LOGIN PASSWORD '<APP_PW>';
GRANT lims_acme_owner TO lims_master;            -- RDS: the master may only create databases for roles it is in
CREATE DATABASE lims_acme OWNER lims_acme_owner;
REVOKE CONNECT ON DATABASE lims_acme FROM PUBLIC;
GRANT CONNECT ON DATABASE lims_acme TO lims_acme_app;
\c lims_acme
GRANT USAGE ON SCHEMA public TO lims_acme_app;
ALTER DEFAULT PRIVILEGES FOR ROLE lims_acme_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO lims_acme_app;
ALTER DEFAULT PRIVILEGES FOR ROLE lims_acme_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO lims_acme_app;
```

This is the same split as the containers' `compose/db-init.sh`: the app role reads and writes rows but owns nothing,
so it cannot disable the audit log's protections. The runbook's app change 4 turns these statements into one
command.

### 6. Run the migrations

Once, from one server, as the owner (`MIGRATION_DATABASE_URL`). The output must end with "All migrations have been
successfully applied". On RDS the owner creates the `pg_trgm` extension itself (it is a trusted extension).

### 7. Start it

```bash
terraform apply     # if app_servers_enabled was false until now, set it true first
aws autoscaling start-instance-refresh --auto-scaling-group-name lims-app
```

Servers read `/lims/prod/labs` at start, so a refresh brings the new company up one server at a time. Wait until
both of its target groups show 2 healthy targets.

### 8. First-run set-up

Open `https://<domain>`. Read the setup token:

```bash
aws ssm get-parameter --with-decryption --name /lims/prod/acme/SETUP_TOKEN --query Parameter.Value --output text
```

Enter it, create the company's first administrator (a named person, a strong password), and complete the wizard:
lab profile, branding, numbering, modules. The token only works while the company has no users, so it is harmless
afterwards.

### 9. Check

- [ ] The administrator signs in at `https://<domain>`
- [ ] Uploading a logo works, and the file appears in `lims-acme-files-<account-id>` (and in Hyderabad within 15 minutes)
- [ ] A quotation PDF downloads (proves the worker, Chromium and S3)
- [ ] A test email arrives
- [ ] Admin, Audit log shows the set-up
- [ ] The company's alarms exist and are OK: `aws cloudwatch describe-alarms --alarm-name-prefix lims-acme`
- [ ] The uptime checks are green: Route 53, Health checks, `lims-acme-ui` and `lims-acme-api`

For the first company only, also do the runbook's Step 10 go-live checks before real data arrives.

## Add another company

The same steps, with three differences:

1. Give it the next unused number. Never reuse a number, even one a departed company had.
2. Its certificate is added beside the first one; the listener and the servers already exist.
3. Step 7 is just the instance refresh: no other company stops while the servers are replaced one at a time.

```hcl
labs = {
  acme   = { number = 1, domain = "lims.acme.example",   dns_zone_id = null, image_tag = "1.0.0" }
  globex = { number = 2, domain = "lims.globex.example", dns_zone_id = null, image_tag = "1.0.0" }
}
```

`terraform plan` should show only `globex` resources, its certificate, and in-place changes to `/lims/prod/labs` and
the Auto Scaling group's target groups. Anything touching `acme` or the shared setup: stop and find out why.

**When to size up:** the defaults carry roughly 8–10 companies. Watch the server memory alarm and the database CPU
alarm; raise `app_instance_type` or `rds_instance_class` in `terraform.tfvars` and apply (RDS changes size during
its maintenance window unless applied immediately; the servers roll one at a time).

## Change a company's release

Set its `image_tag` and apply; that updates `/lims/prod/<slug>/version`. Then roll the servers (runbook,
"Releasing a new version"). Companies can run different releases.

## Remove a company

Removing a company deletes nothing by accident: its buckets have `prevent_destroy`, issued PDFs are locked by
Object Lock, and the database instance has deletion protection. Removal is a written decision with the company,
after their data is handed over.

1. Give the company its data: a database dump (`pg_dump -Fc` as its owner) and a copy of its bucket.
2. Note what must be kept by law (issued reports and invoices for their retention period): those stay locked in S3
   whatever happens next.
3. Stop it: remove its entry from `labs`, then instance refresh. Terraform will refuse to destroy its buckets
   (`prevent_destroy`): move them out of the state instead, so the data stays where it is:

```bash
terraform state rm 'module.lab["globex"].aws_s3_bucket.files' 'module.lab["globex"].aws_s3_bucket.files_dr'
terraform apply
```

4. Drop its database and roles (`DROP DATABASE lims_globex; DROP ROLE lims_globex_app, lims_globex_owner;`) once
   the dump is confirmed good, and record it.
5. Empty its buckets of everything not under retention when the contract says so; locked versions are removed by
   S3 only when their dates pass.
6. Its number is retired. Never give it to another company.
