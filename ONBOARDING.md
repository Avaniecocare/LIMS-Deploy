# Adding a new company

Allow about 30 minutes once the server is set up (see [DEPLOYMENT.md](DEPLOYMENT.md)).

## 1. Collect from the company

- Legal and trading names, GSTIN, PAN, CIN if any, state, SAC code and description
- Registered and lab addresses, phone, email, website, report verification email
- Bank account name, number, bank, branch, IFSC, SWIFT if any
- Logo and favicon, primary and accent colours
- Certification text, and whether NABL applies. If so, the certificate number and ULR format
- A short document number prefix
- Domains (`app.`, `api.` and `files.` under one domain) and SMTP details

## 2. Make their folder, outside this repository

```sh
SLUG=acme
mkdir -p /srv/lims-clients/$SLUG/branding
cd /opt/lims-deploy/clients/_template
cp company.env.example    /srv/lims-clients/$SLUG/company.env
cp deployment.env.example /srv/lims-clients/$SLUG/deployment.env
cp versions.env.example   /srv/lims-clients/$SLUG/versions.env
```

Fill in those three files, and put the logo and favicon in `branding/`. Double-quote every value. `S3_IMAGE` must be the storage image your organisation has chosen; see [DECISIONS.md](DECISIONS.md).

## 3. Point DNS

Create records for the three domains pointing at the server. TLS certificates need these to resolve.

## 4. Provision

```sh
/opt/lims-deploy/scripts/provision.sh --client-dir /srv/lims-clients/$SLUG
/opt/lims-deploy/scripts/install-backup-cron.sh --client-dir /srv/lims-clients/$SLUG
```

If a company value is wrong, the script stops and the log names the variable. Fix it and run the script again; it keeps secrets it already made.

Store a copy of `secrets.env` in your secrets store. If the folder is lost, the app cannot reach its own database and storage until those passwords are reset by hand.

## 5. First-run setup

Open `https://<app domain>`. The setup wizard asks for the `SETUP_TOKEN` from `secrets.env`, the first Admin, and the lab's operating settings: GST rate, credit days, working days, retention, and terms and conditions.

## 6. Hand over

As that Admin:

1. Check **Admin → Company** shows the right details.
2. Create users and give them roles.
3. Set up masters: departments, tests and parameters, methods, specifications, instruments, rates. Excel import works for most.
4. Book one test job through to an issued report and an invoice, and check the PDFs with the company.

## Demo data

For a trial only, add `--with-demo-data` to `provision.sh`. Before going live, remove it with:

```sh
/opt/lims-deploy/scripts/remove-demo.sh --client-dir /srv/lims-clients/$SLUG --yes
```

This removes demo users, customers, masters and everything recorded against them. The audit log keeps its history, since it is append-only.
